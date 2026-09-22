// AssetImport: RoutedMediaInfo -> MediaAsset mapping, with synthetic infos and one real file.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/BackendRouter.h"
#include "TestMedia.h"

using namespace ve;
using namespace ve::media;

namespace {

TrackInfo videoTrack(int index, int w, int h, CMTime fd, int rotation = 0) {
    TrackInfo t;
    t.index = index;
    t.kind = TrackKind::Video;
    t.codec = {fourcc::H264, "H.264"};
    t.width = w;
    t.height = h;
    t.rotationDegrees = rotation;
    t.frameDuration = fd;
    t.nominalFps = 1.0 / CMTimeGetSeconds(fd);
    t.duration = CMTimeMake(600, 60);
    return t;
}

TrackInfo audioTrack(int index, double rate, int channels) {
    TrackInfo t;
    t.index = index;
    t.kind = TrackKind::Audio;
    t.codec = {fourcc::AAC, "AAC"};
    t.sampleRate = rate;
    t.channels = channels;
    t.duration = CMTimeMake(10, 1);
    return t;
}

RoutedMediaInfo routed(std::vector<TrackInfo> tracks, const std::string &backend = "apple", bool hw = true,
                       CMTime duration = CMTimeMake(10, 1)) {
    RoutedMediaInfo r;
    r.info.path = "/Volumes/Media/Day 1/clip.mov";
    r.info.container = "mov";
    r.info.backend = backend;
    r.info.duration = duration;
    r.info.tracks = std::move(tracks);
    for (const TrackInfo &t : r.info.tracks) {
        TrackRoute route;
        route.trackIndex = t.index;
        route.kind = t.kind;
        route.codec = t.codec.fourCC;
        route.backend = backend;
        route.backendTrackIndex = t.index;
        route.hardwareDecode = hw && t.kind == TrackKind::Video;
        r.routes.push_back(route);
    }
    return r;
}

} // namespace

@interface AssetImportTests : XCTestCase
@end

@implementation AssetImportTests

- (void)testAudioVideo {
    auto r = routed({videoTrack(0, 1920, 1080, CMTimeMake(1001, 30000)), audioTrack(1, 48000, 2)});
    auto asset = makeMediaAsset(r, AssetId(7));
    XCTAssertTrue(asset.ok());
    XCTAssertEqual(asset->id, AssetId(7));
    XCTAssertEqual(asset->name, "clip.mov");
    XCTAssertEqual(asset->url, "/Volumes/Media/Day 1/clip.mov");
    XCTAssertEqual(asset->kind, AssetKind::AudioVideo);
    XCTAssertTrue(identical(asset->duration, CMTimeMake(10, 1)));
    XCTAssertEqual(asset->width, 1920);
    XCTAssertEqual(asset->height, 1080);
    XCTAssertTrue(identical(asset->frameDuration, CMTimeMake(1001, 30000)), @"exact rational is kept");
    XCTAssertFalse(asset->isVFR);
    XCTAssertEqual(asset->audioSampleRate, 48000);
    XCTAssertEqual(asset->audioChannels, 2);
    XCTAssertEqual(asset->backendHint, "apple");
    XCTAssertTrue(asset->hardwareDecode);
    XCTAssertEqual(makeMediaAsset(r, AssetId(7), "Interview A")->name, "Interview A");
}

- (void)testRotationSwapsTheReportedSize {
    for (int rotation : {90, 270, -90}) {
        auto asset = makeMediaAsset(routed({videoTrack(0, 1920, 1080, CMTimeMake(1, 30), rotation)}), AssetId(1));
        XCTAssertEqual(asset->width, 1080, @"%d", rotation);
        XCTAssertEqual(asset->height, 1920, @"%d", rotation);
        XCTAssertEqual(asset->kind, AssetKind::Video);
    }
    for (int rotation : {0, 180}) {
        auto asset = makeMediaAsset(routed({videoTrack(0, 1920, 1080, CMTimeMake(1, 30), rotation)}), AssetId(1));
        XCTAssertEqual(asset->width, 1920);
        XCTAssertEqual(asset->height, 1080);
    }
}

- (void)testStill {
    TrackInfo still;
    still.index = 0;
    still.kind = TrackKind::Still;
    still.codec = {fourcc::PNG, "PNG"};
    still.width = 1280;
    still.height = 720;
    still.duration = kCMTimeIndefinite;
    auto r = routed({still}, "apple", true, kCMTimeIndefinite);
    auto asset = makeMediaAsset(r, AssetId(3));
    XCTAssertTrue(asset.ok());
    XCTAssertEqual(asset->kind, AssetKind::Still);
    XCTAssertFalse(CMTIME_IS_VALID(asset->duration));
    XCTAssertFalse(CMTIME_IS_VALID(asset->frameDuration));
    XCTAssertEqual(asset->width, 1280);
    XCTAssertEqual(asset->height, 720);
    XCTAssertFalse(asset->hardwareDecode);
    XCTAssertEqual(asset->audioSampleRate, 0);
}

- (void)testAudioOnlyVFRAndRounding {
    auto audio = makeMediaAsset(routed({audioTrack(0, 44100.0000001, 6)}, "ffmpeg", false), AssetId(2));
    XCTAssertTrue(audio.ok());
    XCTAssertEqual(audio->kind, AssetKind::Audio);
    XCTAssertEqual(audio->audioSampleRate, 44100);
    XCTAssertEqual(audio->audioChannels, 6);
    XCTAssertEqual(audio->width, 0);
    XCTAssertEqual(audio->backendHint, "ffmpeg");
    XCTAssertFalse(audio->hardwareDecode);

    TrackInfo vfr = videoTrack(0, 1280, 720, CMTimeMake(1, 60));
    vfr.isVFR = true;
    auto v = makeMediaAsset(routed({vfr}), AssetId(4));
    XCTAssertTrue(v->isVFR);
    XCTAssertTrue(identical(v->frameDuration, CMTimeMake(1, 60)));
}

- (void)testPerTrackRoutingIsReflected {
    // Video on FFmpeg (software), audio on Apple: the hint follows the picture.
    auto r = routed({videoTrack(0, 640, 480, CMTimeMake(1, 25)), audioTrack(1, 48000, 2)});
    r.routes[0].backend = "ffmpeg";
    r.routes[0].hardwareDecode = false;
    auto asset = makeMediaAsset(r, AssetId(5));
    XCTAssertEqual(asset->backendHint, "ffmpeg");
    XCTAssertFalse(asset->hardwareDecode);
    XCTAssertEqual(asset->kind, AssetKind::AudioVideo);

    // An undecodable video track is ignored: the asset is audio.
    r.routes[0].backend.clear();
    auto audioOnly = makeMediaAsset(r, AssetId(5));
    XCTAssertEqual(audioOnly->kind, AssetKind::Audio);
    XCTAssertEqual(audioOnly->width, 0);
    XCTAssertEqual(audioOnly->backendHint, "apple");

    r.routes[1].backend.clear();
    XCTAssertEqual(makeMediaAsset(r, AssetId(5)).error().code, MediaErrorCode::NoSuchTrack);
}

- (void)testDurationFallbackAndErrors {
    auto r = routed({videoTrack(0, 640, 480, CMTimeMake(1, 25)), audioTrack(1, 48000, 2)}, "apple", true,
                    kCMTimeInvalid);
    r.info.tracks[1].startTime = CMTimeMake(1, 2);
    auto asset = makeMediaAsset(r, AssetId(9));
    XCTAssertTrue(asset.ok());
    XCTAssertEqual(CMTimeCompare(asset->duration, CMTimeMake(21, 2)), 0, @"longest track end");

    XCTAssertEqual(makeMediaAsset(r, AssetId()).error().code, MediaErrorCode::InvalidArgument);
    auto noFd = routed({videoTrack(0, 640, 480, kCMTimeInvalid)});
    XCTAssertEqual(makeMediaAsset(noFd, AssetId(1)).error().code, MediaErrorCode::InvalidArgument);
    auto noSize = routed({videoTrack(0, 0, 0, CMTimeMake(1, 25))});
    XCTAssertEqual(makeMediaAsset(noSize, AssetId(1)).error().code, MediaErrorCode::InvalidArgument);
}

- (void)testRealFileThroughTheRouter {
    std::string error;
    const std::string path = ve::test::testMediaPath("hevc_720p2997.mov", error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    if (path.empty()) {
        return;
    }
    auto routedInfo = BackendRouter::makeDefault()->probe(path);
    XCTAssertTrue(routedInfo.ok());
    auto asset = makeMediaAsset(routedInfo.value(), AssetId(11));
    XCTAssertTrue(asset.ok());
    XCTAssertEqual(asset->kind, AssetKind::AudioVideo);
    XCTAssertEqual(asset->width, 1280);
    XCTAssertEqual(asset->height, 720);
    XCTAssertEqual(CMTimeCompare(asset->frameDuration, CMTimeMake(1001, 30000)), 0);
    XCTAssertEqual(asset->audioSampleRate, 48000);
    XCTAssertEqual(asset->backendHint, "apple");
    XCTAssertEqual(asset->name, "hevc_720p2997.mov");
}

@end
