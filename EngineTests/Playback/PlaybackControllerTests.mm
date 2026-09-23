// PlaybackController end to end on the generated burn-in media (real decoders, real frame
// cache and decode pool, NullAudioOutput): the presented frames track the clock across a
// transition and clip boundaries, the beep lands where the timeline puts it (A/V sync, to the
// sample), seek, 2x, reverse, JKL, stepping, scrubbing, pause, end of sequence (also at 2x),
// seeking back into a clip that already played, edits to the playing clip's gain, mapping and
// track during playback, the idle audio output, the observer and stats.
//
// Transport calls are asynchronous (play() returns in Prerolling); tests wait for the state they
// need with bounded polling gates, never for a wall-clock duration to elapse. The remaining
// wall-clock quantities are bounded generously (documented where they appear).

#import <XCTest/XCTest.h>

#include "../../Engine/Edit/EditOps.h"
#include "../Media/BurnIn.h"
#include "PlaybackTestSupport.h"

#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>

#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;
using SteadyClock = std::chrono::steady_clock;

namespace {

constexpr double kSr = 48000.0;

double secondsOf(CMTime t) {
    return CMTimeGetSeconds(t);
}

int64_t frameOf(CMTime t) {
    return static_cast<int64_t>(std::floor(CMTimeGetSeconds(t) * 30.0 + 1e-9));
}

/// The standard test sequence (30 fps):
///   V1: a = h264 [0, 4 s) src [0, 4 s) --1 s dissolve--> b = hevc 29.97 [4 s, 9 s) src [1 s, 6 s)
///   V2: c = prores 25 fps [1 s, 2.5 s) src [0, 1.5 s)
///   A1: a' (h264 audio, beep at 2 s) --1 s crossfade--> b' (hevc audio, beep at 5 s)
struct Standard {
    AssetId h264, hevc, prores;
    ClipId a, b, c, aa, ba;
};

Standard buildStandard(PlaybackHarness &h) {
    Standard s;
    s.h264 = h.importAsset("h264_1080p30.mp4");
    s.hevc = h.importAsset("hevc_720p2997.mov");
    s.prores = h.importAsset("prores_540p25.mov");
    if (!h.ok()) {
        return s;
    }
    s.a = h.addClip(h.v1, s.h264, 0, 120, kCMTimeZero);
    s.b = h.addClip(h.v1, s.hevc, 120, 150, CMTimeMake(1, 1));
    s.c = h.addClip(h.v2, s.prores, 30, 45, kCMTimeZero);
    s.aa = h.addClip(h.a1, s.h264, 0, 120, kCMTimeZero);
    s.ba = h.addClip(h.a1, s.hevc, 120, 150, CMTimeMake(1, 1));
    h.link(s.a, s.aa);
    h.link(s.b, s.ba);
    h.addTransition(h.v1, s.a, s.b, 30);
    h.addTransition(h.a1, s.aa, s.ba, 30);
    return s;
}

/// Result of sampling the frame source at ~60 Hz for a while.
struct Run {
    int samples = 0;
    int layersChecked = 0;
    int exactLayers = 0;
    int64_t minFrame = INT64_MAX;
    int64_t maxFrame = -1;
    int64_t worstBurnInError = 0; ///< shown burn-in vs expected slot (frames)
    std::vector<ClipId> clipsSeen;
    std::vector<std::string> failures;
};

/// Samples the frame source every 1/60 s for `seconds` of wall time. For every sample, every
/// layer must want the source frame the timeline puts at the presented sequence frame and show
/// it (+- `burnInTolerance` frames, read from the picture's burn-in).
Run sampleFor(PlaybackHarness &h, double seconds, int64_t burnInTolerance = 1) {
    Run run;
    const auto start = SteadyClock::now();
    auto next = start;
    while (SteadyClock::now() - start < std::chrono::duration<double>(seconds)) {
        next += std::chrono::microseconds(16667);
        std::this_thread::sleep_until(next);
        const PlaybackHarness::Sample s = h.present();
        if (s.presented.frameIndex < 0) {
            continue;
        }
        ++run.samples;
        const int64_t p = s.presented.frameIndex;
        run.minFrame = std::min(run.minFrame, p);
        run.maxFrame = std::max(run.maxFrame, p);
        for (size_t i = 0; i < s.presented.layers.size() && i < s.burnIns.size(); ++i) {
            const PresentedLayer &layer = s.presented.layers[i];
            if (std::find(run.clipsSeen.begin(), run.clipsSeen.end(), layer.clip) == run.clipsSeen.end()) {
                run.clipsSeen.push_back(layer.clip);
            }
            const int64_t expected = h.expectedSlot(layer.clip, p);
            ++run.layersChecked;
            if (expected != layer.wantedIndex) {
                run.failures.push_back("layer wants slot " + std::to_string(layer.wantedIndex) + ", expected " +
                                       std::to_string(expected));
            }
            if (!s.burnIns[i]) {
                run.failures.push_back("no picture for layer " + std::to_string(i) + " at frame " + std::to_string(p));
                continue;
            }
            const int64_t error = std::llabs(*s.burnIns[i] - expected);
            run.worstBurnInError = std::max(run.worstBurnInError, error);
            run.exactLayers += error == 0 ? 1 : 0;
            if (error > burnInTolerance) {
                run.failures.push_back("burn-in " + std::to_string(*s.burnIns[i]) + " expected " +
                                       std::to_string(expected) + " at frame " + std::to_string(p));
            }
        }
    }
    return run;
}

std::string summary(const Run &r) {
    std::string s;
    for (size_t i = 0; i < r.failures.size() && i < 5; ++i) {
        s += r.failures[i] + "; ";
    }
    return s;
}

/// Beep onset (sequence seconds) in the captured output, searching from sequence time `from`.
std::optional<double> beepAt(const audio::NullAudioOutput::Capture &capture, double from) {
    if (capture.firstSequenceSample < 0 || capture.samples.empty()) {
        return std::nullopt;
    }
    const int64_t frames = static_cast<int64_t>(capture.samples.size()) / capture.channels;
    const int64_t searchFrom = std::max<int64_t>(0, static_cast<int64_t>(from * kSr) - capture.firstSequenceSample);
    const auto onset = findBeepOnset(capture.samples.data(), frames, capture.channels, kSr, searchFrom);
    if (!onset) {
        return std::nullopt;
    }
    return static_cast<double>(capture.firstSequenceSample) / kSr + *onset;
}

/// Samples between the detected onset and where the timeline puts the beep plus the detector's
/// latency (BurnIn.h): 0 +- 1 when audio is sample-accurate.
int64_t beepErrorSamples(double onsetSeconds, double expectedSeconds) {
    return std::llround(onsetSeconds * kSr) - (std::llround(expectedSeconds * kSr) + kBeepDetectorLatencyFrames48k);
}

/// Manual mode: renders `seconds` of output in 512-frame blocks, waiting before each block
/// until the audio sources are ahead (as they are in real time), presenting a frame every other
/// block. Returns false if the output stopped rendering.
bool renderManual(PlaybackHarness &h, double seconds) {
    const int blocks = static_cast<int>(std::ceil(seconds * kSr / 512.0));
    for (int i = 0; i < blocks; ++i) {
        [[maybe_unused]] const bool ready = h.controller->mixer().waitForBuffered(std::chrono::seconds(5));
        if (h.output->renderBlocks(1) == 0) {
            return false;
        }
        if (i % 2 == 0) {
            h.present();
        }
    }
    return true;
}

/// RMS of channel 0 of the capture over sequence samples [from, to).
double rmsOver(const audio::NullAudioOutput::Capture &capture, int64_t from, int64_t to) {
    double sum = 0;
    int64_t n = 0;
    for (int64_t s = from; s < to; ++s) {
        const int64_t k = s - capture.firstSequenceSample;
        if (k < 0 || k * capture.channels >= static_cast<int64_t>(capture.samples.size())) {
            continue;
        }
        const double v = capture.samples[static_cast<size_t>(k * capture.channels)];
        sum += v * v;
        ++n;
    }
    return n ? std::sqrt(sum / static_cast<double>(n)) : 0.0;
}

} // namespace

@interface PlaybackControllerTests : XCTestCase
@end

@implementation PlaybackControllerTests

- (void)testPlaybackTracksTheClockAcrossATransitionAndClipBoundariesWithSyncedAudio {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 8.0);
    const Standard s = buildStandard(h);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    if (!h.ok()) {
        return;
    }
    h.load();
    // From 1.8 s for 3.4 s: V2 clip end at 2.5 s, the dissolve [3.5 s, 4.5 s), the cut at 4 s,
    // and both beeps (2.0 s in a', 5.0 s in b').
    h.controller->seek(CMTimeMakeWithSeconds(1.8, 30));
    const double playMs = h.playAndWait();
    XCTAssertGreaterThanOrEqual(playMs, 0.0, @"never reached Playing");
    const Run run = sampleFor(h, 3.45);
    const PlaybackStats playing = h.controller->stats();
    h.controller->pause();

    XCTAssertGreaterThan(run.samples, 0);
    XCTAssertLessThanOrEqual(run.minFrame, 60, @"sampling started before the first beep");
    XCTAssertGreaterThanOrEqual(run.maxFrame, 150, @"sampling reached the second beep");
    XCTAssertLessThanOrEqual(run.worstBurnInError, 1, @"%s", summary(run).c_str());
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    XCTAssertGreaterThanOrEqual(static_cast<double>(run.exactLayers), 0.95 * run.layersChecked,
                                @"%d of %d layers exact", run.exactLayers, run.layersChecked);
    for (ClipId clip : {s.a, s.b, s.c}) {
        XCTAssertTrue(std::find(run.clipsSeen.begin(), run.clipsSeen.end(), clip) != run.clipsSeen.end(),
                      @"clip %llu never presented", clip.value());
    }

    // A/V: the beeps are where the timeline puts them, to the sample, on the same sample clock
    // as the video.
    const auto capture = h.output->capture();
    XCTAssertEqual(capture.firstSequenceSample, static_cast<int64_t>(1.8 * kSr));
    const auto beep1 = beepAt(capture, 1.8);
    const auto beep2 = beepAt(capture, 4.6);
    XCTAssertTrue(beep1.has_value());
    XCTAssertTrue(beep2.has_value());
    if (beep1 && beep2) {
        XCTAssertLessThanOrEqual(std::llabs(beepErrorSamples(*beep1, 2.0)), 1, @"beep 1 at %.6f s", *beep1);
        XCTAssertLessThanOrEqual(std::llabs(beepErrorSamples(*beep2, 5.0)), 1, @"beep 2 at %.6f s", *beep2);
    }
    const PlaybackStats stats = h.controller->stats();
    XCTAssertEqual(stats.audioUnderruns, 0u);
    XCTAssertGreaterThan(stats.presentedFrames, 0u);
    XCTAssertGreaterThan(playing.fps, 0.0, @"HUD rate while playing");
    XCTAssertEqual(stats.fps, 0.0, @"HUD rate resets on pause");
    XCTAssertGreaterThan(stats.cacheHitRate, 0.9);
    XCTAssertEqual(stats.mapFailures, 0u);
    XCTAssertEqual(stats.droppedFrames, 0u);
    XCTAssertEqual(stats.clockMode, audio::ClockMode::Stopped);
    XCTAssertGreaterThan(stats.cacheBytes, 0u);
    bool sawHardware = false;
    for (const ActiveClipInfo &clip : h.controller->stats().activeClips) {
        XCTAssertFalse(clip.backend.empty(), @"clip %llu has no backend", clip.clip.value());
        sawHardware = sawHardware || clip.hardware;
    }
    XCTAssertTrue(sawHardware, @"the HEVC clip decodes on VideoToolbox hardware");
    XCTAssertEqual(stats.audioOutput, "null");
    NSLog(@"playback 1.8->5.25 s: play() returned in %.3f ms, %d samples, %d/%d layers exact, worst burn-in "
          @"error %lld; beeps at %.6f s and %.6f s (%lld / %lld samples from timeline + detector latency); fps "
          @"%.1f while playing, dropped %llu, late %llu, hit rate %.3f, underruns %llu",
          playMs, run.samples, run.exactLayers, run.layersChecked, run.worstBurnInError, beep1.value_or(-1),
          beep2.value_or(-1), beep1 ? beepErrorSamples(*beep1, 2.0) : 0, beep2 ? beepErrorSamples(*beep2, 5.0) : 0,
          playing.fps, stats.droppedFrames, stats.lateFrames, stats.cacheHitRate, stats.audioUnderruns);
}

- (void)testSeekThenPlayFromFiveSeconds {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 4.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(5, 1));
    XCTAssertEqual(secondsOf(h.controller->currentTime()), 5.0);
    const PlaybackHarness::Sample paused = h.presentExact();
    XCTAssertEqual(paused.presented.frameIndex, 150);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    const Run run = sampleFor(h, 1.0);
    h.controller->pause();
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    // Wall-clock bound, generous: the realtime null output ran for about a second.
    const double t = secondsOf(h.controller->currentTime());
    XCTAssertGreaterThan(t, 5.3);
    XCTAssertLessThan(t, 7.0);
    // The hevc beep (b' at 5 s) is exactly at the start of this run.
    const auto capture = h.output->capture();
    XCTAssertEqual(capture.firstSequenceSample, static_cast<int64_t>(5 * kSr));
    const auto beep = beepAt(capture, 4.9);
    XCTAssertTrue(beep.has_value());
    if (beep) {
        XCTAssertLessThanOrEqual(std::llabs(beepErrorSamples(*beep, 5.0)), 1, @"beep at %.6f s", *beep);
    }
}

- (void)testRateTwoPlaysAudioAndReverseIsVideoOnly {
    // Manual output: the test renders every block, so the arithmetic is exact.
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 4.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMakeWithSeconds(1.2, 30));
    h.presentExact();
    h.controller->setRate(2.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    XCTAssertTrue(h.controller->stats().audioActive);
    XCTAssertTrue(renderManual(h, 0.1));
    const int64_t p0 = h.controller->mixer().position();
    const int64_t f0 = h.output->framesRendered();
    XCTAssertTrue(renderManual(h, 0.5));
    const int64_t p1 = h.controller->mixer().position();
    const int64_t f1 = h.output->framesRendered();
    XCTAssertEqual(p1 - p0, 2 * (f1 - f0), @"two sequence samples per output sample");
    // One block after its IO time (where the null output leaves the virtual clock) the clock is
    // the rendered position, less the 2x decimation filter's delay: 1.2 s + 2 * output seconds.
    const double filterDelay = 2.0 * h.controller->mixer().processingLatency(2);
    XCTAssertGreaterThan(filterDelay, 0.0);
    XCTAssertEqualWithAccuracy(secondsOf(h.controller->clock().now()), static_cast<double>(p1) / kSr - filterDelay,
                               1e-8);
    // The beep of a' (2.0 s) was played at 2x (low-pass decimated, still well above threshold).
    const auto beep = beepAt(h.output->capture(), 1.2);
    XCTAssertTrue(beep.has_value(), @"audio plays at 2x");
    XCTAssertEqual(h.controller->stats().audioUnderruns, 0u);

    // Reverse: host-time clock, no audio; the output keeps running (idle), the mix is stopped.
    h.controller->seek(CMTimeMake(7, 1));
    h.controller->setRate(-1.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime);
    XCTAssertFalse(h.controller->stats().audioActive);
    XCTAssertFalse(h.controller->mixer().isRunning(), @"reverse plays video only");
    const double t0 = secondsOf(h.controller->clock().now());
    h.host->advance(500'000'000ull);
    XCTAssertEqualWithAccuracy(secondsOf(h.controller->clock().now()), t0 - 0.5, 1e-6, @"exactly backwards");
    const PlaybackHarness::Sample reverse = h.present();
    XCTAssertEqual(reverse.presented.frameIndex, frameOf(CMTimeMakeWithSeconds(t0 - 0.5, kPreciseTimescale)));
    h.controller->pause();
    const PlaybackHarness::Sample exact = h.presentExact();
    for (size_t i = 0; i < exact.burnIns.size(); ++i) {
        XCTAssertEqual(exact.burnIns[i].value_or(-1), h.expectedSlot(exact.clips[i], exact.presented.frameIndex));
    }
}

- (void)testShuttleKeysAndAudioAboveTwoX {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 1.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 2.0);
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing, @"same direction: no pre-roll");
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 4.0);
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime, @"no audio above 2x");
    h.controller->shuttleForward();
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 8.0, @"capped at 8x");
    h.controller->shuttleReverse();
    XCTAssertEqual(h.controller->rate(), -1.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime, @"no audio in reverse");
    h.controller->shuttleReverse();
    XCTAssertEqual(h.controller->rate(), -2.0);
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing);
    h.controller->setRate(0);
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);
    h.controller->togglePlay();
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    h.controller->togglePlay();
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);

    // Muting keeps the audio clock; the mix ramps to silence.
    h.controller->setMuted(true);
    XCTAssertTrue(h.controller->isMuted());
    h.controller->seek(kCMTimeZero);
    // Let the last run's fade-out and the mute ramp (5 ms each) pass before capturing.
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return !h.controller->mixer().lastRenderWasRunning(); }));
    const int64_t rendered = h.output->framesRendered();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->framesRendered() >= rendered + 1024; }));
    h.output->resetCapture();
    h.controller->setRate(1.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    XCTAssertTrue(h.controller->stats().audioActive);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->capture().samples.size() >= 9600; }));
    const auto capture = h.output->capture();
    XCTAssertTrue(std::all_of(capture.samples.begin(), capture.samples.end(), [](float v) { return v == 0.0f; }),
                  @"muted");
    h.controller->pause();
}

- (void)testStepFramesShowsExactFrames {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Standard s = buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(3, 1)); // frame 90: a + c? (c ends at 75) -> a only
    for (const int step : {1, 1, 5, -3, 30}) {
        const int64_t before = frameOf(h.controller->currentTime());
        h.controller->stepFrames(step);
        const int64_t now = frameOf(h.controller->currentTime());
        XCTAssertEqual(now, before + step);
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, now);
        XCTAssertFalse(sample.presented.clockDriven);
        for (size_t i = 0; i < sample.burnIns.size(); ++i) {
            XCTAssertEqual(sample.burnIns[i].value_or(-1), h.expectedSlot(sample.clips[i], now),
                           @"step %d layer %zu", step, i);
        }
    }
    // Clamped at both ends.
    h.controller->seek(kCMTimeZero);
    h.controller->stepFrames(-5);
    XCTAssertEqual(secondsOf(h.controller->currentTime()), 0.0);
    h.controller->seek(CMTimeMake(100, 1));
    XCTAssertEqual(frameOf(h.controller->currentTime()), 269, @"last frame of a 9 s sequence");
    (void)s;
}

- (void)testScrubCoalescesAndLandsOnTheLastPosition {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.presentExact();
    const uint64_t requestsBefore = h.pool->stats().scrubRequests;
    int64_t last = 0;
    for (int i = 0; i < 40; ++i) {
        last = 7 + i * 6; // a drag across 8 s, faster than frames can decode
        h.controller->scrubTo(frames30(last));
        XCTAssertEqual(h.controller->state(), PlaybackState::Scrubbing);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, last);
    for (size_t i = 0; i < sample.burnIns.size(); ++i) {
        XCTAssertEqual(sample.burnIns[i].value_or(-1), h.expectedSlot(sample.clips[i], last));
    }
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    const media::DecodePool::Stats stats = h.pool->stats();
    const uint64_t requests = stats.scrubRequests - requestsBefore;
    XCTAssertGreaterThan(requests, 0u);
    XCTAssertGreaterThan(stats.scrubCancelled, 0u, @"superseded scrub requests are dropped");
    XCTAssertLessThan(stats.scrubServiced, requests);
    h.controller->endScrub();
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);
    NSLog(@"scrub: %llu requests, %llu serviced, %llu cancelled", requests, stats.scrubServiced, stats.scrubCancelled);
}

- (void)testPauseRendersTheExactFrameAndKeepsTheOutputWarm {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(3, 1));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    sampleFor(h, 0.73);
    h.controller->pause();
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);
    const CMTime paused = h.controller->currentTime();
    XCTAssertTrue(CMTimeCompare(paused, snapToFrame(paused, CMTimeMake(1, 30), SnapMode::Floor)) == 0,
                  @"on the frame grid");
    const int64_t frame = frameOf(paused);
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, frame);
    XCTAssertFalse(sample.burnIns.empty());
    for (size_t i = 0; i < sample.burnIns.size(); ++i) {
        XCTAssertEqual(sample.burnIns[i].value_or(-1), h.expectedSlot(sample.clips[i], frame));
    }
    // Paused: the time does not move and the frame source reports no change.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    XCTAssertEqual(CMTimeCompare(h.controller->currentTime(), paused), 0);
    XCTAssertFalse(h.present().changed);
    // The mix fades out and stops; the device keeps running (idle timeout: 10 s by default).
    XCTAssertFalse(h.controller->mixer().isRunning());
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return !h.controller->mixer().lastRenderWasRunning(); }));
    XCTAssertGreaterThanOrEqual(h.controller->mixer().stats().stopFades, 1u);
    XCTAssertTrue(h.output->isRunning(), @"pause does not stop the audio device");
}

- (void)testIdleOutputStopsAfterTheTimeoutAndRestartsForPlay {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0,
                      [](PlaybackConfig &config) { config.outputIdleTimeout = std::chrono::milliseconds(300); });
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }),
                  @"opening a sequence warms the output");
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const auto pausedAt = SteadyClock::now();
    h.controller->pause();
    XCTAssertTrue(h.output->isRunning());
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return !h.output->isRunning(); }),
                  @"stopped after the idle timeout");
    const double idleMs = std::chrono::duration<double, std::milli>(SteadyClock::now() - pausedAt).count();
    XCTAssertGreaterThanOrEqual(idleMs, 250.0, @"not before the timeout");
    XCTAssertFalse(h.controller->stats().outputRunning);
    // The next play starts it again (on the tick thread) and plays with audio.
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(h.output->isRunning());
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    h.controller->pause();
    NSLog(@"idle output stopped %.0f ms after pause (timeout 300 ms)", idleMs);
}

/// UX round review finding 5: the output keeps running 5 minutes after the last transport activity
/// on AC power and 1 minute on battery (the power source is injectable; the system's is IOKit's).
- (void)testTheIdleTimeoutIsFiveMinutesOnACAndOneMinuteOnBattery {
    const PlaybackConfig defaults;
    XCTAssertEqual(defaults.outputIdleTimeout.count(), 300'000);
    XCTAssertEqual(defaults.outputIdleTimeoutOnBattery.count(), 60'000);
    XCTAssertFalse(defaults.powerSource, @"unset: the controller uses the system's power source");
    auto power = std::make_shared<audio::ManualPowerSource>(false);
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 0.5, [&](PlaybackConfig &config) {
        config.outputIdleTimeout = defaults.outputIdleTimeout;
        config.outputIdleTimeoutOnBattery = defaults.outputIdleTimeoutOnBattery;
        config.powerSource = power;
    });
    XCTAssertEqual(h.controller->outputIdleTimeout(), std::chrono::minutes(5), @"on AC");
    power->setOnBattery(true);
    XCTAssertEqual(h.controller->outputIdleTimeout(), std::chrono::minutes(1), @"on battery");
    power->setOnBattery(false);
    XCTAssertEqual(h.controller->outputIdleTimeout(), std::chrono::minutes(5), @"back on AC");
}

/// On battery the idle output stops after the battery timeout; unplugging the charger while the
/// output idles (within the AC timeout) stops it at once when the battery timeout has passed, and
/// plugging it back in keeps a restarted output running.
- (void)testTheIdleOutputFollowsThePowerSource {
    auto power = std::make_shared<audio::ManualPowerSource>(true);
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0, [&](PlaybackConfig &config) {
        config.outputIdleTimeout = std::chrono::milliseconds(20'000);
        config.outputIdleTimeoutOnBattery = std::chrono::milliseconds(300);
        config.powerSource = power;
    });
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    // On battery: stopped after the battery timeout, not before.
    const auto loadedAt = SteadyClock::now();
    h.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }), @"opening a sequence warms it");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return !h.output->isRunning(); }), @"stopped on battery");
    const double batteryMs = std::chrono::duration<double, std::milli>(SteadyClock::now() - loadedAt).count();
    XCTAssertGreaterThanOrEqual(batteryMs, 250.0, @"not before the battery timeout");
    XCTAssertLessThan(batteryMs, 5000.0, @"not the AC timeout");

    // On AC: an idle output keeps running past the battery timeout...
    power->setOnBattery(false);
    h.controller->stepFrames(1); // transport activity: the output starts again
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }));
    std::this_thread::sleep_for(std::chrono::milliseconds(700));
    XCTAssertTrue(h.output->isRunning(), @"on AC the output idles for the AC timeout");
    // ...until the charger is unplugged: the battery timeout has passed, so it stops at once.
    const auto unpluggedAt = SteadyClock::now();
    power->setOnBattery(true);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return !h.output->isRunning(); }, std::chrono::milliseconds(2000)),
                  @"unplugged: stopped without waiting for the AC deadline");
    const double unpluggedMs = std::chrono::duration<double, std::milli>(SteadyClock::now() - unpluggedAt).count();
    XCTAssertLessThan(unpluggedMs, 1000.0);
    NSLog(@"idle output: stopped %.0f ms after load on battery (timeout 300 ms), %.0f ms after unplugging", batteryMs,
          unpluggedMs);
}

/// The system power source answers what IOKit answers.
- (void)testTheSystemPowerSourceIsIOKits {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    bool battery = false;
    if (info != nullptr) {
        CFStringRef type = IOPSGetProvidingPowerSourceType(info);
        battery = type != nullptr && CFEqual(type, CFSTR(kIOPSBatteryPowerValue));
        CFRelease(info);
    }
    const std::shared_ptr<audio::PowerSource> system = audio::systemPowerSource();
    XCTAssertTrue(system);
    XCTAssertEqual(system.get(), audio::systemPowerSource().get(), @"one per process");
    XCTAssertEqual(system->onBattery(), battery);
    NSLog(@"system power source: %s", battery ? "battery" : "AC (or no battery)");
}

- (void)testPlaybackStopsAtTheLastFrame {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMakeWithSeconds(8.5, 30));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    const Run run = sampleFor(h, 0.9);
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    XCTAssertTrue(h.waitForState(PlaybackState::Stopped, std::chrono::seconds(5)));
    XCTAssertEqual(frameOf(h.controller->currentTime()), 269);
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, 269);
    XCTAssertFalse(sample.presented.layers.empty());
    // play() at the end restarts from the beginning.
    h.controller->play();
    XCTAssertLessThan(secondsOf(h.controller->currentTime()), 0.5);
    h.controller->pause();
}

- (void)testPlaybackAtTwoXStopsAtTheLastFrame {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 2.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(8, 1));
    h.controller->setRate(2.0);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    // 1 s of sequence remains: 0.5 s of output at 2x. Render up to 1 s of output and let the
    // tick thread notice the end.
    for (int i = 0; i < 100 && h.controller->state() == PlaybackState::Playing; ++i) {
        [[maybe_unused]] const bool ready = h.controller->mixer().waitForBuffered(std::chrono::seconds(5));
        h.output->renderBlocks(1);
        h.present();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    XCTAssertTrue(h.waitForState(PlaybackState::Stopped, std::chrono::seconds(5)));
    XCTAssertEqual(frameOf(h.controller->currentTime()), 269);
    XCTAssertFalse(h.controller->mixer().isRunning());
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, 269);
    for (size_t i = 0; i < sample.burnIns.size(); ++i) {
        XCTAssertEqual(sample.burnIns[i].value_or(-1), h.expectedSlot(sample.clips[i], 269));
    }
    XCTAssertEqual(h.controller->stats().audioUnderruns, 0u);
}

- (void)testEditDuringPlaybackDoesNotGlitchTheCurrentClip {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 4.0);
    const Standard s = buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(1, 2));
    h.presentExact();
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    Run before = sampleFor(h, 0.5);
    const audio::AudioMixer::Stats mixerBefore = h.controller->mixer().stats();
    const uint64_t lateBefore = h.controller->stats().lateFrames;
    const double editAt = secondsOf(h.controller->clock().now());

    // Trim the later clip pair (b, b') while a/a' play.
    TrimClipTail trim(h.sequenceId, s.b, CMTimeMake(8, 1));
    const EditResult result = trim.apply(h.project);
    XCTAssertTrue(result.ok(), @"%s", result.message.c_str());
    h.publishEdit();
    Run after = sampleFor(h, 0.8);
    h.controller->pause();

    XCTAssertTrue(after.failures.empty(), @"%s", summary(after).c_str());
    const audio::AudioMixer::Stats mixerAfter = h.controller->mixer().stats();
    XCTAssertEqual(mixerAfter.sourcesCreated, mixerBefore.sourcesCreated, @"the playing clip keeps its source");
    XCTAssertEqual(mixerAfter.underruns, mixerBefore.underruns, @"no audio dropout after the edit");
    XCTAssertEqual(h.controller->stats().lateFrames, lateBefore, @"no late video frame after the edit");
    NSLog(@"edit test warm-up: %zu issues before the edit (cold decoders), %llu underruns", before.failures.size(),
          mixerBefore.underruns);

    // The audio around the edit is the uninterrupted 440 Hz tone of a' (AAC: compare in 10 ms
    // windows against the ideal signal).
    const auto capture = h.output->capture();
    const int64_t first = capture.firstSequenceSample;
    const int64_t frames = static_cast<int64_t>(capture.samples.size()) / 2;
    double worstRms = 0;
    for (int64_t n0 = static_cast<int64_t>(editAt * kSr); n0 + 480 <= static_cast<int64_t>((editAt + 0.6) * kSr);
         n0 += 480) {
        double sum = 0;
        for (int64_t n = n0; n < n0 + 480; ++n) {
            const int64_t k = n - first;
            if (k < 0 || k >= frames) {
                continue;
            }
            const double ideal = 0.1 * std::sin(2 * M_PI * 440 * static_cast<double>(n) / kSr);
            const double d = capture.samples[static_cast<size_t>(k) * 2] - ideal;
            sum += d * d;
        }
        worstRms = std::max(worstRms, std::sqrt(sum / 480));
    }
    XCTAssertLessThan(worstRms, 0.01, @"audio of the playing clip is continuous across the edit");
    NSLog(@"edit during playback at %.3f s: worst 10 ms RMS error vs ideal tone %.4f, sources %llu -> %llu", editAt,
          worstRms, mixerBefore.sourcesCreated, mixerAfter.sourcesCreated);
}

- (void)testSeekingBackAndReplayingKeepsTheHeadOfAPlayedClip {
    // The review's scenario on real media (Apple MP4 audio): play C [1 s, 3 s) from 1 s to 2 s,
    // pause, play again from 0.2 s. C's source was consumed up to 2 s; before the fix its head
    // came out as silence plus an underrun when playback reached 1 s again.
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 3.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId c = h.addClip(h.a1, h264, 30, 60, kCMTimeZero);
    h.load();
    h.controller->seek(CMTimeMake(1, 1));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(renderManual(h, 1.0));
    h.controller->pause();
    const uint64_t underrunsBefore = h.controller->mixer().stats().underruns;
    const uint64_t createdBefore = h.controller->mixer().stats().sourcesCreated;
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        h.output->renderBlocks(1); // let the render thread finish the fade-out
        return !h.controller->mixer().lastRenderWasRunning();
    }));

    h.controller->seek(CMTimeMakeWithSeconds(0.2, 30));
    h.output->resetCapture();
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(renderManual(h, 1.0)); // 0.2 s -> 1.2 s
    const audio::AudioMixer::Stats after = h.controller->mixer().stats();
    XCTAssertEqual(after.underruns, underrunsBefore, @"no underrun when reaching the played clip again");
    XCTAssertEqual(after.sourcesCreated, createdBefore, @"the source is reused");
    XCTAssertGreaterThanOrEqual(after.repositionsWhileStopped, 1u, @"and moved back to the clip's head");

    const auto capture = h.output->capture();
    XCTAssertEqual(capture.firstSequenceSample, 9600, @"0.2 s");
    int64_t silent = 0;
    for (int64_t n = 48000; n < 48000 + 4800; ++n) {
        const int64_t k = n - capture.firstSequenceSample;
        if (capture.samples[static_cast<size_t>(k * 2)] == 0.0f) {
            ++silent;
        }
    }
    XCTAssertEqual(silent, 0, @"C's first 100 ms are audible");
    XCTAssertEqual(rmsOver(capture, 38400, 47999), 0.0, @"nothing before C");
    XCTAssertGreaterThan(rmsOver(capture, 48000, 52800), 0.06, @"the 0.1-amplitude tone from C's first sample");
    (void)c;
}

- (void)testEditsToThePlayingClipItselfDuringPlayback {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 6.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId v = h.addClip(h.v1, h264, 0, 120, kCMTimeZero);
    const ClipId a = h.addClip(h.a1, h264, 0, 120, kCMTimeZero);
    h.link(v, a);
    h.sequence().audioTracks.push_back(h.sequence().audioTracks[0]);
    Track &a2 = h.sequence().audioTracks.back();
    a2.id = h.project.ids.make<TrackId>();
    a2.clips.clear();
    const TrackId a2id = a2.id;
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(renderManual(h, 0.3));
    audio::AudioMixer::Stats stats = h.controller->mixer().stats();
    const uint64_t created = stats.sourcesCreated;

    // Each edit is re-planned by the tick thread (setGraph counts the sources it reuses); the
    // next rendered block adopts the plan.
    auto applyEdit = [&] {
        const audio::AudioMixer::Stats before = h.controller->mixer().stats();
        h.publishEdit();
        return PlaybackHarness::waitUntil([&] {
            const audio::AudioMixer::Stats now = h.controller->mixer().stats();
            return now.sourcesReused > before.sourcesReused || now.sourcesCreated > before.sourcesCreated;
        });
    };

    // 1. Gain -6 dB on the playing clip: same source, a ramp, no dropout.
    h.setClipGain(a, -6.0206);
    XCTAssertTrue(applyEdit());
    const int64_t gainAt = h.controller->mixer().position();
    XCTAssertTrue(renderManual(h, 0.3));
    stats = h.controller->mixer().stats();
    XCTAssertEqual(stats.sourcesCreated, created, @"gain edit keeps the source");
    XCTAssertGreaterThanOrEqual(stats.planBlends, 1u, @"envelope crossfade");

    // 2. Move the playing clip to A2: the same media, reused.
    h.moveClipToTrack(a, a2id);
    XCTAssertTrue(applyEdit());
    XCTAssertTrue(renderManual(h, 0.3));
    stats = h.controller->mixer().stats();
    XCTAssertEqual(stats.sourcesCreated, created, @"track move keeps the source");
    XCTAssertEqual(stats.underruns, 0u, @"gain edit and track move: no dropout");

    // 3. Slip the playing clip by +0.5 s: new media mapping, so a new source; the beep (source
    // 2.0 s) now plays at sequence 1.5 s, sample-accurately, and the picture follows.
    h.slipClip(a, CMTimeMake(1, 2));
    h.slipClip(v, CMTimeMake(1, 2));
    XCTAssertTrue(applyEdit());
    XCTAssertTrue(renderManual(h, 1.0));
    stats = h.controller->mixer().stats();
    XCTAssertEqual(stats.sourcesCreated, created + 1, @"a new mapping needs new media");
    XCTAssertLessThan(stats.underrunFrames, 4800u, @"the new source catches up within 100 ms");
    const auto capture = h.output->capture();
    // The clip plays at -6 dB now: undo the gain so the detector's latency is the documented one
    // (its threshold is an absolute level).
    audio::NullAudioOutput::Capture unity = capture;
    for (float &sample : unity.samples) {
        sample *= 2.0f;
    }
    const auto beep = beepAt(unity, 1.2);
    XCTAssertTrue(beep.has_value());
    if (beep) {
        XCTAssertLessThanOrEqual(std::llabs(beepErrorSamples(*beep, 1.5)), 1, @"slipped beep at %.6f s", *beep);
    }
    // The gain ramp: the level halves (-6 dB) without a step.
    const double before = rmsOver(capture, gainAt - 9600, gainAt - 4800);
    const double afterGain = rmsOver(capture, gainAt + 4800, gainAt + 9600);
    XCTAssertEqualWithAccuracy(afterGain / before, 0.5, 0.03);
    double worstStep = 0;
    for (int64_t n = gainAt - 2400; n < gainAt + 9600; ++n) {
        const int64_t k = n - capture.firstSequenceSample;
        worstStep = std::max(worstStep, static_cast<double>(std::fabs(capture.samples[static_cast<size_t>(k * 2 + 2)] -
                                                                      capture.samples[static_cast<size_t>(k * 2)])));
    }
    // A 0.1-amplitude 440 Hz tone changes by at most 0.0058 per sample; a gain step at a peak
    // would add 0.05.
    XCTAssertLessThan(worstStep, 0.012, @"no step at the gain edit");
    h.controller->pause();
    const PlaybackHarness::Sample sample = h.presentExact();
    for (size_t i = 0; i < sample.burnIns.size(); ++i) {
        XCTAssertEqual(sample.burnIns[i].value_or(-1), h.expectedSlot(sample.clips[i], sample.presented.frameIndex));
    }
    NSLog(@"edits to the playing clip: gain ratio %.3f, worst sample step %.4f, slip underrun frames %llu",
          afterGain / before, worstStep, stats.underrunFrames);
}

- (void)testSequenceWithoutAudioAndMutedAudioTrack {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.addClip(h.v1, h264, 0, 90, kCMTimeZero);
    const ClipId audio = h.addClip(h.a1, h264, 0, 90, kCMTimeZero);
    h.sequence().audioTracks[0].muted = true;
    h.load();
    h.controller->seek(CMTimeMakeWithSeconds(1.5, 30));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    const Run run = sampleFor(h, 1.0);
    h.controller->pause();
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    const auto capture = h.output->capture();
    XCTAssertFalse(capture.samples.empty(), @"the null output still drives the clock");
    XCTAssertTrue(std::all_of(capture.samples.begin(), capture.samples.end(), [](float v) { return v == 0.0f; }),
                  @"muted track is silent");
    XCTAssertEqual(h.controller->stats().audioUnderruns, 0u);
    (void)audio;

    // Video-only sequence: no audio clips at all.
    h.sequence().audioTracks[0].clips.clear();
    h.publishEdit();
    h.controller->seek(kCMTimeZero);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    const Run video = sampleFor(h, 0.5);
    h.controller->pause();
    XCTAssertTrue(video.failures.empty(), @"%s", summary(video).c_str());
    XCTAssertGreaterThan(secondsOf(h.controller->currentTime()), 0.2, @"wall-clock bound, generous");
}

- (void)testObserverIsCoalescedOnTheCallersQueue {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("playback.observer.test", DISPATCH_QUEUE_SERIAL);
    static const void *const kKey = &kKey;
    dispatch_queue_set_specific(queue, kKey, (void *)1, nullptr);
    std::atomic<int> statuses{0};
    std::atomic<int> displays{0};
    std::atomic<int> offQueue{0};
    std::atomic<int> playingSeen{0};
    h.controller->setObserver(queue, PlaybackObserver{
                                         [&](const PlaybackStatus &status) {
                                             ++statuses;
                                             offQueue += dispatch_get_specific(kKey) ? 0 : 1;
                                             playingSeen += status.state == PlaybackState::Playing ? 1 : 0;
                                         },
                                         [&] {
                                             ++displays;
                                             offQueue += dispatch_get_specific(kKey) ? 0 : 1;
                                         }});
    h.load();
    dispatch_sync(queue, ^{
                  });
    const int base = statuses.load();
    // Deterministic coalescing: with the queue suspended, every update posted meanwhile (the
    // pre-roll, Playing, one per frame, the pause) collapses into one pending block carrying
    // the latest status.
    std::atomic<PlaybackState> delivered{PlaybackState::Playing};
    h.controller->setObserver(queue, PlaybackObserver{
                                         [&](const PlaybackStatus &status) {
                                             ++statuses;
                                             offQueue += dispatch_get_specific(kKey) ? 0 : 1;
                                             playingSeen += status.state == PlaybackState::Playing ? 1 : 0;
                                             delivered.store(status.state);
                                         },
                                         [&] {
                                             ++displays;
                                             offQueue += dispatch_get_specific(kKey) ? 0 : 1;
                                         }});
    dispatch_suspend(queue);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return frameOf(h.controller->currentTime()) >= 10; }));
    h.controller->pause(); // the last post; nothing is posted while stopped
    dispatch_resume(queue);
    dispatch_sync(queue, ^{
                  });
    XCTAssertEqual(statuses.load() - base, 1, @"one delivery for everything posted while the queue was busy");
    XCTAssertEqual(delivered.load(), PlaybackState::Stopped, @"and it carries the latest status");
    // Unblocked, Playing is delivered too.
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        __block int seen = 0;
        dispatch_sync(queue, ^{
          seen = playingSeen.load();
        });
        return seen > 0;
    }));
    h.controller->pause();
    h.controller->seek(CMTimeMake(2, 1));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        __block bool seen = false;
        dispatch_sync(queue, ^{
          seen = displays.load() > 0;
        });
        return seen;
    }),
                  @"seek while paused asks for a redraw");
    dispatch_sync(queue, ^{
                  });
    XCTAssertEqual(offQueue.load(), 0);
    h.controller->setObserver(nullptr, PlaybackObserver{});
    NSLog(@"observer: %d status updates, %d redraw requests", statuses.load(), displays.load());
}

- (void)testCachedFrameThatCannotBeMappedIsNeitherAHitNorExact {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId clip = h.addClip(h.v1, h264, 0, 90, kCMTimeZero);
    h.load();
    const PlaybackHarness::Sample good = h.presentExact();
    XCTAssertTrue(good.presented.layers.size() == 1 && good.presented.layers[0].exact);
    // Replace frame 30's slot with a buffer Metal cannot map (not IOSurface backed), then seek
    // there: the source keeps the previous picture and counts a map failure, not a hit.
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)),
                  @"no decoder writes frame 30 behind the test's back");
    CVPixelBufferRef raw = nullptr;
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nullptr, &raw),
                   kCVReturnSuccess);
    const CMTime fd = h.project.findAsset(h264)->frameDuration;
    const CMTime pts = CMTimeMultiply(fd, static_cast<int32_t>(h.expectedSlot(clip, 30)));
    XCTAssertTrue(h.cache->put(h264, media::PixelBuffer::adopt(raw), pts, fd, fd));
    const PlaybackStats before = h.controller->stats();
    h.controller->seek(frames30(30));
    const PlaybackHarness::Sample bad = h.present();
    const PlaybackStats after = h.controller->stats();
    XCTAssertEqual(bad.presented.frameIndex, 30);
    XCTAssertEqual(bad.presented.layers.size(), 1u);
    XCTAssertFalse(bad.presented.layers[0].exact);
    XCTAssertEqual(bad.presented.layers[0].shownIndex, good.presented.layers[0].shownIndex, @"previous picture held");
    XCTAssertEqual(after.mapFailures, before.mapFailures + 1);
    XCTAssertEqual(after.cacheHits, before.cacheHits);
}

/// Phase 7 review P2: a clip that runs past the end of its video (a project saved before the video
/// end was recorded, whose asset lasts as long as its container; or a track that overstates its
/// pictures) shows the video's last picture there, playing and paused, never a missing layer.
- (void)testTheLastPictureIsHeldPastTheEndOfTheVideo {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4"); // 300 frames, 10 s
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    MediaAsset &asset = *h.project.findAsset(movie);
    asset.duration = CMTimeMake(11, 1); // as the container might say; the video end unknown
    asset.videoDuration = kCMTimeInvalid;
    h.addClip(h.v1, movie, 0, 330, kCMTimeZero);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    // Playing across the end of the video.
    h.controller->seek(frames30(285));
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    int pastEnd = 0;
    std::vector<std::string> failures;
    const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(1100);
    while (std::chrono::steady_clock::now() < until) {
        std::this_thread::sleep_for(std::chrono::milliseconds(8));
        const PlaybackHarness::Sample sample = h.present();
        const int64_t frame = sample.presented.frameIndex;
        if (frame < 0 || sample.burnIns.empty()) {
            continue;
        }
        if (!sample.presented.layers.at(0).exact || !sample.burnIns[0]) {
            failures.push_back("frame " + std::to_string(frame) + ": no picture");
            continue;
        }
        const int expected = int(std::min<int64_t>(frame, 299));
        if (*sample.burnIns[0] != expected && std::llabs(*sample.burnIns[0] - expected) > 1) {
            failures.push_back("frame " + std::to_string(frame) + ": burn-in " + std::to_string(*sample.burnIns[0]));
        }
        if (frame >= 300) {
            ++pastEnd;
            if (*sample.burnIns[0] != 299) {
                failures.push_back("frame " + std::to_string(frame) + " past the end shows " +
                                   std::to_string(*sample.burnIns[0]));
            }
        }
    }
    h.controller->pause();
    XCTAssertGreaterThan(pastEnd, 10, @"frames past the end of the video were presented");
    XCTAssertTrue(failures.empty(), @"%zu failures, first: %s", failures.size(),
                  failures.empty() ? "" : failures.front().c_str());

    // Paused (the scrub path) further past the end.
    h.controller->seek(frames30(320));
    const PlaybackHarness::Sample paused = h.presentExact();
    XCTAssertEqual(paused.presented.frameIndex, 320);
    XCTAssertFalse(paused.presented.layers.empty());
    if (!paused.presented.layers.empty()) {
        XCTAssertTrue(paused.presented.layers[0].exact, @"the layer has its picture");
        XCTAssertEqual(paused.burnIns.at(0).value_or(-1), 299);
    }
}

@end
