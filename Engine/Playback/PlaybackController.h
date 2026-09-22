// PlaybackController: transport (play/pause/seek/rate/step/scrub), pre-roll, A/V sync and the
// preview frame source for one sequence.
//
// Ownership: owns the Clock (inside a shared core that the frame source also holds), the
// AudioMixer and the audio output; shares the BackendRouter, FrameCache and DecodePool with the
// rest of the engine. The model is given as immutable snapshots (std::shared_ptr<const
// Project>): setSequence() picks the project and sequence, modelChanged() hands over the edited
// snapshot and re-plans decode targets and the audio mix without stopping playback (sources
// whose media mapping is unchanged keep playing, so edits elsewhere do not glitch the clip under
// the playhead).
//
// Timing: the audio sample clock is master at 1x and 2x (audio audible, AudioSamples clock
// mode). Reverse, |rate| > 2, a muted controller, or a failed output use the host-time clock
// (video only). Video never waits: every vsync the frame source reads the clock (at the display
// link's target presentation time when available), snaps it down to the sequence frame grid,
// resolves the RenderGraph and shows the cached picture of each layer; a layer whose frame is
// not decoded yet keeps its previous picture (counted as late) and the next vsync tries again.
// Frames skipped beyond what the rate explains are counted as dropped.
//
// Pre-roll (play): decode targets are set for the start time, the mixer positions its sources
// there, then the caller waits up to Config::prerollTimeout for the first video frames and
// mixer.prime before the clock and the audio start together. State is Prerolling meanwhile.
//
// JKL: setRate(r) with r in [-8, 8] (0 pauses); shuttleForward()/shuttleReverse() step through
// 1, 2, 4, 8 in one direction (the other direction's key restarts at 1). Audio plays at 1x and
// 2x (2x: pitched up, decimated); it is muted above 2x and in reverse.
//
// End of sequence: forward playback stops on the last frame (reverse on frame 0) and the
// controller pauses there. play() at the last frame restarts from the beginning.
//
// Threading contract
// - Public control methods (setSequence, modelChanged, setAssetRouting, play, pause, togglePlay,
//   seek, setRate, shuttle*, stepFrames, scrubTo, endScrub, setMuted, setObserver): any thread
//   (normally main), serialised by an internal mutex. play() and seek() during playback block
//   the caller for at most the pre-roll timeout. None of them waits for the render thread.
// - Readers (currentTime, state, rate, stats, lastPresented): any thread.
// - The frame source runs on the preview view's render thread; it never blocks (it takes no
//   lock the control side holds for more than a pointer copy, does no I/O and never waits for
//   decoding). It holds the FrameCache pins of the frame it returned until it returns the next
//   one.
// - A private tick thread (while playing) retargets the DecodePool every ~100 ms of sequence
//   time, re-plans the audio mix every second, detects the sequence end and posts observer
//   updates.
// - Observer callbacks run on the caller-chosen dispatch queue: statusChanged at most once per
//   displayed frame (coalesced: never more than one pending block), needsDisplay whenever the
//   paused/scrubbed picture changed (the facade then calls -[VEPreviewView renderOnce]).
//
// Facade wiring:
//   auto controller = std::make_unique<PlaybackController>(router, frameCache, decodePool);
//   controller->setSequence(projectSnapshot, sequenceId);
//   [previewView setFrameSource:controller->frameSource()];
//   controller->setObserver(dispatch_get_main_queue(), {
//       .statusChanged = [view](const PlaybackStatus &s) { view.paused = s.state != PlaybackState::Playing; ... },
//       .needsDisplay = [view] { [view renderOnce]; }});
//   // after every edit: controller->modelChanged(newSnapshot);
//   // before destroying the controller: [previewView setFrameSource:{}];

#pragma once

#include "../Audio/AudioMixer.h"
#include "../Audio/AudioOutput.h"
#include "../Audio/Clock.h"
#include "../Media/BackendRouter.h"
#include "../Media/DecodePool.h"
#include "../Media/FrameCache.h"
#include "../Model/Project.h"
#include "../Render/PreviewFrame.h"

#include <dispatch/dispatch.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ve::playback {

enum class PlaybackState {
    Stopped,    ///< Paused (showing displayTime).
    Prerolling, ///< play() is waiting for the first frames and audio.
    Playing,
    Scrubbing,  ///< scrubTo() in progress; ends with endScrub(), play() or seek().
};

const char *nameOf(PlaybackState state);

enum class SeekMode {
    /// The displayed frame converges on the exact frame at the time (during playback:
    /// restart with pre-roll).
    Exact,
    /// Scrub semantics: coalesced decode requests (only the latest per asset survives), the
    /// previous picture stays up until the new one lands, sequential decode streams are not
    /// retargeted. The decoder interfaces expose no sync-sample index, so the picture is still
    /// the exact frame, just reached through the cheapest path.
    NearestKeyframeFast,
};

struct PlaybackStatus {
    CMTime time = kCMTimeZero; ///< currentTime() at the moment of the update.
    PlaybackState state = PlaybackState::Stopped;
    double rate = 1.0;
};

struct PlaybackObserver {
    std::function<void(const PlaybackStatus &)> statusChanged;
    std::function<void()> needsDisplay;
};

struct ActiveClipInfo {
    ClipId clip;
    AssetId asset;
    bool isAudio = false;
    std::string backend;
    bool hardware = false;
    bool failed = false;
};

struct PlaybackStats {
    double fps = 0.0; ///< Presented frames per second (moving average, while playing).
    uint64_t presentedFrames = 0;
    uint64_t droppedFrames = 0; ///< Sequence frames skipped beyond what the rate explains.
    uint64_t lateFrames = 0;    ///< Presentations missing a frame (previous picture held).
    uint64_t cacheHits = 0;     ///< Frame source lookups.
    uint64_t cacheMisses = 0;
    double cacheHitRate = 0.0;
    int decodeQueueDepth = 0; ///< Busy decode streams + pending scrub requests.
    uint64_t audioUnderruns = 0;
    uint64_t audioUnderrunFrames = 0;
    bool audioActive = false;
    std::string audioOutput; ///< IAudioOutput::kind().
    audio::ClockMode clockMode = audio::ClockMode::Stopped;
    CMTime clockTime = kCMTimeZero;
    size_t cacheBytes = 0;
    std::vector<ActiveClipInfo> activeClips;
};

/// What the frame source returned last (tests and the debug HUD).
struct PresentedLayer {
    ClipId clip;
    AssetId asset;
    int64_t wantedIndex = 0; ///< FrameCache slot of the exact frame.
    int64_t shownIndex = -1; ///< Slot actually shown (-1: nothing).
    bool exact = false;
};
struct PresentedFrame {
    uint64_t serial = 0; ///< Increments per returned frame.
    CMTime time = kCMTimeInvalid; ///< Clock (or display) time the frame was chosen for.
    int64_t frameIndex = -1;      ///< Sequence frame index.
    bool clockDriven = false;
    std::vector<PresentedLayer> layers;
};

struct PlaybackConfig {
    audio::AudioMixerConfig mixer;
    /// Creates the output pulling from the mixer. Default: AutomaticAudioOutput (AVAudioEngine,
    /// falling back to a realtime NullAudioOutput without a device).
    std::function<std::unique_ptr<audio::IAudioOutput>(audio::AudioMixer &, audio::Clock &)> makeOutput;
    /// Host time source of the clock (default: system). Tests use a virtual one with a manual
    /// NullAudioOutput to run faster than real time.
    std::shared_ptr<audio::HostClock> hostClock;
    CMTime decodeLookahead = CMTimeMake(1, 1);
    std::chrono::milliseconds prerollTimeout{300};
    double audioHorizonSeconds = 5.0;   ///< Audio plan window ahead of the playhead.
    double audioReplanSeconds = 1.0;    ///< Re-plan when the playhead moved this far.
    double retargetSeconds = 0.1;       ///< DecodePool retarget interval (sequence time).
    std::chrono::milliseconds tickInterval{4};
};

class PlaybackController {
  public:
    PlaybackController(std::shared_ptr<media::BackendRouter> router, std::shared_ptr<media::FrameCache> cache,
                       std::shared_ptr<media::DecodePool> pool, PlaybackConfig config = {});
    ~PlaybackController();
    PlaybackController(const PlaybackController &) = delete;
    PlaybackController &operator=(const PlaybackController &) = delete;

    // MARK: Model

    /// Selects the sequence to play (stops playback, moves to frame 0).
    void setSequence(std::shared_ptr<const Project> project, SequenceId sequenceId);
    /// The model changed (same sequence id): re-plan without stopping playback.
    void modelChanged(std::shared_ptr<const Project> project);
    /// Routing computed at import (saves a probe per decoder).
    void setAssetRouting(AssetId asset, media::RoutedMediaInfo routed);

    // MARK: Transport

    void play();
    void pause();
    void togglePlay();
    void seek(CMTime time, SeekMode mode = SeekMode::Exact);
    /// 0 pauses; otherwise plays at `rate` (clamped to [-8, 8]).
    void setRate(double rate);
    /// L: 1 -> 2 -> 4 -> 8 forward (from reverse or stopped: 1).
    void shuttleForward();
    /// J: -1 -> -2 -> -4 -> -8.
    void shuttleReverse();
    /// Pauses and moves by `frames` sequence frames (clamped to the sequence).
    void stepFrames(int frames);
    /// Shows the frame at `time` as soon as it can be decoded (coalescing), no audio.
    void scrubTo(CMTime time);
    void endScrub();
    /// Mutes audio: playback then runs on the host-time clock without decoding audio.
    void setMuted(bool muted);
    bool isMuted() const;

    // MARK: State

    /// Clock time (playing) or the paused/scrub position, snapped down to the sequence frame
    /// grid and clamped to the sequence.
    CMTime currentTime() const;
    PlaybackState state() const;
    double rate() const;
    PlaybackStats stats() const;
    PresentedFrame lastPresented() const;

    void setObserver(dispatch_queue_t queue, PlaybackObserver observer);

    /// The source to install with -[VEPreviewView setFrameSource:]. Each call returns an
    /// independent source (its own pins and change tracking) over the same clock and model.
    render::PreviewFrameSource frameSource();

    // MARK: Components (tests, HUD)

    audio::Clock &clock();
    audio::AudioMixer &mixer() { return *mixer_; }
    audio::IAudioOutput &output() { return *output_; }

    struct Core;
    struct ObserverHub;

  private:
    const Sequence *sequenceLocked() const;
    CMTime lastFrameStartLocked() const;
    CMTime clampLocked(CMTime t) const;
    void publishDisplayLocked();
    void startPlaybackLocked(CMTime at, double rate);
    void stopPipelineLocked();
    void pauseLocked(std::optional<CMTime> at = std::nullopt);
    void retargetLocked(CMTime at, double rate);
    void planAudioLocked(CMTime at);
    void requestDisplayFramesLocked(CMTime at);
    void registerAssetsLocked();
    void postStatusLocked();
    void postNeedsDisplay();
    void tickMain();
    CMTime nowLocked() const;

    const std::shared_ptr<media::BackendRouter> router_;
    const std::shared_ptr<media::FrameCache> cache_;
    const std::shared_ptr<media::DecodePool> pool_;
    const PlaybackConfig config_;

    // Declaration order matters: the output is destroyed before the mixer, the mixer before the
    // core (whose clock it advances).
    std::shared_ptr<Core> core_;
    std::shared_ptr<ObserverHub> hub_;
    std::unique_ptr<audio::AudioMixer> mixer_;
    std::unique_ptr<audio::IAudioOutput> output_;

    mutable std::mutex mutex_;
    std::condition_variable tickCv_;
    std::shared_ptr<const Project> project_;
    SequenceId sequenceId_;
    PlaybackState state_ = PlaybackState::Stopped;
    double rate_ = 1.0;
    bool muted_ = false;
    bool audioActive_ = false;
    CMTime displayTime_ = kCMTimeZero;
    CMTime lastRetarget_ = kCMTimeInvalid;
    CMTime audioPlannedAt_ = kCMTimeInvalid;
    int64_t lastPostedFrame_ = -1;
    std::map<AssetId, std::string> registeredPaths_;
    std::map<AssetId, media::RoutedMediaInfo> routing_;
    bool stopTick_ = false;
    std::thread tickThread_;
};

} // namespace ve::playback
