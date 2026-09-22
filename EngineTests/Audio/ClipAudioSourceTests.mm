// ClipAudioSource on the generated media: sample-accurate seek + read against the known wav
// signal, clip offsets, speed resampling (the beep moves to beepTime / speed), and the
// consumer's non-blocking repositioning.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/ClipAudioSource.h"
#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"

#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::audio;
using namespace ve::test;

namespace {

constexpr double kSr = 48000.0;

bool waitReady(const ClipAudioSource &source, int64_t at, int64_t frames, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (source.isReady(at, frames)) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

/// Reads [at, at + frames) from `source` as the consumer, waiting for the producer as needed.
std::vector<float> readRange(ClipAudioSource &source, int64_t at, int64_t frames) {
    std::vector<float> out(static_cast<size_t>(frames) * 2, 0.0f);
    int64_t done = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (done < frames && std::chrono::steady_clock::now() < deadline) {
        const int want = static_cast<int>(std::min<int64_t>(4096, frames - done));
        const int got = source.read(at + done, out.data() + done * 2, want);
        done += got;
        if (got < want) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    return out;
}

} // namespace

@interface ClipAudioSourceTests : XCTestCase
@end

@implementation ClipAudioSourceTests {
    std::shared_ptr<media::BackendRouter> _router;
    std::string _wav;
}

- (void)setUp {
    _router = media::BackendRouter::makeDefault();
    std::string error;
    _wav = testMediaPath("audio_only.wav", error);
    XCTAssertFalse(_wav.empty(), @"test media: %s", error.c_str());
}

- (AudioSourceMapping)mappingSpeed:(Ratio)speed sourceAtZero:(CMTime)offset {
    AudioSourceMapping m;
    m.asset = AssetId(1);
    m.path = _wav;
    m.speed = speed;
    m.sourceAtZero = offset;
    return m;
}

- (void)testSeekThenReadIsSampleAccurateAgainstTheWav {
    if (_wav.empty()) {
        return;
    }
    const TestClip &clip = testClip("audio_only.wav");
    const auto reference = makeToneWithBeep(clip.toneHz, kSr, 2, static_cast<int64_t>(clip.audioSeconds * kSr),
                                            kMediaBeepStart);
    ClipAudioSource source(_router, [self mappingSpeed:Ratio{1, 1} sourceAtZero:kCMTimeZero]);
    // Forward and backward jumps, including one across the beep.
    for (const int64_t at : {int64_t(12345), int64_t(95'000), int64_t(3000), int64_t(250'001), int64_t(47'999)}) {
        source.seekTo(at);
        XCTAssertTrue(waitReady(source, at, 4800, std::chrono::seconds(10)), @"not ready at %lld", at);
        const std::vector<float> got = readRange(source, at, 4800);
        double worst = 0;
        double worstShifted = 0;
        for (int64_t k = 0; k < 4800; ++k) {
            for (int c = 0; c < 2; ++c) {
                const float v = got[static_cast<size_t>(k) * 2 + c];
                worst = std::max(worst, static_cast<double>(std::fabs(v - reference[static_cast<size_t>(at + k) * 2 + c])));
                worstShifted =
                    std::max(worstShifted, static_cast<double>(std::fabs(v - reference[static_cast<size_t>(at + k + 1) * 2 + c])));
            }
        }
        XCTAssertLessThan(worst, 1e-4, @"at %lld: 16-bit wav vs float reference", at);
        XCTAssertGreaterThan(worstShifted, 1e-3, @"a one-sample shift must be detectable");
    }
    XCTAssertTrue(source.stats().opened);
    XCTAssertEqual(source.stats().backend, "apple");
}

- (void)testClipOffsetMovesTheBeep {
    if (_wav.empty()) {
        return;
    }
    // A clip at timeline 3 s whose source starts at 1 s: sourceAtZero = -2 s, beep (source 2 s)
    // at sequence 4 s.
    ClipAudioSource source(_router, [self mappingSpeed:Ratio{1, 1} sourceAtZero:CMTimeMake(-2, 1)]);
    const int64_t from = static_cast<int64_t>(3.5 * kSr);
    source.seekTo(from);
    const std::vector<float> got = readRange(source, from, static_cast<int64_t>(kSr));
    const auto onset = findBeepOnset(got.data(), static_cast<int64_t>(kSr), 2, kSr);
    XCTAssertTrue(onset.has_value());
    if (onset) {
        XCTAssertEqualWithAccuracy(3.5 + *onset, 4.0, 0.0002);
    }
    // Before the media starts (sequence < 2 s) the source is silent.
    source.seekTo(0);
    const std::vector<float> head = readRange(source, 0, 4800);
    XCTAssertTrue(std::all_of(head.begin(), head.end(), [](float v) { return v == 0.0f; }));
}

- (void)testSpeedTwoHalvesTheBeepTime {
    if (_wav.empty()) {
        return;
    }
    const TestClip &clip = testClip("audio_only.wav");
    ClipAudioSource source(_router, [self mappingSpeed:Ratio{2, 1} sourceAtZero:kCMTimeZero]);
    source.seekTo(0);
    const int64_t frames = static_cast<int64_t>(2 * kSr);
    const std::vector<float> got = readRange(source, 0, frames);
    const auto onset = findBeepOnset(got.data(), frames, 2, kSr);
    XCTAssertTrue(onset.has_value());
    if (onset) {
        XCTAssertEqualWithAccuracy(*onset, kMediaBeepStart / 2.0, 0.0002, @"beep at %.5f s", *onset);
        NSLog(@"speed 2: beep at %.4f ms (expected 1000 ms)", *onset * 1000);
    }
    XCTAssertEqualWithAccuracy(estimateFrequency(got.data(), 4800, 40000, 2, kSr), clip.toneHz * 2, 2.0);
}

- (void)testSpeedHalfDoublesTheBeepTime {
    if (_wav.empty()) {
        return;
    }
    const TestClip &clip = testClip("audio_only.wav");
    ClipAudioSource source(_router, [self mappingSpeed:Ratio{1, 2} sourceAtZero:kCMTimeZero]);
    const int64_t from = static_cast<int64_t>(3.5 * kSr);
    source.seekTo(from);
    const std::vector<float> got = readRange(source, from, static_cast<int64_t>(kSr));
    const auto onset = findBeepOnset(got.data(), static_cast<int64_t>(kSr), 2, kSr);
    XCTAssertTrue(onset.has_value());
    if (onset) {
        XCTAssertEqualWithAccuracy(3.5 + *onset, kMediaBeepStart * 2.0, 0.0003);
    }
    XCTAssertEqualWithAccuracy(estimateFrequency(got.data(), 0, 20000, 2, kSr), clip.toneHz / 2, 2.0);
}

- (void)testConsumerNeverWaitsAndRepositionsItself {
    if (_wav.empty()) {
        return;
    }
    ClipAudioSource source(_router, [self mappingSpeed:Ratio{1, 1} sourceAtZero:kCMTimeZero]);
    std::vector<float> buffer(512 * 2);
    // No request yet: the first read posts one for its position and returns nothing at once.
    const auto t0 = std::chrono::steady_clock::now();
    XCTAssertEqual(source.read(200'000, buffer.data(), 512), 0);
    const double readMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    XCTAssertLessThan(readMs, 1.0);
    XCTAssertTrue(waitReady(source, 200'000, 512, std::chrono::seconds(10)));
    XCTAssertEqual(source.read(200'000, buffer.data(), 512), 512);
    // Continuous reads keep flowing; a far jump is answered by a new segment.
    XCTAssertEqual(source.read(200'512, buffer.data(), 512), 512);
    XCTAssertEqual(source.read(10, buffer.data(), 512), 0, @"behind the consumed audio: repositions");
    XCTAssertTrue(waitReady(source, 10, 512, std::chrono::seconds(10)));
    XCTAssertEqual(source.read(10, buffer.data(), 512), 512);
    XCTAssertGreaterThanOrEqual(source.stats().repositions, 2u);
}

- (void)testMissingFilePlaysSilenceAndReportsTheError {
    AudioSourceMapping m;
    m.asset = AssetId(9);
    m.path = "/nonexistent/missing.wav";
    ClipAudioSource source(_router, m);
    source.seekTo(0);
    XCTAssertTrue(waitReady(source, 0, 4800, std::chrono::seconds(10)), @"silence counts as ready");
    const std::vector<float> got = readRange(source, 0, 4800);
    XCTAssertTrue(std::all_of(got.begin(), got.end(), [](float v) { return v == 0.0f; }));
    XCTAssertTrue(source.stats().failed);
    XCTAssertFalse(source.stats().error.empty());
}

@end
