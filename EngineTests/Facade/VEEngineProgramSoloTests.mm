// The facade's program preview solo (-[VEEngine setProgramPreviewSoloClip:identityMotion:], the Ken
// Burns editor's picture): it is refused for a clip that is not a video clip of the sequence, an
// export made while it is set renders the program (the clip as placed, not the solo picture), and
// it ends when the clip is removed and on New.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../Media/TestMedia.h"

#include <string>

namespace {

struct Pixel {
    int r = -1, g = -1, b = -1;
};

/// One pixel of a 32BGRA buffer.
Pixel pixelAt(CVPixelBufferRef buffer, size_t x, size_t y) {
    Pixel p;
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) {
        return p;
    }
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const uint8_t *px = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4;
    p.b = px[0];
    p.g = px[1];
    p.r = px[2];
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return p;
}

} // namespace

@interface VEEngineProgramSoloTests : XCTestCase
@end

@implementation VEEngineProgramSoloTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (void)testTheSoloPreviewIsRefusedForNonVideoClipsStaysOutOfTheExportAndEndsWithTheClip {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    std::string mediaError;
    const std::string mediaPath = ve::test::testMediaPath("h264_1080p30.mp4", mediaError);
    XCTAssertTrue(mediaError.empty(), @"%s", mediaError.c_str());
    XCTestExpectation *imported = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ [NSURL fileURLWithPath:@(mediaPath.c_str())] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [imported fulfill];
                   }];
    [self waitForExpectations:@[ imported ] timeout:60];
    XCTAssertNotNil(asset);
    if (asset == nil) {
        return;
    }
    // A 2 s clip placed at half size in the middle of the frame, its sound on A1.
    VEEditResult *placed = [engine overwriteAsset:asset.assetID
                                           atTime:kCMTimeZero
                                       videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                       audioTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                         sourceIn:kCMTimeZero
                                        sourceOut:CMTimeMake(2, 1)];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    VEClipID video = 0;
    VEClipID audio = 0;
    for (NSNumber *created in placed.createdIDs) {
        VEClipInfo *info = [engine clipInfo:created.longLongValue];
        if (info.trackKind == VETrackKindVideo) {
            video = info.clipID;
        } else {
            audio = info.clipID;
        }
    }
    XCTAssertNotEqual(video, 0);
    XCTAssertNotEqual(audio, 0);
    const VEVideoParams half = {0, 0, 0.5, 0, 1};
    XCTAssertTrue([engine setVideoParams:half forClip:video].ok);

    // Only a video clip of the sequence.
    XCTAssertFalse([engine setProgramPreviewSoloClip:audio identityMotion:YES]);
    XCTAssertEqual(engine.programPreviewSoloClipID, 0);
    XCTAssertFalse([engine setProgramPreviewSoloClip:987654 identityMotion:YES]);
    XCTAssertTrue([engine setProgramPreviewSoloClip:video identityMotion:YES]);
    XCTAssertEqual(engine.programPreviewSoloClipID, video);
    XCTAssertTrue(engine.programPreviewSoloIdentityMotion);

    // An export meanwhile renders the program: the clip at half size (the frame's corners black),
    // where the solo picture (identity) fills the frame.
    VEExportSettings *d = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    VEExportSettings *settings = [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                                                container:d.container
                                                               resolution:VEExportResolution720p
                                                              customWidth:d.customWidth
                                                              rateControl:d.rateControl
                                                                  quality:d.quality
                                                             videoBitRate:d.videoBitRate
                                                               audioCodec:d.audioCodec
                                                             audioBitRate:d.audioBitRate];
    NSURL *url = [_scratch URLByAppendingPathComponent:@"solo.mp4"];
    __block BOOL completed = NO;
    __block NSError *failure = nil;
    NSError *error = nil;
    VEExportHandle *handle = [engine beginExportWithSettings:settings
                                                   outputURL:url
                                                    progress:nil
                                                  completion:^(VEExportSummary *, NSError *e) {
                                                      failure = e;
                                                      completed = YES;
                                                  }
                                                       error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertTrue([self spinUntil:^BOOL { return completed; } timeout:120]);
    XCTAssertNil(failure, @"%@", failure);
    XCTAssertEqual(engine.programPreviewSoloClipID, video, @"the export leaves the monitor's override alone");

    ve::media::apple::AppleBackend apple;
    const std::string path = url.path.fileSystemRepresentation;
    auto probed = apple.makeProber()->probe(path);
    XCTAssertTrue(probed.ok());
    if (!probed.ok()) {
        return;
    }
    const ve::media::TrackInfo *track = probed->firstTrack(ve::media::TrackKind::Video);
    XCTAssertTrue(track != nullptr);
    if (track == nullptr) {
        return;
    }
    ve::media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = apple.makeVideoDecoder();
    XCTAssertTrue(decoder->open(path, track->index, bgra).ok());
    XCTAssertTrue(decoder->seek(CMTimeMake(10, 30)).ok());
    auto frame = decoder->next();
    XCTAssertTrue(frame.ok() && frame.value());
    if (frame.ok() && frame.value()) {
        CVPixelBufferRef image = frame.value()->image.get();
        XCTAssertEqual(CVPixelBufferGetWidth(image), 1280u);
        const Pixel corner = pixelAt(image, 20, 20);
        const Pixel centre = pixelAt(image, 640, 400);
        NSLog(@"SOLO export: corner %d %d %d, centre %d %d %d", corner.r, corner.g, corner.b, centre.r, centre.g,
              centre.b);
        XCTAssertTrue(corner.r >= 0 && corner.r < 12 && corner.g < 12 && corner.b < 12,
                      @"the program's black around the half-size clip");
        XCTAssertGreaterThan(centre.r + centre.g + centre.b, 120, @"the clip's picture in the middle");
    }

    // The clip removed: the override ends. On New as well.
    XCTAssertTrue([engine removeClips:@[ @(video) ]].ok);
    XCTAssertEqual(engine.programPreviewSoloClipID, 0);
    XCTAssertFalse(engine.programPreviewSoloIdentityMotion);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.programPreviewSoloClipID, 0, @"undo brings the clip back, not the override");
    XCTAssertTrue([engine setProgramPreviewSoloClip:video identityMotion:NO]);
    XCTAssertFalse(engine.programPreviewSoloIdentityMotion);
    [engine clearProgramPreviewSolo];
    XCTAssertEqual(engine.programPreviewSoloClipID, 0);
    XCTAssertTrue([engine setProgramPreviewSoloClip:video identityMotion:YES]);
    [engine newProjectWithName:@"Next"];
    XCTAssertEqual(engine.programPreviewSoloClipID, 0);
}

@end
