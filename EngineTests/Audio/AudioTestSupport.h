// Test doubles for the clock, mixer and output tests: a backend whose audio decoder synthesises
// a known signal per path (sample-exact, so mixer output can be predicted per sample), with a
// gate to starve the producer; and a per-thread heap allocation counter.
#pragma once

#include "../../Engine/Media/BackendRouter.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>

namespace ve::test {

/// The signal of one fake audio file, at the decoder's output rate: value(sample, channel).
using ToneSignal = std::function<float(int64_t sample, int channel)>;

struct ToneBehavior {
    std::mutex mutex;
    std::map<std::string, ToneSignal> signals; ///< By path; unknown paths fail to probe.
    int64_t lengthFrames = 48000 * 20;
    std::condition_variable gateCv;
    std::atomic<int> opens{0};
    std::atomic<int> seeks{0};
    std::atomic<int64_t> framesRead{0};

    void setSignal(const std::string &path, ToneSignal signal) {
        std::lock_guard<std::mutex> lock(mutex);
        signals[path] = std::move(signal);
    }
    /// Blocks (true) or releases (false) every decoder read(), starving the producers.
    void setReadsBlocked(bool blocked) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            readsBlocked = blocked;
        }
        gateCv.notify_all();
    }
    bool readsBlocked = false; ///< Guarded by `mutex`.
};

/// A router whose only backend ("tone") serves the paths registered in `behavior`.
std::shared_ptr<media::BackendRouter> makeToneRouter(std::shared_ptr<ToneBehavior> behavior);

/// sin(2 pi f n / rate) * amplitude.
ToneSignal sineSignal(double frequency, double amplitude, double rate = 48000.0);
/// A constant per channel (channel 0: c0, channel >= 1: c1).
ToneSignal constantSignal(float c0, float c1);

/// Counts heap allocations and frees made by the calling thread between start() and stop()
/// (through libmalloc's malloc_logger hook, which sees malloc/calloc/realloc/free and
/// operator new/delete). One counter may be active at a time.
class AllocationCounter {
  public:
    AllocationCounter();
    ~AllocationCounter();
    void start();
    /// Returns the number of allocation events seen since start().
    uint64_t stop();
};

} // namespace ve::test
