// Lock-free building blocks shared by the clock, the audio mixer and the playback controller:
// a host time source that tests can virtualise, a seqlock for small trivially copyable
// snapshots, and a bounded single-producer/single-consumer queue.
//
// Everything here is realtime-safe on the paths documented as such: no locks, no allocation
// (after construction), no Objective-C, no system calls other than mach_absolute_time.
//
// Data is stored in std::atomic words (relaxed) guarded by acquire/release sequence counters,
// so the structures are free of data races in the C++ memory model (and under Thread
// Sanitizer), not just "benign" races.

#pragma once

#include <mach/mach_time.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <type_traits>

namespace ve::audio {

// MARK: - Host time

/// Source of host time in nanoseconds. The system clock reads mach_absolute_time (the same
/// timebase as CADisplayLink and CACurrentMediaTime). A virtual clock only moves when advance()
/// or set() is called: tests and the accelerated NullAudioOutput use it to run playback faster
/// than real time with deterministic interpolation.
///
/// Threading: nowNanos() is lock-free and realtime-safe from any thread. advance()/set() may be
/// called from any thread (virtual clocks only; ignored by the system clock).
class HostClock {
  public:
    /// The shared system clock.
    static std::shared_ptr<HostClock> system() {
        static const std::shared_ptr<HostClock> clock(new HostClock(false, 0));
        return clock;
    }
    /// A virtual clock starting at `startNanos`.
    static std::shared_ptr<HostClock> makeVirtual(uint64_t startNanos = 1'000'000'000ull) {
        return std::shared_ptr<HostClock>(new HostClock(true, startNanos));
    }

    bool isVirtual() const noexcept { return virtual_; }

    uint64_t nowNanos() const noexcept {
        if (virtual_) {
            return virtualNow_.load(std::memory_order_acquire);
        }
        return machToNanos(mach_absolute_time());
    }

    void advance(uint64_t nanos) noexcept {
        if (virtual_) {
            virtualNow_.fetch_add(nanos, std::memory_order_acq_rel);
        }
    }
    void set(uint64_t nanos) noexcept {
        if (virtual_) {
            virtualNow_.store(nanos, std::memory_order_release);
        }
    }

    static uint64_t machToNanos(uint64_t ticks) noexcept {
        const mach_timebase_info_data_t &tb = timebase();
        if (tb.numer == tb.denom) {
            return ticks;
        }
        // 128-bit intermediate: no overflow for any realistic uptime.
        return static_cast<uint64_t>((static_cast<unsigned __int128>(ticks) * tb.numer) / tb.denom);
    }
    static uint64_t nanosToMach(uint64_t nanos) noexcept {
        const mach_timebase_info_data_t &tb = timebase();
        if (tb.numer == tb.denom) {
            return nanos;
        }
        return static_cast<uint64_t>((static_cast<unsigned __int128>(nanos) * tb.denom) / tb.numer);
    }
    /// Host time in seconds (CACurrentMediaTime / CADisplayLink timestamps) to nanoseconds.
    static uint64_t secondsToNanos(double seconds) noexcept {
        return seconds <= 0 ? 0 : static_cast<uint64_t>(seconds * 1e9 + 0.5);
    }

  private:
    HostClock(bool isVirtualClock, uint64_t start) : virtual_(isVirtualClock), virtualNow_(start) {}

    static const mach_timebase_info_data_t &timebase() noexcept {
        static const mach_timebase_info_data_t tb = [] {
            mach_timebase_info_data_t info{};
            mach_timebase_info(&info);
            if (info.denom == 0) {
                info.numer = info.denom = 1;
            }
            return info;
        }();
        return tb;
    }

    const bool virtual_;
    std::atomic<uint64_t> virtualNow_;
};

// MARK: - SeqLock

/// A sequence lock holding one trivially copyable T.
///
/// Threading: exactly one writer at a time (callers serialise writers externally); any number
/// of concurrent readers. store() is wait-free; load() is lock-free (it retries while a write
/// is in progress, which lasts a few stores). Both are realtime-safe.
template <class T> class SeqLock {
    static_assert(std::is_trivially_copyable_v<T>, "SeqLock needs a trivially copyable type");
    static constexpr size_t kWords = (sizeof(T) + sizeof(uint64_t) - 1) / sizeof(uint64_t);

  public:
    SeqLock() { store(T{}); }
    explicit SeqLock(const T &value) { store(value); }

    void store(const T &value) noexcept {
        std::array<uint64_t, kWords> words{};
        std::memcpy(words.data(), &value, sizeof(T));
        const uint64_t s = sequence_.load(std::memory_order_relaxed);
        sequence_.store(s + 1, std::memory_order_relaxed); // odd: write in progress
        std::atomic_thread_fence(std::memory_order_release);
        for (size_t i = 0; i < kWords; ++i) {
            words_[i].store(words[i], std::memory_order_relaxed);
        }
        sequence_.store(s + 2, std::memory_order_release);
    }

    T load() const noexcept {
        std::array<uint64_t, kWords> words{};
        for (;;) {
            const uint64_t before = sequence_.load(std::memory_order_acquire);
            if (before & 1u) {
                continue;
            }
            for (size_t i = 0; i < kWords; ++i) {
                words[i] = words_[i].load(std::memory_order_relaxed);
            }
            std::atomic_thread_fence(std::memory_order_acquire);
            if (sequence_.load(std::memory_order_relaxed) == before) {
                break;
            }
        }
        T value;
        std::memcpy(&value, words.data(), sizeof(T));
        return value;
    }

  private:
    std::atomic<uint64_t> sequence_{0};
    std::array<std::atomic<uint64_t>, kWords> words_{};
};

// MARK: - SPSC queue

/// Bounded single-producer/single-consumer queue of trivially copyable values (pointers,
/// indices). Capacity is a power of two fixed at compile time; storage is inline.
///
/// Threading: one producer thread calls push(), one consumer thread calls pop(); both are
/// wait-free and realtime-safe. size() may be called from anywhere (approximate).
template <class T, size_t Capacity> class SpscQueue {
    static_assert((Capacity & (Capacity - 1)) == 0, "capacity must be a power of two");
    static_assert(std::is_trivially_copyable_v<T>, "SpscQueue needs a trivially copyable type");

  public:
    /// False when full (the value is not queued).
    bool push(const T &value) noexcept {
        const size_t head = head_.load(std::memory_order_relaxed);
        if (head - tail_.load(std::memory_order_acquire) >= Capacity) {
            return false;
        }
        slots_[head & (Capacity - 1)].store(value, std::memory_order_relaxed);
        head_.store(head + 1, std::memory_order_release);
        return true;
    }
    /// False when empty.
    bool pop(T &value) noexcept {
        const size_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) {
            return false;
        }
        value = slots_[tail & (Capacity - 1)].load(std::memory_order_relaxed);
        tail_.store(tail + 1, std::memory_order_release);
        return true;
    }
    size_t size() const noexcept {
        return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire);
    }

  private:
    std::array<std::atomic<T>, Capacity> slots_{};
    std::atomic<size_t> head_{0};
    std::atomic<size_t> tail_{0};
};

/// Stores `value` into `target` if it is larger (lock-free).
inline void atomicMax(std::atomic<int64_t> &target, int64_t value) noexcept {
    int64_t current = target.load(std::memory_order_relaxed);
    while (current < value && !target.compare_exchange_weak(current, value, std::memory_order_relaxed)) {
    }
}

} // namespace ve::audio
