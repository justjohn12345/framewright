// Runs the backend conformance suite against AppleBackend, plus checks specific to its
// two-path video decoder.

#import "MediaBackendConformanceTests.h"

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/Apple/AppleVideoDecoder.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "BurnIn.h"

using namespace ve::media;
using namespace ve::test;

@interface AppleBackendConformanceTests : MediaBackendConformanceTests
@end

@implementation AppleBackendConformanceTests

+ (std::shared_ptr<IMediaBackend>)backend {
    return apple::makeAppleBackend();
}

- (void)testBackendIdentity {
    XCTAssertEqual(self.backendUnderTest->name(), "apple");
    XCTAssertEqual(self.backendUnderTest->makeVideoEncoder(), nullptr);
    XCTAssertEqual(self.backendUnderTest->makeAudioEncoder(), nullptr);
    XCTAssertEqual(self.backendUnderTest->makeMuxer(), nullptr);
}

- (void)testCanHandleItsOwnMediaAndRejectsForeignCodecs {
    auto prober = self.backendUnderTest->makeProber();
    for (const TestClip &clip : testClips()) {
        const std::string path = [self pathForFile:clip.file];
        auto info = prober->probe(path);
        XCTAssertTrue(info.ok(), @"%s", clip.file.c_str());
        if (info.ok()) {
            XCTAssertTrue(self.backendUnderTest->canHandle(info.value()), @"%s", clip.file.c_str());
        }
    }
    MediaInfo mkv;
    mkv.container = "mkv";
    TrackInfo h264;
    h264.kind = TrackKind::Video;
    h264.codec = {fourcc::H264, "H.264"};
    mkv.tracks = {h264};
    XCTAssertFalse(self.backendUnderTest->canHandle(mkv), @"Matroska belongs to the FFmpeg backend");

    MediaInfo vp9;
    vp9.container = "mp4";
    TrackInfo t;
    t.kind = TrackKind::Video;
    t.codec = {fourcc::VP9, "VP9"};
    vp9.tracks = {t};
    XCTAssertEqual(self.backendUnderTest->canHandle(vp9), HardwareCaps::get().vp9.hardwareDecode);

    MediaInfo opusInMP4;
    opusInMP4.container = "mp4";
    TrackInfo vorbis;
    vorbis.kind = TrackKind::Audio;
    vorbis.codec = {fourcc::make("vorb"), "Vorbis"};
    opusInMP4.tracks = {vorbis};
    XCTAssertFalse(self.backendUnderTest->canHandle(opusInMP4));
}

- (void)testRandomAccessPathIsUsedForBackwardSeeksAndHandsBackToTheReader {
    const TestClip &clip = testClip("h264_1080p30.mp4"); // 30-frame GOPs with B-frames.
    const std::string path = [self pathForFile:clip.file];
    if (path.empty()) {
        return;
    }
    apple::AppleVideoDecoder decoder(10.0);
    XCTAssertTrue(decoder.open(path, -1, {}).ok());
    XCTAssertTrue(decoder.supportsRandomAccess());
    XCTAssertFalse(decoder.isOnRandomAccessPath(), @"open() starts on the sequential reader");
    for (int i = 0; i < 100; ++i) {
        (void)decoder.next();
    }
    // Close ahead: stays on the reader.
    XCTAssertTrue(decoder.seek(CMTimeMake(110, 30)).ok());
    auto r = decoder.next();
    XCTAssertTrue(r.ok() && r.value() && readBurnIn(r.value()->image.get()) == 110);
    XCTAssertFalse(decoder.isOnRandomAccessPath());

    // Backwards: random access (cursor + VTDecompressionSession).
    XCTAssertTrue(decoder.seek(CMTimeMake(45, 30)).ok());
    XCTAssertTrue(decoder.isOnRandomAccessPath());
    bool handedOver = false;
    for (int i = 45; i < 100; ++i) {
        auto f = decoder.next();
        XCTAssertTrue(f.ok() && f.value(), @"frame %d", i);
        if (!f.ok() || !f.value()) {
            break;
        }
        XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(i));
        XCTAssertEqual(CMTimeCompare(f.value()->pts, CMTimeMake(i, 30)), 0, @"frame %d pts %lld/%d", i,
                       f.value()->pts.value, f.value()->pts.timescale);
        handedOver = handedOver || !decoder.isOnRandomAccessPath();
    }
    XCTAssertTrue(handedOver, @"random access should hand back to AVAssetReader at the next GOP");

    // Far forward (> 2 s): random access again.
    XCTAssertTrue(decoder.seek(CMTimeMake(250, 30)).ok());
    XCTAssertTrue(decoder.isOnRandomAccessPath());
    auto far = decoder.next();
    XCTAssertTrue(far.ok() && far.value() && readBurnIn(far.value()->image.get()) == 250);
}

- (void)testSoftwareDecodeWhenHardwareIsDisallowed {
    for (const char *file : {"h264_1080p30.mp4", "hevc_720p2997.mov", "prores_540p25.mov"}) {
        const TestClip &clip = testClip(file);
        const std::string path = [self pathForFile:clip.file];
        if (path.empty()) {
            return;
        }
        auto decoder = self.backendUnderTest->makeVideoDecoder();
        DecodeOptions options;
        options.allowHardware = false;
        Status s = decoder->open(path, -1, options);
        XCTAssertTrue(s.ok(), @"%s: %s", file, s.ok() ? "" : s.error().description().c_str());
        if (!s.ok()) {
            continue;
        }
        for (int i = 0; i < 40; ++i) {
            auto f = decoder->next();
            XCTAssertTrue(f.ok() && f.value(), @"%s frame %d", file, i);
            if (!f.ok() || !f.value()) {
                break;
            }
            XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(i), @"%s", file);
            XCTAssertFalse(f.value()->wasHardwareDecoded, @"%s", file);
        }
        XCTAssertFalse(decoder->usedHardware(), @"%s", file);
    }
}

@end
