// Clock: sample-driven interpolation, monotonicity, rates, epochs, host-time fallback.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/Clock.h"

#include <thread>

using namespace ve;
using namespace ve::audio;

namespace {

constexpr uint64_t kMs = 1'000'000ull;
constexpr double kRate = 48000.0;

double seconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

} // namespace

@interface ClockTests : XCTestCase
@end

@implementation ClockTests

- (void)testStartsStoppedAtZero {
    Clock clock(HostClock::makeVirtual());
    XCTAssertEqual(clock.mode(), ClockMode::Stopped);
    XCTAssertEqual(seconds(clock.now()), 0.0);
    clock.setTime(CMTimeMake(3, 1));
    XCTAssertEqual(seconds(clock.now()), 3.0);
    XCTAssertFalse(clock.isRunning());
}

- (void)testAudioModeHoldsAtAnchorUntilFirstCallback {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(CMTimeMake(2, 1), 1.0);
    host->advance(50 * kMs);
    XCTAssertEqual(seconds(clock.now()), 2.0, @"no audio rendered yet: video waits for audio");
    clock.advanceSamples(512);
    XCTAssertEqual(seconds(clock.now()), 2.0, @"the first block starts at the anchor");
    host->advance(5 * kMs);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 2.005, 1e-9);
}

- (void)testInterpolationIsMonotonicAndTracksSamplesAcrossJitter {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(kCMTimeZero, 1.0);
    const int block = 512;
    const uint64_t blockNanos = static_cast<uint64_t>(block * 1e9 / kRate);
    double previous = -1.0;
    double maxError = 0.0;
    int64_t rendered = 0;
    for (int i = 0; i < 400; ++i) {
        // Callbacks arrive with up to +-2 ms of jitter around their nominal time.
        const int64_t jitter = (i % 7 - 3) * static_cast<int64_t>(kMs) * 2 / 3;
        const uint64_t nominal = static_cast<uint64_t>(i) * blockNanos;
        host->set(1'000'000'000ull + static_cast<uint64_t>(std::max<int64_t>(0, static_cast<int64_t>(nominal) + jitter)));
        clock.advanceSamples(block);
        rendered += block;
        // Sample the clock 8 times until the next nominal callback.
        for (int k = 0; k < 8; ++k) {
            const double now = seconds(clock.now());
            XCTAssertGreaterThanOrEqual(now, previous, @"monotonic at block %d probe %d", i, k);
            previous = now;
            const double audio = static_cast<double>(rendered - block) / kRate;
            maxError = std::max(maxError, std::fabs(now - audio));
            host->advance(blockNanos / 8);
        }
    }
    XCTAssertEqual(clock.samplesRendered(), rendered);
    // Interpolation stays within one block (+ extrapolation cap) of the rendered position.
    XCTAssertLessThan(maxError, (block / kRate) + Clock::kMaxExtrapolationSeconds);
    NSLog(@"clock vs rendered samples, max deviation with +-2 ms jitter: %.3f ms", maxError * 1000);
}

- (void)testExactAtCallbackBoundariesAndRationalTime {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(CMTimeMake(1001, 30000), 1.0); // odd anchor
    for (int i = 0; i < 1000; ++i) {
        clock.advanceSamples(480);
    }
    // No host time elapsed since the last callback: exactly the samples before it.
    const CMTime t = clock.now();
    const CMTime expected = CMTimeAdd(CMTimeMake(1001, 30000), CMTimeMake(999 * 480, 48000));
    XCTAssertEqual(CMTimeCompare(t, expected), 0, @"%s", describe(t).c_str());
}

- (void)testStallsWhenAudioStops {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(kCMTimeZero, 1.0);
    clock.advanceSamples(480); // 10 ms block
    host->advance(500 * kMs);  // device stalls
    const double capped = seconds(clock.now());
    XCTAssertEqualWithAccuracy(capped, 0.010 + Clock::kMaxExtrapolationSeconds, 1e-6);
    clock.advanceSamples(480);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), capped, 1e-9, @"held by the monotonic guard until audio catches up");
}

- (void)testRateTwoAdvancesTwiceAsFast {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(CMTimeMake(1, 1), 2.0);
    for (int i = 0; i < 100; ++i) {
        clock.advanceSamples(480);
        host->advance(10 * kMs);
    }
    // 100 blocks of 10 ms: 1.0 s of output -> 2.0 s of sequence.
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 1.0 + 2.0, 1e-6);
    XCTAssertEqual(clock.rate(), 2.0);
}

- (void)testNegativeRateHostModeRunsBackwardsMonotonically {
    auto host = HostClock::makeVirtual();
    Clock clock(host);
    clock.start(CMTimeMake(5, 1), -1.0, ClockMode::HostTime);
    double previous = 1e9;
    for (int i = 0; i < 100; ++i) {
        host->advance(10 * kMs);
        const double now = seconds(clock.now());
        XCTAssertLessThanOrEqual(now, previous);
        previous = now;
    }
    XCTAssertEqualWithAccuracy(previous, 4.0, 1e-6);
    clock.advanceSamples(48000); // ignored in host mode
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 4.0, 1e-6);
}

- (void)testHighRateHostMode {
    auto host = HostClock::makeVirtual();
    Clock clock(host);
    clock.start(kCMTimeZero, 8.0, ClockMode::HostTime);
    host->advance(250 * kMs);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 2.0, 1e-6);
}

- (void)testStopFreezesAndStartResumesFromAnchor {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(kCMTimeZero, 1.0);
    for (int i = 0; i < 50; ++i) {
        clock.advanceSamples(480);
    }
    host->advance(3 * kMs);
    const double atStop = seconds(clock.now());
    clock.stop();
    XCTAssertEqual(clock.mode(), ClockMode::Stopped);
    host->advance(1000 * kMs);
    clock.advanceSamples(48000); // audio thread still running: ignored while stopped
    XCTAssertEqualWithAccuracy(seconds(clock.now()), atStop, 1e-9);

    const uint32_t epoch = clock.start(clock.now(), 1.0);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), atStop, 1e-9);
    clock.advanceSamples(480, 0, epoch);
    host->advance(10 * kMs);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), atStop + 0.010, 1e-6);
}

- (void)testSamplesFromAnOldEpochAreIgnored {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    const uint32_t first = clock.start(kCMTimeZero, 1.0);
    clock.advanceSamples(480, 0, first);
    const uint32_t second = clock.start(CMTimeMake(10, 1), 1.0); // seek while a callback is in flight
    XCTAssertNotEqual(first, second);
    clock.advanceSamples(48000, 0, first); // the stale callback finishes
    XCTAssertEqual(clock.samplesRendered(), 0);
    XCTAssertEqual(seconds(clock.now()), 10.0);
    clock.advanceSamples(480, 0, second);
    host->advance(10 * kMs);
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 10.010, 1e-6);
}

- (void)testOutputLatencyDelaysTheAudibleClock {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.setOutputLatency(0.020);
    clock.start(kCMTimeZero, 1.0);
    for (int i = 0; i < 10; ++i) {
        clock.advanceSamples(480);
    }
    // 9 blocks before the last callback = 90 ms rendered, 20 ms still in flight.
    XCTAssertEqualWithAccuracy(seconds(clock.now()), 0.070, 1e-6);
}

- (void)testTimeAtExtrapolatesToPresentationTime {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(kCMTimeZero, 1.0);
    clock.advanceSamples(960); // 20 ms block
    const uint64_t callback = clock.lastCallbackNanos();
    XCTAssertEqualWithAccuracy(seconds(clock.timeAt(callback + 16 * kMs)), 0.016, 1e-6);
    XCTAssertEqual(seconds(clock.now()), 0.0, @"timeAt does not move the monotonic guard");
}

- (void)testHostTimeFallbackFollowsTheSystemClock {
    Clock clock; // system host clock
    const auto wallStart = std::chrono::steady_clock::now();
    clock.start(kCMTimeZero, 1.0, ClockMode::HostTime);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - wallStart).count();
    const double now = seconds(clock.now());
    XCTAssertEqualWithAccuracy(now, elapsed, 0.005);
}

- (void)testConcurrentReadersSeeMonotonicTime {
    auto host = HostClock::makeVirtual();
    Clock clock(host, kRate);
    clock.start(kCMTimeZero, 1.0);
    std::atomic<bool> done{false};
    std::atomic<int> violations{0};
    std::vector<std::thread> readers;
    for (int r = 0; r < 3; ++r) {
        readers.emplace_back([&] {
            double previous = 0.0;
            while (!done.load()) {
                const double now = seconds(clock.now());
                if (now < previous) {
                    ++violations;
                }
                previous = now;
            }
        });
    }
    for (int i = 0; i < 20000; ++i) {
        clock.advanceSamples(256);
        host->advance(5 * kMs / 2);
    }
    done = true;
    for (auto &t : readers) {
        t.join();
    }
    XCTAssertEqual(violations.load(), 0);
}

@end
