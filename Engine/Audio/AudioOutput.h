// Audio outputs that pull from an AudioMixer.
//
// - AudioOutput: AVAudioEngine + AVAudioSourceNode. The source node runs at the mixer's rate and
//   channel count (48 kHz stereo float by default); the engine's main mixer converts to the
//   device format (sample rate, channel count) when it differs, so the mixer and the clock
//   always count samples at the mixer rate. The render block calls AudioMixer::render into a
//   preallocated interleaved buffer and deinterleaves into the engine's buffers; it does no
//   Objective-C messaging, no locking and no allocation. Device changes
//   (AVAudioEngineConfigurationChangeNotification: the engine has stopped itself) are handled by
//   reconnecting the source node with the mixer format and restarting the engine; while it is
//   stopped no samples are rendered, so the sample-driven Clock simply holds its position and
//   continues from it (coherent: no jump, no drift). The output latency reported by the engine
//   is pushed to the clock on every (re)start.
// - NullAudioOutput: drives the mixer without a device, from its own thread paced by
//   mach_wait_until at the mixer rate (Realtime mode), or synchronously from the caller with a
//   virtual HostClock advanced by exactly one block per block (Manual mode: deterministic and
//   as fast as the machine allows). Optionally captures everything it renders (tests).
// - AutomaticAudioOutput: an AudioOutput that falls back to a realtime NullAudioOutput when the
//   engine cannot be created or started (no output device, headless CI). kind() tells which.
//
// Threading contract: start/stop/setMuted/isRunning/kind and the accessors may be called from
// any non-realtime thread (serialised internally). NullAudioOutput::renderBlocks is for Manual
// mode only and must not run concurrently with start(). Destroying an output stops it first;
// destroy outputs before their mixer.

#pragma once

#include "../Media/Result.h"
#include "AudioMixer.h"
#include "Clock.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ve::audio {

class IAudioOutput {
  public:
    virtual ~IAudioOutput() = default;
    /// Starts pulling from the mixer. Idempotent.
    virtual media::Status start() = 0;
    /// Stops pulling (blocks until the render callback is no longer running). Idempotent.
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    /// Muted outputs still pull (and so still drive the clock) but emit silence.
    virtual void setMuted(bool muted) = 0;
    virtual bool isMuted() const = 0;
    /// "avaudioengine", "null", "null-manual" (AutomaticAudioOutput reports the active one).
    virtual std::string kind() const = 0;
    /// Seconds between rendering a sample and hearing it (0 for the null output).
    virtual double outputLatency() const = 0;
};

// MARK: - AVAudioEngine

class AudioOutput final : public IAudioOutput {
  public:
    /// Builds the engine graph (does not start it). `latencyClock` (optional) receives
    /// setOutputLatency on every start. Fails with Internal if AVAudioEngine cannot be set up.
    static media::Result<std::unique_ptr<AudioOutput>> create(AudioMixer &mixer, Clock *latencyClock = nullptr);
    ~AudioOutput() override;

    media::Status start() override;
    void stop() override;
    bool isRunning() const override;
    void setMuted(bool muted) override;
    bool isMuted() const override;
    std::string kind() const override { return "avaudioengine"; }
    double outputLatency() const override;

    /// Sample rate of the output device (the engine converts from the mixer rate).
    double deviceSampleRate() const;
    /// Number of handled configuration changes.
    uint64_t configurationChanges() const;
    /// What the notification handler does; public so tests can exercise it without a device
    /// change.
    void handleConfigurationChange();

    struct Impl;

  private:
    explicit AudioOutput(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
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
        /// contiguous 1x playback.
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
    AutomaticAudioOutput(AudioMixer &mixer, Clock *latencyClock = nullptr);
    ~AutomaticAudioOutput() override;

    /// Tries AVAudioEngine; on failure (no device) switches to a realtime NullAudioOutput for
    /// the rest of its life. Fails only if both fail.
    media::Status start() override;
    void stop() override;
    bool isRunning() const override;
    void setMuted(bool muted) override;
    bool isMuted() const override;
    std::string kind() const override;
    double outputLatency() const override;
    /// Why the engine was not used (empty while it is).
    std::string fallbackReason() const;

  private:
    AudioMixer &mixer_;
    Clock *const latencyClock_;
    mutable std::mutex mutex_;
    std::unique_ptr<IAudioOutput> active_;
    bool triedEngine_ = false;
    bool muted_ = false;
    std::string fallbackReason_;
};

} // namespace ve::audio
