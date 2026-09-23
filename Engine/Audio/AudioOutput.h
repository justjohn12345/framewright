// Audio outputs that pull from an AudioMixer.
//
// - AudioOutput: AVAudioEngine + AVAudioSourceNode. The source node runs at the mixer's rate and
//   channel count (48 kHz stereo float by default); the engine's main mixer converts to the
//   device format (sample rate, channel count) when it differs, so the mixer and the clock
//   always count samples at the mixer rate. The render block calls AudioMixer::render into a
//   preallocated interleaved buffer and deinterleaves into the engine's buffers; it does no
//   Objective-C messaging, no locking and no allocation.
//   Timing: the render block passes the callback's AudioTimeStamp.mHostTime (when
//   kAudioTimeStampHostTimeValid is set) to the mixer and so to the clock. For output that is the
//   host time at which the block's first frame reaches the device's IO boundary (measured on
//   macOS 26: one IO buffer after the callback starts, with no scheduling jitter). Without a
//   valid host time the block's entry time plus the IO buffer and safety offset estimate it.
//   outputLatency() is what remains from the IO boundary to the listener:
//     the source node's outputPresentationLatency (the engine's mixer latency plus the output
//     presentation latency = device latency + stream latency, as AVAudioIONode documents)
//     + the main mixer's sample-rate converter delay when the device rate differs from the
//       mixer rate (AVAudioEngine reports 0 for it; measured once per rate pair by rendering an
//       impulse offline through an identically configured engine, ~0.35 ms at 44.1/96 kHz).
//   latencyBreakdown() reports every component. What is not measured: the device's reported
//   latency itself (the path after the HAL, e.g. a Bluetooth link, is taken on trust) and
//   whether the HAL's IO time already includes the device's safety offset (assumed, as the HAL
//   documents; every device measured so far reports a zero output safety offset).
//   Device changes: AVAudioEngineConfigurationChangeNotification (the engine has stopped
//   itself) is handled on the output's own serial queue, never on the posting thread: it
//   reconnects the source node with the mixer format and restarts the engine if it was
//   running, then reports an AudioOutputEvent (ConfigurationChanged with the new latency, or
//   RestartFailed). The output never touches the Clock: its owner applies the latency (the
//   playback controller does so under its own mutex). While the engine is stopped no samples
//   are rendered, so a sample-driven Clock holds its position and continues from it. The
//   handler is guarded against teardown: once the output is being destroyed it does nothing.
// - NullAudioOutput: drives the mixer without a device, from its own thread paced by
//   mach_wait_until at the mixer rate (Realtime mode), or synchronously from the caller with a
//   virtual HostClock advanced by exactly one block per block (Manual mode: deterministic and
//   as fast as the machine allows). Optionally captures what it renders while the mixer
//   renders a transport (tests).
// - AutomaticAudioOutput: an AudioOutput that falls back to a realtime NullAudioOutput when the
//   engine cannot be created or started (no output device, headless CI). While on the fallback
//   it retries the engine on start() at most once per retry interval (wantsRestart() tells the
//   owner a retry is due, so the playback controller retries at the next play), and after the
//   engine failed to restart. It also listens for the system's default output device changing
//   (CoreAudio kAudioHardwarePropertyDefaultOutputDevice): when a device appears while it runs
//   on the fallback, a retry is due at once instead of after the interval. kind() tells which
//   one runs.
//
// Threading contract: start/stop may block (AVAudioEngine start/stop are synchronous: tens to
// hundreds of milliseconds on Bluetooth devices), so owners call them off latency-sensitive
// threads (the playback controller: from its tick thread). isRunning/setMuted/isMuted/kind/
// outputLatency never block (atomics). Event handlers run on an arbitrary non-realtime thread,
// one at a time per output; they must return quickly. NullAudioOutput::renderBlocks is for
// Manual mode only and must not run concurrently with start(). Destroying an output stops it
// first; destroy outputs before their mixer.

#pragma once

#include "../Media/Result.h"
#include "AudioMixer.h"
#include "Clock.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ve::audio {

/// Something happened to an output outside a start()/stop() call.
struct AudioOutputEvent {
    enum class Kind {
        ConfigurationChanged, ///< Device/format change handled; `running` and `latency` are current.
        RestartFailed,        ///< The engine stopped for a device change and could not restart.
    };
    Kind kind = Kind::ConfigurationChanged;
    bool running = false;
    double latency = 0.0; ///< outputLatency() after the event.
    std::string message;
};
using AudioOutputEventHandler = std::function<void(const AudioOutputEvent &)>;

class IAudioOutput {
  public:
    virtual ~IAudioOutput() = default;
    /// Starts pulling from the mixer. Idempotent. May block (device start).
    virtual media::Status start() = 0;
    /// Stops pulling (blocks until the render callback is no longer running). Idempotent.
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    /// Muted outputs still pull (and so still drive the clock) but emit silence.
    virtual void setMuted(bool muted) = 0;
    virtual bool isMuted() const = 0;
    /// "avaudioengine", "null", "null-manual" (AutomaticAudioOutput reports the active one).
    virtual std::string kind() const = 0;
    /// Seconds from the IO boundary (the host time passed to AudioMixer::render) to the
    /// listener (0 for the null output).
    virtual double outputLatency() const = 0;
    /// Receives events (device changes, restart failures). Replaces any previous handler; an
    /// empty function removes it (waiting for a call in flight).
    virtual void setEventHandler(AudioOutputEventHandler handler) { (void)handler; }
    /// A start() now would switch to a better output (a fallback whose retry is due). Never
    /// blocks.
    virtual bool wantsRestart() const { return false; }
};

// MARK: - AVAudioEngine

class AudioOutput final : public IAudioOutput {
  public:
    struct LatencyBreakdown {
        double mixerSampleRate = 0.0;
        double deviceSampleRate = 0.0;
        // Device properties read through the output unit (AUHAL passes them through).
        uint32_t bufferFrames = 0;        ///< kAudioDevicePropertyBufferFrameSize (device frames).
        uint32_t safetyOffsetFrames = 0;  ///< kAudioDevicePropertySafetyOffset.
        uint32_t deviceLatencyFrames = 0; ///< kAudioDevicePropertyLatency.
        /// presentationLatency minus the device latency: the stream latency (device frames).
        int64_t streamLatencyFrames = 0;
        double presentationLatency = 0.0; ///< AVAudioOutputNode.presentationLatency.
        double pipelineLatency = 0.0;     ///< Source node outputPresentationLatency (mixer + output).
        double converterDelay = 0.0;      ///< Measured SRC delay of the main mixer (0: same rate).
        double total = 0.0;               ///< outputLatency(): pipeline + converter beyond the mixer's report.
    };

    /// One render callback (diagnostics; see captureTimeline()).
    struct TimelineEntry {
        uint64_t ioHostNanos = 0;    ///< Host time passed to the mixer (IO boundary).
        uint64_t entryHostNanos = 0; ///< Host time at callback entry.
        int64_t transportSample = -1; ///< Sequence sample of the block's first frame (-1: no transport).
        int frames = 0;
        bool hostTimeValid = false;
    };

    /// Builds the engine graph (does not start it). Fails with Internal if AVAudioEngine cannot be
    /// set up.
    static media::Result<std::unique_ptr<AudioOutput>> create(AudioMixer &mixer);
    ~AudioOutput() override;

    media::Status start() override;
    void stop() override;
    bool isRunning() const override;
    void setMuted(bool muted) override;
    bool isMuted() const override;
    std::string kind() const override { return "avaudioengine"; }
    double outputLatency() const override;
    void setEventHandler(AudioOutputEventHandler handler) override;

    /// Sample rate of the output device (the engine converts from the mixer rate).
    double deviceSampleRate() const;
    LatencyBreakdown latencyBreakdown() const;
    /// Number of handled configuration changes.
    uint64_t configurationChanges() const;
    /// Render callbacks whose timestamp had no valid host time (the estimate was used).
    uint64_t hostTimeFallbacks() const;
    /// What the notification handler does (on the calling thread); public so tests can run it
    /// without a device change.
    void handleConfigurationChange();
    /// Posts AVAudioEngineConfigurationChangeNotification for this output's engine, as a device
    /// change does, so tests exercise the real delivery path (observer, queue hop, teardown
    /// guard).
    void postConfigurationChangeNotification();

    /// Records up to `capacity` render callbacks from now on (drainTimeline() reads them). Call
    /// while stopped; allocates.
    void captureTimeline(size_t capacity);
    std::vector<TimelineEntry> drainTimeline();

    /// Delay of AVAudioEngine's mixer converting `channels` channels from `fromRate` to `toRate`,
    /// in seconds of output, measured offline (cached per rate pair). 0 when the rates match or
    /// the measurement fails.
    static double measureConverterDelay(double fromRate, double toRate, int channels);

    struct Impl;

  private:
    explicit AudioOutput(std::shared_ptr<Impl> impl);
    std::shared_ptr<Impl> impl_;
};

// MARK: - Null output

struct NullAudioOutputConfig {
    enum class Mode {
        Realtime, ///< Own thread, paced at the mixer rate against the system host clock.
        Manual,   ///< No thread: renderBlocks() renders and advances `virtualClock`.
    };
    Mode mode = Mode::Realtime;
    int blockFrames = 512;
    /// Manual mode: the host clock advanced by blockFrames / sampleRate per block (normally the
    /// same virtual clock the Clock reads).
    std::shared_ptr<HostClock> virtualClock;
    /// Frames of output to keep (0: no capture).
    size_t captureFrames = 0;
};

class NullAudioOutput final : public IAudioOutput {
  public:
    struct Capture {
        std::vector<float> samples; ///< Interleaved, mixer channel count.
        int channels = 0;
        /// Sequence sample the first captured frame was rendered for (-1 if none). Valid for
        /// contiguous 1x playback. Only blocks in which the mixer rendered a transport are kept.
        int64_t firstSequenceSample = -1;
    };

    NullAudioOutput(AudioMixer &mixer, NullAudioOutputConfig config = {});
    ~NullAudioOutput() override;

    media::Status start() override;
    void stop() override;
    bool isRunning() const override { return running_.load(std::memory_order_acquire); }
    void setMuted(bool muted) override { muted_.store(muted, std::memory_order_relaxed); }
    bool isMuted() const override { return muted_.load(std::memory_order_relaxed); }
    std::string kind() const override { return config_.mode == NullAudioOutputConfig::Mode::Manual ? "null-manual" : "null"; }
    double outputLatency() const override { return 0.0; }

    /// Manual mode: renders `count` blocks now on the calling thread (start() must have been
    /// called; a stopped output renders nothing). Returns the frames rendered.
    int64_t renderBlocks(int count);

    /// Clears and re-arms the capture buffer (capacity from the config).
    void resetCapture();
    /// A copy of what was captured so far.
    Capture capture() const;
    int64_t framesRendered() const { return framesRendered_.load(std::memory_order_acquire); }

  private:
    void renderOne();
    void threadMain();

    AudioMixer &mixer_;
    const NullAudioOutputConfig config_;
    std::vector<float> buffer_;
    std::atomic<bool> running_{false};
    std::atomic<bool> muted_{false};
    std::atomic<bool> stopRequested_{false};
    std::atomic<int64_t> framesRendered_{0};
    std::mutex controlMutex_;
    std::thread thread_;
    mutable std::mutex captureMutex_;
    Capture capture_;
};

// MARK: - Automatic fallback

class AutomaticAudioOutput final : public IAudioOutput {
  public:
    /// Creates the preferred output (default: AudioOutput::create).
    using EngineFactory = std::function<media::Result<std::unique_ptr<IAudioOutput>>(AudioMixer &)>;

    /// `watchDefaultDevice`: install the CoreAudio default-output-device listener (tests of the
    /// retry logic pass false and call defaultOutputDeviceDidChange() themselves).
    explicit AutomaticAudioOutput(AudioMixer &mixer, EngineFactory engineFactory = {},
                                  std::chrono::milliseconds retryInterval = std::chrono::seconds(5),
                                  bool watchDefaultDevice = true);
    ~AutomaticAudioOutput() override;

    /// The system's default output device changed to a usable one (called by the CoreAudio
    /// listener on a private queue; any thread). While on the fallback, makes a retry due now.
    void defaultOutputDeviceDidChange();

    /// Uses the engine when it can be created and started; otherwise a realtime NullAudioOutput.
    /// While on the fallback, a start() retries the engine once the retry interval has passed
    /// since the last attempt. Fails only if both fail.
    media::Status start() override;
    void stop() override;
    bool isRunning() const override;
    void setMuted(bool muted) override;
    bool isMuted() const override;
    std::string kind() const override;
    double outputLatency() const override;
    void setEventHandler(AudioOutputEventHandler handler) override;
    bool wantsRestart() const override;
    /// Why the engine is not used (empty while it is).
    std::string fallbackReason() const;
    /// Engine creation/start attempts so far.
    int engineAttempts() const { return engineAttempts_.load(std::memory_order_relaxed); }

  private:
    enum class Active { None, Engine, Null };
    void applyMutedLocked();
    void publishStateLocked();
    void emit(const AudioOutputEvent &event);

    AudioMixer &mixer_;
    const EngineFactory engineFactory_;
    const std::chrono::milliseconds retryInterval_;
    std::mutex mutex_; // start/stop and the active output
    std::unique_ptr<IAudioOutput> engine_;
    std::unique_ptr<NullAudioOutput> null_;
    Active active_ = Active::None;
    std::atomic<bool> engineFailed_{false}; // the engine stopped for a device change and could not restart
    std::chrono::steady_clock::time_point lastAttempt_{};
    bool attempted_ = false;
    std::atomic<int64_t> nextAttemptNanos_{0}; // steady-clock nanoseconds; wantsRestart() reads it
    std::atomic<bool> deviceAppeared_{false};  // a default output device appeared since the last attempt
    struct DeviceListener;
    std::unique_ptr<DeviceListener> deviceListener_; // removed first in the destructor
    std::atomic<int> engineAttempts_{0};
    std::atomic<bool> muted_{false};
    std::atomic<bool> muteDirty_{false};
    std::atomic<int> activeKind_{0}; // Active
    std::atomic<bool> running_{false};
    std::atomic<double> latency_{0.0};
    mutable std::mutex infoMutex_; // fallbackReason_
    std::string fallbackReason_;
    std::mutex handlerMutex_; // held while the handler runs
    AudioOutputEventHandler handler_;
};

} // namespace ve::audio
