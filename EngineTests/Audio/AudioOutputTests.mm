// Audio outputs: the null output paces the clock at the mixer rate (realtime) or exactly per
// block (manual); the AVAudioEngine output passes the device's IO timestamps (checked against
// the sample count tightly enough to catch a 44.1/48 kHz mix-up), reports its latency
// components, handles configuration changes on its own queue and survives teardown with a
// change in flight; it is skipped without a device. The automatic output falls back to the null
// output and retries the engine later.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/AudioOutput.h"
#include "AudioTestSupport.h"

#include <chrono>
#include <cmath>
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

bool waitUntil(const std::function<bool()> &condition, double seconds = 5.0) {
    const auto start = std::chrono::steady_clock::now();
    while (!condition()) {
        if (wallSince(start) > seconds) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

/// A stand-in for the engine: fails to start until `available`.
class FakeEngine final : public IAudioOutput {
  public:
    explicit FakeEngine(std::shared_ptr<std::atomic<bool>> available) : available_(std::move(available)) {}
    media::Status start() override {
        if (!available_->load()) {
            return media::makeError(media::MediaErrorCode::InvalidState, "fake: no device");
        }
        running_ = true;
        return media::okStatus();
    }
    void stop() override { running_ = false; }
    bool isRunning() const override { return running_.load(); }
    void setMuted(bool muted) override { muted_ = muted; }
    bool isMuted() const override { return muted_.load(); }
    std::string kind() const override { return "fake"; }
    double outputLatency() const override { return 0.042; }

  private:
    std::shared_ptr<std::atomic<bool>> available_;
    std::atomic<bool> running_{false};
    std::atomic<bool> muted_{false};
};

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
    XCTAssertTrue(waitUntil([&] { return fx.clock->samplesRendered() > 0; }));
    const double clockStart = CMTimeGetSeconds(fx.clock->now());
    const auto wallStart = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    const double clockElapsed = CMTimeGetSeconds(fx.clock->now()) - clockStart;
    const double wall = wallSince(wallStart);
    output.stop();
    XCTAssertFalse(output.isRunning());
    // Wall-clock bound: the null output paces itself with mach_wait_until against the system
    // clock and re-anchors after stalls over 100 ms, so a loaded machine (sanitizers) loses at
    // most a few percent; a 44.1/48 kHz mix-up would be 8.8 %.
    XCTAssertEqualWithAccuracy(clockElapsed / wall, 1.0, 0.03, @"clock %.4f s over %.4f s wall", clockElapsed, wall);
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
    auto created = AudioOutput::create(*fx.mixer);
    if (!created.ok()) {
        XCTSkip(@"AVAudioEngine unavailable: %s", created.error().description().c_str());
    }
    std::unique_ptr<AudioOutput> output = std::move(created).value();
    output->setMuted(true); // never make noise in tests
    output->captureTimeline(4096);
    std::atomic<int> events{0};
    std::atomic<bool> lastRunning{false};
    output->setEventHandler([&](const AudioOutputEvent &event) {
        lastRunning = event.running;
        ++events;
    });
    fx.startTransport();
    auto started = output->start();
    if (!started.ok()) {
        XCTSkip(@"no audio output device: %s", started.error().description().c_str());
    }
    XCTAssertTrue(output->isRunning());
    XCTAssertTrue(waitUntil([&] { return fx.clock->samplesRendered() >= 48000; }));
    // The device's own timeline: sequence samples per second of IO time. Deterministic (the IO
    // timestamps come from the device, not from when the callbacks ran) and tight: a 44.1 vs
    // 48 kHz counting error is 8.8 %, the tolerance 0.1 %.
    const auto timeline = output->drainTimeline();
    XCTAssertGreaterThan(timeline.size(), 50u);
    const AudioOutput::TimelineEntry *first = nullptr;
    const AudioOutput::TimelineEntry *last = nullptr;
    for (const auto &e : timeline) {
        if (e.transportSample >= 0) {
            first = first ? first : &e;
            last = &e;
        }
    }
    XCTAssertTrue(first && last && first != last);
    double rate = 0;
    if (first && last && first != last) {
        rate = static_cast<double>(last->transportSample - first->transportSample) /
               (static_cast<double>(last->ioHostNanos - first->ioHostNanos) * 1e-9);
        XCTAssertEqualWithAccuracy(rate, 48000.0, 48.0);
    }
    XCTAssertEqual(fx.clock->outputLatency(), 0.0, @"the output never writes the clock (its owner does)");
    const AudioOutput::LatencyBreakdown b = output->latencyBreakdown();
    XCTAssertEqualWithAccuracy(output->outputLatency(), b.total, 1e-12);
    XCTAssertGreaterThan(b.deviceSampleRate, 0.0);
    NSLog(@"AVAudioEngine output: device %.0f Hz, %.2f sequence samples per IO second, latency %.1f ms "
          @"(presentation %.1f, pipeline %.1f, converter %.3f), buffer %u frames",
          b.deviceSampleRate, rate, b.total * 1000, b.presentationLatency * 1000, b.pipelineLatency * 1000,
          b.converterDelay * 1000, b.bufferFrames);

    // A device change: the engine restarts, reports the event, and the sample clock continues
    // from where it was.
    const double beforeChange = CMTimeGetSeconds(fx.clock->now());
    output->handleConfigurationChange();
    XCTAssertEqual(output->configurationChanges(), 1u);
    XCTAssertTrue(output->isRunning());
    XCTAssertEqual(events.load(), 1);
    XCTAssertTrue(lastRunning.load());
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(fx.clock->now()), beforeChange);
    const int64_t samples = fx.clock->samplesRendered();
    XCTAssertTrue(waitUntil([&] { return fx.clock->samplesRendered() > samples + 4800; }), @"clock keeps running");
    // Through the real notification path (observer -> the output's serial queue).
    output->postConfigurationChangeNotification();
    XCTAssertTrue(waitUntil([&] { return output->configurationChanges() == 2; }));
    XCTAssertTrue(waitUntil([&] { return events.load() == 2; }));
    output->stop();
    XCTAssertFalse(output->isRunning());
}

- (void)testTeardownWithConfigurationChangesInFlight {
    OutputFixture fx;
    for (int round = 0; round < 5; ++round) {
        auto created = AudioOutput::create(*fx.mixer);
        if (!created.ok()) {
            XCTSkip(@"AVAudioEngine unavailable");
        }
        std::unique_ptr<AudioOutput> output = std::move(created).value();
        output->setMuted(true);
        std::atomic<int> events{0};
        output->setEventHandler([&](const AudioOutputEvent &) { ++events; });
        (void)output->start();
        // Queue handlers on the output's queue, then destroy the output at once: the queued
        // handlers must do nothing (no use of the freed output, no restart of a dead engine).
        for (int i = 0; i < 10; ++i) {
            output->postConfigurationChangeNotification();
        }
        output.reset();
        const int atTeardown = events.load();
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        XCTAssertEqual(events.load(), atTeardown, @"no event after destruction");
    }
    // The mixer was not rendered after the outputs went away.
    const uint64_t renders = fx.mixer->stats().renders;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    XCTAssertEqual(fx.mixer->stats().renders, renders);
}

- (void)testConverterDelayIsMeasured {
    XCTAssertEqual(AudioOutput::measureConverterDelay(48000, 48000, 2), 0.0);
    const double to441 = AudioOutput::measureConverterDelay(48000, 44100, 2);
    const double to96 = AudioOutput::measureConverterDelay(48000, 96000, 2);
    XCTAssertGreaterThan(to441, 0.00005);
    XCTAssertLessThan(to441, 0.002);
    XCTAssertGreaterThan(to96, 0.00005);
    XCTAssertLessThan(to96, 0.002);
    XCTAssertEqual(AudioOutput::measureConverterDelay(48000, 44100, 2), to441, @"cached");
    NSLog(@"AVAudioEngine mixer sample-rate conversion delay: 48->44.1 kHz %.3f ms, 48->96 kHz %.3f ms (reported "
          @"latency: 0)",
          to441 * 1000, to96 * 1000);
}

- (void)testAutomaticOutputRunsOrFallsBack {
    OutputFixture fx;
    AutomaticAudioOutput output(*fx.mixer);
    output.setMuted(true);
    fx.startTransport();
    XCTAssertTrue(output.start().ok());
    const std::string kind = output.kind();
    XCTAssertTrue(kind == "avaudioengine" || kind == "null", @"%s", kind.c_str());
    XCTAssertTrue(waitUntil([&] { return fx.clock->samplesRendered() > 0; }));
    NSLog(@"AutomaticAudioOutput uses %s%s%s", kind.c_str(), output.fallbackReason().empty() ? "" : ": ",
          output.fallbackReason().c_str());
    output.stop();
    XCTAssertFalse(output.isRunning());
}

- (void)testAutomaticOutputRetriesTheEngineOnALaterStart {
    OutputFixture fx;
    auto available = std::make_shared<std::atomic<bool>>(false);
    AutomaticAudioOutput output(
        *fx.mixer,
        [available](AudioMixer &) -> media::Result<std::unique_ptr<IAudioOutput>> {
            return std::unique_ptr<IAudioOutput>(std::make_unique<FakeEngine>(available));
        },
        std::chrono::milliseconds(100));
    output.setMuted(true);
    XCTAssertTrue(output.start().ok());
    XCTAssertEqual(output.kind(), "null", @"no device yet: the fallback runs");
    XCTAssertFalse(output.fallbackReason().empty());
    XCTAssertEqual(output.engineAttempts(), 1);
    XCTAssertFalse(output.wantsRestart(), @"bounded: not before the retry interval");
    XCTAssertTrue(output.start().ok());
    XCTAssertEqual(output.engineAttempts(), 1, @"no retry within the interval");
    // A device appears; after the interval the owner is told a restart is worth it, and the
    // next start() switches to the engine.
    available->store(true);
    XCTAssertTrue(waitUntil([&] { return output.wantsRestart(); }));
    XCTAssertTrue(output.start().ok());
    XCTAssertEqual(output.engineAttempts(), 2);
    XCTAssertEqual(output.kind(), "avaudioengine");
    XCTAssertTrue(output.fallbackReason().empty());
    XCTAssertTrue(output.isRunning());
    XCTAssertEqual(output.outputLatency(), 0.042);
    XCTAssertFalse(output.wantsRestart());
    // Muting is non-blocking and reaches the active output.
    output.setMuted(false);
    XCTAssertFalse(output.isMuted());
    output.stop();
    XCTAssertFalse(output.isRunning());
}

/// A default output device appearing while the output runs on its fallback makes the engine
/// retry due at once (CoreAudio listener), not only after the retry interval.
- (void)testAutomaticOutputRetriesAtOnceWhenAnOutputDeviceAppears {
    OutputFixture fx;
    auto available = std::make_shared<std::atomic<bool>>(false);
    AutomaticAudioOutput output(
        *fx.mixer,
        [available](AudioMixer &) -> media::Result<std::unique_ptr<IAudioOutput>> {
            return std::unique_ptr<IAudioOutput>(std::make_unique<FakeEngine>(available));
        },
        std::chrono::hours(1), /*watchDefaultDevice*/ false);
    output.setMuted(true);
    XCTAssertTrue(output.start().ok());
    XCTAssertEqual(output.kind(), "null");
    XCTAssertFalse(output.wantsRestart(), @"an hour-long retry interval");
    available->store(true);
    output.defaultOutputDeviceDidChange(); // what the CoreAudio listener reports
    XCTAssertTrue(output.wantsRestart(), @"the new device makes a retry due now");
    XCTAssertTrue(output.start().ok());
    XCTAssertEqual(output.engineAttempts(), 2);
    XCTAssertEqual(output.kind(), "avaudioengine");
    XCTAssertFalse(output.wantsRestart());
    output.stop();
}

/// The real listener installs and uninstalls cleanly (it cannot be triggered headless).
- (void)testAutomaticOutputInstallsTheDeviceListener {
    OutputFixture fx;
    for (int i = 0; i < 3; ++i) {
        auto output = std::make_unique<AutomaticAudioOutput>(*fx.mixer);
        output->setMuted(true);
        XCTAssertTrue(output->start().ok());
        output->defaultOutputDeviceDidChange();
        output.reset();
    }
}

@end
