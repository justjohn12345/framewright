// Regression tests for the facade findings of the 2026-09-23 review (docs/reviews): asset ids
// that another project reused must never show the previous project's media (E1), an edit made
// while a gesture's coalescing group is open must not join the group (E2), only one monitor
// plays at a time (E3), and moving both clips of a transition to another track keeps the
// transition (E4).

#import <Metal/Metal.h>
#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"

#include <string>

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

/// The burn-in frame index `view` shows (-1: none readable, e.g. black).
int shownIndex(VEPreviewView *view) {
    CGImageRef image = [view snapshot];
    if (image == NULL) {
        return -1;
    }
    const size_t w = CGImageGetWidth(image);
    const size_t h = CGImageGetHeight(image);
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nullptr, &buffer) !=
        kCVReturnSuccess) {
        return -1;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), w, h, 8,
                                             CVPixelBufferGetBytesPerRow(buffer), CGImageGetColorSpace(image),
                                             CGBitmapInfo(kCGImageAlphaNoneSkipFirst) |
                                                 CGBitmapInfo(kCGBitmapByteOrder32Little));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(w), CGFloat(h)), image);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    const int index = ve::test::readBurnIn(buffer).value_or(-1);
    CVPixelBufferRelease(buffer);
    return index;
}

} // namespace

@interface VEEngineReviewRegressionTests : XCTestCase
@end

@implementation VEEngineReviewRegressionTests {
    NSURL *_cacheDir;
    NSURL *_projectDir;
    id<MTLDevice> _device;
}

- (void)setUp {
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
    _projectDir = [scratch URLByAppendingPathComponent:[NSString stringWithFormat:@"Projects-%@", NSUUID.UUID.UUIDString]
                                           isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_projectDir
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    _device = MTLCreateSystemDefaultDevice();
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_projectDir error:nil];
}

- (VEEngine *)makeEngine {
    return [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
}

- (VEPreviewView *)makeView {
    return _device ? [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270) device:_device error:nil] : nil;
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (VEAssetInfo *)importOne:(const char *)file into:(VEEngine *)engine {
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ [self mediaURL:file] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertNotNil(asset);
    return asset;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (void)renderAndWait:(VEPreviewView *)view {
    XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
    [view renderOnceWithCompletion:^(NSError *) {
        [rendered fulfill];
    }];
    [self waitForExpectations:@[ rendered ] timeout:5];
}

/// Renders until `done` holds (checked after each render) or `timeout`; returns `done`.
- (BOOL)render:(VEPreviewView *)view until:(BOOL (^)(void))done timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        [self renderAndWait:view];
        if (done()) {
            return YES;
        }
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while (deadline.timeIntervalSinceNow > 0);
    return NO;
}

/// Waits until the program monitor's decode work is done (no stream busy, no scrub request
/// pending), then renders once more.
- (void)settleProgram:(VEEngine *)engine view:(VEPreviewView *)view {
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.playbackStats.decodeQueueDepth == 0;
    }
                          timeout:10]);
    [self renderAndWait:view];
}

- (NSURL *)saveProjectOf:(VEEngine *)engine named:(NSString *)name {
    NSURL *url = [_projectDir URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    return url;
}

// MARK: - E1: asset ids reused by another project

// Project B names asset 1 with a file that is missing. Both monitors had decoded project A's
// asset 1 (another file) just before: neither may show it after B opens.
- (void)testMissingFileUnderAReusedIdShowsNothingInEitherMonitor {
    VEPreviewView *source = [self makeView];
    VEPreviewView *program = [self makeView];
    if (source == nil || program == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    XCTAssertTrue([engine overwriteAsset:asset.assetID
                                  atTime:kCMTimeZero
                              videoTrack:v1
                              audioTrack:0
                                sourceIn:kCMTimeZero
                               sourceOut:seconds(2)]
                      .ok);
    // Project B: the same project with asset 1's file missing.
    NSString *json = [engine.projectJSON stringByReplacingOccurrencesOfString:asset.path
                                                                   withString:@"/nonexistent/videdit/missing.mp4"];
    XCTAssertNotEqualObjects(json, engine.projectJSON);
    NSURL *projectB = [_projectDir URLByAppendingPathComponent:@"missing.videdit"];
    XCTAssertTrue([json writeToURL:projectB atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    // Both monitors decode project A's asset 1.
    [engine attachSourceView:source];
    [engine attachProgramView:program];
    [engine sourceMonitorShowAsset:asset.assetID atTime:CMTimeMake(30, 30)];
    [engine seekToTime:CMTimeMake(30, 30)];
    XCTAssertTrue([self render:source
                         until:^BOOL {
                             return shownIndex(source) == 30;
                         }
                       timeout:10]);
    XCTAssertTrue([self render:program
                         until:^BOOL {
                             return shownIndex(program) == 30;
                         }
                       timeout:10]);

    NSError *error = nil;
    XCTAssertTrue([engine openProjectAtURL:projectB error:&error], @"%@", error);
    XCTAssertEqualObjects(engine.missingAssetIDs, @[ @(asset.assetID) ]);

    // The source monitor reports the missing file instead of showing A's picture.
    [engine sourceMonitorShowAsset:asset.assetID atTime:CMTimeMake(30, 30)];
    const BOOL failed = [self render:source
                               until:^BOOL {
                                   return source.lastError != nil || shownIndex(source) >= 0;
                               }
                             timeout:10];
    XCTAssertTrue(failed, @"the source monitor settles");
    XCTAssertEqual(shownIndex(source), -1, @"the source monitor shows the previous project's file for a missing one");
    XCTAssertNotNil(source.lastError, @"the missing file is reported");

    // The program monitor shows nothing for the missing clip either.
    [engine seekToTime:CMTimeMake(30, 30)];
    [self settleProgram:engine view:program];
    XCTAssertEqual(shownIndex(program), -1, @"the program monitor shows the previous project's file for a missing one");

    [engine attachSourceView:nil];
    [engine attachProgramView:nil];
}

// Project B's asset 1 is another file (25 fps ProRes: frame 25 at 1 s) than project A's asset 1
// (30 fps H.264: frame 30 at 1 s). After opening B, both monitors show B's file.
- (void)testReusedIdNamingAnotherFileShowsTheNewFile {
    VEPreviewView *source = [self makeView];
    VEPreviewView *program = [self makeView];
    if (source == nil || program == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEAssetInfo *prores = [self importOne:"prores_540p25.mov" into:engine];
    XCTAssertTrue([engine overwriteAsset:prores.assetID
                                  atTime:kCMTimeZero
                              videoTrack:v1
                              audioTrack:0
                                sourceIn:kCMTimeZero
                               sourceOut:seconds(2)]
                      .ok);
    NSURL *projectB = [self saveProjectOf:engine named:@"prores.videdit"];

    [engine newProjectWithName:@"A"];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    XCTAssertEqual(h264.assetID, prores.assetID, @"ids restart in every project");
    XCTAssertTrue([engine overwriteAsset:h264.assetID
                                  atTime:kCMTimeZero
                              videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                              audioTrack:0
                                sourceIn:kCMTimeZero
                               sourceOut:seconds(2)]
                      .ok);
    [engine attachSourceView:source];
    [engine attachProgramView:program];
    [engine sourceMonitorShowAsset:h264.assetID atTime:seconds(1)];
    [engine seekToTime:seconds(1)];
    XCTAssertTrue([self render:source
                         until:^BOOL {
                             return shownIndex(source) == 30;
                         }
                       timeout:10]);
    XCTAssertTrue([self render:program
                         until:^BOOL {
                             return shownIndex(program) == 30;
                         }
                       timeout:10]);

    NSError *error = nil;
    XCTAssertTrue([engine openProjectAtURL:projectB error:&error], @"%@", error);
    XCTAssertEqual(engine.missingAssetIDs.count, 0u);
    [engine sourceMonitorShowAsset:prores.assetID atTime:seconds(1)];
    XCTAssertTrue([self render:source
                         until:^BOOL {
                             return shownIndex(source) >= 0;
                         }
                       timeout:10]);
    XCTAssertEqual(shownIndex(source), 25, @"the source monitor shows project B's file");
    [engine seekToTime:seconds(1)];
    [self settleProgram:engine view:program];
    XCTAssertTrue([self render:program
                         until:^BOOL {
                             return shownIndex(program) >= 0;
                         }
                       timeout:10]);
    XCTAssertEqual(shownIndex(program), 25, @"the program monitor shows project B's file");

    [engine attachSourceView:nil];
    [engine attachProgramView:nil];
}

// MARK: - E2: edits while a gesture's coalescing group is open

// Cmd+K from the menu during a drag: the drag is committed as its own undo step, the split
// applies, and the drag's later steps are refused (its group has ended).
- (void)testAnUnrelatedEditDuringADragCommitsTheDragAndApplies {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEEditResult *placed = [engine overwriteAsset:asset.assetID
                                           atTime:kCMTimeZero
                                       videoTrack:v1
                                       audioTrack:0
                                         sourceIn:kCMTimeZero
                                        sourceOut:seconds(2)];
    NSNumber *clip = placed.createdIDs.firstObject;
    NSString *beforeDrag = engine.projectJSON;

    [engine beginCoalescingWithKey:@"timeline.move"];
    VEEditResult *step = [engine performInCoalescingGroup:@"timeline.move"
                                                     edit:^VEEditResult * {
                                                         return [engine moveClips:@[ clip ]
                                                                           byTime:seconds(1)
                                                                      trackOffset:0];
                                                     }];
    XCTAssertTrue(step.ok, @"%@", step.message);
    VEEditResult *split = [engine splitClips:@[] atTime:seconds(2.5)];
    XCTAssertTrue(split.ok, @"a split during a drag is applied: %@", split.message);
    XCTAssertEqual([engine clipsOnTrack:v1].count, 2u);
    XCTAssertFalse(engine.isCoalescing, @"the unrelated edit ended the drag's group");
    VEEditResult *late = [engine performInCoalescingGroup:@"timeline.move"
                                                     edit:^VEEditResult * {
                                                         return [engine moveClips:@[ clip ]
                                                                           byTime:seconds(2)
                                                                      trackOffset:0];
                                                     }];
    XCTAssertFalse(late.ok, @"the drag's group has ended");
    XCTAssertEqual(late.errorCode, VEEditErrorBusy);
    [engine endCoalescing];
    XCTAssertEqual([engine clipsOnTrack:v1].count, 2u, @"the split survived the end of the drag");

    XCTAssertEqualObjects(engine.undoActionName, @"Split Clip");
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.undoActionName, @"Move Clip");
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:clip.longLongValue].timelineStart), 1, 1e-9);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.projectJSON, beforeDrag);
}

// Delete during an inspector slider drag: the slider's change is kept (committed), the delete
// applies, and the slider's later steps cannot bring the deleted clip back.
- (void)testDeleteDuringASliderDragKeepsTheSliderChangeAndTheDeletion {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    NSNumber *clip = [engine overwriteAsset:asset.assetID
                                     atTime:kCMTimeZero
                                 videoTrack:v1
                                 audioTrack:0
                                   sourceIn:kCMTimeZero
                                  sourceOut:seconds(2)]
                         .createdIDs.firstObject;
    NSNumber *other = [engine overwriteAsset:asset.assetID
                                      atTime:seconds(5)
                                  videoTrack:v1
                                  audioTrack:0
                                    sourceIn:kCMTimeZero
                                   sourceOut:seconds(1)]
                          .createdIDs.firstObject;

    NSString *key = [NSString stringWithFormat:@"inspector.opacity.%@", clip];
    [engine beginCoalescingWithKey:key];
    VEVideoParams params = VEVideoParamsIdentity();
    params.opacity = 0.5;
    XCTAssertTrue([engine performInCoalescingGroup:key
                                              edit:^VEEditResult * {
                                                  return [engine setVideoParams:params forClip:clip.longLongValue];
                                              }]
                      .ok);
    VEEditResult *removed = [engine removeClips:@[ other ]];
    XCTAssertTrue(removed.ok, @"%@", removed.message);
    XCTAssertNil([engine clipInfo:other.longLongValue]);
    XCTAssertEqualWithAccuracy([engine clipInfo:clip.longLongValue].videoParams.opacity, 0.5, 1e-9,
                               @"the slider's change is kept");
    params.opacity = 0.4;
    VEEditResult *late = [engine performInCoalescingGroup:key
                                                     edit:^VEEditResult * {
                                                         return [engine setVideoParams:params
                                                                               forClip:clip.longLongValue];
                                                     }];
    XCTAssertFalse(late.ok);
    XCTAssertEqual(late.errorCode, VEEditErrorBusy);
    [engine endCoalescing];
    XCTAssertNil([engine clipInfo:other.longLongValue], @"the deleted clip is not resurrected");
    XCTAssertEqualWithAccuracy([engine clipInfo:clip.longLongValue].videoParams.opacity, 0.5, 1e-9);

    XCTAssertTrue([engine undo]); // the deletion
    XCTAssertNotNil([engine clipInfo:other.longLongValue]);
    XCTAssertEqualWithAccuracy([engine clipInfo:clip.longLongValue].videoParams.opacity, 0.5, 1e-9);
    XCTAssertTrue([engine undo]); // the slider drag
    XCTAssertEqualWithAccuracy([engine clipInfo:clip.longLongValue].videoParams.opacity, 1.0, 1e-9);
}

// MARK: - E3: one monitor plays at a time

- (void)testStartingOneMonitorPausesTheOther {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    const VETrackID a1 = engine.sequence.audioTrackIDs[0].longLongValue;
    XCTAssertTrue([engine overwriteAsset:asset.assetID
                                  atTime:kCMTimeZero
                              videoTrack:v1
                              audioTrack:a1
                                sourceIn:kCMTimeZero
                               sourceOut:seconds(8)]
                      .ok);
    auto running = [](VEPlaybackState state) {
        return state == VEPlaybackStatePlaying || state == VEPlaybackStatePrerolling;
    };

    [engine play];
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.playbackState == VEPlaybackStatePlaying;
    }
                          timeout:10]);
    [engine sourceMonitorShowAsset:asset.assetID atTime:kCMTimeZero];
    [engine sourceMonitorTogglePlay];
    XCTAssertTrue(running(engine.sourceMonitorPlaybackState));
    XCTAssertFalse(running(engine.playbackState), @"starting the source monitor pauses the program");
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.sourceMonitorPlaybackState == VEPlaybackStatePlaying;
    }
                          timeout:10]);
    XCTAssertFalse(running(engine.playbackState));

    // And the other way round, through the shuttle keys.
    [engine shuttleForward];
    XCTAssertTrue(running(engine.playbackState));
    XCTAssertFalse(running(engine.sourceMonitorPlaybackState), @"starting the program pauses the source monitor");
    [engine sourceMonitorShuttleReverse];
    XCTAssertTrue(running(engine.sourceMonitorPlaybackState));
    XCTAssertFalse(running(engine.playbackState));
    [engine sourceMonitorPause];
    [engine pause];
}

// MARK: - E4: transitions follow their clips across tracks

- (void)testMovingATransitionPairToAnotherTrackKeepsTheTransition {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    NSArray<NSNumber *> *video = engine.sequence.videoTrackIDs;
    const VETrackID v1 = video[0].longLongValue;
    const VETrackID v2 = video[1].longLongValue;
    VEEditResult *a = [engine overwriteAsset:asset.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:v1
                                  audioTrack:0
                                    sourceIn:kCMTimeZero
                                   sourceOut:seconds(2)];
    VEEditResult *b = [engine overwriteAsset:asset.assetID
                                      atTime:seconds(2)
                                  videoTrack:v1
                                  audioTrack:0
                                    sourceIn:seconds(5)
                                   sourceOut:seconds(8)];
    VEEditResult *t = [engine addTransitionFromClip:a.createdIDs[0].longLongValue
                                             toClip:b.createdIDs[0].longLongValue
                                           duration:CMTimeMake(10, 30)];
    XCTAssertTrue(t.ok, @"%@", t.message);
    const VETransitionID transition = t.createdIDs[0].longLongValue;
    NSString *before = engine.projectJSON;

    VEEditResult *moved = [engine moveClips:@[ a.createdIDs[0], b.createdIDs[0] ]
                                     byTime:kCMTimeZero
                                trackOffset:1
                                ofTrackKind:VETrackKindVideo];
    XCTAssertTrue(moved.ok, @"%@", moved.message);
    XCTAssertEqual(moved.droppedTransitionIDs.count, 0u, @"note: %@", moved.note);
    VETransitionInfo *info = [engine transitionInfo:transition];
    XCTAssertNotNil(info, @"the transition moved with its clips");
    XCTAssertEqual(info.trackID, v2);
    XCTAssertEqual([engine clipsOnTrack:v2].count, 2u);

    // Moving them back in time and track together keeps it too; undo restores the start.
    moved = [engine moveClips:@[ a.createdIDs[0], b.createdIDs[0] ]
                       byTime:seconds(1)
                  trackOffset:-1
                  ofTrackKind:VETrackKindVideo];
    XCTAssertTrue(moved.ok, @"%@", moved.message);
    XCTAssertEqual([engine transitionInfo:transition].trackID, v1);
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.projectJSON, before);

    // Moving only one of the two clips still drops it (its cut no longer exists).
    moved = [engine moveClips:@[ b.createdIDs[0] ] byTime:kCMTimeZero trackOffset:1 ofTrackKind:VETrackKindVideo];
    XCTAssertTrue(moved.ok, @"%@", moved.message);
    XCTAssertEqualObjects(moved.droppedTransitionIDs, @[ @(transition) ]);
}

// MARK: - Opening a project: bookmarks resolve off the main thread

// A media file moved after the project was saved is found again through its bookmark (resolved
// in the background without mounting anything), and the project notes the new path.
- (void)testABookmarkFollowsAMovedFileOnOpen {
    NSURL *original = [_projectDir URLByAppendingPathComponent:@"clip.wav"];
    NSURL *moved = [_projectDir URLByAppendingPathComponent:@"moved/clip-renamed.wav"];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self mediaURL:"audio_only.wav"] toURL:original error:&error],
                  @"%@", error);
    VEEngine *engine = [self makeEngine];
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ original ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    NSURL *project = [self saveProjectOf:engine named:@"moved.videdit"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:[moved URLByDeletingLastPathComponent]
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:original toURL:moved error:&error], @"%@", error);

    VEEngine *reopened = [self makeEngine];
    XCTAssertTrue([reopened openProjectAtURL:project error:&error], @"%@", error);
    XCTAssertEqual(reopened.missingAssetIDs.count, 0u, @"the bookmark found the moved file");
    VEAssetInfo *info = [reopened assetInfo:asset.assetID];
    XCTAssertEqualObjects(info.path.stringByResolvingSymlinksInPath, moved.path.stringByResolvingSymlinksInPath);
    XCTAssertTrue(reopened.isDirty, @"the new path is not saved yet");
}

@end
