// PlaybackController: transport (play/pause/seek/rate/step/scrub), pre-roll, A/V sync and the
// preview frame source for one sequence.
//
// Ownership: owns the Clock (inside a shared core that the frame source also holds), the
// AudioMixer and the audio output; shares the BackendRouter, FrameCache and DecodePool with the
// rest of the engine. The model is given as immutable snapshots (std::shared_ptr<const
// Project>): setSequence() picks the project and sequence, modelChanged() hands over the edited
// snapshot and re-plans decode targets and the audio mix without stopping playback (sources
// whose media mapping is unchanged keep playing, so edits elsewhere do not glitch the clip under
// the playhead; a gain edit ramps over a few milliseconds).
//
// Timing: the audio sample clock is master at 1x and 2x (AudioSamples clock mode). Reverse,
// |rate| > 2 or an output that failed use the host-time clock (video only). Muting keeps the
// audio clock (the mixer ramps its output to silence). Video never waits: every vsync the frame
// source reads the clock at the display link's target presentation time (the view's
// PreviewFrameRequest::targetTimestamp, in the clock's host time base; "now" when 0), holds it
// monotonic within a clock epoch, snaps it down to the sequence frame grid, resolves the
// RenderGraph and shows the cached picture of each layer; a layer whose frame is not decoded
// yet (or cannot be mapped to a texture) keeps its previous picture (counted as late) and the
// next vsync tries again. Frames skipped beyond what the rate explains are counted as dropped.
//
// Asynchronous pre-roll. play(), a seek during playback, and a direction change publish state
// Prerolling and return at once (the paused picture of the target frame is requested at the
// same time). The private tick thread then: waits (bounded by Config::stopFadeTimeout) until
// the mixer has faded out the previous run, retargets the decode pool, plans the audio mix and
// positions its sources, starts the audio output if it is not running, and waits (bounded by
// Config::prerollTimeout once the output is up) for the first video frames and
// AudioMixer::isPrimed; then it starts the clock and the mixer together and publishes Playing.
// A later transport call supersedes a pre-roll in progress. While stopped, the tick thread
// positions the audio sources at the paused frame once it has been still for
// Config::audioWarmDelay, so play() after a pause or a seek usually finds them primed.
//
// Rate changes in the same direction do not pre-roll: 1x <-> 2x continue the audio seamlessly
// (Clock::startContinuation + AudioMixer::changeRate), 2x -> 4x/8x switches the clock to host
// time and fades the audio out, and 4x/8x -> 1x/2x switches the clock to host time at the new
// rate at once and joins the audio a moment later (the sources are primed ahead of the playhead
// and the clock continues into the audio run). JKL: setRate(r) with r in [-8, 8] (0 pauses);
// shuttleForward()/shuttleReverse() step through 1, 2, 4, 8 in one direction (the other
// direction's key restarts at 1). Audio plays at 1x and 2x (2x: pitched up, low-pass decimated);
// it is silent above 2x and in reverse.
//
// Audio output lifetime: the output (AVAudioEngine) is started by the tick thread when a sequence
// is opened or a pre-roll needs it and keeps running (the mixer renders silence and the clock
// ignores it while stopped) until Config::outputIdleTimeout passes without transport activity;
// then the tick thread stops it. So play/pause/seek/JKL never start or stop the device on the
// caller's thread, and pausing does not rebuild the audio route. Device changes are reported by
// the output as events; the controller applies them on its tick thread under its mutex (it is
// the only writer of the Clock). If the device is lost during playback (the engine cannot
// restart), playback continues on the host clock without audio and status().lastError says why;
// the next play() tries the output again.
//
// End of sequence: forward playback stops on the last frame (reverse on frame 0) and the
// controller pauses there. play() at the last frame restarts from the beginning.
//
// Threading contract
// - Public control methods (setSequence, modelChanged, setAssetRouting, play, pause, togglePlay,
//   seek, setRate, shuttle*, stepFrames, scrubTo, endScrub, setMuted, setObserver): any thread
//   (normally main), serialised by an internal mutex. None of them waits: no pre-roll, no device
//   start/stop, no decoder or render-thread wait, no source destruction happens on the caller's
//   thread (each returns in well under a millisecond of work plus the mutex).
// - Readers (currentTime, state, rate, status, stats, lastPresented): any thread; they take the
//   same mutex, which no thread holds across a blocking operation.
// - The frame source runs on the preview view's render thread; it never blocks (it takes no
//   lock the control side holds for more than a pointer copy, does no I/O and never waits for
//   decoding). It holds the FrameCache pins of the frame it returned until it returns the next
//   one.
// - The private tick thread (always running; asleep while nothing is pending) completes
//   pre-rolls, retargets the DecodePool every ~100 ms of sequence time, re-plans the audio mix
//   every second, joins audio after a fast shuttle, detects the sequence end, applies output
//   events, starts/stops the output, hands dropped audio sources to the mixer's reaper, and
//   posts observer updates. It holds the mutex only for bookkeeping.
// - Observer callbacks run on the caller-chosen dispatch queue: statusChanged at most once per
//   displayed frame (coalesced: never more than one pending block), needsDisplay whenever the
//   paused/scrubbed picture changed (the facade then calls -[VEPreviewView renderOnce]).
//
// Facade wiring:
//   auto controller = std::make_unique<PlaybackController>(router, frameCache, decodePool);
//   controller->setSequence(projectSnapshot, sequenceId);
//   [previewView setFrameSource:controller->frameSource()];
//   controller->setObserver(dispatch_get_main_queue(), {
//       .statusChanged = [view](const PlaybackStatus &s) {
//           view.paused = s.state != PlaybackState::Playing; // Prerolling: show the target frame
//           if (s.lastError) { /* surface s.lastError->message */ } ... },
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

enum class PlaybackErrorCode {
    AudioOutputUnavailable, ///< The audio output could not be started; playing without audio.
    AudioDeviceLost,        ///< The device went away during playback and the engine could not
                            ///< restart; playback continued on the host clock without audio.
};

struct PlaybackError {
    PlaybackErrorCode code = PlaybackErrorCode::AudioOutputUnavailable;
    std::string message;
};

struct PlaybackStatus {
    CMTime time = kCMTimeZero; ///< currentTime() at the moment of the update.
    PlaybackState state = PlaybackState::Stopped;
    double rate = 1.0;
    bool audioActive = false; ///< The audio clock drives playback (audible or muted).
    /// The most recent audio problem; cleared when a play() next starts audio successfully.
    std::optional<PlaybackError> lastError;
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
    /// Presented frames per second (moving average while playing; 0 once no clock-driven frame
    /// was presented for half a second, and reset by pause/seek).
    double fps = 0.0;
    uint64_t presentedFrames = 0;
    uint64_t droppedFrames = 0; ///< Sequence frames skipped beyond what the rate explains.
    uint64_t lateFrames = 0;    ///< Presentations missing a frame (previous picture held).
    uint64_t cacheHits = 0;     ///< Frame source lookups that produced a picture.
    uint64_t cacheMisses = 0;
    uint64_t mapFailures = 0;   ///< Cached frames that could not be mapped to textures (not hits).
    uint64_t monotonicHolds = 0; ///< Presentations whose clock read was held against going backwards.
    double cacheHitRate = 0.0;
    int decodeQueueDepth = 0; ///< Busy decode streams + pending scrub requests.
    uint64_t audioUnderruns = 0;
    uint64_t audioUnderrunFrames = 0;
    bool audioActive = false;
    bool outputRunning = false;
    std::string audioOutput; ///< IAudioOutput::kind().
    double outputLatency = 0.0; ///< Seconds subtracted by the clock (output + mixer processing).
    std::optional<PlaybackError> lastError;
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
    std::function<std::unique_ptr<audio::IAudioOutput>(audio::AudioMixer &)> makeOutput;
    /// Host time source of the clock (default: system). Tests use a virtual one with a manual
    /// output to run faster than real time.
    std::shared_ptr<audio::HostClock> hostClock;
    CMTime decodeLookahead = CMTimeMake(1, 1);
    /// Longest wait for the first frames and audio once the output is up (then playback starts
    /// anyway, with late frames / underruns). The caller never waits for it; it only bounds how
    /// long a cold start (the process's first AAC decode takes ~0.5 s) may delay playback.
    std::chrono::milliseconds prerollTimeout{1000};
    /// While stopped, the audio sources are positioned (and primed) at the paused frame once it
    /// has not moved for this long, so the next play() starts without opening decoders.
    std::chrono::milliseconds audioWarmDelay{150};
    /// Longest wait for the mixer to finish the previous run's fade-out before its sources are
    /// repositioned (it takes one output callback; this only matters if the device stalls).
    std::chrono::milliseconds stopFadeTimeout{50};
    /// The output is stopped after this long without playback or a new sequence.
    std::chrono::milliseconds outputIdleTimeout{10'000};
    double audioHorizonSeconds = 5.0; ///< Audio plan window ahead of the playhead.
    double audioReplanSeconds = 1.0;  ///< Re-plan when the playhead moved this far.
    double retargetSeconds = 0.1;     ///< DecodePool retarget interval (sequence time).
    /// Joining audio into a running host-clock run: sources are primed this far (sequence
    /// seconds per unit of rate) ahead of the playhead.
    double audioJoinLeadSeconds = 0.3;
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
    /// Mutes audio (a short ramp to silence). The audio clock keeps running, so mute and unmute
    /// never interrupt playback.
    void setMuted(bool muted);
    bool isMuted() const;

    // MARK: State

    /// Clock time (playing) or the paused/scrub position, snapped down to the sequence frame
    /// grid and clamped to the sequence.
    CMTime currentTime() const;
    PlaybackState state() const;
    double rate() const;
    /// What the observer's statusChanged would receive now.
    PlaybackStatus status() const;
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
    struct Preroll {
        uint64_t serial = 0;
        CMTime at = kCMTimeZero;
        double rate = 1.0;
        bool wantAudio = false;
        uint64_t stopSerial = 0; // mixer stop to wait for before repositioning sources
        std::chrono::steady_clock::time_point stopRequested{};
        bool retargeted = false;
        bool planned = false;
        bool waiting = false; // planned and output up: waiting for data until `deadline`
        std::chrono::steady_clock::time_point deadline{};
    };
    struct Join {
        bool active = false;
        CMTime at = kCMTimeInvalid;
    };

    const Sequence *sequenceLocked() const;
    CMTime lastFrameStartLocked() const;
    CMTime clampLocked(CMTime t) const;
    PlaybackStatus statusLocked() const;
    void publishDisplayLocked();
    void beginPrerollLocked(CMTime at, double rate);
    void advancePrerollLocked();
    void completePrerollLocked();
    void playingTickLocked();
    void advanceJoinLocked(CMTime t);
    void dropAudioLocked(); // audio clock -> host clock at the current time, mixer faded out
    void noteDisplayChangedLocked(); // stopped: the paused frame moved (re-warm the audio later)
    void warmAudioLocked();
    bool firstFramesReadyLocked(CMTime at) const;
    void pauseLocked(std::optional<CMTime> at = std::nullopt);
    void retargetLocked(CMTime at, double rate);
    void planAudioLocked(CMTime at);
    void requestDisplayFramesLocked(CMTime at);
    void registerAssetsLocked();
    void postStatusLocked();
    void postNeedsDisplay();
    void touchIdleLocked();
    double audioLatencyLocked(double rate) const;
    void handleOutputEventsLocked();
    /// Starts/stops the output as needed; unlocks around the call. True if it did something.
    bool manageOutput(std::unique_lock<std::mutex> &lock);
    void tickMain();
    CMTime nowLocked() const;
    static bool wantsAudio(double rate) { return rate == 1.0 || rate == 2.0; }

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
    std::optional<std::pair<CMTime, double>> pendingRetarget_;
    bool replanAudio_ = false;
    int64_t lastPostedFrame_ = -1;
    uint64_t prerollSerial_ = 0;
    Preroll preroll_;
    Join join_;
    uint64_t lastStopSerial_ = 0;
    std::chrono::steady_clock::time_point lastStopAt_{};
    std::chrono::steady_clock::time_point displayChangedAt_{};
    bool audioWarm_ = false; // stopped: sources are positioned at displayTime_
    // Output lifecycle (decided by the tick thread).
    bool outputStarted_ = false;
    bool outputFailed_ = false; // the last start failed or the device was lost: no audio until the next pre-roll
    std::chrono::steady_clock::time_point idleDeadline_{};
    std::vector<audio::AudioOutputEvent> outputEvents_;
    std::optional<PlaybackError> lastError_;
    std::map<AssetId, std::string> registeredPaths_;
    std::map<AssetId, media::RoutedMediaInfo> routing_;
    bool stopTick_ = false;
    std::thread tickThread_;
};

} // namespace ve::playback
