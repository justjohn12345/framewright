#import "MediaBackendConformanceTests.h"

#include "../../Engine/Media/HardwareCaps.h"
#include "BurnIn.h"
#include "VideoToolboxProbe.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <random>
#include <thread>
#include <vector>

using namespace ve::media;
using namespace ve::test;

namespace {

NSString *ns(const std::string &s) {
    return @(s.c_str());
}

NSString *describe(const MediaError &e) {
    return ns(e.description());
}

double seconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

/// pts within 0.1 ms of the expected value: exact up to timescale rounding.
bool timeClose(CMTime a, CMTime b) {
    return CMTIME_IS_NUMERIC(a) && CMTIME_IS_NUMERIC(b) && std::fabs(seconds(a) - seconds(b)) < 1e-4;
}

CMTime frameTime(const TestClip &clip, int index) {
    return CMTimeMultiply(clip.frameDuration, index);
}

/// Frame index containing time t.
int indexAt(const TestClip &clip, double t) {
    return static_cast<int>(std::floor(t / seconds(clip.frameDuration) + 1e-9));
}

/// Where findBeepOnset() finds the beep in the ideal signal (the generator's), at `rate`: the
/// reference decoded audio is compared with, to a few samples instead of a millisecond.
double referenceOnset(double toneHz, double rate, double beepStart) {
    const auto frames = static_cast<int64_t>((beepStart + 0.2) * rate);
    const std::vector<float> ideal = makeToneWithBeep(toneHz, rate, 1, frames, beepStart);
    return findBeepOnset(ideal.data(), frames, 1, rate, static_cast<int64_t>((beepStart - 0.5) * rate)).value_or(-1);
}

/// Onset tolerance: lossless audio must land on the same sample; lossy codecs smear the attack
/// by a few samples.
double onsetTolerance(uint32_t codec, double rate) {
    return (codec == fourcc::LinearPCM ? 1.0 : 4.0) / rate;
}

} // namespace

@implementation MediaBackendConformanceTests {
    std::shared_ptr<IMediaBackend> _backend;
    std::vector<TestClip> _clips;
    BOOL _clipsLoaded;
}

+ (std::shared_ptr<IMediaBackend>)backend {
    return nullptr;
}

+ (XCTestSuite *)defaultTestSuite {
    if ([self backend] == nullptr) {
        return [[XCTestSuite alloc] initWithName:NSStringFromClass(self)]; // Abstract: nothing to run.
    }
    return [super defaultTestSuite];
}

- (std::shared_ptr<IMediaBackend>)backendUnderTest {
    if (!_backend) {
        _backend = [self.class backend];
    }
    return _backend;
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = YES;
}

- (std::optional<bool>)videoToolboxAnswerForClip:(const TestClip &)clip {
    // Remuxed copies (e.g. .mkv) carry the same bitstream as their generated original.
    const auto stem = [](const std::string &name) { return name.substr(0, name.rfind('.')); };
    for (const TestClip &original : testClips()) {
        if (stem(original.file) == stem(clip.file)) {
            std::string error;
            const std::string path = testMediaPath(original.file, error);
            return path.empty() ? std::nullopt : videoToolboxDecodesInHardware(path);
        }
    }
    return std::nullopt;
}

- (std::string)expectedContainerForClip:(const TestClip &)clip {
    return clip.container;
}

- (std::string)pathForFile:(const std::string &)file {
    std::string error;
    std::string path = testMediaPath(file, error);
    if (path.empty()) {
        XCTFail(@"test media unavailable: %s", error.c_str());
    }
    return path;
}

- (std::vector<TestClip>)clips {
    return testClips();
}

/// -clips, evaluated once per test.
- (const std::vector<TestClip> &)suiteClips {
    if (!_clipsLoaded) {
        _clips = [self clips];
        _clipsLoaded = YES;
    }
    return _clips;
}

- (const TestClip *)clipNamed:(const std::string &)file {
    const std::vector<TestClip> &clips = [self suiteClips];
    for (const TestClip &c : clips) {
        if (c.file == file) {
            return &c;
        }
    }
    const auto stem = [](const std::string &name) { return name.substr(0, name.rfind('.')); };
    for (const TestClip &c : clips) {
        if (stem(c.file) == stem(file)) {
            return &c;
        }
    }
    return nullptr;
}

- (std::vector<const TestClip *>)clipsWhere:(bool (^)(const TestClip &))predicate {
    std::vector<const TestClip *> out;
    for (const TestClip &c : [self suiteClips]) {
        if (predicate(c)) {
            out.push_back(&c);
        }
    }
    return out;
}

- (std::vector<const TestClip *>)videoClips {
    return [self clipsWhere:^bool(const TestClip &c) {
        return c.hasVideo();
    }];
}

- (std::vector<const TestClip *>)audioClips {
    return [self clipsWhere:^bool(const TestClip &c) {
        return c.hasAudio();
    }];
}

- (std::vector<const TestClip *>)stillClips {
    return [self clipsWhere:^bool(const TestClip &c) {
        return c.isStill();
    }];
}

// MARK: - Helpers

/// Opens a video decoder or records a failure and returns nullptr.
- (std::unique_ptr<IVideoDecoder>)openVideo:(const TestClip &)clip options:(DecodeOptions)options {
    const std::string path = [self pathForFile:clip.file];
    if (path.empty()) {
        return nullptr;
    }
    auto decoder = self.backendUnderTest->makeVideoDecoder();
    Status s = decoder->open(path, -1, options);
    if (!s.ok()) {
        XCTFail(@"%s: open failed: %@", clip.file.c_str(), describe(s.error()));
        return nullptr;
    }
    return decoder;
}

- (std::unique_ptr<IAudioDecoder>)openAudio:(const TestClip &)clip options:(AudioOptions)options {
    const std::string path = [self pathForFile:clip.file];
    if (path.empty()) {
        return nullptr;
    }
    auto decoder = self.backendUnderTest->makeAudioDecoder();
    Status s = decoder->open(path, -1, options);
    if (!s.ok()) {
        XCTFail(@"%s: audio open failed: %@", clip.file.c_str(), describe(s.error()));
        return nullptr;
    }
    return decoder;
}

/// next() must return the frame with burn-in `index` and pts index * frameDuration.
- (BOOL)expectNext:(IVideoDecoder &)decoder clip:(const TestClip &)clip index:(int)index label:(NSString *)label {
    auto r = decoder.next();
    if (!r.ok()) {
        XCTFail(@"%s %@: next() failed: %@", clip.file.c_str(), label, describe(r.error()));
        return NO;
    }
    if (!r.value()) {
        XCTFail(@"%s %@: unexpected end of stream, wanted frame %d", clip.file.c_str(), label, index);
        return NO;
    }
    const VideoFrame &f = *r.value();
    const std::optional<int> burnIn = readBurnIn(f.image.get());
    BOOL ok = YES;
    if (burnIn != index) {
        XCTFail(@"%s %@: burn-in %d, wanted %d (pts %.6f)", clip.file.c_str(), label, burnIn.value_or(-1), index,
                seconds(f.pts));
        ok = NO;
    }
    if (!timeClose(f.pts, frameTime(clip, index))) {
        XCTFail(@"%s %@: pts %.6f (%lld/%d), wanted %.6f", clip.file.c_str(), label, seconds(f.pts), f.pts.value,
                f.pts.timescale, seconds(frameTime(clip, index)));
        ok = NO;
    }
    if (!timeClose(f.duration, clip.frameDuration)) {
        XCTFail(@"%s %@: duration %.6f, wanted %.6f", clip.file.c_str(), label, seconds(f.duration),
                seconds(clip.frameDuration));
        ok = NO;
    }
    return ok;
}

- (void)expectEndOfStream:(IVideoDecoder &)decoder clip:(const TestClip &)clip label:(NSString *)label {
    auto r = decoder.next();
    XCTAssertTrue(r.ok(), @"%s %@: %@", clip.file.c_str(), label, r.ok() ? @"" : describe(r.error()));
    if (r.ok()) {
        XCTAssertFalse(r.value().has_value(), @"%s %@: expected end of stream, got pts %.6f", clip.file.c_str(), label,
                       r.value() ? seconds(r.value()->pts) : 0.0);
    }
}

- (void)seek:(IVideoDecoder &)decoder to:(double)t clip:(const TestClip &)clip {
    Status s = decoder.seek(CMTimeMakeWithSeconds(t, 600000));
    XCTAssertTrue(s.ok(), @"%s: seek(%.4f) failed: %@", clip.file.c_str(), t, s.ok() ? @"" : describe(s.error()));
}

- (void)seek:(IVideoDecoder &)decoder toFrame:(int)index clip:(const TestClip &)clip {
    Status s = decoder.seek(frameTime(clip, index));
    XCTAssertTrue(s.ok(), @"%s: seek(frame %d) failed: %@", clip.file.c_str(), index,
                  s.ok() ? @"" : describe(s.error()));
}

/// Reads the whole track at the decoder's configuration.
- (std::vector<float>)readAll:(IAudioDecoder &)decoder clip:(const TestClip &)clip {
    std::vector<float> all;
    std::vector<float> chunk(static_cast<size_t>(4096 * decoder.channels()));
    for (int guard = 0; guard < 100000; ++guard) {
        auto n = decoder.read(chunk.data(), 4096);
        if (!n.ok()) {
            XCTFail(@"%s: read failed: %@", clip.file.c_str(), describe(n.error()));
            break;
        }
        if (n.value() == 0) {
            break;
        }
        all.insert(all.end(), chunk.begin(), chunk.begin() + n.value() * decoder.channels());
    }
    return all;
}

// MARK: - Probe

- (void)testProbeMetadata {
    auto prober = self.backendUnderTest->makeProber();
    for (const TestClip &clip : [self suiteClips]) {
        const std::string path = [self pathForFile:clip.file];
        if (path.empty()) {
            return;
        }
        auto r = prober->probe(path);
        if (!r.ok()) {
            XCTFail(@"%s: probe failed: %@", clip.file.c_str(), describe(r.error()));
            continue;
        }
        const MediaInfo &info = r.value();
        NSLog(@"%@", ns(info.description()));
        XCTAssertEqual(info.container, [self expectedContainerForClip:clip], @"%s", clip.file.c_str());
        XCTAssertEqual(info.backend, self.backendUnderTest->name(), @"%s", clip.file.c_str());
        const size_t expectedTracks = (clip.hasVideo() || clip.isStill() ? 1 : 0) + (clip.hasAudio() ? 1 : 0);
        XCTAssertEqual(info.tracks.size(), expectedTracks, @"%s", clip.file.c_str());
        XCTAssertEqual(info.isStill(), clip.isStill(), @"%s", clip.file.c_str());

        if (clip.isStill()) {
            const TrackInfo *t = info.firstTrack(TrackKind::Still);
            XCTAssertTrue(t != nullptr, @"%s: no still track", clip.file.c_str());
            if (t) {
                XCTAssertEqual(t->width, clip.width, @"%s", clip.file.c_str());
                XCTAssertEqual(t->height, clip.height, @"%s", clip.file.c_str());
                XCTAssertEqual(t->codec.fourCC, clip.videoCodec, @"%s: %s", clip.file.c_str(),
                               t->codec.fourCCString().c_str());
                XCTAssertTrue(CMTIME_IS_INDEFINITE(t->duration), @"%s", clip.file.c_str());
            }
            XCTAssertTrue(CMTIME_IS_INDEFINITE(info.duration), @"%s", clip.file.c_str());
            continue;
        }

        const double onePercentOfFrame = clip.hasVideo() ? seconds(clip.frameDuration) : 0.025;
        const double expectedDuration = clip.hasVideo() ? seconds(clip.videoDuration()) : clip.audioSeconds;
        XCTAssertEqualWithAccuracy(seconds(info.duration), expectedDuration, onePercentOfFrame, @"%s",
                                   clip.file.c_str());
        if (clip.hasVideo()) {
            const TrackInfo *t = info.firstTrack(TrackKind::Video);
            XCTAssertTrue(t != nullptr, @"%s: no video track", clip.file.c_str());
            if (t) {
                XCTAssertEqual(canonicalCodec(t->codec.fourCC), clip.videoCodec, @"%s: %s", clip.file.c_str(),
                               t->codec.fourCCString().c_str());
                XCTAssertFalse(t->codec.name.empty(), @"%s", clip.file.c_str());
                XCTAssertEqual(t->width, clip.width, @"%s", clip.file.c_str());
                XCTAssertEqual(t->height, clip.height, @"%s", clip.file.c_str());
                XCTAssertEqual(CMTimeCompare(t->frameDuration, clip.frameDuration), 0,
                               @"%s: frame duration %lld/%d", clip.file.c_str(), t->frameDuration.value,
                               t->frameDuration.timescale);
                XCTAssertEqualWithAccuracy(t->nominalFps, 1.0 / seconds(clip.frameDuration), 0.01, @"%s",
                                           clip.file.c_str());
                XCTAssertFalse(t->isVFR, @"%s", clip.file.c_str());
                XCTAssertEqualWithAccuracy(seconds(t->duration), seconds(clip.videoDuration()),
                                           seconds(clip.frameDuration), @"%s", clip.file.c_str());
                XCTAssertEqual(t->color.primaries, ColorPrimaries::BT709, @"%s", clip.file.c_str());
                XCTAssertEqual(t->color.transfer, TransferFunction::BT709, @"%s", clip.file.c_str());
                XCTAssertEqual(t->color.matrix, YCbCrMatrix::BT709, @"%s", clip.file.c_str());
                XCTAssertEqual(t->rotationDegrees, 0, @"%s", clip.file.c_str());
            }
        }
        if (clip.hasAudio()) {
            const TrackInfo *a = info.firstTrack(TrackKind::Audio);
            XCTAssertTrue(a != nullptr, @"%s: no audio track", clip.file.c_str());
            if (a) {
                XCTAssertEqual(a->codec.fourCC, clip.audioCodec, @"%s: %s", clip.file.c_str(),
                               a->codec.fourCCString().c_str());
                XCTAssertEqual(a->sampleRate, 48000.0, @"%s", clip.file.c_str());
                XCTAssertEqual(a->channels, 2, @"%s", clip.file.c_str());
                XCTAssertEqualWithAccuracy(seconds(a->duration), clip.audioSeconds, 0.025, @"%s", clip.file.c_str());
            }
        }
    }
}

- (void)testBadFilesAreErrorsNotCrashes {
    const std::string dir = scratchDirectory();
    auto prober = self.backendUnderTest->makeProber();
    auto expectFailure = [&](const std::string &path, NSString *what) {
        auto info = prober->probe(path);
        XCTAssertFalse(info.ok(), @"%@: probe unexpectedly succeeded", what);
        auto video = self.backendUnderTest->makeVideoDecoder();
        XCTAssertFalse(video->open(path, -1, {}).ok(), @"%@: video open unexpectedly succeeded", what);
        auto audio = self.backendUnderTest->makeAudioDecoder();
        XCTAssertFalse(audio->open(path, -1, {}).ok(), @"%@: audio open unexpectedly succeeded", what);
        // Calls on a decoder whose open failed are errors, not crashes.
        XCTAssertFalse(video->next().ok(), @"%@", what);
        XCTAssertFalse(video->seek(kCMTimeZero).ok(), @"%@", what);
        float buffer[16];
        XCTAssertFalse(audio->read(buffer, 8).ok(), @"%@", what);
    };

    auto missing = prober->probe(dir + "/does-not-exist.mov");
    XCTAssertFalse(missing.ok());
    if (!missing.ok()) {
        XCTAssertEqual(missing.error().code, MediaErrorCode::FileNotFound, @"%@", describe(missing.error()));
    }
    expectFailure(dir + "/does-not-exist.mov", @"missing");
    expectFailure(dir, @"directory");

    std::ofstream(dir + "/empty.mp4").close();
    expectFailure(dir + "/empty.mp4", @"empty");

    std::mt19937 rng(1234);
    std::vector<char> garbage(64 * 1024);
    for (char &c : garbage) {
        c = static_cast<char>(rng() & 0xFF);
    }
    std::ofstream(dir + "/garbage.mp4", std::ios::binary)
        .write(garbage.data(), static_cast<std::streamsize>(garbage.size()));
    expectFailure(dir + "/garbage.mp4", @"garbage");
    std::ofstream(dir + "/text.mov") << "this is not a movie\n";
    expectFailure(dir + "/text.mov", @"text");

    // A movie whose header survives but whose media data is cut off (the H.264 file has its
    // moov at the front) and one whose header is lost (the HEVC .mov has moov at the end).
    for (const char *original : {"h264_1080p30.mp4", "hevc_720p2997.mov"}) {
        const TestClip *clip = [self clipNamed:original];
        if (clip == nullptr) {
            continue;
        }
        const char *name = clip->file.c_str();
        const std::string source = [self pathForFile:clip->file];
        if (source.empty()) {
            return;
        }
        std::ifstream in(source, std::ios::binary);
        std::vector<char> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        const std::string truncated = dir + "/truncated_" + name;
        std::ofstream(truncated, std::ios::binary)
            .write(bytes.data(), static_cast<std::streamsize>(bytes.size() * 2 / 5));

        auto info = prober->probe(truncated);
        NSLog(@"truncated %s probe: %@", name, info.ok() ? @"ok" : describe(info.error()));
        auto video = self.backendUnderTest->makeVideoDecoder();
        if (video->open(truncated, -1, {}).ok()) {
            int frames = 0;
            int errors = 0;
            for (int i = 0; i < 400 && errors < 3; ++i) {
                auto f = video->next();
                if (!f.ok()) {
                    ++errors;
                    continue;
                }
                if (!f.value()) {
                    break;
                }
                ++frames;
            }
            XCTAssertLessThan(frames, 300, @"%s: truncated file decoded completely?", name);
            (void)video->seek(CMTimeMake(8, 1));
            (void)video->next();
            (void)video->seek(kCMTimeZero);
            (void)video->next();
        }
        auto audio = self.backendUnderTest->makeAudioDecoder();
        if (audio->open(truncated, -1, {}).ok()) {
            std::vector<float> chunk(8192);
            for (int i = 0; i < 1000; ++i) {
                auto n = audio->read(chunk.data(), 4096);
                if (!n.ok() || n.value() == 0) {
                    break;
                }
            }
        }
    }
}

// MARK: - Video decode

- (void)testSequentialDecodeReturnsEveryFrameWithExactPts {
    for (const TestClip *clip : [self videoClips]) {
        auto decoder = [self openVideo:*clip options:{}];
        if (!decoder) {
            continue;
        }
        XCTAssertEqual(CMTimeCompare(decoder->frameDuration(), clip->frameDuration), 0, @"%s", clip->file.c_str());
        int failures = 0;
        for (int i = 0; i < clip->frames && failures < 5; ++i) {
            if (![self expectNext:*decoder clip:*clip index:i label:[NSString stringWithFormat:@"frame %d", i]]) {
                ++failures;
            }
        }
        if (failures == 0) {
            [self expectEndOfStream:*decoder clip:*clip label:@"after last frame"];
            [self expectEndOfStream:*decoder clip:*clip label:@"after end, again"];
        }
    }
}

- (void)testSeekLandsOnTheFrameContainingTheTime {
    for (const TestClip *clip : [self videoClips]) {
        auto decoder = [self openVideo:*clip options:{}];
        if (!decoder) {
            continue;
        }
        const TestClip &c = *clip;
        const int n = c.frames;
        const double fd = seconds(c.frameDuration);

        [self seek:*decoder to:0 clip:c];
        [self expectNext:*decoder clip:c index:0 label:@"seek start"];
        [self expectNext:*decoder clip:c index:1 label:@"after seek start"];

        [self seek:*decoder toFrame:n / 2 clip:c];
        [self expectNext:*decoder clip:c index:n / 2 label:@"seek middle"];
        [self expectNext:*decoder clip:c index:n / 2 + 1 label:@"after seek middle"];

        [self seek:*decoder toFrame:n - 1 clip:c];
        [self expectNext:*decoder clip:c index:n - 1 label:@"seek last frame"];
        [self expectEndOfStream:*decoder clip:c label:@"after last frame"];

        const int between = n / 3;
        [self seek:*decoder to:(between + 0.5) * fd clip:c];
        [self expectNext:*decoder clip:c index:between label:@"seek between frames"];
        [self seek:*decoder to:(between + 1) * fd - 1e-5 clip:c];
        [self expectNext:*decoder clip:c index:between label:@"seek just before next frame"];

        [self seek:*decoder toFrame:n - 10 clip:c];
        [self expectNext:*decoder clip:c index:n - 10 label:@"seek late"];
        [self seek:*decoder toFrame:7 clip:c];
        [self expectNext:*decoder clip:c index:7 label:@"seek backwards"];
        [self expectNext:*decoder clip:c index:8 label:@"after seek backwards"];

        // Forward by 5 s (or as far as the clip allows, still beyond any close-ahead window).
        const double jump = std::min(5.0, (n - 1) * fd - 9 * fd);
        const int forward = indexAt(c, 9 * fd + jump);
        [self seek:*decoder to:9 * fd + jump clip:c];
        [self expectNext:*decoder clip:c index:forward label:@"seek forward 5 s"];

        [self seek:*decoder toFrame:forward - 20 clip:c];
        [self expectNext:*decoder clip:c index:forward - 20 label:@"reposition"];
        [self seek:*decoder toFrame:forward - 16 clip:c];
        [self expectNext:*decoder clip:c index:forward - 16 label:@"seek close ahead"];
        [self seek:*decoder to:(forward - 16 + 0.25) * fd clip:c];
        [self expectNext:*decoder clip:c index:forward - 16 label:@"seek into the frame just returned"];
        [self expectNext:*decoder clip:c index:forward - 15 label:@"continue after repeated frame"];

        [self seek:*decoder to:-1.0 clip:c];
        [self expectNext:*decoder clip:c index:0 label:@"seek before start"];
        [self seek:*decoder to:n * fd clip:c];
        [self expectEndOfStream:*decoder clip:c label:@"seek to end"];
        [self seek:*decoder to:n * fd + 10 clip:c];
        [self expectEndOfStream:*decoder clip:c label:@"seek past end"];
        [self seek:*decoder toFrame:3 clip:c];
        [self expectNext:*decoder clip:c index:3 label:@"seek after end of stream"];
    }
}

- (void)testDecodingContinuesInOrderAfterRandomSeek {
    for (const TestClip *clip : [self videoClips]) {
        auto decoder = [self openVideo:*clip options:{}];
        if (!decoder) {
            continue;
        }
        for (int i = 0; i < 5; ++i) {
            (void)decoder->next();
        }
        // Back to the middle of a GOP, then read across two GOP boundaries.
        const int start = std::min(12, clip->frames / 4);
        [self seek:*decoder toFrame:start clip:*clip];
        const int end = std::min(clip->frames, start + 130);
        int failures = 0;
        for (int i = start; i < end && failures < 3; ++i) {
            if (![self expectNext:*decoder clip:*clip index:i label:@"continuous after seek"]) {
                ++failures;
            }
        }
        // A far forward seek followed by continuous reading.
        const int far = clip->frames - 40;
        [self seek:*decoder toFrame:far clip:*clip];
        failures = 0;
        for (int i = far; i < clip->frames && failures < 3; ++i) {
            if (![self expectNext:*decoder clip:*clip index:i label:@"continuous after far seek"]) {
                ++failures;
            }
        }
        [self expectEndOfStream:*decoder clip:*clip label:@"end after far seek"];
    }
}

- (void)testSeekAroundEveryKeyframeBoundary {
    // Targets on both sides of every GOP boundary, visited backwards so every seek is a
    // random-access seek. Catches open-GOP leading pictures (HEVC RASL) and B-frame reordering.
    for (const TestClip *clip : [self videoClips]) {
        if (clip->gopFrames <= 0) {
            continue;
        }
        auto decoder = [self openVideo:*clip options:{}];
        if (!decoder) {
            continue;
        }
        std::vector<int> targets;
        for (int g = clip->gopFrames; g < clip->frames; g += clip->gopFrames) {
            for (int d : {-2, -1, 0, 1}) {
                targets.push_back(g + d);
            }
        }
        std::sort(targets.rbegin(), targets.rend());
        int failures = 0;
        for (int target : targets) {
            [self seek:*decoder toFrame:target clip:*clip];
            if (![self expectNext:*decoder clip:*clip index:target label:@"GOP boundary"] ||
                ![self expectNext:*decoder clip:*clip index:target + 1 label:@"after GOP boundary"]) {
                if (++failures >= 3) {
                    break;
                }
            }
        }
    }
}

- (void)testStillsReturnOneFramePerSeek {
    for (const TestClip *clip : [self stillClips]) {
        auto decoder = [self openVideo:*clip options:{}];
        if (!decoder) {
            continue;
        }
        XCTAssertTrue(decoder->supportsRandomAccess(), @"%s", clip->file.c_str());
        for (double t : {-1.0, 0.0, 5.0, 3600.0}) {
            if (t != -1.0) {
                XCTAssertTrue(decoder->seek(CMTimeMakeWithSeconds(t, 600)).ok(), @"%s", clip->file.c_str());
            }
            auto r = decoder->next();
            XCTAssertTrue(r.ok() && r.value(), @"%s: no frame after seek(%.1f)", clip->file.c_str(), t);
            if (!r.ok() || !r.value()) {
                continue;
            }
            const VideoFrame &f = *r.value();
            XCTAssertEqual(readBurnIn(f.image.get()), std::optional<int>(clip->stillIndex), @"%s", clip->file.c_str());
            XCTAssertEqual(static_cast<int>(f.image.width()), clip->width, @"%s", clip->file.c_str());
            XCTAssertEqual(static_cast<int>(f.image.height()), clip->height, @"%s", clip->file.c_str());
            XCTAssertEqual(CMTimeCompare(f.pts, kCMTimeZero), 0, @"%s", clip->file.c_str());
            XCTAssertTrue(CMTIME_IS_POSITIVE_INFINITY(f.duration), @"%s", clip->file.c_str());
            XCTAssertTrue(f.contains(CMTimeMake(1000, 1)), @"%s", clip->file.c_str());
            XCTAssertTrue(f.image.isIOSurfaceBacked(), @"%s", clip->file.c_str());
            auto again = decoder->next();
            XCTAssertTrue(again.ok() && !again.value(), @"%s: still returned twice without a seek", clip->file.c_str());
        }
    }
}

- (void)testThumbnailDecodeScalesAndKeepsBurnIn {
    for (const TestClip &clip : [self suiteClips]) {
        if (!clip.hasVideo() && !clip.isStill()) {
            continue;
        }
        DecodeOptions options;
        options.maxDimension = 320;
        auto decoder = [self openVideo:clip options:options];
        if (!decoder) {
            continue;
        }
        const int frame = clip.hasVideo() ? 10 : 0;
        if (clip.hasVideo()) {
            [self seek:*decoder toFrame:frame clip:clip];
        }
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value(), @"%s", clip.file.c_str());
        if (!r.ok() || !r.value()) {
            continue;
        }
        const PixelBuffer &image = r.value()->image;
        XCTAssertLessThanOrEqual(image.width(), 320u, @"%s", clip.file.c_str());
        XCTAssertLessThanOrEqual(image.height(), 320u, @"%s", clip.file.c_str());
        XCTAssertEqual(std::max(image.width(), image.height()), 320u, @"%s", clip.file.c_str());
        const double aspect = static_cast<double>(clip.width) / clip.height;
        XCTAssertEqualWithAccuracy(static_cast<double>(image.width()) / static_cast<double>(image.height()), aspect,
                                   0.02, @"%s", clip.file.c_str());
        const int expected = clip.hasVideo() ? frame : clip.stillIndex;
        XCTAssertEqual(readBurnIn(image.get()), std::optional<int>(expected), @"%s", clip.file.c_str());
    }
}

- (void)testOutputPixelFormats {
    struct Case {
        const char *file;
        OSType native;
    };
    for (const Case &test : {Case{"h264_1080p30.mp4", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
                             Case{"hevc_720p2997.mov", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
                             Case{"prores_540p25.mov", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange},
                             Case{"still.png", kCVPixelFormatType_32BGRA}}) {
        const TestClip *found = [self clipNamed:test.file];
        if (found == nullptr) {
            continue;
        }
        const TestClip &clip = *found;
        auto decoder = [self openVideo:clip options:{}];
        if (!decoder) {
            continue;
        }
        XCTAssertEqual(decoder->outputPixelFormat(), test.native, @"%s", test.file);
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value(), @"%s", test.file);
        if (r.ok() && r.value()) {
            XCTAssertEqual(r.value()->image.pixelFormat(), test.native, @"%s", test.file);
            XCTAssertTrue(r.value()->image.isIOSurfaceBacked(), @"%s", test.file);
        }

        DecodeOptions bgra;
        bgra.pixelFormat = kCVPixelFormatType_32BGRA;
        auto rgbDecoder = [self openVideo:clip options:bgra];
        if (!rgbDecoder) {
            continue;
        }
        auto f = rgbDecoder->next();
        XCTAssertTrue(f.ok() && f.value(), @"%s", test.file);
        if (f.ok() && f.value()) {
            XCTAssertEqual(f.value()->image.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA, @"%s", test.file);
            XCTAssertEqual(readBurnIn(f.value()->image.get()),
                           std::optional<int>(clip.isStill() ? clip.stillIndex : 0), @"%s", test.file);
        }
    }
}

- (void)testHardwareDecodeIsReported {
    for (const char *file : {"h264_1080p30.mp4", "hevc_720p2997.mov", "prores_540p25.mov"}) {
        const TestClip *found = [self clipNamed:file];
        if (found == nullptr) {
            continue;
        }
        const TestClip &clip = *found;
        auto decoder = [self openVideo:clip options:{}];
        if (!decoder) {
            continue;
        }
        // The platform's own answer, not HardwareCaps (which the decoders consult too).
        const std::optional<bool> vt = [self videoToolboxAnswerForClip:clip];
        XCTAssertTrue(vt.has_value(), @"%s: VideoToolbox refuses the format", file);
        const bool expected = vt.value_or(false);
        NSLog(@"%s: VideoToolbox hardware decode %d; decoder reports %d", file, expected, decoder->usedHardware());
        auto first = decoder->next();
        XCTAssertTrue(first.ok() && first.value(), @"%s", file);
        if (first.ok() && first.value()) {
            XCTAssertEqual(first.value()->wasHardwareDecoded, (bool)expected, @"%s sequential", file);
        }
        XCTAssertEqual(decoder->usedHardware(), (bool)expected, @"%s sequential", file);

        [self seek:*decoder toFrame:clip.frames - 5 clip:clip];
        [self seek:*decoder toFrame:20 clip:clip];
        auto seeked = decoder->next();
        XCTAssertTrue(seeked.ok() && seeked.value(), @"%s", file);
        if (seeked.ok() && seeked.value()) {
            XCTAssertEqual(seeked.value()->wasHardwareDecoded, (bool)expected, @"%s after seek", file);
        }
        XCTAssertEqual(decoder->usedHardware(), (bool)expected, @"%s after seek", file);
    }
}

- (void)testDecodedFramesOutliveTheDecoder {
    const TestClip *found = [self clipNamed:"hevc_720p2997.mov"];
    if (found == nullptr) {
        return;
    }
    const TestClip &clip = *found;
    PixelBuffer kept;
    {
        auto decoder = [self openVideo:clip options:{}];
        if (!decoder) {
            return;
        }
        [self seek:*decoder toFrame:42 clip:clip];
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value());
        if (r.ok() && r.value()) {
            kept = r.value()->image;
        }
    }
    XCTAssertEqual(readBurnIn(kept.get()), std::optional<int>(42));
}

- (void)testDecodeMemoryIsBounded {
    const TestClip *found = [self clipNamed:"h264_1080p30.mp4"];
    if (found == nullptr) {
        return;
    }
    const TestClip &clip = *found;
    auto decoder = [self openVideo:clip options:{}];
    if (!decoder) {
        return;
    }
    for (int i = 0; i < 30; ++i) {
        (void)decoder->next();
    }
    const uint64_t before = physicalFootprint();
    int decoded = 0;
    for (int i = 30; i < clip.frames; ++i) {
        auto r = decoder->next();
        decoded += (r.ok() && r.value()) ? 1 : 0;
    }
    std::mt19937 rng(7);
    for (int i = 0; i < 25; ++i) {
        (void)decoder->seek(frameTime(clip, static_cast<int>(rng() % static_cast<unsigned>(clip.frames))));
        for (int k = 0; k < 3; ++k) {
            auto r = decoder->next();
            decoded += (r.ok() && r.value()) ? 1 : 0;
        }
    }
    const uint64_t after = physicalFootprint();
    const double growthMB = (static_cast<double>(after) - static_cast<double>(before)) / (1024.0 * 1024.0);
    NSLog(@"decoded %d frames; footprint %.1f MB -> %.1f MB (%+.1f MB)", decoded, before / 1048576.0,
          after / 1048576.0, growthMB);
    XCTAssertGreaterThanOrEqual(decoded, 300);
    XCTAssertLessThan(growthMB, 64.0, @"footprint grew by %.1f MB over %d frames", growthMB, decoded);
}

- (void)testIndependentDecodersRunConcurrently {
    const TestClip *clips[] = {[self clipNamed:"h264_1080p30.mp4"], [self clipNamed:"hevc_720p2997.mov"]};
    if (clips[0] == nullptr || clips[1] == nullptr) {
        return;
    }
    std::string paths[2];
    for (int i = 0; i < 2; ++i) {
        paths[i] = [self pathForFile:clips[i]->file];
        if (paths[i].empty()) {
            return;
        }
    }
    std::atomic<int> mismatches{0};
    std::atomic<int> frames{0};
    auto backend = self.backendUnderTest;
    auto work = [&](int which) {
        const TestClip &clip = *clips[which];
        auto decoder = backend->makeVideoDecoder();
        if (!decoder->open(paths[which], -1, {}).ok()) {
            ++mismatches;
            return;
        }
        for (int round = 0; round < 4; ++round) {
            const int start = (round * 67 + which * 13) % (clip.frames - 20);
            if (!decoder->seek(frameTime(clip, start)).ok()) {
                ++mismatches;
                continue;
            }
            for (int i = start; i < start + 15; ++i) {
                auto r = decoder->next();
                if (!r.ok() || !r.value() || readBurnIn(r.value()->image.get()) != i) {
                    ++mismatches;
                }
                ++frames;
            }
        }
    };
    std::thread a(work, 0);
    std::thread b(work, 1);
    a.join();
    b.join();
    XCTAssertEqual(mismatches.load(), 0);
    XCTAssertEqual(frames.load(), 120);
}

// MARK: - Audio

- (void)testAudioBeepIsAtTwoSecondsAndToneIsRight {
    for (const TestClip *clip : [self audioClips]) {
        auto decoder = [self openAudio:*clip options:{}];
        if (!decoder) {
            continue;
        }
        XCTAssertEqual(decoder->sampleRate(), 48000.0);
        XCTAssertEqual(decoder->channels(), 2);
        const std::vector<float> all = [self readAll:*decoder clip:*clip];
        const auto frames = static_cast<int64_t>(all.size() / 2);
        const auto expected = static_cast<int64_t>(std::llround(clip->audioSeconds * 48000));
        // Linear PCM has no codec framing: the count is exact. Compressed tracks are exact too
        // where the container states the length (ISO-BMFF edit lists / iTunSMPB), else within a
        // codec frame (Matroska).
        const int64_t countSlack = clip->audioCodec == fourcc::LinearPCM ? 0 : 1024;
        XCTAssertLessThanOrEqual(std::llabs(frames - expected), countSlack, @"%s: %lld frames, wanted %lld",
                                 clip->file.c_str(), frames, expected);
        XCTAssertLessThanOrEqual(std::llabs(decoder->lengthFrames() - expected), countSlack, @"%s",
                                 clip->file.c_str());
        XCTAssertEqual(decoder->position(), frames, @"%s", clip->file.c_str());
        auto onset = findBeepOnset(all.data(), frames, 2, 48000, static_cast<int64_t>(1.5 * 48000));
        XCTAssertTrue(onset.has_value(), @"%s: no beep", clip->file.c_str());
        if (onset) {
            XCTAssertEqualWithAccuracy(*onset, referenceOnset(clip->toneHz, 48000, kMediaBeepStart),
                                       onsetTolerance(clip->audioCodec, 48000), @"%s: beep at %.6f s",
                                       clip->file.c_str(), *onset);
        }
        XCTAssertFalse(findBeepOnset(all.data(), static_cast<int64_t>(1.95 * 48000), 2, 48000).has_value(),
                       @"%s: loud samples before the beep", clip->file.c_str());
        const double hz = estimateFrequency(all.data(), 24000, 72000, 2, 48000);
        XCTAssertEqualWithAccuracy(hz, clip->toneHz, clip->toneHz * 0.01, @"%s", clip->file.c_str());
        double maxChannelDiff = 0;
        for (int64_t i = 0; i < frames; ++i) {
            maxChannelDiff = std::max(maxChannelDiff, static_cast<double>(std::fabs(all[i * 2] - all[i * 2 + 1])));
        }
        XCTAssertLessThan(maxChannelDiff, 0.01, @"%s: channels differ", clip->file.c_str());
    }
}

- (void)testAudioSeekIsSampleAccurate {
    for (const TestClip *clip : [self audioClips]) {
        auto reference = [self openAudio:*clip options:{}];
        auto decoder = [self openAudio:*clip options:{}];
        if (!reference || !decoder) {
            continue;
        }
        const std::vector<float> all = [self readAll:*reference clip:*clip];
        const auto total = static_cast<int64_t>(all.size() / 2);
        const bool lossless = clip->audioCodec == fourcc::LinearPCM;
        std::vector<float> chunk(4800 * 2);
        // Backwards, small forward skip, far forward, far backward, non-integral sample time.
        for (double t : {1.234567, 0.5, 0.6, 7.0, 0.001, 2.9, 1.95}) {
            if (t * 48000 + 4800 > static_cast<double>(total)) {
                continue;
            }
            Status s = decoder->seek(CMTimeMakeWithSeconds(t, 1000000000));
            XCTAssertTrue(s.ok(), @"%s: seek %.6f: %@", clip->file.c_str(), t, s.ok() ? @"" : describe(s.error()));
            const auto pos = static_cast<int64_t>(std::floor(t * 48000));
            XCTAssertEqual(decoder->position(), pos, @"%s seek %.6f", clip->file.c_str(), t);
            auto n = decoder->read(chunk.data(), 4800);
            XCTAssertTrue(n.ok() && n.value() == 4800, @"%s seek %.6f", clip->file.c_str(), t);
            if (!n.ok()) {
                continue;
            }
            double maxDiff = 0;
            for (int64_t i = 0; i < n.value() * 2; ++i) {
                maxDiff = std::max(maxDiff, static_cast<double>(std::fabs(chunk[i] - all[pos * 2 + i])));
            }
            XCTAssertLessThan(maxDiff, lossless ? 1e-6 : 2e-3, @"%s: seek %.6f differs from sequential by %g",
                              clip->file.c_str(), t, maxDiff);
            if (t == 1.95) {
                auto onset = findBeepOnset(chunk.data(), n.value(), 2, 48000);
                XCTAssertTrue(onset.has_value(), @"%s", clip->file.c_str());
                if (onset) {
                    XCTAssertEqualWithAccuracy(*onset + static_cast<double>(pos) / 48000.0,
                                               referenceOnset(clip->toneHz, 48000, kMediaBeepStart),
                                               onsetTolerance(clip->audioCodec, 48000), @"%s: beep after seek",
                                               clip->file.c_str());
                }
            }
        }
    }
}

- (void)testAudioConvertsRateAndChannels {
    for (const TestClip *clip : [self audioClips]) {
        AudioOptions options;
        options.sampleRate = 44100;
        options.channels = 1;
        auto decoder = [self openAudio:*clip options:options];
        if (!decoder) {
            continue;
        }
        const std::vector<float> all = [self readAll:*decoder clip:*clip];
        const auto frames = static_cast<int64_t>(all.size());
        XCTAssertLessThanOrEqual(std::llabs(frames - std::llround(clip->audioSeconds * 44100)), 1024, @"%s",
                                 clip->file.c_str());
        auto onset = findBeepOnset(all.data(), frames, 1, 44100, static_cast<int64_t>(1.5 * 44100));
        XCTAssertTrue(onset.has_value(), @"%s", clip->file.c_str());
        if (onset) {
            // Resampling to 44.1 kHz moves the attack by at most a couple of output samples.
            XCTAssertEqualWithAccuracy(*onset, referenceOnset(clip->toneHz, 44100, kMediaBeepStart), 4.0 / 44100,
                                       @"%s: beep at %.6f s at 44.1 kHz mono", clip->file.c_str(), *onset);
        }
        XCTAssertEqualWithAccuracy(estimateFrequency(all.data(), 22050, 66150, 1, 44100), clip->toneHz,
                                   clip->toneHz * 0.01, @"%s", clip->file.c_str());
    }
}

// MARK: - Writer

struct WriterCase {
    VideoCodec codec;
    ContainerFormat container;
    AudioCodec audio;
    CMTime frameDuration;
    bool pull;
    bool requireHardware;
    const char *name;
};

- (void)roundTrip:(const WriterCase &)wc {
    constexpr int kFrames = 60;
    constexpr int kWidth = 640;
    constexpr int kHeight = 360;
    constexpr double kBeep = 1.0;
    constexpr double kTone = 500;
    const std::string path = scratchDirectory() + "/" + wc.name;

    EncodeSettings settings;
    settings.container = wc.container;
    VideoEncodeSettings video;
    video.codec = wc.codec;
    video.width = kWidth;
    video.height = kHeight;
    video.frameDuration = wc.frameDuration;
    video.averageBitRate = 4'000'000;
    video.maxKeyFrameInterval = 30;
    video.requireHardware = wc.requireHardware;
    settings.video = video;
    AudioEncodeSettings audio;
    audio.codec = wc.audio;
    settings.audio = audio;

    const double fd = seconds(wc.frameDuration);
    const auto audioFrames = static_cast<int64_t>(std::llround(kFrames * fd * 48000));
    const std::vector<float> pcm = makeToneWithBeep(kTone, 48000, 2, audioFrames, kBeep);

    XCTAssertTrue(self.backendUnderTest->canWrite(settings), @"%s", wc.name);
    auto writer = self.backendUnderTest->makeWriter();
    Status opened = writer->open(path, settings);
    XCTAssertTrue(opened.ok(), @"%s: %@", wc.name, opened.ok() ? @"" : describe(opened.error()));
    if (!opened.ok()) {
        return;
    }
    // VideoToolbox's own answer for these settings, not HardwareCaps.
    const bool expectHardware = videoToolboxEncodesInHardware(codecType(wc.codec), kWidth, kHeight);
    XCTAssertEqual(writer->usesHardwareVideoEncoder(), expectHardware, @"%s", wc.name);

    auto makeFrame = [&](int i) -> PixelBuffer {
        auto buffer = writer->makePixelBuffer();
        if (!buffer.ok()) {
            return {};
        }
        drawBurnIn(buffer->get(), i);
        return std::move(buffer).value();
    };
    if (wc.pull) {
        int nextFrame = 0;
        int64_t nextSample = 0;
        Status s = writer->runPull(
            [&]() -> Result<std::optional<VideoInput>> {
                if (nextFrame >= kFrames) {
                    return std::optional<VideoInput>();
                }
                PixelBuffer image = makeFrame(nextFrame);
                if (!image) {
                    return makeError(MediaErrorCode::Internal, "no pixel buffer");
                }
                VideoInput in{image, CMTimeMultiply(wc.frameDuration, nextFrame)};
                ++nextFrame;
                return std::optional<VideoInput>(std::move(in));
            },
            [&](float *dst, int maxFrames) -> Result<int> {
                const auto n = static_cast<int>(std::min<int64_t>(maxFrames, audioFrames - nextSample));
                std::copy_n(pcm.data() + nextSample * 2, n * 2, dst);
                nextSample += n;
                return n;
            });
        XCTAssertTrue(s.ok(), @"%s: runPull: %@", wc.name, s.ok() ? @"" : describe(s.error()));
        XCTAssertEqual(nextFrame, kFrames, @"%s", wc.name);
        XCTAssertEqual(nextSample, audioFrames, @"%s", wc.name);
    } else {
        // Push: audio runs up to 1.5 s ahead of video, as the IMediaWriter contract asks.
        int64_t written = 0;
        for (int i = 0; i < kFrames; ++i) {
            const auto until = std::min<int64_t>(audioFrames, std::llround((i * fd + 1.5) * 48000));
            while (written < until) {
                const auto n = static_cast<int>(std::min<int64_t>(1024, until - written));
                Status s = writer->appendAudio(pcm.data() + written * 2, n);
                XCTAssertTrue(s.ok(), @"%s: appendAudio: %@", wc.name, s.ok() ? @"" : describe(s.error()));
                if (!s.ok()) {
                    return;
                }
                written += n;
            }
            if (written == audioFrames) {
                XCTAssertTrue(writer->endStream(TrackKind::Audio).ok(), @"%s", wc.name);
                written = audioFrames + 1; // Ended.
            }
            PixelBuffer image = makeFrame(i);
            XCTAssertTrue(static_cast<bool>(image), @"%s", wc.name);
            Status s = writer->appendVideo(image, CMTimeMultiply(wc.frameDuration, i));
            XCTAssertTrue(s.ok(), @"%s: appendVideo %d: %@", wc.name, i, s.ok() ? @"" : describe(s.error()));
            if (!s.ok()) {
                return;
            }
        }
    }
    Status finished = writer->finish();
    XCTAssertTrue(finished.ok(), @"%s: finish: %@", wc.name, finished.ok() ? @"" : describe(finished.error()));
    if (!finished.ok()) {
        return;
    }

    // Re-read with the same backend.
    auto info = self.backendUnderTest->makeProber()->probe(path);
    XCTAssertTrue(info.ok(), @"%s: %@", wc.name, info.ok() ? @"" : describe(info.error()));
    if (!info.ok()) {
        return;
    }
    const TrackInfo *v = info->firstTrack(TrackKind::Video);
    const TrackInfo *a = info->firstTrack(TrackKind::Audio);
    XCTAssertTrue(v && a, @"%s", wc.name);
    if (!v || !a) {
        return;
    }
    XCTAssertEqual(canonicalCodec(v->codec.fourCC), codecType(wc.codec), @"%s", wc.name);
    XCTAssertEqual(v->width, kWidth);
    XCTAssertEqual(v->height, kHeight);
    XCTAssertEqual(CMTimeCompare(v->frameDuration, wc.frameDuration), 0, @"%s: %lld/%d", wc.name,
                   v->frameDuration.value, v->frameDuration.timescale);
    XCTAssertEqualWithAccuracy(seconds(v->duration), kFrames * fd, fd, @"%s", wc.name);
    XCTAssertEqual(v->color.primaries, ColorPrimaries::BT709, @"%s", wc.name);
    XCTAssertEqual(a->codec.fourCC, wc.audio == AudioCodec::AAC ? fourcc::AAC : fourcc::LinearPCM, @"%s", wc.name);

    TestClip clip;
    clip.file = wc.name;
    clip.frameDuration = wc.frameDuration;
    clip.frames = kFrames;
    auto decoder = self.backendUnderTest->makeVideoDecoder();
    XCTAssertTrue(decoder->open(path, -1, {}).ok(), @"%s", wc.name);
    int failures = 0;
    for (int i = 0; i < kFrames && failures < 3; ++i) {
        if (![self expectNext:*decoder clip:clip index:i label:@"round trip"]) {
            ++failures;
        }
    }
    [self expectEndOfStream:*decoder clip:clip label:@"round trip end"];

    auto audioDecoder = self.backendUnderTest->makeAudioDecoder();
    XCTAssertTrue(audioDecoder->open(path, -1, {}).ok(), @"%s", wc.name);
    clip.audioCodec = a->codec.fourCC;
    const std::vector<float> decoded = [self readAll:*audioDecoder clip:clip];
    auto onset = findBeepOnset(decoded.data(), static_cast<int64_t>(decoded.size() / 2), 2, 48000, 24000);
    XCTAssertTrue(onset.has_value(), @"%s: no beep", wc.name);
    if (onset) {
        XCTAssertEqualWithAccuracy(*onset, referenceOnset(kTone, 48000, kBeep),
                                   onsetTolerance(wc.audio == AudioCodec::LinearPCM ? fourcc::LinearPCM : fourcc::AAC,
                                                  48000),
                                   @"%s: beep at %.6f", wc.name, *onset);
    }
    XCTAssertEqualWithAccuracy(estimateFrequency(decoded.data(), 4800, 43200, 2, 48000), kTone, kTone * 0.01, @"%s",
                               wc.name);
}

- (void)testWriterRoundTripH264Push {
    [self roundTrip:{VideoCodec::H264, ContainerFormat::MP4, AudioCodec::AAC, CMTimeMake(1, 30), false,
                     HardwareCaps::get().h264.hardwareEncode, "rt_h264.mp4"}];
}

- (void)testWriterRoundTripHEVCPush {
    [self roundTrip:{VideoCodec::HEVC, ContainerFormat::MOV, AudioCodec::AAC, CMTimeMake(1001, 30000), false, false,
                     "rt_hevc.mov"}];
}

- (void)testWriterRoundTripProResPull {
    [self roundTrip:{VideoCodec::ProRes422, ContainerFormat::MOV, AudioCodec::LinearPCM, CMTimeMake(1, 25), true,
                     false, "rt_prores.mov"}];
}

- (void)testWriterRoundTripH264Pull {
    [self roundTrip:{VideoCodec::H264, ContainerFormat::MOV, AudioCodec::AAC, CMTimeMake(1, 30), true, false,
                     "rt_h264_pull.mov"}];
}

/// Audio that runs past the last video frame is kept (the session ends with the longer
/// stream); the video track still ends one frame after its last frame.
- (void)testWriterKeepsAudioLongerThanVideo {
    const std::string path = scratchDirectory() + "/longer_audio.mov";
    EncodeSettings settings;
    settings.container = ContainerFormat::MOV;
    VideoEncodeSettings v;
    v.codec = VideoCodec::H264;
    v.width = 320;
    v.height = 180;
    v.frameDuration = CMTimeMake(1, 30);
    settings.video = v;
    settings.audio = AudioEncodeSettings{};
    settings.audio->codec = AudioCodec::LinearPCM;
    auto writer = self.backendUnderTest->makeWriter();
    Status opened = writer->open(path, settings);
    XCTAssertTrue(opened.ok(), @"%@", opened.ok() ? @"" : describe(opened.error()));
    if (!opened.ok()) {
        return;
    }
    // 1 s of video, 3 s of audio with the beep at 2.5 s (well after the video ended).
    const std::vector<float> pcm = makeToneWithBeep(440, 48000, 2, 3 * 48000, 2.5);
    int64_t written = 0;
    for (int i = 0; i < 30; ++i) {
        const int64_t until = std::min<int64_t>(3 * 48000, (i + 45) * 1600);
        while (written < until) {
            const auto n = static_cast<int>(std::min<int64_t>(1600, until - written));
            XCTAssertTrue(writer->appendAudio(pcm.data() + written * 2, n).ok());
            written += n;
        }
        auto frame = writer->makePixelBuffer();
        XCTAssertTrue(frame.ok());
        if (!frame.ok()) {
            return;
        }
        drawBurnIn(frame->get(), i);
        XCTAssertTrue(writer->appendVideo(frame.value(), CMTimeMake(i, 30)).ok());
    }
    XCTAssertTrue(writer->endStream(TrackKind::Video).ok());
    while (written < 3 * 48000) {
        const auto n = static_cast<int>(std::min<int64_t>(4800, 3 * 48000 - written));
        XCTAssertTrue(writer->appendAudio(pcm.data() + written * 2, n).ok());
        written += n;
    }
    Status finished = writer->finish();
    XCTAssertTrue(finished.ok(), @"%@", finished.ok() ? @"" : describe(finished.error()));
    auto info = self.backendUnderTest->makeProber()->probe(path);
    XCTAssertTrue(info.ok());
    if (!info.ok()) {
        return;
    }
    XCTAssertEqualWithAccuracy(seconds(info->firstTrack(TrackKind::Audio)->duration), 3.0, 1e-3, @"audio kept");
    XCTAssertEqualWithAccuracy(seconds(info->firstTrack(TrackKind::Video)->duration), 1.0, 1.0 / 30,
                               @"video ends after its last frame");
    auto audio = self.backendUnderTest->makeAudioDecoder();
    XCTAssertTrue(audio->open(path, -1, {}).ok());
    TestClip clip;
    clip.file = "longer_audio.mov";
    const std::vector<float> decoded = [self readAll:*audio clip:clip];
    XCTAssertEqual(decoded.size(), pcm.size(), @"every audio sample survives");
    auto onset = findBeepOnset(decoded.data(), static_cast<int64_t>(decoded.size() / 2), 2, 48000, 96000);
    XCTAssertTrue(onset.has_value(), @"the beep after the video's end is there");
    if (onset) {
        XCTAssertEqualWithAccuracy(*onset, referenceOnset(440, 48000, 2.5), 1.0 / 48000);
    }
}

/// A pull callback that fails aborts runPull() with that error (no deadlock waiting for the
/// other stream, no half-written file left behind), for either stream.
- (void)testWriterPullCallbackFailureAbortsCleanly {
    for (int failing = 0; failing < 2; ++failing) {
        const std::string path = scratchDirectory() + (failing == 0 ? "/fail_video.mov" : "/fail_audio.mov");
        EncodeSettings settings;
        settings.container = ContainerFormat::MOV;
        VideoEncodeSettings v;
        v.codec = VideoCodec::H264;
        v.width = 320;
        v.height = 180;
        v.frameDuration = CMTimeMake(1, 30);
        settings.video = v;
        settings.audio = AudioEncodeSettings{};
        auto writer = self.backendUnderTest->makeWriter();
        XCTAssertTrue(writer->open(path, settings).ok());
        int frames = 0;
        int64_t samples = 0;
        IMediaWriter *w = writer.get();
        // A deadlock (waiting for the stream that did not fail) would hang here.
        const Status result = w->runPull(
            [&]() -> Result<std::optional<VideoInput>> {
                if (failing == 0 && frames == 10) {
                    return makeError(MediaErrorCode::Internal, "scripted video failure");
                }
                auto buffer = w->makePixelBuffer();
                if (!buffer.ok()) {
                    return std::move(buffer).error();
                }
                return std::optional<VideoInput>(VideoInput{buffer.value(), CMTimeMake(frames++, 30)});
            },
            [&](float *dst, int maxFrames) -> Result<int> {
                if (failing == 1 && samples >= 48000) {
                    return makeError(MediaErrorCode::Internal, "scripted audio failure");
                }
                std::fill_n(dst, maxFrames * 2, 0.0f);
                samples += maxFrames;
                return maxFrames;
            });
        XCTAssertFalse(result.ok(), @"the callback's error is reported");
        if (!result.ok()) {
            XCTAssertEqual(result.error().code, MediaErrorCode::Internal, @"%@", describe(result.error()));
        }
        XCTAssertFalse(writer->finish().ok(), @"nothing to finish after an aborted write");
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:ns(path)], @"no partial file");
    }
}

- (void)testWriterRejectsInvalidUse {
    const std::string dir = scratchDirectory();
    auto backend = self.backendUnderTest;

    EncodeSettings noStreams;
    XCTAssertFalse(backend->canWrite(noStreams));
    XCTAssertFalse(backend->makeWriter()->open(dir + "/a.mov", noStreams).ok());

    EncodeSettings zeroSize;
    zeroSize.video = VideoEncodeSettings{};
    auto zero = backend->makeWriter()->open(dir + "/b.mov", zeroSize);
    XCTAssertFalse(zero.ok());
    if (!zero.ok()) {
        XCTAssertEqual(zero.error().code, MediaErrorCode::InvalidArgument, @"%@", describe(zero.error()));
    }

    EncodeSettings proresInMP4;
    proresInMP4.container = ContainerFormat::MP4;
    VideoEncodeSettings pr;
    pr.codec = VideoCodec::ProRes422;
    pr.width = 640;
    pr.height = 360;
    proresInMP4.video = pr;
    XCTAssertFalse(backend->canWrite(proresInMP4));
    XCTAssertFalse(backend->makeWriter()->open(dir + "/c.mp4", proresInMP4).ok());

    EncodeSettings good;
    good.container = ContainerFormat::MOV;
    VideoEncodeSettings v;
    v.width = 320;
    v.height = 240;
    good.video = v;
    XCTAssertFalse(backend->makeWriter()->open(dir + "/no/such/dir/d.mov", good).ok());

    auto writer = backend->makeWriter();
    XCTAssertFalse(writer->appendVideo({}, kCMTimeZero).ok(), @"append before open");
    XCTAssertFalse(writer->finish().ok(), @"finish before open");
    XCTAssertTrue(writer->open(dir + "/e.mov", good).ok());
    XCTAssertFalse(writer->open(dir + "/e.mov", good).ok(), @"open twice");
    XCTAssertFalse(writer->appendAudio(nullptr, 10).ok(), @"audio without an audio stream");
    auto frame = writer->makePixelBuffer();
    XCTAssertTrue(frame.ok());
    if (frame.ok()) {
        drawBurnIn(frame->get(), 1);
        XCTAssertTrue(writer->appendVideo(frame.value(), CMTimeMake(1, 30)).ok());
        XCTAssertFalse(writer->appendVideo(frame.value(), CMTimeMake(1, 30)).ok(), @"non-increasing pts");
    }
    writer->cancel();
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:ns(dir + "/e.mov")], @"cancel leaves no file");
    XCTAssertFalse(writer->finish().ok(), @"finish after cancel");
}

@end
