// 60 s of sequence time, played faster than real time: a manual NullAudioOutput renders audio
// blocks against a virtual host clock and the frame source is sampled at a virtual 60 Hz. Six
// back-to-back h264 clips (each with its linked audio and a beep 2 s in) make every beep and
// every presented frame a sync check; the drift between the audio sample clock, the video
// frames and the timeline must stay under one frame for the whole minute.
//
// The harness waits for decoded frames/audio between steps (the frame source itself never
// waits); that stands in for a machine fast enough to keep up at the accelerated speed.

#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "PlaybackTestSupport.h"

#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

@interface PlaybackDriftTests : XCTestCase
@end

@implementation PlaybackDriftTests

- (void)testSixtySecondsWithoutDrift {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 61.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    std::vector<ClipId> clips;
    for (int k = 0; k < 6; ++k) {
        const ClipId v = h.addClip(h.v1, h264, k * 300, 300, kCMTimeZero);
        const ClipId a = h.addClip(h.a1, h264, k * 300, 300, kCMTimeZero);
        h.link(v, a);
        clips.push_back(v);
    }
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    const auto wallStart = std::chrono::steady_clock::now();
    h.controller->play();
    XCTAssertEqual(h.controller->state(), PlaybackState::Playing);
    XCTAssertEqual(h.output->kind(), "null-manual");

    const double blockSeconds = 512.0 / 48000.0;
    const double vsync = 1.0 / 60.0;
    double nextVsync = 0.0;
    int presentations = 0;
    int64_t worstFrameError = 0;
    int64_t worstClockLag = 0;
    double worstClockDrift = 0.0;
    int64_t rendered = 0;
    std::vector<std::string> failures;
    while (rendered * blockSeconds < 59.9) {
        if (rendered % 20 == 0 && !h.controller->mixer().waitForBuffered(std::chrono::seconds(5))) {
            failures.push_back("audio not buffered at block " + std::to_string(rendered));
        }
        if (h.output->renderBlocks(1) == 0) {
            failures.push_back("output stopped early at " + std::to_string(rendered * blockSeconds));
            break;
        }
        ++rendered;
        // The clock equals the audio samples rendered (to the sample) at every block boundary.
        const double audioTime = static_cast<double>(h.controller->mixer().position()) / 48000.0;
        const double clockTime = CMTimeGetSeconds(h.controller->clock().now());
        worstClockDrift = std::max(worstClockDrift, std::fabs(clockTime - audioTime));
        const double t = rendered * blockSeconds;
        while (nextVsync <= t) {
            nextVsync += vsync;
            const int64_t frame = static_cast<int64_t>(std::floor(clockTime * 30.0 + 1e-9));
            const ClipId clip = clips[static_cast<size_t>(std::min<int64_t>(5, frame / 300))];
            // Harness pacing: wait until the frame the clock wants is decoded.
            const int64_t slot = h.expectedSlot(clip, frame);
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
            while (!h.cache->contains(h264, slot) && std::chrono::steady_clock::now() < deadline) {
                std::this_thread::sleep_for(std::chrono::microseconds(200));
            }
            const PlaybackHarness::Sample s = h.present();
            ++presentations;
            worstClockLag = std::max(worstClockLag, std::llabs(s.presented.frameIndex - frame));
            if (s.burnIns.size() != 1 || !s.burnIns[0]) {
                failures.push_back("no picture at frame " + std::to_string(frame));
                continue;
            }
            const int64_t error = std::llabs(*s.burnIns[0] - slot);
            worstFrameError = std::max(worstFrameError, error);
            if (error > 0 && failures.size() < 10) {
                failures.push_back("frame " + std::to_string(frame) + ": burn-in " + std::to_string(*s.burnIns[0]) +
                                   " expected " + std::to_string(slot));
            }
        }
    }
    h.controller->pause();
    const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - wallStart).count();

    // Audio: every beep exactly where its clip puts it.
    const auto capture = h.output->capture();
    XCTAssertEqual(capture.firstSequenceSample, 0);
    const int64_t frames = static_cast<int64_t>(capture.samples.size()) / 2;
    double worstBeep = 0.0;
    int beeps = 0;
    for (int k = 0; k < 6; ++k) {
        const double expected = k * 10.0 + 2.0;
        const auto onset = findBeepOnset(capture.samples.data(), frames, 2, 48000,
                                         static_cast<int64_t>((expected - 0.5) * 48000));
        XCTAssertTrue(onset.has_value(), @"beep %d", k);
        if (onset) {
            ++beeps;
            worstBeep = std::max(worstBeep, std::fabs(*onset - expected));
        }
    }
    const PlaybackStats stats = h.controller->stats();
    XCTAssertTrue(failures.empty(), @"%s", failures.empty() ? "" : failures.front().c_str());
    XCTAssertEqual(beeps, 6);
    XCTAssertLessThan(worstBeep, 0.001, @"audio drift");
    XCTAssertEqual(worstFrameError, 0, @"video drift");
    XCTAssertLessThanOrEqual(worstClockLag, 0);
    XCTAssertLessThan(worstClockDrift, 1.0 / 30.0);
    XCTAssertEqual(stats.audioUnderruns, 0u);
    XCTAssertGreaterThan(presentations, 3500);
    NSLog(@"60 s drift run (%.1f s wall, %.1fx real time): %d presentations, worst burn-in error %lld frames, worst "
          @"presented-vs-clock %lld frames, worst beep error %.4f ms over %d beeps, clock vs audio samples %.4f ms, "
          @"underruns %llu",
          wall, 60.0 / wall, presentations, worstFrameError, worstClockLag, worstBeep * 1000, beeps,
          worstClockDrift * 1000, stats.audioUnderruns);
}

@end
