// Long runs without drift, driven the way the real device and display drive playback:
// - audio callbacks at the device's cadence (512-frame IO periods), each stamped with its IO time
//   and entered up to 2 ms late, like AVAudioEngine's render callback;
// - a 60 Hz display asking for the frame of each vsync's target time;
// - both on a virtual host clock that advances with wall time at a fixed speed-up, with NO
//   waiting for decoded frames or audio (the decoders and producers run on their own threads,
//   at their own speed, exactly as in the app). Late frames, dropped frames and underruns are
//   measured, not prevented; they must stay under small bounds.
// Every presented frame index is checked against pure arithmetic on the callback schedule (not
// against the Clock), every exact picture against its burn-in, and every beep (one per clip,
// 2 s in) against its timeline position to the sample. One run on the Apple backend (h264 MP4,
// 60 s) and one on the FFmpeg backend (the same media remuxed to MKV, 20 s).
//
// Speed-up: 3x in normal builds; 1x (and 20 s instead of 60 s) under Thread Sanitizer, whose
// instrumentation slows the frame source and the test's own burn-in reads.

#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
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

#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
constexpr bool kSanitized = true;
#else
constexpr bool kSanitized = false;
#endif
#else
constexpr bool kSanitized = false;
#endif

struct DriftResult {
    bool ran = false;
    std::string error;
    double wallSeconds = 0;
    int presentations = 0;
    int boundarySkips = 0;     ///< vsyncs whose target sits within 1 us of a frame boundary
    int indexErrors = 0;       ///< presented frame != arithmetic on the schedule
    int64_t worstIndexError = 0;
    int latePresentations = 0; ///< some layer not exact (previous picture held)
    int burnInErrors = 0;      ///< exact layer whose burn-in is not the expected source frame
    int beepsFound = 0;
    int64_t worstBeepError = 0; ///< samples from timeline position + detector latency
    uint64_t underruns = 0;
    uint64_t underrunFrames = 0;
    uint64_t dropped = 0;
    int64_t positionError = 0; ///< mixer position vs frames rendered (samples)
    std::vector<std::string> failures;
};

DriftResult runDrift(const std::string &path, int clips, double speedup) {
    DriftResult r;
    const int seconds = clips * 10;
    PlaybackHarness h(PlaybackHarness::Mode::Scripted, seconds + 1.0);
    const AssetId asset = h.importAssetAtPath(path);
    if (!h.ok()) {
        r.error = h.error();
        return r;
    }
    std::vector<ClipId> videoClips;
    for (int k = 0; k < clips; ++k) {
        const ClipId v = h.addClip(h.v1, asset, k * 300, 300, kCMTimeZero);
        const ClipId a = h.addClip(h.a1, asset, k * 300, 300, kCMTimeZero);
        h.link(v, a);
        videoClips.push_back(v);
    }
    if (auto problem = h.problem()) {
        r.error = *problem;
        return r;
    }
    h.load();
    h.controller->play();
    if (!h.waitForState(PlaybackState::Playing)) {
        r.error = "never reached Playing";
        return r;
    }
    r.ran = true;

    // Exact schedule in integer nanoseconds (no accumulated rounding).
    const uint64_t t0 = h.host->nowNanos();
    auto ioTime = [&](int64_t k) { return t0 + static_cast<uint64_t>(std::llround((k + 1) * 512.0 * 1e9 / kSr)); };
    auto vsyncTime = [&](int64_t j) { return t0 + static_cast<uint64_t>(std::llround(j * 1e9 / 60.0)); };
    const uint64_t h0 = ioTime(0); // the first sample (sequence 0) reaches the device here
    const uint64_t end = t0 + static_cast<uint64_t>(seconds) * kNs - 200'000'000ull;
    uint64_t lcg = 0x2545F4914F6CDD1Dull;
    auto jitter = [&] {
        lcg = lcg * 6364136223846793005ull + 1442695040888963407ull;
        return (lcg >> 33) % 2'000'000ull; // 0-2 ms late
    };
    int64_t k = 0;
    int64_t j = 1;
    uint64_t entry = ioTime(0) - (ioTime(1) - ioTime(0)) + jitter();
    const auto wallStart = std::chrono::steady_clock::now();
    auto pace = [&](uint64_t virtualTime) {
        const auto due = wallStart + std::chrono::nanoseconds(
                                         static_cast<int64_t>(static_cast<double>(virtualTime - t0) / speedup));
        std::this_thread::sleep_until(due);
    };
    int64_t rendered = 0;
    while (true) {
        const uint64_t vsync = vsyncTime(j);
        if (std::min(entry, vsync) >= end) {
            break;
        }
        if (entry <= vsync) {
            pace(entry);
            h.host->set(entry);
            rendered += h.scripted->renderAt(ioTime(k));
            ++k;
            const uint64_t nominal = ioTime(k) - (ioTime(k + 1) - ioTime(k));
            entry = std::max(entry + 50'000, nominal + jitter());
            continue;
        }
        pace(vsync);
        h.host->set(vsync);
        const uint64_t target = vsyncTime(j + 1);
        ++j;
        const PlaybackHarness::Sample s = h.presentAt(static_cast<double>(target) / 1e9);
        ++r.presentations;
        // What is audible at `target` according to the schedule: sequence time target - h0.
        const double exact = target > h0 ? static_cast<double>(target - h0) * 30.0 / 1e9 : 0.0;
        const auto expected = static_cast<int64_t>(std::floor(exact));
        if (exact - std::floor(exact) < 1e-6 * 30 && exact > 0) {
            ++r.boundarySkips; // within a microsecond of a frame edge: either frame is right
        } else if (s.presented.frameIndex != expected) {
            ++r.indexErrors;
            r.worstIndexError = std::max(r.worstIndexError, std::llabs(s.presented.frameIndex - expected));
            if (r.failures.size() < 5) {
                r.failures.push_back("vsync " + std::to_string(j) + ": frame " +
                                     std::to_string(s.presented.frameIndex) + ", schedule says " +
                                     std::to_string(expected));
            }
        }
        bool late = s.presented.layers.empty();
        for (size_t i = 0; i < s.presented.layers.size(); ++i) {
            const PresentedLayer &layer = s.presented.layers[i];
            if (!layer.exact) {
                late = true;
                continue;
            }
            const int64_t slot = h.expectedSlot(layer.clip, s.presented.frameIndex);
            if (i >= s.burnIns.size() || !s.burnIns[i] || *s.burnIns[i] != slot) {
                ++r.burnInErrors;
                if (r.failures.size() < 5) {
                    r.failures.push_back("frame " + std::to_string(s.presented.frameIndex) + ": burn-in " +
                                         std::to_string(i < s.burnIns.size() ? s.burnIns[i].value_or(-1) : -1) +
                                         " expected " + std::to_string(slot));
                }
            }
        }
        r.latePresentations += late ? 1 : 0;
    }
    r.wallSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - wallStart).count();
    r.positionError = h.controller->mixer().position() - rendered; // started at sequence sample 0
    const PlaybackStats stats = h.controller->stats();
    r.underruns = stats.audioUnderruns;
    r.underrunFrames = stats.audioUnderrunFrames;
    r.dropped = stats.droppedFrames;
    h.controller->pause();

    const auto capture = h.scripted->capture();
    const int64_t frames = static_cast<int64_t>(capture.samples.size()) / 2;
    for (int c = 0; c < clips; ++c) {
        const int64_t beep = std::llround((c * 10.0 + 2.0) * kSr);
        const int64_t searchFrom = beep - capture.firstSequenceSample - 2400;
        const auto onset = findBeepOnset(capture.samples.data(), frames, 2, kSr, searchFrom);
        if (!onset) {
            r.failures.push_back("no beep for clip " + std::to_string(c));
            continue;
        }
        ++r.beepsFound;
        const int64_t detected = std::llround(*onset * kSr) + capture.firstSequenceSample;
        const int64_t error = detected - (beep + kBeepDetectorLatencyFrames48k);
        r.worstBeepError = std::max(r.worstBeepError, std::llabs(error));
    }
    return r;
}

void report(XCTestCase *test, const char *label, const DriftResult &r, int clips) {
    (void)test;
    NSLog(@"%s: %d s of sequence in %.1f s wall; %d presentations, frame index vs schedule: %d errors (%d at a frame "
          @"edge, skipped); burn-in errors %d; late %d (%.2f %%), dropped %llu; audio: %d/%d beeps, worst %lld samples "
          @"from the timeline, underruns %llu (%llu frames), mixer position vs rendered %lld samples",
          label, clips * 10, r.wallSeconds, r.presentations, r.indexErrors, r.boundarySkips, r.burnInErrors,
          r.latePresentations, 100.0 * r.latePresentations / std::max(1, r.presentations), r.dropped, r.beepsFound,
          clips, r.worstBeepError, r.underruns, r.underrunFrames, r.positionError);
}

} // namespace

@interface PlaybackDriftTests : XCTestCase
@end

@implementation PlaybackDriftTests

- (void)checkDrift:(const DriftResult &)r clips:(int)clips {
    XCTAssertTrue(r.ran, @"%s", r.error.c_str());
    if (!r.ran) {
        return;
    }
    XCTAssertGreaterThan(r.presentations, clips * 10 * 60 - 60);
    XCTAssertEqual(r.indexErrors, 0, @"%s", r.failures.empty() ? "" : r.failures.front().c_str());
    XCTAssertEqual(r.burnInErrors, 0, @"%s", r.failures.empty() ? "" : r.failures.front().c_str());
    XCTAssertEqual(r.beepsFound, clips);
    XCTAssertLessThanOrEqual(r.worstBeepError, 1, @"audio drift");
    XCTAssertEqual(r.positionError, 0, @"the mix advanced by exactly the samples rendered");
    // Measured, not prevented: small bounds for a machine that keeps up in real time.
    XCTAssertLessThanOrEqual(r.latePresentations, r.presentations / 50, @"late frames: %d", r.latePresentations);
    XCTAssertLessThanOrEqual(r.dropped, 2u);
    XCTAssertLessThanOrEqual(r.underruns, 2u, @"underrun callbacks");
}

- (void)testSixtySecondsWithoutDriftOnTheAppleBackend {
    std::string error;
    const std::string path = testMediaPath("h264_1080p30.mp4", error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    const int clips = kSanitized ? 2 : 6;
    const DriftResult r = runDrift(path, clips, kSanitized ? 1.0 : 3.0);
    [self checkDrift:r clips:clips];
    report(self, "Apple MP4 drift run", r, clips);
}

- (void)testTwentySecondsWithoutDriftOnTheFFmpegBackend {
    std::string error;
    const std::string dir = mkvTestMediaDirectory(error);
    XCTAssertFalse(dir.empty(), @"%s", error.c_str());
    if (dir.empty()) {
        return;
    }
    const std::string path = dir + "/h264_1080p30.mkv";
    const DriftResult r = runDrift(path, 2, kSanitized ? 1.0 : 3.0);
    [self checkDrift:r clips:2];
    report(self, "FFmpeg MKV drift run", r, 2);
}

@end
