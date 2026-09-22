// AudioMixer: realtime-safe summing of the clips in an AudioGraph, driving the master Clock.
//
// Model
// - The non-realtime side turns an AudioGraph (Scheduler::audioGraphFor over a window around the
//   playhead) into an immutable Plan: per source, the sequence sample span it covers and its
//   gain segments (sample ranges with linear ramps), plus the transport (running, start sample,
//   audio rate, clock epoch). setGraph()/start()/stop() publish a new Plan; the render thread
//   adopts the newest one at the start of its next callback (one atomic exchange). Plans are
//   never freed on the render thread: the old plan goes into a lock-free retire queue that the
//   non-realtime side drains on its next call.
// - Sources (ClipAudioSource) are keyed by (track, asset, speed, sourceAtZero) and survive
//   re-planning: a model edit that leaves a clip's media mapping unchanged (trimming another
//   clip, changing gain, trimming this clip's far edge) keeps its decoded audio and plays on
//   without a glitch. New sources are positioned at max(their first sample, the playhead).
// - Positions are sequence samples at the mixer rate: sample n <-> time n / sampleRate.
//   Segment edges are rounded to the nearest sample (exact for 23.976/24/25/29.97/30/50/60 fps
//   grids at 48 kHz except 29.97's fractional 1601.6-sample frames, rounded).
//
// Envelopes (sample-accurate): sample gain = clipGain * fade(t) * crossfadeShape(c(t)), where
// fade and c are the linear ramps of AudioSegment and crossfadeShape(c) = sin(c * pi / 2): the
// constant-power law (outgoing sin((1 - f) pi/2) = cos(f pi/2), incoming sin(f pi/2); the powers
// sum to 1 across the transition). Ramps are evaluated per sample with vDSP_vramp / vvsinf.
//
// Rates: audioRate 1 renders the sequence as is; audioRate 2 mixes two sequence samples per
// output sample and averages each pair (a 2-tap box decimator, preview quality). The clock is
// advanced by output samples; it applies the rate.
//
// Underruns: when a source has not decoded the samples a callback needs, those samples are
// silent and the callback counts as an underrun (Stats::underruns, underrunFrames). The render
// thread never waits.
//
// Threading contract
// - Control methods (registerAsset, setGraph, clearGraph, start, stop, prime, waitForBuffered,
//   setMasterGain, stats, sampleFor): any non-realtime thread; serialised by an internal mutex.
//   prime()/waitForBuffered() block the caller (bounded by their timeout). stop() then prime()
//   is how a caller repositions: prime() must not be called while the transport runs.
// - render(): the audio render thread (or any single thread acting as one, e.g.
//   NullAudioOutput or a test). Realtime-safe: no locks, no allocation, no Objective-C, no
//   logging; vDSP/vForce only.
// - Destruction: stop the thread calling render() first (AudioOutput::stop or destroying it).

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
    double primeSeconds = 0.25; ///< Audio prime()/waitForBuffered() wait for, per source.
    int maxChunkFrames = 1024;  ///< Output frames mixed per internal step.
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
    };

    struct Stats {
        uint64_t renders = 0;       ///< render() calls.
        uint64_t renderedFrames = 0;
        uint64_t underruns = 0;     ///< Callbacks in which some source had no audio ready.
        uint64_t underrunFrames = 0;
        uint64_t planSwaps = 0;     ///< Plans adopted by the render thread.
        uint64_t sourcesCreated = 0;
        uint64_t retireOverflows = 0;
        int64_t position = 0; ///< Next sequence sample to render.
        bool running = false;
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

    // MARK: Control (non-realtime)

    /// Path (absolute POSIX) and optional routing for an asset's audio.
    void registerAsset(AssetId asset, std::string path, std::optional<media::RoutedMediaInfo> routed = std::nullopt);

    /// Replaces the mix plan with `graph` (segments of unknown assets are skipped). New sources
    /// start decoding at max(their first sample, sequenceTime).
    void setGraph(const AudioGraph &graph, CMTime sequenceTime);
    /// Removes every source (silence).
    void clearGraph();

    /// Starts rendering at `at` with `audioRate` (1 or 2), crediting `clockEpoch` (Clock::start's
    /// return value) with the rendered samples.
    void start(CMTime at, int audioRate, uint32_t clockEpoch);
    /// Stops rendering (silence; the clock is not advanced).
    void stop();
    bool isRunning() const;

    /// Positions every source that sounds within primeSeconds of `at` at `at` and waits until
    /// they have primeSeconds decoded (or up to their end), or `timeout`. Returns whether all
    /// were ready. Call with the transport stopped.
    bool prime(CMTime at, std::chrono::milliseconds timeout);
    /// Waits until every source sounding at the current render position has primeSeconds (or
    /// up to its end) decoded ahead of it, without repositioning. For tests and diagnostics.
    bool waitForBuffered(std::chrono::milliseconds timeout);

    void setMasterGain(float gain);
    float masterGain() const;

    /// Nearest sample to `t` at the mixer rate.
    int64_t sampleFor(CMTime t) const;

    Stats stats() const;

    // MARK: Realtime

    /// Renders `frames` interleaved frames. `channels` must equal channels() (otherwise silence).
    /// `hostNanos` is the host time of the callback for the clock (0: now).
    void render(float *interleaved, int frames, int channels, uint64_t hostNanos = 0) noexcept;

    /// Sequence sample at the start of the most recent render() (-1 before the first running one).
    int64_t lastRenderStartSample() const noexcept { return lastRenderStart_.load(std::memory_order_acquire); }
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

    void publish(std::unique_ptr<Plan> plan); // mutex_ held
    void drainRetired();                      // mutex_ held
    std::unique_ptr<Plan> copyLatest() const; // mutex_ held
    void mixChunk(const Plan &plan, int64_t position, int frames, float *mix, uint64_t &missing) noexcept;

    const std::shared_ptr<media::BackendRouter> router_;
    Clock *const clock_;
    const AudioMixerConfig config_;
    const int maxSequenceFrames_; // per chunk, at the highest audio rate

    // Non-realtime state (mutex_).
    mutable std::mutex mutex_;
    std::map<AssetId, AssetEntry> assets_;
    std::vector<SourceEntry> sources_;
    Plan *latest_ = nullptr; // newest published plan (owned by the handoff chain below)
    uint64_t transportSerial_ = 0;
    uint64_t sourcesCreated_ = 0;

    // Handoff to the render thread.
    std::atomic<Plan *> pending_{nullptr};
    SpscQueue<Plan *, 256> retired_;

    // Render-thread state.
    Plan *current_ = nullptr;
    uint64_t rtTransportSerial_ = 0;
    uint32_t rtEpoch_ = Clock::kAnyEpoch;
    int64_t rtPosition_ = 0;
    std::vector<float> mixScratch_;
    std::vector<float> readScratch_;
    std::vector<float> envelope_;
    std::vector<float> ramp_;
    std::vector<float> shape_;

    // Shared counters.
    std::atomic<float> masterGain_{1.0f};
    std::atomic<int64_t> position_{0};
    std::atomic<int64_t> lastRenderStart_{-1};
    std::atomic<bool> rtRunning_{false};
    std::atomic<int> rtAudioRate_{1};
    std::atomic<uint64_t> renders_{0};
    std::atomic<uint64_t> renderedFrames_{0};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> underrunFrames_{0};
    std::atomic<uint64_t> planSwaps_{0};
    std::atomic<uint64_t> retireOverflows_{0};
};

} // namespace ve::audio
