// Audio outputs: the null output paces the clock at the mixer rate (realtime) or exactly per
// block (manual); the AVAudioEngine output runs when a device exists and is skipped otherwise;
// the automatic output falls back to the null output.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/AudioOutput.h"
#include "AudioTestSupport.h"

#include <chrono>
#include <thread>

using namespace ve;
using namespace ve::audio;
using namespace ve::test;

namespace {

struct OutputFixture {
    std::shared_ptr<ToneBehavior> tones = std::make_shared<ToneBehavior>();
    std::shared_ptr<media::BackendRouter> router = makeToneRouter(tones);
    std::shared_ptr<HostClock> host;
    std::unique_ptr<Clock> clock;
    std::unique_ptr<AudioMixer> mixer;

    explicit OutputFixture(std::shared_ptr<HostClock> hostClock = HostClock::system()) : host(std::move(hostClock)) {
        clock = std::make_unique<Clock>(host, 48000.0);
        mixer = std::make_unique<AudioMixer>(router, clock.get());
    }
    /// Starts the clock and the (empty) mix at 0.
    void startTransport() {
        const uint32_t epoch = clock->start(kCMTimeZero, 1.0);
        mixer->start(kCMTimeZero, 1, epoch);
    }
};

double wallSince(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count();
}

} // namespace

@interface AudioOutputTests : XCTestCase
@end

@implementation AudioOutputTests

- (void)testNullOutputDrivesTheClockInRealTime {
    OutputFixture fx;
    NullAudioOutput output(*fx.mixer);
    fx.startTransport();
    XCTAssertTrue(output.start().ok());
    XCTAssertTrue(output.isRunning());
    // Measure from the first rendered block.
    while (fx.clock->samplesRendered() == 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const double clockStart = CMTimeGetSeconds(fx.clock->now());
    const auto wallStart = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    const double clockElapsed = CMTimeGetSeconds(fx.clock->now()) - clockStart;
    const double wall = wallSince(wallStart);
    output.stop();
    XCTAssertFalse(output.isRunning());
    XCTAssertEqualWithAccuracy(clockElapsed / wall, 1.0, 0.01, @"clock %.4f s over %.4f s wall", clockElapsed, wall);
    NSLog(@"NullAudioOutput: clock advanced %.4f s in %.4f s wall (ratio %.5f)", clockElapsed, wall, clockElapsed / wall);
    // Stopped: the clock no longer moves (beyond the interpolation cap of the last block).
    const double stoppedAt = CMTimeGetSeconds(fx.clock->now());
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    XCTAssertLessThanOrEqual(CMTimeGetSeconds(fx.clock->now()) - stoppedAt, 512.0 / 48000 + Clock::kMaxExtrapolationSeconds);
}

- (void)testManualNullOutputIsExactAndDeterministic {
    auto host = HostClock::makeVirtual();
    OutputFixture fx(host);
    NullAudioOutputConfig config;
    config.mode = NullAudioOutputConfig::Mode::Manual;
    config.virtualClock = host;
    config.blockFrames = 480;
    config.captureFrames = 48000;
    NullAudioOutput output(*fx.mixer, config);
    XCTAssertEqual(output.renderBlocks(1), 0, @"not started");
    fx.startTransport();
    XCTAssertTrue(output.start().ok());
    const uint64_t hostStart = host->nowNanos();
    XCTAssertEqual(output.renderBlocks(100), 48000);
    XCTAssertEqual(host->nowNanos() - hostStart, 1'000'000'000ull, @"virtual time advances by exactly 1 s");
    XCTAssertEqual(fx.clock->samplesRendered(), 48000);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(fx.clock->now()), 1.0, 1e-9);
    const NullAudioOutput::Capture capture = output.capture();
    XCTAssertEqual(capture.samples.size(), 48000u * 2);
    XCTAssertEqual(capture.firstSequenceSample, 0);
    // Muted outputs still drive the clock.
    output.setMuted(true);
    output.renderBlocks(10);
    XCTAssertEqual(fx.clock->samplesRendered(), 52800);
    NullAudioOutputConfig bad;
    bad.mode = NullAudioOutputConfig::Mode::Manual;
    NullAudioOutput noClock(*fx.mixer, bad);
    XCTAssertFalse(noClock.start().ok(), @"manual mode needs a virtual clock");
}

- (void)testAVAudioEngineOutputWhenADeviceExists {
    OutputFixture fx;
    auto created = AudioOutput::create(*fx.mixer, fx.clock.get());
    if (!created.ok()) {
        XCTSkip(@"AVAudioEngine unavailable: %s", created.error().description().c_str());
    }
    std::unique_ptr<AudioOutput> output = std::move(created).value();
    output->setMuted(true); // never make noise in tests
    fx.startTransport();
    auto started = output->start();
    if (!started.ok()) {
        XCTSkip(@"no audio output device: %s", started.error().description().c_str());
    }
    XCTAssertTrue(output->isRunning());
    // Measure once the first samples are audible: engine start-up plus the output latency
    // (which the clock subtracts) have passed.
    const auto waitStart = std::chrono::steady_clock::now();
    while (CMTimeGetSeconds(fx.clock->now()) < 0.01 && wallSince(waitStart) < 5.0) {
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
    XCTAssertGreaterThan(fx.clock->samplesRendered(), 0);
    const double origin = CMTimeGetSeconds(fx.clock->now());
    const auto wallStart = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(600));
    const double first = CMTimeGetSeconds(fx.clock->now());
    XCTAssertEqualWithAccuracy(first - origin, wallSince(wallStart), 0.06, @"device clock runs in real time");
    NSLog(@"AVAudioEngine output: device %.0f Hz, latency %.1f ms, clock %.3f s after %.3f s",
          output->deviceSampleRate(), output->outputLatency() * 1000, first, wallSince(wallStart));

    // A device change: the engine restarts and the clock continues from where it was.
    output->handleConfigurationChange();
    XCTAssertEqual(output->configurationChanges(), 1u);
    XCTAssertTrue(output->isRunning());
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(fx.clock->now()), first);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    const double after = CMTimeGetSeconds(fx.clock->now());
    XCTAssertGreaterThan(after, first + 0.1, @"clock keeps running after the restart");
    output->stop();
    XCTAssertFalse(output->isRunning());
}

- (void)testAutomaticOutputRunsOrFallsBack {
    OutputFixture fx;
    AutomaticAudioOutput output(*fx.mixer, fx.clock.get());
    output.setMuted(true);
    fx.startTransport();
    XCTAssertTrue(output.start().ok());
    const std::string kind = output.kind();
    XCTAssertTrue(kind == "avaudioengine" || kind == "null", @"%s", kind.c_str());
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    XCTAssertGreaterThan(fx.clock->samplesRendered(), 0);
    NSLog(@"AutomaticAudioOutput uses %s%s%s", kind.c_str(), output.fallbackReason().empty() ? "" : ": ",
          output.fallbackReason().c_str());
    output.stop();
    XCTAssertFalse(output.isRunning());
}

@end
