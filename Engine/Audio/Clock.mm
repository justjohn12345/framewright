// Plain C++ (an .mm only for consistency with the rest of the engine).

#include "Clock.h"

#include <algorithm>
#include <cmath>

namespace ve::audio {

namespace {

constexpr int64_t kTicksPerSecond = kPreciseTimescale;
constexpr uint64_t kGuardTickMask = (uint64_t(1) << 48) - 1;

int64_t secondsToTicks(double seconds) {
    return static_cast<int64_t>(std::llround(seconds * static_cast<double>(kTicksPerSecond)));
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
    if (sampleRate > 0) {
        control_.sampleRate = sampleRate;
        anchor_.store(control_);
    }
}

double Clock::sampleRate() const noexcept {
    return anchor_.load().sampleRate;
}

void Clock::setOutputLatency(double seconds) {
    control_.latency = std::max(0.0, seconds);
    anchor_.store(control_);
}

uint32_t Clock::publish(CMTime at, double rate, ClockMode mode) {
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
    control_.hostNanos = host_->nowNanos();
    // Reset the monotonic guard before readers can see the new epoch (a stale guard of an
    // earlier epoch with the same 16-bit tag must not hold the clock back).
    guard_.store(static_cast<uint64_t>(next & 0xFFFF) << 48, std::memory_order_relaxed);
    anchor_.store(control_);
    return next;
}

uint32_t Clock::start(CMTime at, double rate, ClockMode mode) {
    if (rate == 0.0 || !std::isfinite(rate) || mode == ClockMode::Stopped) {
        return publish(at, 0.0, ClockMode::Stopped);
    }
    return publish(at, rate, mode);
}

uint32_t Clock::stop() {
    return publish(now(), 0.0, ClockMode::Stopped);
}

uint32_t Clock::setTime(CMTime t) {
    return publish(t, 0.0, ClockMode::Stopped);
}

void Clock::advanceSamples(int64_t frames, uint64_t hostNanos, uint32_t epoch) noexcept {
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
    } else {
        p.samplesBefore += p.lastBlock;
    }
    p.lastBlock = frames;
    p.lastHostNanos = hostNanos ? hostNanos : host_->nowNanos();
    progress_.store(p);
}

int64_t Clock::elapsedTicks(const Anchor &anchor, uint64_t hostNanos) const noexcept {
    switch (anchor.mode) {
    case ClockMode::Stopped:
        return 0;
    case ClockMode::HostTime:
        return hostNanos > anchor.hostNanos
                   ? static_cast<int64_t>((static_cast<__int128>(hostNanos - anchor.hostNanos) * kTicksPerSecond) /
                                          1'000'000'000)
                   : 0;
    case ClockMode::AudioSamples: {
        const Progress p = progress_.load();
        if (p.epoch != anchor.epoch || p.lastHostNanos == 0) {
            return 0;
        }
        const double sr = anchor.sampleRate;
        const double ticksPerSample = static_cast<double>(kTicksPerSecond) / sr;
        const bool exact = std::floor(ticksPerSample) == ticksPerSample;
        const int64_t base = exact ? p.samplesBefore * static_cast<int64_t>(ticksPerSample)
                                   : static_cast<int64_t>(std::llround(static_cast<double>(p.samplesBefore) * ticksPerSample));
        const double sinceCallback =
            hostNanos > p.lastHostNanos ? static_cast<double>(hostNanos - p.lastHostNanos) * 1e-9 : 0.0;
        const double cap = static_cast<double>(p.lastBlock) / sr + kMaxExtrapolationSeconds;
        const int64_t interp = secondsToTicks(std::min(sinceCallback, cap));
        return std::max<int64_t>(0, base + interp - secondsToTicks(anchor.latency));
    }
    }
    return 0;
}

CMTime Clock::compose(const Anchor &anchor, int64_t ticks) noexcept {
    const CMTime origin = CMTimeMake(anchor.value, anchor.timescale);
    if (ticks == 0 || anchor.rate == 0.0) {
        return origin;
    }
    const double scaled = anchor.rate * static_cast<double>(ticks);
    const bool integralRate = anchor.rate == std::floor(anchor.rate);
    const int64_t delta = integralRate ? static_cast<int64_t>(anchor.rate) * ticks : std::llround(scaled);
    return CMTimeAdd(origin, CMTimeMake(delta, kPreciseTimescale));
}

CMTime Clock::now() const noexcept {
    const Anchor anchor = anchor_.load();
    int64_t ticks = elapsedTicks(anchor, host_->nowNanos());
    if (anchor.mode != ClockMode::Stopped) {
        // Monotonic guard, per epoch.
        const uint64_t tag = static_cast<uint64_t>(anchor.epoch & 0xFFFF) << 48;
        uint64_t current = guard_.load(std::memory_order_relaxed);
        for (;;) {
            const bool sameEpoch = (current & ~kGuardTickMask) == tag;
            const int64_t previous = sameEpoch ? static_cast<int64_t>(current & kGuardTickMask) : -1;
            if (previous >= ticks) {
                ticks = previous;
                break;
            }
            const uint64_t desired = tag | (static_cast<uint64_t>(ticks) & kGuardTickMask);
            if (guard_.compare_exchange_weak(current, desired, std::memory_order_relaxed)) {
                break;
            }
        }
    }
    return compose(anchor, ticks);
}

CMTime Clock::timeAt(uint64_t hostNanos) const noexcept {
    const Anchor anchor = anchor_.load();
    return compose(anchor, elapsedTicks(anchor, hostNanos));
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
    const Anchor anchor = anchor_.load();
    const Progress p = progress_.load();
    return p.epoch == anchor.epoch ? p.samplesBefore + p.lastBlock : 0;
}

uint64_t Clock::lastCallbackNanos() const noexcept {
    const Anchor anchor = anchor_.load();
    const Progress p = progress_.load();
    return p.epoch == anchor.epoch ? p.lastHostNanos : 0;
}

} // namespace ve::audio
