// The display path as the preview view drives it: the frame source is asked for the frame of a
// vsync's target presentation time (CADisplayLink.targetTimestamp) while audio callbacks arrive
// late and bunched, and on the real AVAudioEngine output the A/V offset is measured from the
// device's own render timestamps.

#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "PlaybackTestSupport.h"

#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

constexpr double kSr = 48000.0;
constexpr uint64_t kNs = 1'000'000'000ull;

double seconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

/// Deterministic pseudo-random numbers in [0, 1).
struct Lcg {
    uint64_t state = 0x9E3779B97F4A7C15ull;
    double next() {
        state = state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<double>(state >> 11) / static_cast<double>(1ull << 53);
    }
};

struct JitterRun {
    int vsyncs = 0;
    int callbacks = 0;
    int lateCallbacks = 0;
    int rawRegressions = 0;       ///< clock.timeAt(target) went backwards between vsyncs
    double worstRawRegressionMs = 0;
    int presentedRegressions = 0; ///< the presented frame index went backwards
    int64_t firstFrame = -1;
    int64_t lastFrame = -1;
    uint64_t monotonicHolds = 0;
};

/// Five seconds of 1x playback on a virtual host clock. Audio callbacks for 512-frame IO
/// periods: callback k's IO time is H0 + k * P; it runs (entry) one period earlier plus jitter,
/// usually under a millisecond, but every ~15th callback 10-30 ms late, after which the render
/// thread catches up (bunched callbacks). The callback passes its IO time (what AudioOutput
/// passes from AudioTimeStamp.mHostTime) or, with `stampEntryTime`, its entry time (what the
/// output did before: mach_absolute_time at entry). A 120 Hz display (ProMotion) asks for the
/// frame of each vsync's target time (the next vsync); it samples the clock more often than the
/// audio period, which is what exposes the entry-time clock stepping back after a late callback
/// (at 60 Hz the steps usually fall between two vsyncs).
JitterRun runWithLateCallbacks(ToneRig &rig, bool stampEntryTime) {
    JitterRun run;
    rig.controller->seek(kCMTimeZero);
    rig.controller->play();
    if (!rig.waitForState(PlaybackState::Playing)) {
        return run;
    }
    const uint64_t holdsBefore = rig.controller->stats().monotonicHolds;
    render::PreviewFrameSource source = rig.controller->frameSource();
    render::PreviewFrame frame;
    const uint64_t period = static_cast<uint64_t>(512.0 * 1e9 / kSr);
    const uint64_t vsync = kNs / 120;
    const uint64_t t0 = rig.host->nowNanos();
    uint64_t io = t0 + period; // IO time of the next callback
    uint64_t lastEntry = t0;
    uint64_t nextVsync = t0 + vsync;
    Lcg random;
    auto entryFor = [&](uint64_t ioTime) {
        const double r = random.next();
        const double lateMs = r < 1.0 / 15.0 ? 10.0 + 20.0 * random.next() : random.next();
        if (lateMs >= 10.0) {
            ++run.lateCallbacks;
        }
        return std::max(lastEntry + 100'000, ioTime - period + static_cast<uint64_t>(lateMs * 1e6));
    };
    uint64_t entry = entryFor(io);
    double previousRaw = -1.0;
    while (rig.host->nowNanos() < t0 + 5 * kNs) {
        if (entry <= nextVsync) {
            rig.host->set(entry);
            rig.out->renderAt(stampEntryTime ? entry : io);
            ++run.callbacks;
            lastEntry = entry;
            io += period;
            entry = entryFor(io);
            continue;
        }
        rig.host->set(nextVsync);
        const uint64_t target = nextVsync + vsync;
        const double raw = seconds(rig.controller->clock().timeAt(target));
        if (previousRaw >= 0 && raw < previousRaw - 1e-9) {
            ++run.rawRegressions;
            run.worstRawRegressionMs = std::max(run.worstRawRegressionMs, (previousRaw - raw) * 1000.0);
        }
        previousRaw = raw;
        render::PreviewFrameRequest request;
        request.targetTimestamp = static_cast<double>(target) / 1e9;
        source(request, frame);
        const int64_t index = rig.controller->lastPresented().frameIndex;
        if (run.lastFrame >= 0 && index < run.lastFrame) {
            ++run.presentedRegressions;
        }
        if (run.firstFrame < 0) {
            run.firstFrame = index;
        }
        run.lastFrame = index;
        ++run.vsyncs;
        nextVsync += vsync;
    }
    run.monotonicHolds = rig.controller->stats().monotonicHolds - holdsBefore;
    rig.controller->pause();
    return run;
}

} // namespace

@interface PlaybackDisplayPathTests : XCTestCase
@end

@implementation PlaybackDisplayPathTests

- (void)testPresentedFramesNeverGoBackwardsWithLateAudioCallbacks {
    ToneRig rig(1);
    rig.load();
    // IO timestamps (AudioOutput now): the clock itself is monotonic along the display
    // targets, so the frame source never has to hold it.
    const JitterRun io = runWithLateCallbacks(rig, false);
    XCTAssertGreaterThan(io.vsyncs, 590);
    XCTAssertGreaterThan(io.lateCallbacks, 10, @"the run must contain late callbacks");
    XCTAssertEqual(io.presentedRegressions, 0);
    XCTAssertEqual(io.rawRegressions, 0, @"worst %.3f ms", io.worstRawRegressionMs);
    XCTAssertEqual(io.monotonicHolds, 0u);
    XCTAssertGreaterThanOrEqual(io.lastFrame - io.firstFrame, 145, @"about 5 s at 30 fps");

    // Entry timestamps (the output before the fix), as a control: the raw clock steps back
    // after every late callback (the review's probe); the frame source's per-epoch guard still
    // never shows an earlier frame.
    const JitterRun entry = runWithLateCallbacks(rig, true);
    XCTAssertGreaterThan(entry.rawRegressions, 0, @"the scenario must provoke the old failure");
    XCTAssertEqual(entry.presentedRegressions, 0);
    XCTAssertGreaterThan(entry.monotonicHolds, 0u);
    XCTAssertEqual(rig.controller->clock().controlViolations(), 0u);
    NSLog(@"late callbacks (%d of %d late by 10-30 ms): IO time stamps: %d clock regressions, %d frame regressions; "
          @"entry time stamps: %d clock regressions (worst %.2f ms), %d held by the frame source, %d frame "
          @"regressions",
          io.lateCallbacks, io.callbacks, io.rawRegressions, io.presentedRegressions, entry.rawRegressions,
          entry.worstRawRegressionMs, static_cast<int>(entry.monotonicHolds), entry.presentedRegressions);
}

- (void)testMeasuredAVOffsetOnTheRealOutput {
    audio::AudioOutput *device = nullptr;
    bool created = false;
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 0.0, [&](PlaybackConfig &config) {
        config.makeOutput = [&](audio::AudioMixer &mixer) -> std::unique_ptr<audio::IAudioOutput> {
            auto output = audio::AudioOutput::create(mixer);
            if (!output.ok()) {
                return std::make_unique<audio::NullAudioOutput>(mixer);
            }
            created = true;
            device = output.value().get();
            device->setMuted(true); // never make noise in tests
            device->captureTimeline(20000);
            return std::move(output).value();
        };
    });
    if (!created) {
        XCTSkip(@"AVAudioEngine unavailable");
    }
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId v = h.addClip(h.v1, h264, 0, 120, kCMTimeZero);
    const ClipId a = h.addClip(h.a1, h264, 0, 120, kCMTimeZero); // the beep plays at sequence 2.0 s
    h.link(v, a);
    h.load();
    if (!PlaybackHarness::waitUntil([&] { return device->isRunning(); }, std::chrono::seconds(5))) {
        XCTSkip(@"no audio output device");
    }
    h.controller->seek(CMTimeMakeWithSeconds(1.5, 30));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return seconds(h.controller->clock().now()) >= 2.4; }));

    // The device's own account of when each rendered sample reaches its IO boundary.
    const std::vector<audio::AudioOutput::TimelineEntry> timeline = device->drainTimeline();
    const audio::AudioOutput::LatencyBreakdown b = device->latencyBreakdown();
    const double latency = h.controller->clock().outputLatency();
    auto audibleAt = [&](int64_t sample) -> std::optional<uint64_t> {
        for (const auto &e : timeline) {
            if (e.transportSample >= 0 && sample >= e.transportSample && sample < e.transportSample + e.frames) {
                return e.ioHostNanos + static_cast<uint64_t>(static_cast<double>(sample - e.transportSample) * 1e9 / kSr) +
                       static_cast<uint64_t>(latency * 1e9);
            }
        }
        return std::nullopt;
    };

    // 1. The clock's time at the moment each sample is audible (the "click" at the beep, and a
    // sample every 50 ms from 1.6 s to 2.3 s).
    double worstOffset = 0;
    double sumOffset = 0;
    int probes = 0;
    for (int64_t sample = static_cast<int64_t>(1.6 * kSr); sample <= static_cast<int64_t>(2.3 * kSr); sample += 2400) {
        const auto when = audibleAt(sample);
        XCTAssertTrue(when.has_value(), @"sample %lld not rendered", sample);
        if (!when) {
            continue;
        }
        const double offset = seconds(h.controller->clock().timeAt(*when)) - static_cast<double>(sample) / kSr;
        worstOffset = std::max(worstOffset, std::fabs(offset));
        sumOffset += offset;
        ++probes;
    }
    const auto beepAudible = audibleAt(static_cast<int64_t>(2.0 * kSr));
    XCTAssertTrue(beepAudible.has_value());
    const double beepOffset =
        beepAudible ? seconds(h.controller->clock().timeAt(*beepAudible)) - 2.0 : 1.0;
    XCTAssertLessThan(worstOffset, 0.0001, @"clock vs audible sample: worst %.4f ms", worstOffset * 1000);

    // 2. The frame the display shows for a vsync presented when a mid-frame sample is audible.
    int wrongFrames = 0;
    for (int64_t frameIndex = 50; frameIndex <= 68; ++frameIndex) {
        const auto when = audibleAt(frameIndex * 1600 + 800);
        if (!when) {
            continue;
        }
        render::PreviewFrameSource source = h.controller->frameSource(); // fresh monotonic guard
        render::PreviewFrame frame;
        render::PreviewFrameRequest request;
        request.targetTimestamp = static_cast<double>(*when) / 1e9;
        source(request, frame);
        wrongFrames += h.controller->lastPresented().frameIndex == frameIndex ? 0 : 1;
    }
    XCTAssertEqual(wrongFrames, 0, @"the frame on screen when its audio is heard");

    // 3. The device clock against the sample count (a 44.1/48 kHz counting error is 8.8 %).
    const audio::AudioOutput::TimelineEntry *first = nullptr;
    const audio::AudioOutput::TimelineEntry *last = nullptr;
    double ioMinusEntry = 0;
    int valid = 0;
    for (const auto &e : timeline) {
        if (e.transportSample < 0 || !e.hostTimeValid) {
            continue;
        }
        first = first ? first : &e;
        last = &e;
        ioMinusEntry += static_cast<double>(static_cast<int64_t>(e.ioHostNanos - e.entryHostNanos)) * 1e-9;
        ++valid;
    }
    XCTAssertGreaterThan(valid, 10);
    if (first && last && last != first) {
        const double rate = static_cast<double>(last->transportSample - first->transportSample) /
                            (static_cast<double>(last->ioHostNanos - first->ioHostNanos) * 1e-9);
        XCTAssertEqualWithAccuracy(rate, kSr, kSr * 0.001, @"sequence samples per device second");
        NSLog(@"device timeline: %.1f sequence samples per second over %.3f s", rate,
              static_cast<double>(last->ioHostNanos - first->ioHostNanos) * 1e-9);
    }
    // 4. The compensation is the documented sum, and the IO time already carries the IO buffer
    // (adding the buffer duration on top would double count it).
    const double reportedMixer = b.pipelineLatency - b.presentationLatency;
    XCTAssertEqualWithAccuracy(b.total, b.pipelineLatency + std::max(0.0, b.converterDelay - reportedMixer), 1e-12);
    XCTAssertEqualWithAccuracy(latency, b.total, 1e-9, @"the clock subtracts the output's compensation");
    XCTAssertGreaterThanOrEqual(b.streamLatencyFrames, 0);
    const double meanIoAhead = valid ? ioMinusEntry / valid : 0;
    const double bufferSeconds = b.deviceSampleRate > 0 ? b.bufferFrames / b.deviceSampleRate : 0;
    XCTAssertGreaterThan(meanIoAhead, 0.5 * bufferSeconds);
    XCTAssertLessThan(meanIoAhead, 1.5 * bufferSeconds + 0.002);
    XCTAssertEqual(device->hostTimeFallbacks(), 0u);
    h.controller->pause();
    NSLog(@"A/V offset on the real output (device %.0f Hz, buffer %u, device latency %u, stream latency %lld frames, "
          @"safety offset %u; presentation %.3f ms, pipeline %.3f ms, converter %.3f ms => compensation %.3f ms): "
          @"clock - audible sample over %d probes: mean %.4f ms, worst %.4f ms, beep %.4f ms; frames on screen when "
          @"their audio is heard: %d wrong of 19. Entry-time stamps (before the fix) would put video %.3f ms ahead "
          @"(mean IO time - callback entry)%s.",
          b.deviceSampleRate, b.bufferFrames, b.deviceLatencyFrames, b.streamLatencyFrames, b.safetyOffsetFrames,
          b.presentationLatency * 1000, b.pipelineLatency * 1000, b.converterDelay * 1000, b.total * 1000, probes,
          probes ? sumOffset / probes * 1000 : 0.0, worstOffset * 1000, beepOffset * 1000, wrongFrames,
          meanIoAhead * 1000,
          b.converterDelay > 0 ? " plus the unreported converter delay" : "");
}

- (void)testConfigurationChangesOnTheRealOutputRaceTransport {
    audio::AudioOutput *device = nullptr;
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 0.0, [&](PlaybackConfig &config) {
        config.makeOutput = [&](audio::AudioMixer &mixer) -> std::unique_ptr<audio::IAudioOutput> {
            auto output = audio::AudioOutput::create(mixer);
            if (!output.ok()) {
                return std::make_unique<audio::NullAudioOutput>(mixer);
            }
            device = output.value().get();
            device->setMuted(true);
            return std::move(output).value();
        };
    });
    if (!device) {
        XCTSkip(@"AVAudioEngine unavailable");
    }
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.addClip(h.v1, h264, 0, 120, kCMTimeZero);
    h.addClip(h.a1, h264, 0, 120, kCMTimeZero);
    h.load();
    if (!PlaybackHarness::waitUntil([&] { return device->isRunning(); }, std::chrono::seconds(5))) {
        XCTSkip(@"no audio output device");
    }
    std::atomic<bool> running{true};
    std::thread changes([&] {
        // The real handler (engine stop, reconnect, restart, event), on another thread, and the
        // real notification path (observer -> the output's queue).
        for (int i = 0; running.load() && i < 12; ++i) {
            if (i % 2 == 0) {
                device->handleConfigurationChange();
            } else {
                device->postConfigurationChangeNotification();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
        }
    });
    const auto t0 = std::chrono::steady_clock::now();
    int calls = 0;
    while (std::chrono::steady_clock::now() - t0 < std::chrono::milliseconds(800)) {
        switch (calls++ % 5) {
        case 0:
            h.controller->play();
            break;
        case 1:
            h.controller->setRate(2.0);
            break;
        case 2:
            h.controller->seek(CMTimeMakeWithSeconds(0.1 * (calls % 30), 30));
            break;
        case 3:
            h.controller->setRate(1.0);
            break;
        default:
            h.controller->pause();
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(7));
    }
    running = false;
    changes.join();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return device->configurationChanges() >= 6; }));
    XCTAssertEqual(h.controller->clock().controlViolations(), 0u);
    // Playback still works on the audio clock afterwards.
    h.controller->seek(kCMTimeZero);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    const double start = seconds(h.controller->clock().now());
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return seconds(h.controller->clock().now()) > start + 0.2; }));
    XCTAssertFalse(h.controller->status().lastError.has_value());
    h.controller->pause();
    NSLog(@"%llu configuration changes on the real device raced %d transport calls: %llu clock control violations",
          device->configurationChanges(), calls, h.controller->clock().controlViolations());
}

@end
