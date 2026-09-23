// Plain C++ (an .mm only for consistency with the rest of the engine).

#include "Clock.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace ve::audio {

namespace {

constexpr int64_t kTicksPerSecond = kPreciseTimescale;
constexpr uint64_t kGuardTickMask = (uint64_t(1) << 48) - 1;
constexpr int64_t kNotAudible = std::numeric_limits<int64_t>::min();

int64_t secondsToTicks(double seconds) {
    return static_cast<int64_t>(std::llround(seconds * static_cast<double>(kTicksPerSecond)));
}

/// Signed host-time difference b - a in kPreciseTimescale ticks.
int64_t hostDeltaTicks(uint64_t a, uint64_t b) {
    const __int128 delta = static_cast<__int128>(b) - static_cast<__int128>(a);
    return static_cast<int64_t>((delta * kTicksPerSecond) / 1'000'000'000);
}

/// origin + rate * ticks (ticks in kPreciseTimescale), exact for integral rates.
CMTime compose(CMTime origin, double rate, int64_t ticks) {
    if (ticks == 0 || rate == 0.0) {
        return origin;
    }
    const bool integralRate = rate == std::floor(rate);
    const int64_t delta = integralRate ? static_cast<int64_t>(rate) * ticks
                                       : std::llround(rate * static_cast<double>(ticks));
    return CMTimeAdd(origin, CMTimeMake(delta, kPreciseTimescale));
}

/// Sequence time of sample `n` at `rate` Hz.
CMTime sampleTime(int64_t n, double rate) {
    if (rate == std::floor(rate) && rate > 0 && rate <= 0x7FFFFFFF) {
        return CMTimeMake(n, static_cast<int32_t>(rate));
    }
    return CMTimeMakeWithSeconds(static_cast<double>(n) / rate, kPreciseTimescale);
}

/// `t` in kPreciseTimescale ticks, clamped to the guard's 48-bit range.
uint64_t guardTicks(CMTime t) {
    const CMTime converted = CMTimeConvertScale(t, kPreciseTimescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    if (!CMTIME_IS_NUMERIC(converted) || converted.value <= 0) {
        return 0;
    }
    return std::min<uint64_t>(static_cast<uint64_t>(converted.value), kGuardTickMask);
}

} // namespace

const char *nameOf(ClockMode mode) {
    switch (mode) {
    case ClockMode::Stopped:
        return "stopped";
    case ClockMode::AudioSamples:
        return "audio";
    case ClockMode::HostTime:
        return "host";
    }
    return "?";
}

Clock::ControlScope::ControlScope(const Clock &clock) : clock_(clock) {
    if (clock_.controlBusy_.exchange(true, std::memory_order_acq_rel)) {
        clock_.controlViolations_.fetch_add(1, std::memory_order_relaxed);
    }
}

Clock::ControlScope::~ControlScope() {
    clock_.controlBusy_.store(false, std::memory_order_release);
}

Clock::Clock(std::shared_ptr<HostClock> hostClock, double sampleRate)
    : host_(hostClock ? std::move(hostClock) : HostClock::system()) {
    // Initialise the mach timebase static here, not lazily on the audio render thread (static
    // initialisation takes a lock).
    (void)HostClock::machToNanos(mach_absolute_time());
    control_.sampleRate = sampleRate > 0 ? sampleRate : 48000.0;
    control_.epoch = 1;
    anchor_.store(control_);
}

void Clock::setSampleRate(double sampleRate) {
    ControlScope scope(*this);
    if (sampleRate > 0) {
        control_.sampleRate = sampleRate;
        anchor_.store(control_);
    }
}

double Clock::sampleRate() const noexcept {
    return anchor_.load().sampleRate;
}

void Clock::setOutputLatency(double seconds) {
    ControlScope scope(*this);
    control_.latency = std::isfinite(seconds) ? std::max(0.0, seconds) : 0.0;
    anchor_.store(control_);
}

double Clock::outputLatency() const noexcept {
    return anchor_.load().latency;
}

uint32_t Clock::publish(CMTime at, double rate, ClockMode mode, bool continuation, double prefixRate,
                        uint64_t hostNanos) {
    if (!CMTIME_IS_NUMERIC(at)) {
        at = kCMTimeZero;
    }
    uint32_t next = control_.epoch + 1;
    if (next == kAnyEpoch) {
        next = 1;
    }
    control_.value = at.value;
    control_.timescale = at.timescale;
    control_.epoch = next;
    control_.rate = rate;
    control_.mode = mode;
    control_.hostNanos = hostNanos ? hostNanos : host_->nowNanos();
    control_.continuation = continuation;
    control_.prefixRate = prefixRate;
    // Seed the monotonic guard with the origin before readers can see the new epoch (a stale
    // guard of an earlier epoch with the same 16-bit tag must not hold the clock back).
    guard_.store((static_cast<uint64_t>(next & 0xFFFF) << 48) | guardTicks(at), std::memory_order_relaxed);
    anchor_.store(control_);
    return next;
}

uint32_t Clock::start(CMTime at, double rate, ClockMode mode) {
    ControlScope scope(*this);
    if (rate == 0.0 || !std::isfinite(rate) || mode == ClockMode::Stopped) {
        return publish(at, 0.0, ClockMode::Stopped);
    }
    return publish(at, rate, mode);
}

uint32_t Clock::startContinuation(double rate) {
    ControlScope scope(*this);
    const uint64_t hostNanos = host_->nowNanos();
    const CMTime t = now();
    if (!(rate > 0) || !std::isfinite(rate)) {
        return publish(t, 0.0, ClockMode::Stopped);
    }
    if (control_.mode == ClockMode::Stopped || !(control_.rate > 0)) {
        return publish(t, rate, ClockMode::AudioSamples);
    }
    return publish(t, rate, ClockMode::AudioSamples, true, control_.rate, hostNanos);
}

uint32_t Clock::stop() {
    ControlScope scope(*this);
    return publish(now(), 0.0, ClockMode::Stopped);
}

uint32_t Clock::setTime(CMTime t) {
    ControlScope scope(*this);
    return publish(t, 0.0, ClockMode::Stopped);
}

void Clock::advanceSamples(int64_t frames, uint64_t hostNanos, uint32_t epoch, int64_t originSample) noexcept {
    if (frames <= 0) {
        return;
    }
    const Anchor anchor = anchor_.load();
    if (anchor.mode != ClockMode::AudioSamples || (epoch != kAnyEpoch && epoch != anchor.epoch)) {
        return;
    }
    Progress p = progress_.load(); // single writer: this thread
    if (p.epoch != anchor.epoch) {
        p = Progress{};
        p.epoch = anchor.epoch;
        p.originSample = originSample;
    } else {
        p.samplesBefore += p.lastBlock;
    }
    p.lastBlock = frames;
    p.lastHostNanos = hostNanos ? hostNanos : host_->nowNanos();
    progress_.store(p);
}

void Clock::snapshot(Anchor &anchor, Progress &progress) const noexcept {
    anchor = anchor_.load();
    progress = progress_.load();
}

CMTime Clock::originTime(const Anchor &anchor) const noexcept {
    return CMTimeMake(anchor.value, anchor.timescale);
}

int64_t Clock::audibleTicks(const Anchor &anchor, const Progress &p, uint64_t hostNanos) const noexcept {
    if (p.epoch != anchor.epoch || p.lastHostNanos == 0) {
        return kNotAudible;
    }
    const double sr = anchor.sampleRate;
    const double ticksPerSample = static_cast<double>(kTicksPerSecond) / sr;
    const bool exact = std::floor(ticksPerSample) == ticksPerSample;
    const int64_t base = exact ? p.samplesBefore * static_cast<int64_t>(ticksPerSample)
                               : static_cast<int64_t>(std::llround(static_cast<double>(p.samplesBefore) * ticksPerSample));
    // Interpolate along the device timeline: backwards into the blocks already rendered (the
    // last callback's IO time is normally in the future), forwards up to the cap.
    const int64_t lower = -base;
    const int64_t upper = secondsToTicks(static_cast<double>(p.lastBlock) / sr + kMaxExtrapolationSeconds);
    const int64_t since = std::clamp(hostDeltaTicks(p.lastHostNanos, hostNanos), lower, upper);
    return base + since - secondsToTicks(anchor.latency);
}

CMTime Clock::evaluate(const Anchor &anchor, const Progress &progress, uint64_t hostNanos) const noexcept {
    const CMTime origin = originTime(anchor);
    switch (anchor.mode) {
    case ClockMode::Stopped:
        return origin;
    case ClockMode::HostTime:
        return compose(origin, anchor.rate, std::max<int64_t>(0, hostDeltaTicks(anchor.hostNanos, hostNanos)));
    case ClockMode::AudioSamples: {
        const int64_t audible = audibleTicks(anchor, progress, hostNanos);
        if (!anchor.continuation) {
            return compose(origin, anchor.rate, std::max<int64_t>(0, audible));
        }
        // Continuation: `origin` is the time at the switch.
        const CMTime prefix =
            compose(origin, anchor.prefixRate, std::max<int64_t>(0, hostDeltaTicks(anchor.hostNanos, hostNanos)));
        if (audible != kNotAudible && progress.originSample >= 0) {
            const CMTime renderOrigin = sampleTime(progress.originSample, anchor.sampleRate);
            if (audible >= 0) {
                return compose(renderOrigin, anchor.rate, audible);
            }
            // The previous run's audio is still playing out up to renderOrigin.
            return clampTime(prefix, origin, maxTime(origin, renderOrigin));
        }
        // No callback of the new epoch yet: follow the previous run, bounded by what can be in
        // flight (the output latency plus the extrapolation allowance).
        const CMTime cap = compose(origin, anchor.prefixRate,
                                   secondsToTicks(anchor.latency + kMaxExtrapolationSeconds));
        return minTime(prefix, cap);
    }
    }
    return origin;
}

CMTime Clock::now() const noexcept {
    Anchor anchor;
    Progress progress;
    snapshot(anchor, progress);
    const CMTime t = evaluate(anchor, progress, host_->nowNanos());
    if (anchor.mode == ClockMode::Stopped) {
        return t;
    }
    // Monotonic guard, per epoch, on the absolute time.
    const uint16_t epoch16 = static_cast<uint16_t>(anchor.epoch & 0xFFFF);
    const uint64_t tag = static_cast<uint64_t>(epoch16) << 48;
    const uint64_t ticks = guardTicks(t);
    const bool forward = anchor.rate >= 0;
    uint64_t current = guard_.load(std::memory_order_relaxed);
    for (;;) {
        const uint16_t currentEpoch16 = static_cast<uint16_t>(current >> 48);
        if (currentEpoch16 == epoch16) {
            const uint64_t previous = current & kGuardTickMask;
            if (forward ? previous >= ticks : previous <= ticks) {
                return previous == ticks ? t : CMTimeMake(static_cast<int64_t>(previous), kPreciseTimescale);
            }
        } else if (static_cast<int16_t>(currentEpoch16 - epoch16) > 0) {
            return t; // this reader is stale: a newer epoch owns the guard
        }
        if (guard_.compare_exchange_weak(current, tag | ticks, std::memory_order_relaxed)) {
            return t;
        }
    }
}

CMTime Clock::timeAt(uint64_t hostNanos) const noexcept {
    Anchor anchor;
    Progress progress;
    snapshot(anchor, progress);
    return evaluate(anchor, progress, hostNanos);
}

double Clock::rate() const noexcept {
    return anchor_.load().rate;
}

ClockMode Clock::mode() const noexcept {
    return anchor_.load().mode;
}

uint32_t Clock::epoch() const noexcept {
    return anchor_.load().epoch;
}

int64_t Clock::samplesRendered() const noexcept {
    Anchor anchor;
    Progress p;
    snapshot(anchor, p);
    return p.epoch == anchor.epoch ? p.samplesBefore + p.lastBlock : 0;
}

uint64_t Clock::lastCallbackNanos() const noexcept {
    Anchor anchor;
    Progress p;
    snapshot(anchor, p);
    return p.epoch == anchor.epoch ? p.lastHostNanos : 0;
}

} // namespace ve::audio
