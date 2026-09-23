// What Photos hands over (feature request 9), imported through the facade and shown by the
// program monitor: an HEIC photo (a still), HEVC video, and an iPhone-style slow-motion clip
// (HEVC, portrait rotation, 30 fps around a 240 fps section: variable frame rate) whose pictures
// are the frames containing each layer's exact source time (playback::pictureTimeFor), at normal
// speed (the 240 fps section skips frames) and at 1/8 speed (it shows every 240 fps frame). Also
// the media folder bookmark the app stores with a project.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Playback/PlaybackTestSupport.h"
#include "TestMedia.h"

#include <string>

using namespace ve;
using namespace ve::test;

@interface PhotosMediaTests : XCTestCase
@end

@implementation PhotosMediaTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(scratchDirectory().c_str()) isDirectory:YES];
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (void)testHEICHEVCAndSlowMotionImportThroughTheFacade {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    NSArray<NSURL *> *urls = @[
        [self mediaURL:"still.heic"], [self mediaURL:"hevc_720p2997.mov"], [self mediaURL:"slowmo_hevc_portrait.mov"]
    ];
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *assets = @[];
    [engine importMediaAtURLs:urls
                   completion:^(NSArray<VEAssetInfo *> *imported, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       assets = imported;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertEqual(assets.count, 3u);
    VEAssetInfo *photo = nil, *hevc = nil, *slowmo = nil;
    for (VEAssetInfo *asset in assets) {
        if ([asset.name isEqualToString:@"still.heic"]) {
            photo = asset;
        } else if ([asset.name isEqualToString:@"hevc_720p2997.mov"]) {
            hevc = asset;
        } else if ([asset.name isEqualToString:@"slowmo_hevc_portrait.mov"]) {
            slowmo = asset;
        }
    }
    XCTAssertNotNil(photo);
    XCTAssertNotNil(hevc);
    XCTAssertNotNil(slowmo);

    // An HEIC photo imports as a still.
    XCTAssertEqual(photo.kind, VEAssetKindStill);
    XCTAssertTrue(photo.isStill);
    XCTAssertEqualObjects(photo.codecName, @"HEIC");
    XCTAssertEqual(photo.width, 1024);
    XCTAssertEqual(photo.height, 576);

    // HEVC video with its audio, decoded in hardware where the Mac has it.
    XCTAssertEqual(hevc.kind, VEAssetKindAudioVideo);
    XCTAssertEqualObjects(hevc.codecName, @"HEVC");
    XCTAssertEqual(hevc.width, 1280);
    XCTAssertEqualObjects(hevc.backendName, @"apple");

    // The slow-motion clip: portrait (rotation applied to the display size) and flagged VFR.
    XCTAssertEqual(slowmo.kind, VEAssetKindVideo);
    XCTAssertEqualObjects(slowmo.codecName, @"HEVC");
    XCTAssertEqual(slowmo.rotationDegrees, 90);
    XCTAssertEqual(slowmo.width, 360);
    XCTAssertEqual(slowmo.height, 640);
    XCTAssertTrue(slowmo.isVFR);
    XCTAssertEqual(CMTimeCompare(slowmo.duration, CMTimeMake(5, 2)), 0);

    // Each can be placed: the still with the default still duration, the video over its media.
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEEditResult *r = [engine insertAsset:photo.assetID atTime:kCMTimeZero videoTrack:v1 audioTrack:0
                                 sourceIn:kCMTimeInvalid sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertTrue([engine clipInfo:r.createdIDs[0].longLongValue].isStill);
    r = [engine insertAsset:slowmo.assetID atTime:CMTimeMake(5, 1) videoTrack:v1 audioTrack:0
                   sourceIn:kCMTimeInvalid sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:r.createdIDs[0].longLongValue].duration, CMTimeMake(75, 30)), 0);
}

/// Every sequence frame shows the source frame containing its exact source time, at normal speed
/// (through the 240 fps section each sequence frame moves 8 source frames) and at 1/8 speed (the
/// 240 fps section plays every frame, the way a slow-motion edit shows it).
- (void)testSlowMotionPicturesAreTheFramesContainingTheExactSourceTime {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId slowmo = h.importAsset("slowmo_hevc_portrait.mov");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const MediaAsset &asset = *h.project.findAsset(slowmo);
    XCTAssertTrue(asset.isVFR);
    XCTAssertEqual(asset.rotationDegrees, 90);
    // V1: the whole clip at speed 1 for 75 frames, then the 240 fps section (source 1 s...1.5 s) at
    // 1/8 speed for 120 frames.
    constexpr int64_t kNormal = 75;
    constexpr int64_t kSlow = 120;
    h.addClip(h.v1, slowmo, 0, kNormal, kCMTimeZero);
    const ClipId slowClip = h.addClip(h.v1, slowmo, kNormal, kSlow, CMTimeMake(1, 1));
    h.sequence().findClip(slowClip)->speed = Ratio{1, 8};
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    int distinctSlowFrames = 0;
    int previous = -1;
    for (int64_t frame = 0; frame < kNormal + kSlow; ++frame) {
        const CMTime source = frame < kNormal ? frames30(frame)
                                              : CMTimeAdd(CMTimeMake(1, 1), CMTimeMake(frame - kNormal, 240));
        h.controller->seek(frames30(frame));
        const PlaybackHarness::Sample s = h.presentExact();
        XCTAssertEqual(s.presented.frameIndex, frame);
        XCTAssertEqual(s.burnIns.size(), 1u, @"frame %lld", frame);
        if (s.burnIns.size() != 1) {
            continue;
        }
        const int shown = s.burnIns[0].value_or(-1);
        XCTAssertEqual(shown, slowmoFrameAt(source), @"sequence frame %lld (source %.4f s)", frame,
                       CMTimeGetSeconds(source));
        if (frame >= kNormal && shown != previous) {
            ++distinctSlowFrames;
        }
        previous = shown;
    }
    XCTAssertEqual(distinctSlowFrames, int(kSlow), @"at 1/8 speed every 240 fps frame is shown once");
}

- (void)testTheMediaFolderBookmarkIsSavedWithTheProject {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:nil];
    XCTAssertNil(engine.mediaFolderBookmark);
    XCTAssertFalse(engine.isDirty);
    NSURL *folder = [_scratch URLByAppendingPathComponent:@"Media" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:folder
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    NSData *bookmark = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    XCTAssertNotNil(bookmark);
    const uint64_t before = engine.changeCount;
    engine.mediaFolderBookmark = bookmark;
    XCTAssertTrue(engine.isDirty, @"an unsaved change of the project");
    XCTAssertGreaterThan(engine.changeCount, before);
    XCTAssertFalse(engine.canUndo, @"not an undo step");
    const uint64_t same = engine.changeCount;
    engine.mediaFolderBookmark = [bookmark copy];
    XCTAssertEqual(engine.changeCount, same, @"the same bookmark changes nothing");

    NSURL *url = [_scratch URLByAppendingPathComponent:@"project.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    XCTAssertFalse(engine.isDirty);
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:nil];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(reopened.mediaFolderBookmark, bookmark);
    XCTAssertFalse(reopened.isDirty);
    BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:reopened.mediaFolderBookmark
                                                options:0
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:nil];
    XCTAssertEqualObjects(resolved.URLByResolvingSymlinksInPath.path, folder.URLByResolvingSymlinksInPath.path);
    [reopened newProjectWithName:@"Next"];
    XCTAssertNil(reopened.mediaFolderBookmark, @"New forgets it");
}

@end
