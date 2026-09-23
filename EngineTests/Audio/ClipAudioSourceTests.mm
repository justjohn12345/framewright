// ClipAudioSource on the generated media: sample-accurate seek + read against the known wav
// signal, clip offsets, speed resampling (the beep moves to beepTime / speed), the consumer's
// non-blocking repositioning, and the producer's wake-ups (none while idle, one per refill).

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/ClipAudioSource.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"
#include "AudioTestSupport.h"

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

- (void)testIdleProducerSleepsUntilTheConsumerDrainsOrARequestArrives {
    auto tones = std::make_shared<ToneBehavior>();
    tones->setSignal("tone://a", sineSignal(440, 0.5));
    AudioSourceMapping m;
    m.asset = AssetId(1);
    m.path = "tone://a";
    ClipAudioSource source(makeToneRouter(tones), m);
    const ClipAudioSourceConfig &config = source.config();
    const int64_t lookahead = static_cast<int64_t>(config.lookaheadSeconds * kSr);
    const int64_t refill = static_cast<int64_t>(config.refillSeconds * kSr);
    // No request: the producer sleeps.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    XCTAssertLessThanOrEqual(source.stats().wakeups, 1u);
    // A request: it fills to the lookahead, then sleeps with no consumer.
    source.seekTo(1000);
    XCTAssertTrue(waitReady(source, 1000, lookahead, std::chrono::seconds(10)));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const uint64_t full = source.stats().wakeups;
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    XCTAssertEqual(source.stats().wakeups, full, @"no polling while full");
    XCTAssertEqual(source.stats().framesProduced, static_cast<uint64_t>(lookahead));
    // The consumer reads, staying above the refill level: still no wake-up.
    std::vector<float> buffer(4096 * 2);
    int64_t pos = 1000;
    while (lookahead - (pos - 1000) > refill + 4096) {
        pos += source.read(pos, buffer.data(), 4096);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    XCTAssertEqual(source.stats().wakeups, full, @"above the refill level the producer is not woken");
    // Crossing the refill level wakes it once; it tops up to the lookahead again.
    while (source.stats().framesProduced == static_cast<uint64_t>(lookahead)) {
        pos += source.read(pos, buffer.data(), 4096);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    XCTAssertTrue(waitReady(source, pos, lookahead, std::chrono::seconds(10)));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const uint64_t woken = source.stats().wakeups - full;
    XCTAssertGreaterThanOrEqual(woken, 1u);
    XCTAssertLessThanOrEqual(woken, 3u, @"one wake-up per refill, not a poll");
    NSLog(@"producer wake-ups: %llu to fill, 0 while full or above the refill level, %llu per refill", full, woken);
}

- (void)testPositionedAtTellsWhetherAReseekWouldHelp {
    auto tones = std::make_shared<ToneBehavior>();
    tones->setSignal("tone://a", constantSignal(0.25f, 0.25f));
    AudioSourceMapping m;
    m.asset = AssetId(1);
    m.path = "tone://a";
    ClipAudioSource source(makeToneRouter(tones), m);
    XCTAssertEqual(source.requestedPosition(), -1);
    XCTAssertFalse(source.isPositionedAt(0));
    source.seekTo(48000);
    XCTAssertEqual(source.requestedPosition(), 48000);
    XCTAssertTrue(source.isPositionedAt(48000));
    XCTAssertFalse(source.isPositionedAt(48001));
    XCTAssertTrue(waitReady(source, 48000, 4800, std::chrono::seconds(10)));
    std::vector<float> buffer(512 * 2);
    XCTAssertEqual(source.read(48000, buffer.data(), 512), 512);
    XCTAssertFalse(source.isPositionedAt(48000), @"consumed past its position: a reseek is needed");
}

/// A read that fails after the decoder opened (phase 7 review P3): the source plays silence (it
/// stays ready: playback goes on) and records the first sequence sample it could not decode, at
/// speed 1 and when resampling, for AudioMixer::failedSourceIn and so the export.
- (void)testReadFailureMidStreamIsRecordedWithItsSequenceSample {
    auto behavior = std::make_shared<FakeBehavior>();
    behavior->frames = 300;
    behavior->failAudioAtSample = 24576; // reads starting there fail (the source reads 1024-frame chunks)
    behavior->probe = [](const std::string &path) -> media::Result<media::MediaInfo> {
        return makeFakeInfo(path, "mp4", media::fourcc::H264, true);
    };
    auto router = std::make_shared<media::BackendRouter>();
    XCTAssertTrue(router->registerBackend(std::make_shared<FakeBackend>(behavior)).ok());
    struct Case {
        Ratio speed;
        int64_t expected; // first sequence sample produced as silence
    };
    // Speed 2: the source window reads 2048 source frames per 1024-frame chunk, so the failing read
    // starts at source sample 24576, which sequence sample 12288 is the first to need.
    for (const Case c : {Case{Ratio{1, 1}, 24576}, Case{Ratio{2, 1}, 12288}}) {
        AudioSourceMapping m;
        m.asset = AssetId(1);
        m.path = "/fake/av.mp4";
        m.speed = c.speed;
        ClipAudioSource source(router, m);
        source.seekTo(0);
        XCTAssertTrue(waitReady(source, 0, 48000, std::chrono::seconds(10)), @"silence counts as ready");
        const std::vector<float> got = readRange(source, 0, 48000);
        XCTAssertEqual(got.size(), size_t(96000));
        const ClipAudioSource::Stats stats = source.stats();
        XCTAssertFalse(stats.failed, @"the decoder opened");
        XCTAssertTrue(stats.readFailed, @"speed %lld", (long long)c.speed.num);
        XCTAssertEqual(stats.readFailedAt, c.expected, @"speed %lld", (long long)c.speed.num);
        XCTAssertNotEqual(stats.error.find("scripted audio failure"), std::string::npos, @"%s", stats.error.c_str());
    }
}

@end
