// The playback master clock: maps host time to sequence time.
//
// Modes
// - AudioSamples (normal playback at 1x/2x with audio): time advances only when the audio
//   render thread reports rendered output samples (advanceSamples). Each report carries the
//   host time at which the block's first sample reaches the device's IO boundary (the render
//   callback's AudioTimeStamp.mHostTime; see AudioOutput). Sequence time at host time h is
//     origin + rate * (outputSeconds(h) - outputLatency)
//   where outputSeconds(h) = (samples rendered before the last callback) / sampleRate
//   + (h - host time of the last callback), i.e. the output position at the IO boundary
//   interpolated along the device timeline. The interpolation may run backwards into the
//   previous block (the last callback's host time is usually ~one IO buffer in the future when
//   a reader asks) and forwards up to that callback's block length plus
//   kMaxExtrapolationSeconds (if the device stalls, the clock stalls with it: audio is master).
//   outputLatency (setOutputLatency) is the time from the IO boundary to the listener (device
//   and stream latency, the engine's sample-rate conversion, ...), so the reported position is
//   what is audible, not what was handed to the device. Until the epoch's first sample is
//   audible the clock stays at its origin (video waits for audio).
// - HostTime (fallback when there is no audio path: |rate| > 2, reverse, no device):
//   origin + rate * (host now - host time of start()).
// - Stopped: frozen at the origin (the paused position).
//
// Continuations (startContinuation): a new AudioSamples epoch that picks up where the running
// one leaves off without a gap, for a rate change or for audio joining a host-clock run. Its
// origin is the sequence sample the render thread renders first in the new epoch (reported
// with that epoch's first advanceSamples), which the control side cannot know in advance.
// Until that sample is audible, the audio still in flight from the previous run is playing:
// the clock continues the previous run's line (time at the switch + previous rate * elapsed),
// clamped to [time at the switch, origin]. So a rate change neither jumps the picture forward
// nor freezes it for the output latency.
//
// Guarantees: within one epoch, now() is monotonic in the direction of the rate (never
// backwards for rate > 0, never forwards for rate < 0), including across callback jitter and
// the continuation's hand-over. Times are CMTime with timescale ve::kPreciseTimescale
// (705,600,000, divisible by every common audio and video rate), so sample and frame positions
// are represented exactly at callback boundaries. Sequence times are assumed non-negative and
// below ~110 hours (the monotonic guard packs them into 48 bits).
//
// Epochs: every start()/startContinuation()/stop()/setTime() begins a new epoch.
// advanceSamples() may be tagged with the epoch the caller observed when it started rendering;
// samples tagged with an older epoch are ignored, so a callback in flight across a seek cannot
// shift the new anchor.
//
// Threading contract
// - Control (start, startContinuation, stop, setTime, setSampleRate, setOutputLatency): one
//   thread at a time (callers serialise, e.g. under the playback controller's mutex). Not
//   realtime. Overlapping control calls are a contract violation; they are detected (not
//   prevented) and counted in controlViolations(), which tests assert is zero.
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
    /// Seconds from the IO boundary (the host time passed to advanceSamples) to the listener;
    /// subtracted in AudioSamples mode. Takes effect immediately.
    void setOutputLatency(double seconds);
    double outputLatency() const noexcept;

    /// Starts moving from `at` at `rate` (sequence seconds per second; negative plays backwards;
    /// 0 behaves like stop at `at`). AudioSamples requires rate > 0 in practice (audio only
    /// plays forwards) but any non-zero rate is accepted. Returns the new epoch (never 0).
    uint32_t start(CMTime at, double rate, ClockMode mode = ClockMode::AudioSamples);
    /// Starts an AudioSamples epoch at `rate` (> 0) that continues the current run (see the
    /// header). The render thread must report the new epoch's first advanceSamples with the
    /// sequence sample it renders first (`originSample`). From a stopped clock this is
    /// start(now(), rate). Returns the new epoch.
    uint32_t startContinuation(double rate);
    /// Freezes at now(). Returns the new epoch.
    uint32_t stop();
    /// Stops at `t` (seek while stopped, or a hard jump). Returns the new epoch.
    uint32_t setTime(CMTime t);

    // MARK: Audio render thread

    /// Reports `frames` output samples whose first one reaches the device's IO boundary at host
    /// time `hostNanos` (0: now). `originSample` is the sequence sample (at sampleRate()) of the
    /// block's first frame; it is used by continuation epochs. Ignored unless the clock runs in
    /// AudioSamples mode with `epoch` current (or kAnyEpoch).
    void advanceSamples(int64_t frames, uint64_t hostNanos = 0, uint32_t epoch = kAnyEpoch,
                        int64_t originSample = -1) noexcept;

    // MARK: Readers (any thread)

    /// Current sequence time (monotonic within an epoch, see header).
    CMTime now() const noexcept;
    double nowSeconds() const noexcept { return CMTimeGetSeconds(now()); }
    /// Sequence time at host time `hostNanos` (e.g. a display link's target presentation
    /// time). Same formula as now() but without the monotonic guard (callers that need
    /// monotonic presentation keep their own per-epoch guard).
    CMTime timeAt(uint64_t hostNanos) const noexcept;

    double rate() const noexcept;
    ClockMode mode() const noexcept;
    bool isRunning() const noexcept { return mode() != ClockMode::Stopped; }
    uint32_t epoch() const noexcept;
    /// Output samples reported in the current epoch.
    int64_t samplesRendered() const noexcept;
    /// Host time of the last advanceSamples of the current epoch (0 if none yet).
    uint64_t lastCallbackNanos() const noexcept;
    /// Number of control calls that overlapped another control call (contract violations).
    uint64_t controlViolations() const noexcept { return controlViolations_.load(std::memory_order_relaxed); }

    const std::shared_ptr<HostClock> &hostClock() const noexcept { return host_; }

  private:
    struct Anchor {
        int64_t value = 0; // origin time, value/timescale (continuation: the time at the switch)
        int32_t timescale = 1;
        uint32_t epoch = 1;
        double rate = 0.0;
        double sampleRate = 48000.0;
        double latency = 0.0;
        uint64_t hostNanos = 0; // HostTime origin; continuation: host time of the switch
        ClockMode mode = ClockMode::Stopped;
        bool continuation = false;
        double prefixRate = 0.0; // continuation: rate of the run being continued
    };
    struct Progress {
        uint32_t epoch = 0;
        int64_t samplesBefore = 0; // rendered before the last callback
        int64_t lastBlock = 0;     // frames of the last callback
        uint64_t lastHostNanos = 0;
        int64_t originSample = -1; // sequence sample of the epoch's first rendered frame
    };
    /// RAII detector of overlapping control calls.
    class ControlScope {
      public:
        explicit ControlScope(const Clock &clock);
        ~ControlScope();
        ControlScope(const ControlScope &) = delete;
        ControlScope &operator=(const ControlScope &) = delete;

      private:
        const Clock &clock_;
    };

    /// Audible output time since the epoch's first sample became audible, in
    /// kPreciseTimescale ticks; negative while that sample is not audible yet (or before the
    /// first callback: INT64_MIN).
    int64_t audibleTicks(const Anchor &anchor, const Progress &progress, uint64_t hostNanos) const noexcept;
    CMTime evaluate(const Anchor &anchor, const Progress &progress, uint64_t hostNanos) const noexcept;
    CMTime originTime(const Anchor &anchor) const noexcept;
    uint32_t publish(CMTime at, double rate, ClockMode mode, bool continuation = false, double prefixRate = 0.0,
                     uint64_t hostNanos = 0);
    /// A consistent (anchor, progress) pair.
    void snapshot(Anchor &anchor, Progress &progress) const noexcept;

    const std::shared_ptr<HostClock> host_;
    SeqLock<Anchor> anchor_;
    SeqLock<Progress> progress_;
    // Control-thread shadow of the anchor (single writer, so no need to re-read the seqlock).
    Anchor control_;
    // Monotonic guard for now(): epoch in the top 16 bits, the last returned time in
    // kPreciseTimescale ticks in the low 48.
    mutable std::atomic<uint64_t> guard_{0};
    mutable std::atomic<bool> controlBusy_{false};
    mutable std::atomic<uint64_t> controlViolations_{0};
};

} // namespace ve::audio
