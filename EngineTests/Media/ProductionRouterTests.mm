// The production router (Apple and FFmpeg backends both registered, as the app registers them)
// on real files: routing decisions, rotation through AssetImport, decodability checks and
// fallback between backends.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "BurnIn.h"
#include "FFmpegTestMedia.h"
#include "RouterTestSupport.h"
#include "TestMedia.h"
#include "VideoToolboxProbe.h"

using namespace ve;
using namespace ve::media;
using namespace ve::test;

@interface ProductionRouterTests : XCTestCase
@end

@implementation ProductionRouterTests {
    std::shared_ptr<BackendRouter> _router;
}

- (void)setUp {
    self.continueAfterFailure = YES;
    _router = std::make_shared<BackendRouter>();
    XCTAssertTrue(_router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(_router->registerBackend(ffmpeg::makeFFmpegBackend()).ok());
}

- (std::string)generated:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    return path;
}

/// A derived file, or "" after XCTSkip-worthy unavailability (the caller skips).
- (std::string)derived:(const std::string &)file {
    std::string error;
    const std::string path = derivedMediaPath(file, error);
    if (path.empty() && !(derivedNeedsTool(file) && ffmpegToolPath().empty())) {
        XCTFail(@"%s", error.c_str());
    }
    return path;
}

// MARK: - Rotation

- (void)testRotationIsProbedByBothBackendsAndCarriedIntoTheAsset {
    const std::string mp4 = [self generated:"rotated90_h264.mp4"];
    const std::string mkv = [self derived:"rotated90_h264.mkv"];
    if (mp4.empty() || mkv.empty()) {
        return;
    }
    struct Case {
        std::string path;
        std::shared_ptr<IMediaBackend> backend;
    };
    for (const Case &c : {Case{mp4, apple::makeAppleBackend()}, Case{mp4, ffmpeg::makeFFmpegBackend()},
                          Case{mkv, ffmpeg::makeFFmpegBackend()}}) {
        auto info = c.backend->makeProber()->probe(c.path);
        XCTAssertTrue(info.ok());
        if (!info.ok()) {
            continue;
        }
        const TrackInfo *v = info->firstTrack(TrackKind::Video);
        XCTAssertEqual(v->rotationDegrees, 90, @"%s via %s", c.path.c_str(), c.backend->name().c_str());
        XCTAssertEqual(v->width, 640, @"storage size");
        XCTAssertEqual(v->height, 360);
    }
    for (const std::string &path : {mp4, mkv}) {
        auto routed = _router->probe(path);
        XCTAssertTrue(routed.ok());
        if (!routed.ok()) {
            continue;
        }
        auto asset = makeMediaAsset(routed.value(), AssetId(7));
        XCTAssertTrue(asset.ok());
        if (!asset.ok()) {
            continue;
        }
        XCTAssertEqual(asset->rotationDegrees, 90, @"%s: MediaAsset::rotationDegrees", path.c_str());
        XCTAssertEqual(asset->width, 360, @"%s: displayed size", path.c_str());
        XCTAssertEqual(asset->height, 640);
    }
}

// MARK: - Decodability

/// MPEG-4 Part 2 Advanced Simple Profile with B-frames in MP4: AVFoundation loads the track and
/// reports it playable and decodable, but VideoToolbox refuses the bitstream (codecBadDataErr at
/// VTDecompressionSessionCreate, AVAssetReader fails on the first sample). The router must send
/// it to FFmpeg.
- (void)testStreamVideoToolboxRefusesIsRoutedToFFmpegAndDecodes {
    const std::string path = [self derived:"asp_mpeg4.mp4"];
    if (path.empty()) {
        XCTSkip(@"asp_mpeg4.mp4 needs ThirdParty/ffmpeg/tools/bin/ffmpeg (Scripts/build-ffmpeg.sh)");
    }
    auto routed = _router->probe(path);
    XCTAssertTrue(routed.ok());
    if (!routed.ok()) {
        return;
    }
    NSLog(@"asp_mpeg4.mp4 routing:\n%s", routed->reason.c_str());
    XCTAssertEqual(routed->backendFor(TrackKind::Video), "ffmpeg", @"%s", routed->reason.c_str());
    auto decoder = _router->makeVideoDecoder(routed.value(), -1, DecodeOptions{});
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }
    [self expectFrames:*decoder->decoder label:@"default policy"];

    // Software-only policy (the Apple decoder then opens its random-access path, which creates
    // the VideoToolbox session lazily): the stream must still decode.
    RoutingPolicy software;
    software.allowHardware = false;
    auto routedSW = _router->probe(path, software);
    XCTAssertTrue(routedSW.ok());
    if (!routedSW.ok()) {
        return;
    }
    XCTAssertEqual(routedSW->backendFor(TrackKind::Video), "ffmpeg", @"%s", routedSW->reason.c_str());
    auto decoderSW = _router->makeVideoDecoder(routedSW.value(), -1, DecodeOptions{});
    XCTAssertTrue(decoderSW.ok());
    if (decoderSW.ok()) {
        [self expectFrames:*decoderSW->decoder label:@"software policy"];
    }
}

/// Per-track routing on a real file: the ASP video goes to FFmpeg while its AAC audio stays on
/// the Apple fast path, each opened with its own backend's track numbering.
- (void)testTracksOfOneFileAreRoutedIndependently {
    const std::string path = [self derived:"asp_mpeg4.mp4"];
    if (path.empty()) {
        XCTSkip(@"asp_mpeg4.mp4 needs ThirdParty/ffmpeg/tools/bin/ffmpeg");
    }
    auto routed = _router->probe(path);
    XCTAssertTrue(routed.ok());
    if (!routed.ok()) {
        return;
    }
    XCTAssertEqual(routed->backendFor(TrackKind::Video), "ffmpeg", @"%s", routed->reason.c_str());
    XCTAssertEqual(routed->backendFor(TrackKind::Audio), "apple", @"%s", routed->reason.c_str());
    auto video = _router->makeVideoDecoder(routed.value(), -1, DecodeOptions{});
    auto audio = _router->makeAudioDecoder(routed.value(), -1, AudioOptions{});
    XCTAssertTrue(video.ok() && audio.ok());
    if (!video.ok() || !audio.ok()) {
        return;
    }
    XCTAssertEqual(video->backend, "ffmpeg");
    XCTAssertEqual(audio->backend, "apple");
    [self expectFrames:*video->decoder label:@"per-track video"];
    std::vector<float> pcm(48000 * 2);
    XCTAssertTrue(audio->decoder->seek(CMTimeMake(3, 2)).ok());
    auto n = audio->decoder->read(pcm.data(), 48000);
    XCTAssertTrue(n.ok() && n.value() == 48000);
    auto onset = findBeepOnset(pcm.data(), 48000, 2, 48000);
    XCTAssertTrue(onset.has_value());
    if (onset) {
        XCTAssertEqualWithAccuracy(*onset + 1.5, kMediaBeepStart, 0.25e-3);
    }
}

/// Matroska goes to FFmpeg, and the route's hardware flag is what VideoToolbox does for the
/// stream (FFmpeg's prober decodes the first frame through the videotoolbox hwaccel).
- (void)testMatroskaRoutesToFFmpegWithMeasuredHardware {
    std::string error;
    const std::string dir = mkvTestMediaDirectory(error);
    XCTAssertFalse(dir.empty(), @"%s", error.c_str());
    if (dir.empty()) {
        return;
    }
    for (const char *file : {"h264_1080p30", "hevc_720p2997"}) {
        auto routed = _router->probe(dir + "/" + file + ".mkv");
        XCTAssertTrue(routed.ok(), @"%s", file);
        if (!routed.ok()) {
            continue;
        }
        const std::string original = std::string(file) + (std::string(file) == "h264_1080p30" ? ".mp4" : ".mov");
        const std::optional<bool> vt = videoToolboxDecodesInHardware([self generated:original]);
        XCTAssertTrue(vt.has_value());
        XCTAssertEqual(routed->backendFor(TrackKind::Video), "ffmpeg", @"%s", routed->reason.c_str());
        XCTAssertEqual(routed->firstRoute(TrackKind::Video)->hardwareDecode, vt.value_or(false), @"%s", file);
        auto decoder = _router->makeVideoDecoder(routed.value(), -1, DecodeOptions{});
        XCTAssertTrue(decoder.ok());
        if (decoder.ok()) {
            auto f = decoder->decoder->next();
            XCTAssertTrue(f.ok() && f.value());
            if (f.ok() && f.value()) {
                XCTAssertEqual(f.value()->wasHardwareDecoded, vt.value_or(false), @"%s", file);
            }
        }
        NSLog(@"%s.mkv routing:\n%s", file, routed->reason.c_str());
    }
}

- (void)expectFrames:(IVideoDecoder &)decoder label:(NSString *)label {
    for (int i = 0; i < 20; ++i) {
        auto frame = decoder.next();
        XCTAssertTrue(frame.ok() && frame.value(), @"%@: frame %d: %s", label, i,
                      frame.ok() ? "end of stream" : frame.error().description().c_str());
        if (!frame.ok() || !frame.value()) {
            return;
        }
        XCTAssertEqual(readBurnIn(frame.value()->image.get()), std::optional<int>(i), @"%@", label);
    }
}

@end
