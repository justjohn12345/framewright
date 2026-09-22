// PlaybackController end to end on the generated burn-in media (real decoders, real frame
// cache and decode pool, NullAudioOutput): the presented frames track the clock across a
// transition and clip boundaries, the beep lands where the timeline puts it (A/V sync), seek,
// 2x, reverse, JKL, stepping, scrubbing, pause, end of sequence, edits during playback, the
// observer and stats.

#import <XCTest/XCTest.h>

#include "../../Engine/Edit/EditOps.h"
#include "../Media/BurnIn.h"
#include "PlaybackTestSupport.h"

#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;
using SteadyClock = std::chrono::steady_clock;

namespace {

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
    int64_t worstClockLag = 0;   ///< presented frame vs clock frame (frames)
    int64_t worstBurnInError = 0; ///< shown burn-in vs expected slot (frames)
    double worstOffsetMs = 0;    ///< |start of the shown frame - clock| (ms)
    std::vector<ClipId> clipsSeen;
    std::vector<std::string> failures;
};

/// Samples the frame source every 1/60 s for `seconds` of wall time. For every sample: the
/// presented sequence frame must be the clock's frame (or the one before, when the clock moved
/// on after the vsync), and every layer must show its expected source frame +-1.
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
        const int64_t before = frameOf(s.clockBefore);
        const int64_t after = frameOf(s.clockAfter);
        const int64_t p = s.presented.frameIndex;
        int64_t lag = 0;
        if (p < before - 1) {
            lag = before - p;
        } else if (p > after) {
            lag = p - after;
        }
        run.worstClockLag = std::max(run.worstClockLag, lag);
        if (lag > 1) {
            run.failures.push_back("frame " + std::to_string(p) + " while the clock was at " + std::to_string(before) +
                                   "-" + std::to_string(after));
        }
        run.worstOffsetMs = std::max(run.worstOffsetMs,
                                     std::fabs(secondsOf(s.presented.time) - static_cast<double>(p) / 30.0) * 1000.0);
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

bool waitFor(const std::function<bool()> &condition, std::chrono::milliseconds timeout) {
    const auto deadline = SteadyClock::now() + timeout;
    while (!condition()) {
        if (SteadyClock::now() >= deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return true;
}

/// Beep onset (sequence seconds) in the captured output, searching from sequence time `from`.
std::optional<double> beepAt(const audio::NullAudioOutput::Capture &capture, double from) {
    if (capture.firstSequenceSample < 0 || capture.samples.empty()) {
        return std::nullopt;
    }
    const int64_t frames = static_cast<int64_t>(capture.samples.size()) / capture.channels;
    const int64_t searchFrom = std::max<int64_t>(0, static_cast<int64_t>(from * 48000) - capture.firstSequenceSample);
    const auto onset = findBeepOnset(capture.samples.data(), frames, capture.channels, 48000, searchFrom);
    if (!onset) {
        return std::nullopt;
    }
    return static_cast<double>(capture.firstSequenceSample) / 48000.0 + *onset;
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
    const auto playStart = SteadyClock::now();
    h.controller->play();
    const double prerollMs = std::chrono::duration<double, std::milli>(SteadyClock::now() - playStart).count();
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing);
    XCTAssertLessThan(prerollMs, 400.0);
    const Run run = sampleFor(h, 3.45);
    h.controller->pause();

    XCTAssertGreaterThan(run.samples, 150);
    XCTAssertLessThanOrEqual(run.worstClockLag, 1, @"%s", summary(run).c_str());
    XCTAssertLessThanOrEqual(run.worstBurnInError, 1, @"%s", summary(run).c_str());
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    XCTAssertGreaterThanOrEqual(static_cast<double>(run.exactLayers), 0.95 * run.layersChecked,
                                @"%d of %d layers exact", run.exactLayers, run.layersChecked);
    for (ClipId clip : {s.a, s.b, s.c}) {
        XCTAssertTrue(std::find(run.clipsSeen.begin(), run.clipsSeen.end(), clip) != run.clipsSeen.end(),
                      @"clip %llu never presented", clip.value());
    }

    // A/V: the beeps are where the timeline puts them, on the same sample clock as the video.
    const auto capture = h.output->capture();
    XCTAssertEqual(capture.firstSequenceSample, static_cast<int64_t>(1.8 * 48000));
    const auto beep1 = beepAt(capture, 1.8);
    const auto beep2 = beepAt(capture, 4.6);
    XCTAssertTrue(beep1.has_value());
    XCTAssertTrue(beep2.has_value());
    if (beep1 && beep2) {
        XCTAssertEqualWithAccuracy(*beep1, 2.0, 0.001);
        XCTAssertEqualWithAccuracy(*beep2, 5.0, 0.001);
    }
    const PlaybackStats stats = h.controller->stats();
    XCTAssertEqual(stats.audioUnderruns, 0u);
    XCTAssertGreaterThan(stats.presentedFrames, 100u);
    XCTAssertGreaterThan(stats.fps, 20.0);
    XCTAssertGreaterThan(stats.cacheHitRate, 0.9);
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
    NSLog(@"playback 1.8->5.25 s: preroll %.1f ms, %d samples, %d/%d layers exact, worst clock lag %lld frame(s), "
          @"worst burn-in error %lld, frame vs clock offset <= %.2f ms; beeps at %.4f s and %.4f s (A/V error %.3f / "
          @"%.3f ms); fps %.1f, dropped %llu, late %llu, hit rate %.3f, underruns %llu",
          prerollMs, run.samples, run.exactLayers, run.layersChecked, run.worstClockLag, run.worstBurnInError,
          run.worstOffsetMs, beep1.value_or(-1), beep2.value_or(-1), (beep1.value_or(0) - 2.0) * 1000,
          (beep2.value_or(0) - 5.0) * 1000, stats.fps, stats.droppedFrames, stats.lateFrames, stats.cacheHitRate,
          stats.audioUnderruns);
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
    h.controller->play();
    const Run run = sampleFor(h, 1.0);
    h.controller->pause();
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    const double t = secondsOf(h.controller->currentTime());
    XCTAssertGreaterThan(t, 5.8);
    XCTAssertLessThan(t, 6.2);
    // The hevc beep (b' at 5 s) is exactly at the start of this run.
    const auto beep = beepAt(h.output->capture(), 4.9);
    XCTAssertTrue(beep.has_value());
    if (beep) {
        XCTAssertEqualWithAccuracy(*beep, 5.0, 0.001);
    }
}

- (void)testRateTwoPlaysAudioAndReverseIsVideoOnly {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 4.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    // Start where all clips of the run are already visible (a clip that starts a quarter second
    // into a cold 2x run may be late while its decoder opens).
    h.controller->seek(CMTimeMakeWithSeconds(1.2, 30));
    h.presentExact();
    h.controller->setRate(2.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    XCTAssertTrue(h.controller->stats().audioActive);
    const double t0 = secondsOf(h.controller->clock().now());
    const auto wall0 = SteadyClock::now();
    const Run fast = sampleFor(h, 1.0, 2);
    const double advanced = secondsOf(h.controller->clock().now()) - t0;
    const double wall = std::chrono::duration<double>(SteadyClock::now() - wall0).count();
    XCTAssertEqualWithAccuracy(advanced / wall, 2.0, 0.1);
    XCTAssertLessThanOrEqual(fast.worstClockLag, 1, @"%s", summary(fast).c_str());
    XCTAssertLessThanOrEqual(fast.worstBurnInError, 2, @"%s", summary(fast).c_str());
    // The beep of a' (2.0 s) was played at 2x.
    const auto beep = beepAt(h.output->capture(), 1.2);
    XCTAssertTrue(beep.has_value(), @"audio plays at 2x");

    // Reverse: host-time clock, no audio.
    h.controller->seek(CMTimeMake(7, 1));
    h.controller->setRate(-1.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime);
    XCTAssertFalse(h.controller->stats().audioActive);
    XCTAssertFalse(h.output->isRunning(), @"reverse plays video only");
    const Run reverse = sampleFor(h, 1.0, 1000);
    XCTAssertLessThanOrEqual(reverse.worstClockLag, 1);
    const double t = secondsOf(h.controller->currentTime());
    XCTAssertGreaterThan(t, 5.8);
    XCTAssertLessThan(t, 6.2);
    h.controller->pause();
    const PlaybackHarness::Sample exact = h.presentExact();
    for (size_t i = 0; i < exact.burnIns.size(); ++i) {
        XCTAssertEqual(exact.burnIns[i].value_or(-1), h.expectedSlot(exact.clips[i], exact.presented.frameIndex));
    }
    NSLog(@"2x: clock %.3f s in %.3f s wall; reverse ended at %.3f s, %llu late / %llu dropped frames", advanced, wall,
          t, h.controller->stats().lateFrames, h.controller->stats().droppedFrames);
}

- (void)testShuttleKeysAndAudioMutingAboveTwoX {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 1.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 2.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::AudioSamples);
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 4.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime, @"audio muted above 2x");
    h.controller->shuttleForward();
    h.controller->shuttleForward();
    XCTAssertEqual(h.controller->rate(), 8.0, @"capped at 8x");
    h.controller->shuttleReverse();
    XCTAssertEqual(h.controller->rate(), -1.0);
    h.controller->shuttleReverse();
    XCTAssertEqual(h.controller->rate(), -2.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime, @"no audio in reverse");
    h.controller->setRate(0);
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);
    h.controller->togglePlay();
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing);
    h.controller->togglePlay();
    XCTAssertEqual(h.controller->state(), PlaybackState::Stopped);

    // Muted playback runs on the host clock.
    h.controller->setMuted(true);
    h.controller->setRate(1.0);
    XCTAssertEqual(h.controller->clock().mode(), audio::ClockMode::HostTime);
    XCTAssertFalse(h.controller->stats().audioActive);
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

- (void)testPauseRendersTheExactFrame {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 2.0);
    buildStandard(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(CMTimeMake(3, 1));
    h.controller->play();
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
    XCTAssertFalse(h.output->isRunning(), @"pause stops audio");
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
    h.controller->play();
    const Run run = sampleFor(h, 0.9);
    XCTAssertTrue(run.failures.empty(), @"%s", summary(run).c_str());
    XCTAssertTrue(waitFor([&] { return h.controller->state() == PlaybackState::Stopped; }, std::chrono::seconds(2)));
    XCTAssertEqual(frameOf(h.controller->currentTime()), 269);
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, 269);
    XCTAssertFalse(sample.presented.layers.empty());
    // play() at the end restarts from the beginning.
    h.controller->play();
    XCTAssertLessThan(secondsOf(h.controller->currentTime()), 0.5);
    h.controller->pause();
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
    h.controller->play();
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
    for (int64_t n0 = static_cast<int64_t>(editAt * 48000); n0 + 480 <= static_cast<int64_t>((editAt + 0.6) * 48000);
         n0 += 480) {
        double sum = 0;
        for (int64_t n = n0; n < n0 + 480; ++n) {
            const int64_t k = n - first;
            if (k < 0 || k >= frames) {
                continue;
            }
            const double ideal = 0.1 * std::sin(2 * M_PI * 440 * static_cast<double>(n) / 48000);
            const double d = capture.samples[static_cast<size_t>(k) * 2] - ideal;
            sum += d * d;
        }
        worstRms = std::max(worstRms, std::sqrt(sum / 480));
    }
    XCTAssertLessThan(worstRms, 0.01, @"audio of the playing clip is continuous across the edit");
    NSLog(@"edit during playback at %.3f s: worst 10 ms RMS error vs ideal tone %.4f, sources %llu -> %llu", editAt,
          worstRms, mixerBefore.sourcesCreated, mixerAfter.sourcesCreated);
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
    h.controller->play();
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
    h.controller->play();
    const Run video = sampleFor(h, 0.5);
    h.controller->pause();
    XCTAssertTrue(video.failures.empty(), @"%s", summary(video).c_str());
    XCTAssertGreaterThan(secondsOf(h.controller->currentTime()), 0.4);
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
    h.controller->play();
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    h.controller->pause();
    h.controller->seek(CMTimeMake(2, 1));
    dispatch_sync(queue, ^{
                  });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    dispatch_sync(queue, ^{
                  });
    XCTAssertEqual(offQueue.load(), 0);
    XCTAssertGreaterThan(playingSeen.load(), 10);
    XCTAssertLessThanOrEqual(statuses.load(), 40, @"at most about one update per frame (30 fps for 1 s)");
    XCTAssertGreaterThan(displays.load(), 0, @"seek while paused asks for a redraw");
    h.controller->setObserver(nullptr, PlaybackObserver{});
    NSLog(@"observer: %d status updates, %d redraw requests in 1 s of playback", statuses.load(), displays.load());
}

@end
