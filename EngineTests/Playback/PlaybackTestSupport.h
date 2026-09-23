// Harness for the playback controller tests: builds projects from the generated burn-in media,
// runs a PlaybackController over a NullAudioOutput (realtime, or manual with a virtual host
// clock for faster-than-real-time runs) or a ScriptedAudioOutput (the test renders every block
// at a host time of its choosing and can inject device events), and samples its frame source
// like the preview view would, reading the burn-in frame index of every presented layer.
#pragma once

#include "../../Engine/Audio/AudioOutput.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Model/Project.h"
#include "../../Engine/Playback/PlaybackController.h"
#include "../../Engine/Render/TextureCache.h"
#include "../Audio/AudioTestSupport.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ve::test {

/// An audio output the test drives: renderAt() renders one block whose first frame reaches the
/// "device" at the given host time (what AudioOutput passes from AudioTimeStamp.mHostTime), from
/// any single thread. start() can be gated (to model a slow device start) or made to fail, and
/// events can be injected from any thread, like AVAudioEngine's notifications.
class ScriptedAudioOutput final : public audio::IAudioOutput {
  public:
    ScriptedAudioOutput(audio::AudioMixer &mixer, int blockFrames, size_t captureFrames);

    media::Status start() override;
    void stop() override;
    bool isRunning() const override { return running_.load(std::memory_order_acquire); }
    void setMuted(bool muted) override { muted_.store(muted, std::memory_order_relaxed); }
    bool isMuted() const override { return muted_.load(std::memory_order_relaxed); }
    std::string kind() const override { return "scripted"; }
    double outputLatency() const override { return latency_.load(std::memory_order_relaxed); }
    void setEventHandler(audio::AudioOutputEventHandler handler) override;

    /// Renders one block (0 frames when stopped). Returns the frames rendered.
    int renderAt(uint64_t ioHostNanos);
    int blockFrames() const { return blockFrames_; }
    /// Delivers `event` to the handler on the calling thread (as the output's queue would).
    void emit(const audio::AudioOutputEvent &event);

    void setLatency(double seconds) { latency_.store(seconds, std::memory_order_relaxed); }
    /// start() blocks while the gate is closed (models a slow device start).
    void setStartGate(bool closed);
    std::atomic<bool> failStart{false};
    std::atomic<int> startAttempts{0}; ///< start() calls, counted before the gate.
    std::atomic<int> starts{0};        ///< start() calls that got past the gate.
    std::atomic<int> stops{0};

    /// Blocks in which the mixer rendered a transport (as NullAudioOutput::Capture).
    audio::NullAudioOutput::Capture capture() const;
    void resetCapture();

  private:
    audio::AudioMixer &mixer_;
    const int blockFrames_;
    const size_t captureFrames_;
    std::vector<float> buffer_;
    std::atomic<bool> running_{false};
    std::atomic<bool> muted_{false};
    std::atomic<double> latency_{0.0};
    std::mutex gateMutex_;
    std::condition_variable gateCv_;
    bool gateClosed_ = false;
    std::mutex handlerMutex_;
    audio::AudioOutputEventHandler handler_;
    mutable std::mutex captureMutex_;
    audio::NullAudioOutput::Capture capture_;
};

class PlaybackHarness {
  public:
    enum class Mode {
        Realtime, ///< NullAudioOutput on its own thread, system host clock.
        Manual,   ///< NullAudioOutput driven by renderBlocks(), virtual host clock.
        Scripted, ///< ScriptedAudioOutput driven by the test, virtual host clock.
    };

    /// `captureSeconds` of rendered audio are kept (sequence-sample aligned). `adjust` may change
    /// the controller configuration before it is created.
    PlaybackHarness(Mode mode, double captureSeconds,
                    const std::function<void(playback::PlaybackConfig &)> &adjust = nullptr);
    ~PlaybackHarness();

    bool ok() const { return error_.empty(); }
    const std::string &error() const { return error_; }

    // MARK: Project

    /// Probes a generated media file and adds it as an asset (routing handed to the controller).
    AssetId importAsset(const std::string &file);
    /// Same for a file at an absolute path (e.g. the MKV remuxes).
    AssetId importAssetAtPath(const std::string &path);
    /// A speed-1 clip; times in 30 fps sequence frames, `sourceIn` in source time.
    ClipId addClip(TrackId track, AssetId asset, int64_t startFrame, int64_t durationFrames, CMTime sourceIn);
    void link(ClipId a, ClipId b);
    void addTransition(TrackId track, ClipId from, ClipId to, int64_t frames);
    // Model edits (then publishEdit()).
    void setClipGain(ClipId clip, double gainDb);
    /// Moves `clip` to `track` keeping its times.
    void moveClipToTrack(ClipId clip, TrackId track);
    /// Changes the source in point, keeping the clip's place and length on the timeline.
    void slipClip(ClipId clip, CMTime sourceIn);
    /// Validation problem, if any.
    std::optional<std::string> problem() const;
    Sequence &sequence() { return *project.findSequence(sequenceId); }
    /// setSequence with a snapshot of `project`.
    void load();
    /// modelChanged with a snapshot of `project`.
    void publishEdit();

    // MARK: Frame source

    struct Sample {
        bool changed = false;
        CMTime clockBefore = kCMTimeInvalid; ///< Clock read just before / after the call.
        CMTime clockAfter = kCMTimeInvalid;
        playback::PresentedFrame presented;
        std::vector<std::optional<int>> burnIns; ///< Per layer of the current frame.
        std::vector<ClipId> clips;
    };
    /// Calls the frame source once (targetTimestamp 0: "now").
    Sample present();
    /// Calls the frame source for a vsync presented at host time `targetSeconds` (the clock's
    /// host time base, like CADisplayLink.targetTimestamp).
    Sample presentAt(double targetSeconds);
    /// Presents until the current frame is presented (not held back while it decodes) with every
    /// layer showing its exact frame (or `timeout`); returns the last sample.
    Sample presentExact(std::chrono::milliseconds timeout = std::chrono::seconds(5));

    /// Expected source frame slot of `clip` at sequence frame `index` (independent of the
    /// scheduler: speed-1 arithmetic on the asset's frame grid).
    int64_t expectedSlot(ClipId clip, int64_t sequenceFrame) const;

    // MARK: Gates (deterministic conditions, bounded by generous timeouts)

    /// Polls until the controller is in `state` (true) or `timeout` passes (false).
    bool waitForState(playback::PlaybackState state, std::chrono::milliseconds timeout = std::chrono::seconds(10));
    /// play() and wait for Playing; returns the time play() took on this thread (ms), or -1 if
    /// Playing was not reached.
    double playAndWait(std::chrono::milliseconds timeout = std::chrono::seconds(10));
    /// Polls `condition` every millisecond until it holds or `timeout` passes.
    static bool waitUntil(const std::function<bool()> &condition,
                          std::chrono::milliseconds timeout = std::chrono::seconds(10));

    // MARK: Parts

    Project project;
    SequenceId sequenceId;
    TrackId v1, v2, a1;
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache;
    std::shared_ptr<media::DecodePool> pool;
    std::shared_ptr<audio::HostClock> host;
    audio::NullAudioOutput *output = nullptr;       // owned by the controller (Realtime, Manual)
    ScriptedAudioOutput *scripted = nullptr;        // owned by the controller (Scripted)
    std::unique_ptr<playback::PlaybackController> controller;

  private:
    Sample presentWith(const render::PreviewFrameRequest &request);

    std::string error_;
    render::TextureCache textures_;
    render::PreviewFrameSource source_;
    render::PreviewFrame frame_;
};

/// A controller over the tone backend (AudioTestSupport: synthetic audio whose decoder reads can
/// be blocked) and a ScriptedAudioOutput on a virtual host clock: an audio-only sequence of
/// `clipCount` 10 s tone clips on A1, back to back, at 30 fps.
class ToneRig {
  public:
    explicit ToneRig(int clipCount = 1, const std::function<void(playback::PlaybackConfig &)> &adjust = nullptr);
    ~ToneRig();
    ToneRig(const ToneRig &) = delete;
    ToneRig &operator=(const ToneRig &) = delete;

    Sequence &sequence() { return *project.findSequence(sequenceId); }
    /// setSequence / modelChanged with a snapshot of `project`.
    void load();
    void publish();
    /// Renders one block whose IO time is one block after the current virtual time, then
    /// advances the virtual clock by one block (a device callback, as AudioOutput stamps it).
    void renderBlock();
    /// A thread calling renderBlock() every `period` of wall time (default: ~5x real time).
    void startPump(std::chrono::microseconds period = std::chrono::microseconds(2000));
    void stopPump();
    bool waitForState(playback::PlaybackState state, std::chrono::milliseconds timeout = std::chrono::seconds(10));
    /// Sum of the producer wake-ups of the mixer's sources.
    uint64_t producerWakeups() const;

    std::shared_ptr<ToneBehavior> tones;
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache;
    std::shared_ptr<media::DecodePool> pool;
    std::shared_ptr<audio::HostClock> host;
    ScriptedAudioOutput *out = nullptr; // owned by the controller
    std::unique_ptr<playback::PlaybackController> controller;
    Project project;
    SequenceId sequenceId;
    std::vector<AssetId> assets;
    std::vector<ClipId> clips;

  private:
    std::atomic<bool> pumping_{false};
    std::thread pump_;
};

/// Sequence time of a frame index at 30 fps.
inline CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

} // namespace ve::test
