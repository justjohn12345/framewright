// The playback master clock: maps host time to sequence time.
//
// Modes
// - AudioSamples (normal playback at 1x/2x with audio): time advances only when the audio
//   render thread reports rendered output samples (advanceSamples). Sequence time is
//     anchor + rate * (samples rendered before the last callback + interpolation) / sampleRate
//   where the interpolation is the host time elapsed since that callback (so video presented
//   between callbacks moves smoothly), capped at the length of that callback's block plus
//   kMaxExtrapolationSeconds (if the audio device stalls, the clock stalls with it: audio is
//   master). The reported position is further delayed by the output latency (setOutputLatency)
//   so it tracks what is audible, not what was handed to the device. Before the first callback
//   of a start() the clock stays at the anchor (video waits for audio).
// - HostTime (fallback when there is no audio path: |rate| > 2, reverse, muted, no device):
//   anchor + rate * (host now - host time of start()).
// - Stopped: frozen at the anchor (the paused position).
//
// Guarantees: now() is monotonic in the direction of the rate within one start() (never goes
// backwards for rate > 0, never forwards for rate < 0), including across callback jitter.
// Times are CMTime with timescale ve::kPreciseTimescale (705,600,000, divisible by every common
// audio and video rate), so sample and frame positions are represented exactly at callback
// boundaries.
//
// Epochs: every start()/stop()/setTime() begins a new epoch. advanceSamples() may be tagged
// with the epoch the caller observed when it started rendering; samples tagged with an older
// epoch are ignored, so a callback in flight across a seek cannot shift the new anchor.
//
// Threading contract
// - Control (start, stop, setTime, setSampleRate, setOutputLatency): one thread at a time
//   (callers serialise, e.g. under the playback controller's mutex). Not realtime.
// - advanceSamples: the audio render thread only (a single writer). Lock-free, wait-free, no
//   allocation: realtime-safe.
// - Readers (now, timeAt, rate, mode, epoch, isRunning, samplesRendered): any thread,
//   lock-free, never block, realtime-safe.

#pragma once

#include "../Model/TimeUtil.h"
#include "Realtime.h"

#include <atomic>
#include <cstdint>
#include <memory>

namespace ve::audio {

enum class ClockMode : uint8_t {
    Stopped,
    AudioSamples,
    HostTime,
};

const char *nameOf(ClockMode mode);

class Clock {
  public:
    /// advanceSamples() epoch wildcard: credit the samples to the current epoch.
    static constexpr uint32_t kAnyEpoch = 0;
    /// Interpolation may run this far past the last rendered block before the clock waits for
    /// the next audio callback.
    static constexpr double kMaxExtrapolationSeconds = 0.05;

    explicit Clock(std::shared_ptr<HostClock> hostClock = HostClock::system(), double sampleRate = 48000.0);
    Clock(const Clock &) = delete;
    Clock &operator=(const Clock &) = delete;

    // MARK: Control (one thread at a time)

    /// Rate of the samples reported by advanceSamples (the output rate). Takes effect at the
    /// next start().
    void setSampleRate(double sampleRate);
    double sampleRate() const noexcept;
    /// Seconds between rendering a sample and hearing it; subtracted in AudioSamples mode.
    void setOutputLatency(double seconds);

    /// Starts moving from `at` at `rate` (sequence seconds per second; negative plays backwards;
    /// 0 behaves like stop at `at`). AudioSamples requires rate > 0 in practice (audio only
    /// plays forwards) but any non-zero rate is accepted. Returns the new epoch (never 0).
    uint32_t start(CMTime at, double rate, ClockMode mode = ClockMode::AudioSamples);
    /// Freezes at now(). Returns the new epoch.
    uint32_t stop();
    /// Stops at `t` (seek while stopped, or a hard jump). Returns the new epoch.
    uint32_t setTime(CMTime t);

    // MARK: Audio render thread

    /// Reports `frames` output samples rendered at host time `hostNanos` (0: now). Ignored
    /// unless the clock runs in AudioSamples mode with `epoch` current (or kAnyEpoch).
    void advanceSamples(int64_t frames, uint64_t hostNanos = 0, uint32_t epoch = kAnyEpoch) noexcept;

    // MARK: Readers (any thread)

    /// Current sequence time (monotonic, see header).
    CMTime now() const noexcept;
    double nowSeconds() const noexcept { return CMTimeGetSeconds(now()); }
    /// Sequence time at host time `hostNanos` (e.g. a display link's target presentation
    /// time). Same formula as now() but without the monotonic guard.
    CMTime timeAt(uint64_t hostNanos) const noexcept;

    double rate() const noexcept;
    ClockMode mode() const noexcept;
    bool isRunning() const noexcept { return mode() != ClockMode::Stopped; }
    uint32_t epoch() const noexcept;
    /// Output samples reported in the current epoch.
    int64_t samplesRendered() const noexcept;
    /// Host time of the last advanceSamples of the current epoch (0 if none yet).
    uint64_t lastCallbackNanos() const noexcept;

    const std::shared_ptr<HostClock> &hostClock() const noexcept { return host_; }

  private:
    struct Anchor {
        int64_t value = 0;     // anchor time, value/timescale
        int32_t timescale = 1;
        uint32_t epoch = 1;
        double rate = 0.0;
        double sampleRate = 48000.0;
        double latency = 0.0;
        uint64_t hostNanos = 0; // HostTime mode origin
        ClockMode mode = ClockMode::Stopped;
    };
    struct Progress {
        uint32_t epoch = 0;
        int64_t samplesBefore = 0; // rendered before the last callback
        int64_t lastBlock = 0;     // frames of the last callback
        uint64_t lastHostNanos = 0;
    };

    /// Elapsed output time since the anchor, in kPreciseTimescale ticks (>= 0).
    int64_t elapsedTicks(const Anchor &anchor, uint64_t hostNanos) const noexcept;
    static CMTime compose(const Anchor &anchor, int64_t ticks) noexcept;
    uint32_t publish(CMTime at, double rate, ClockMode mode);

    const std::shared_ptr<HostClock> host_;
    SeqLock<Anchor> anchor_;
    SeqLock<Progress> progress_;
    // Control-thread shadow of the anchor (single writer, so no need to re-read the seqlock).
    Anchor control_;
    // Monotonic guard for now(): epoch in the top 16 bits, elapsed ticks in the low 48.
    mutable std::atomic<uint64_t> guard_{0};
};

} // namespace ve::audio
