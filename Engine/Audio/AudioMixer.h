// AudioMixer: realtime-safe summing of the clips in an AudioGraph, driving the master Clock.
//
// Model
// - The non-realtime side turns an AudioGraph (Scheduler::audioGraphFor over a window around the
//   playhead) into an immutable Plan: per source, the sequence sample span it covers and its
//   gain segments (sample ranges with linear ramps), plus the transport (running, start sample,
//   audio rate, clock epoch). setGraph()/start()/changeRate()/stop() publish a new Plan; the
//   render thread adopts the newest one at the start of its next callback (one atomic
//   exchange). Plans are never freed on the render thread: replaced plans go into a lock-free
//   retire queue, and everything the control side drops (plans, sources) is destroyed by
//   collectGarbage() on a background reaper queue, never on a control caller's thread and
//   never under the mixer's mutex (destroying a source joins its producer, which may be inside
//   a slow decoder call).
// - Sources (ClipAudioSource) are keyed by (track, asset, speed, sourceAtZero) and survive
//   re-planning: a model edit that leaves a clip's media mapping unchanged (trimming another
//   clip, changing gain, trimming this clip's far edge, moving it to another track) keeps its
//   decoded audio and plays on without a glitch.
// - Positioning. While the transport is stopped, setGraph() positions every source (new or
//   reused) at max(its first sample, the playhead), unless it already sits exactly there, so
//   no clip head is ever skipped after a seek (a reused source may have been consumed past its
//   head by an earlier run). While running, reused sources are left alone (they are playing)
//   and new ones start at max(their first sample, playhead, render position).
// - Positions are sequence samples at the mixer rate: sample n <-> time n / sampleRate.
//   Segment edges are rounded to the nearest sample (exact for 23.976/24/25/29.97/30/50/60 fps
//   grids at 48 kHz except 29.97's fractional 1601.6-sample frames, rounded).
//
// Envelopes (sample-accurate): sample gain = clipGain * fade(t) * crossfadeShape(c(t)), where
// fade and c are the linear ramps of AudioSegment and crossfadeShape(c) = sin(c * pi / 2): the
// constant-power law (outgoing sin((1 - f) pi/2) = cos(f pi/2), incoming sin(f pi/2); the powers
// sum to 1 across the transition). That is the audio half of TransitionKind::CrossDissolve,
// the only transition kind (Transition.h, and constantPowerGain in RenderGraph.h); should the
// model add other kinds or curves, AudioSegment has to carry the choice and PlanSegment select
// the shape here. Ramps are evaluated per sample with vDSP_vramp / vvsinf.
//
// De-clicking (config.rampSeconds, 5 ms by default)
// - stop(): the running transport keeps rendering for one ramp with a linear fade to silence,
//   then stops (stopCompleted() reports when the render thread is done with it; only then may
//   its sources be repositioned without cutting the fade short).
// - A new plan for the same transport (an edit, a periodic re-plan) crossfades every source's
//   envelope from the old plan to the new one over one ramp: gain edits ramp instead of
//   stepping, a clip removed under the playhead fades out, one inserted fades in.
// - setMuted()/setMasterGain() ramp the output gain over one ramp.
// Starting a transport is not faded in: sample-accurate onsets are part of the A/V contract.
//
// Rates: audioRate 1 renders the sequence as is. audioRate 2 mixes two sequence samples per
// output sample and decimates with a 63-tap half-band low-pass (Blackman-windowed sinc; > 60 dB
// rejection of what would alias), which delays the output by processingLatency(2) (the clock's
// output latency should include it). changeRate() switches between 1 and 2 without a gap: the
// render thread continues from its position and reports it as the clock's continuation origin.
// The clock is advanced by output samples; it applies the rate.
//
// Underruns: when a source has not decoded the samples a callback needs, those samples are
// silent and the callback counts as an underrun (Stats::underruns, underrunFrames). The render
// thread never waits.
//
// Threading contract
// - Control methods (registerAsset, setGraph, clearGraph, start, changeRate, stop, prepare,
//   isPrimed, stopCompleted, setMasterGain, setMuted, stats, sampleFor, collectGarbage): any
//   non-realtime thread; serialised by an internal mutex held only for bookkeeping (source
//   construction starts a thread; nothing waits for I/O or for another thread). None blocks.
// - prime()/waitForBuffered(): blocking helpers for tests and offline tools (bounded by their
//   timeout); the playback controller never calls them.
// - render(): the audio render thread (or any single thread acting as one, e.g.
//   NullAudioOutput or a test). Realtime-safe: no locks, no allocation, no Objective-C, no
//   logging; vDSP/vForce only (and ClipAudioSource's semaphore signal).
// - Destruction: stop the thread calling render() first (AudioOutput::stop or destroying it).
//   The destructor waits for the reaper queue.

#pragma once

#include "../Media/BackendRouter.h"
#include "../Model/Ids.h"
#include "../Render/RenderGraph.h"
#include "Clock.h"
#include "ClipAudioSource.h"
#include "Realtime.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace ve::audio {

struct AudioMixerConfig {
    double sampleRate = 48000.0;
    int channels = 2;
    double lookaheadSeconds = 2.0; ///< Per source.
    double refillSeconds = 1.5;
    double primeSeconds = 0.25; ///< Audio prepare()/isPrimed() cover, per source.
    int maxChunkFrames = 1024;  ///< Output frames mixed per internal step.
    double rampSeconds = 0.005; ///< Stop fade, plan crossfade and output gain ramps.
};

class AudioMixer {
  public:
    struct SourceInfo {
        AssetId asset;
        TrackId track;
        std::string backend;
        std::string error;
        bool failed = false;
        int64_t bufferedFrames = 0;
        uint64_t repositions = 0;
        uint64_t wakeups = 0; ///< Producer thread wake-ups (ClipAudioSource::Stats::wakeups).
        /// Sequence sample from which the source played silence because its decoder failed
        /// (failedSourceIn: within the queried range; stats(): the read failure's, -1 if none).
        int64_t failedAt = -1;
    };

    struct Stats {
        uint64_t renders = 0; ///< render() calls.
        uint64_t renderedFrames = 0;
        uint64_t underruns = 0; ///< Callbacks in which some source had no audio ready.
        uint64_t underrunFrames = 0;
        uint64_t planSwaps = 0; ///< Plans adopted by the render thread.
        uint64_t sourcesCreated = 0;
        uint64_t sourcesReused = 0; ///< Sources carried into a new plan (incl. track moves).
        uint64_t repositionsWhileStopped = 0; ///< Reused sources setGraph() moved back to their head.
        uint64_t stopFades = 0;  ///< Transports faded out by stop().
        uint64_t planBlends = 0; ///< Envelope crossfades between plans of one transport.
        uint64_t retireOverflows = 0;
        uint64_t garbageBatches = 0; ///< Batches handed to the reaper queue.
        int64_t position = 0;        ///< Next sequence sample to render.
        bool running = false;        ///< The render thread rendered a transport last callback.
        int audioRate = 1;
        std::vector<SourceInfo> sources;
    };

    /// `clock` (may be null) receives advanceSamples from render(); it must outlive the mixer.
    AudioMixer(std::shared_ptr<media::BackendRouter> router, Clock *clock, AudioMixerConfig config = {});
    ~AudioMixer();
    AudioMixer(const AudioMixer &) = delete;
    AudioMixer &operator=(const AudioMixer &) = delete;

    double sampleRate() const { return config_.sampleRate; }
    int channels() const { return config_.channels; }
    const AudioMixerConfig &config() const { return config_; }

    // MARK: Control (non-realtime, non-blocking)

    /// Path (absolute POSIX) and optional routing for an asset's audio.
    void registerAsset(AssetId asset, std::string path, std::optional<media::RoutedMediaInfo> routed = std::nullopt);

    /// Replaces the mix plan with `graph` (segments of unknown assets are skipped); positions
    /// sources as described in the header, with `sequenceTime` as the playhead.
    void setGraph(const AudioGraph &graph, CMTime sequenceTime);
    /// Removes every source (silence).
    void clearGraph();

    /// Starts rendering at `at` with `audioRate` (1 or 2), crediting `clockEpoch` (Clock::start's
    /// return value) with the rendered samples.
    void start(CMTime at, int audioRate, uint32_t clockEpoch);
    /// While running: continues from the render position at `audioRate` (1 or 2), crediting
    /// `clockEpoch` (Clock::startContinuation's return value), without a gap. Returns false (and
    /// does nothing) when the transport is not running.
    bool changeRate(int audioRate, uint32_t clockEpoch);
    /// Stops rendering after a fade-out of config().rampSeconds (the clock is no longer
    /// advanced for this transport). Returns the stop's serial for stopCompleted().
    uint64_t stop();
    /// The render thread has finished the fade of stop() `serial` (or of a later stop). Only
    /// meaningful while something calls render().
    bool stopCompleted(uint64_t serial) const noexcept;
    bool isRunning() const;

    /// Positions every source that sounds within primeSeconds of `at` at max(its first sample,
    /// `at`) unless it is already there. Call with the transport stopped.
    void prepare(CMTime at);
    /// Every source sounding within primeSeconds of `at` has that much decoded from
    /// max(its first sample, `at`) (or up to its end). Non-blocking.
    bool isPrimed(CMTime at) const;
    /// prepare() then waits (polling) until isPrimed() or `timeout`. Blocking: tests and tools.
    bool prime(CMTime at, std::chrono::milliseconds timeout);
    /// Waits until every source sounding at the current render position has primeSeconds (or
    /// up to its end) decoded ahead of it, without repositioning. Blocking: tests and tools.
    bool waitForBuffered(std::chrono::milliseconds timeout);

    /// Offline rendering (OfflineAudioRenderer): every source of the newest plan that sounds
    /// within sequence samples [from, from + frames) has decoded that part (or can only produce
    /// silence there: its decoder failed, or the media ended). Non-blocking.
    bool isRangeReady(int64_t from, int64_t frames) const;
    /// The first source of the newest plan sounding within [from, from + frames) that renders
    /// silence there because its decoder failed: it could not be opened, or a read or seek failed
    /// at or before a sample of the range where the source sounds (ClipAudioSource::Stats::
    /// readFailedAt); SourceInfo::failedAt says from which sequence sample. nullopt otherwise.
    /// Playback ignores this (it keeps playing silence); the offline renderer fails the export.
    std::optional<SourceInfo> failedSourceIn(int64_t from, int64_t frames) const;
    /// Frames rendered as silence because a source was not ready (Stats::underrunFrames), without
    /// copying the stats. Any thread.
    uint64_t underrunFrames() const noexcept { return underrunFrames_.load(std::memory_order_relaxed); }

    void setMasterGain(float gain);
    float masterGain() const;
    /// Silences the output (ramped) while the transport and the clock keep running.
    void setMuted(bool muted);
    bool isMuted() const;

    /// Output delay the mixer adds at `audioRate` (the 2x decimation filter), in seconds.
    double processingLatency(int audioRate) const;

    /// Nearest sample to `t` at the mixer rate.
    int64_t sampleFor(CMTime t) const;

    /// Moves retired plans and dropped sources to the reaper queue, which destroys them in the
    /// background. Non-blocking; call regularly (the playback controller's tick thread does).
    void collectGarbage();

    Stats stats() const;

    // MARK: Realtime

    /// Renders `frames` interleaved frames. `channels` must equal channels() (otherwise silence).
    /// `hostNanos` is the host time at which the first frame reaches the device's IO boundary
    /// (0: now), passed on to the clock.
    void render(float *interleaved, int frames, int channels, uint64_t hostNanos = 0) noexcept;

    /// Sequence sample of the first frame of the transport rendered in the most recent render()
    /// (-1 before the first running one).
    int64_t lastRenderStartSample() const noexcept { return lastRenderStart_.load(std::memory_order_acquire); }
    /// The most recent render() rendered a transport (playing or fading out).
    bool lastRenderWasRunning() const noexcept { return rtRunning_.load(std::memory_order_acquire); }
    /// Next sequence sample render() will produce.
    int64_t position() const noexcept { return position_.load(std::memory_order_acquire); }

  private:
    struct PlanSegment {
        int64_t start = 0; // sequence samples [start, end)
        int64_t end = 0;
        double gainStart = 1.0; // clip gain * fade, linear over the segment
        double gainEnd = 1.0;
        bool crossfade = false;
        double crossfadeStart = 1.0; // linear crossfade parameter c, shaped by sin(c pi / 2)
        double crossfadeEnd = 1.0;
    };
    struct PlanSource {
        ClipAudioSource *source = nullptr;
        int64_t spanStart = 0;
        int64_t spanEnd = 0;
        uint32_t firstSegment = 0;
        uint32_t segmentCount = 0;
    };
    struct Plan {
        std::vector<PlanSource> sources;
        std::vector<PlanSegment> segments;
        std::vector<std::shared_ptr<ClipAudioSource>> owners;
        uint64_t transportSerial = 0;
        // The start() this transport descends from: changeRate() keeps it, so the render thread
        // continues (rather than restarts) a transport with the live one's base.
        uint64_t baseSerial = 0;
        bool running = false;
        int64_t startSample = 0;
        int audioRate = 1;
        uint32_t clockEpoch = Clock::kAnyEpoch;
    };
    struct SourceEntry {
        TrackId track;
        std::shared_ptr<ClipAudioSource> source;
    };
    struct AssetEntry {
        std::string path;
        std::optional<media::RoutedMediaInfo> routed;
    };
    struct Garbage {
        std::vector<Plan *> plans; // owned: deleted with the batch
        std::vector<std::shared_ptr<ClipAudioSource>> sources;
        Garbage() = default;
        Garbage(Garbage &&) noexcept = default;
        Garbage &operator=(Garbage &&) noexcept = default;
        Garbage(const Garbage &) = delete;
        Garbage &operator=(const Garbage &) = delete;
        ~Garbage();
        bool empty() const { return plans.empty() && sources.empty(); }
    };

    void publish(std::unique_ptr<Plan> plan); // mutex_ held
    void reclaimRetired();                    // mutex_ held
    std::unique_ptr<Plan> copyLatest() const; // mutex_ held
    struct Window {
        ClipAudioSource *source = nullptr; // owned by latest_ (valid while mutex_ is held)
        int64_t from = 0;
        int64_t frames = 0;
    };
    std::vector<Window> primeWindows(int64_t s) const; // mutex_ held

    // Render thread.
    void retire(Plan *plan) noexcept;
    void adopt(Plan *next) noexcept;
    /// Renders `frames` output frames of `plan`'s transport from rtPosition_ into `out`
    /// (accumulating), advancing rtPosition_. Blends envelopes from blendPlan_ while a plan
    /// crossfade is in progress.
    void renderTransport(const Plan &plan, float *out, int frames, uint64_t &missing, bool blend) noexcept;
    void mixChunk(const Plan &plan, int64_t position, int frames, float *mix, uint64_t &missing, bool blend) noexcept;
    /// Gain envelope of `ps` over sequence samples [a, b) into env (zero outside its segments).
    static void envelope(const Plan &plan, const PlanSource &ps, int64_t a, int64_t b, float *env, float *ramp,
                         float *shape) noexcept;
    void decimate(const float *mix, int outFrames, float *out) noexcept;
    void updateHistory(const float *mix, int sequenceFrames) noexcept;

    const std::shared_ptr<media::BackendRouter> router_;
    Clock *const clock_;
    const AudioMixerConfig config_;
    const int maxSequenceFrames_; // per chunk, at the highest audio rate
    const int rampFrames_;        // config.rampSeconds at the mixer rate (>= 1)

    // Non-realtime state (mutex_).
    mutable std::mutex mutex_;
    std::map<AssetId, AssetEntry> assets_;
    std::vector<SourceEntry> sources_;
    Plan *latest_ = nullptr; // newest published plan (owned by the handoff chain below)
    uint64_t transportSerial_ = 0;
    uint64_t sourcesCreated_ = 0;
    uint64_t sourcesReused_ = 0;
    uint64_t repositionsWhileStopped_ = 0;
    uint64_t garbageBatches_ = 0;
    Garbage garbage_;
    struct Reaper; // serial background queue (defined in the .mm: keeps GCD types out of this header)
    std::unique_ptr<Reaper> reaper_;

    // Handoff to the render thread.
    std::atomic<Plan *> pending_{nullptr};
    SpscQueue<Plan *, 256> retired_;

    // Render-thread state.
    Plan *current_ = nullptr;
    Plan *fadePlan_ = nullptr;  // transport fading out after stop()
    int fadeDone_ = 0;          // output frames of the fade rendered
    Plan *blendPlan_ = nullptr; // previous plan of the live transport (envelope crossfade)
    int blendDone_ = 0;         // sequence samples of the crossfade rendered
    bool rtLive_ = false;       // rendering current_'s transport
    uint64_t rtBaseSerial_ = 0;
    uint32_t rtEpoch_ = Clock::kAnyEpoch;
    int64_t rtPosition_ = 0;
    float outGain_ = 1.0f;
    float gainTarget_ = 1.0f;
    float gainStep_ = 0.0f;
    int gainRampLeft_ = 0;
    std::vector<float> mixScratch_;
    std::vector<float> readScratch_;
    std::vector<float> envelope_;
    std::vector<float> oldEnvelope_;
    std::vector<float> ramp_;
    std::vector<float> shape_;
    std::vector<float> decimatorTaps_;
    std::vector<float> history_;    // per channel: the last (taps - 1) sequence samples
    std::vector<float> filterIn_;   // one channel: history + chunk
    std::vector<float> filterOut_;  // one channel: decimated chunk

    // Shared counters.
    std::atomic<float> masterGain_{1.0f};
    std::atomic<bool> muted_{false};
    std::atomic<int64_t> position_{0};
    std::atomic<int64_t> lastRenderStart_{-1};
    std::atomic<bool> rtRunning_{false};
    std::atomic<int> rtAudioRate_{1};
    std::atomic<uint64_t> rtStoppedSerial_{0};
    std::atomic<uint64_t> renders_{0};
    std::atomic<uint64_t> renderedFrames_{0};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> underrunFrames_{0};
    std::atomic<uint64_t> planSwaps_{0};
    std::atomic<uint64_t> retireOverflows_{0};
    std::atomic<uint64_t> stopFades_{0};
    std::atomic<uint64_t> planBlends_{0};
};

} // namespace ve::audio
