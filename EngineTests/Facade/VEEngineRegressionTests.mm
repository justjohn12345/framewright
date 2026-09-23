// Regression tests for facade bugs found in review (open findings 1, 2 and 3). They use only
// API that existed before the fixes, so they also build against the unfixed engine.

#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <string>

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

} // namespace

@interface VEEngineRegressionTests : XCTestCase
@end

@implementation VEEngineRegressionTests {
    NSURL *_cacheDir;
}

- (void)setUp {
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

- (VEEngine *)makeEngine {
    return [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
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

/// Spins the main run loop until `condition` holds or `timeout` seconds pass.
- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

// MARK: - Finding 1: imports and coalescing groups

- (void)testImportFinishingDuringADragDoesNotBreakTheDrag {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    const VETrackID a1 = engine.sequence.audioTrackIDs[0].longLongValue;
    VEEditResult *r = [engine insertAsset:wav.assetID
                                   atTime:seconds(0.5)
                               videoTrack:0
                               audioTrack:a1
                                 sourceIn:kCMTimeZero
                                sourceOut:seconds(2)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    NSNumber *clip = r.createdIDs.firstObject;
    NSString *beforeDrag = engine.projectJSON;

    // A drag: 1 s, then an import completes while the pointer is still down, then 2 s.
    [engine beginCoalescingWithKey:@"timeline.move"];
    XCTAssertTrue([engine moveClips:@[ clip ] byTime:seconds(1) trackOffset:0].ok);
    __block BOOL importCompleted = NO;
    __block NSArray<VEAssetInfo *> *imported = nil;
    [engine importMediaAtURLs:@[ [self mediaURL:"audio_only.m4a"] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       imported = assets;
                       importCompleted = YES;
                   }];
    // Long enough for the probe to finish (the engine may hold the result until the drag ends).
    [self spinUntil:^BOOL {
        return importCompleted;
    }
            timeout:3];
    XCTAssertTrue(engine.isCoalescing, @"the import must not end the drag's undo group");
    XCTAssertTrue([engine moveClips:@[ clip ] byTime:seconds(2) trackOffset:0].ok);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:clip.longLongValue].timelineStart), 2.5, 1e-9,
                               @"the drag's total offset is applied to the position before the drag");
    [engine endCoalescing];

    XCTAssertTrue([self spinUntil:^BOOL {
        return importCompleted;
    }
                          timeout:30]);
    XCTAssertEqual(imported.count, 1u);
    XCTAssertEqual(engine.allAssets.count, 2u);

    // The drag is one undo step on its own, the import another.
    XCTAssertEqualObjects(engine.undoActionName, @"Import");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.allAssets.count, 1u);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.projectJSON, beforeDrag, @"one undo reverts the whole drag");
}

- (void)testImportStartedBeforeANewProjectIsNotAddedToIt {
    VEEngine *engine = [self makeEngine];
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *imported = nil;
    __block NSArray<NSError *> *failures = nil;
    [engine importMediaAtURLs:@[ [self mediaURL:"audio_only.wav"] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       imported = assets;
                       failures = errors;
                       [done fulfill];
                   }];
    [engine newProjectWithName:@"Other"];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertEqual(engine.allAssets.count, 0u, @"the import belonged to the closed project");
    XCTAssertEqual(imported.count, 0u);
    XCTAssertEqual(failures.count, 1u);
    XCTAssertFalse(engine.canUndo);
}

// MARK: - Finding 2: ids after undo

- (void)testIdsAreNeverReusedAfterUndo {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.allAssets.count, 0u);
    VEAssetInfo *mp4 = [self importOne:"h264_1080p30.mp4" into:engine];
    XCTAssertNotEqual(mp4.assetID, wav.assetID, @"an undone import's asset id names a different file");

    // The waveform served for the new id is the new file's (10 s at the waveform rate).
    XCTestExpectation *done = [self expectationWithDescription:@"waveform"];
    __block VEWaveform *waveform = nil;
    [engine waveformForAsset:mp4.assetID
                  completion:^(VEWaveform *w, NSError *error) {
                      XCTAssertNil(error);
                      waveform = w;
                      [done fulfill];
                  }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertEqual(waveform.assetID, mp4.assetID);

    // Clip ids too.
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEEditResult *first = [engine insertAsset:mp4.assetID
                                       atTime:kCMTimeZero
                                   videoTrack:v1
                                   audioTrack:0
                                     sourceIn:kCMTimeZero
                                    sourceOut:seconds(1)];
    XCTAssertTrue(first.ok, @"%@", first.message);
    XCTAssertTrue([engine undo]);
    VEEditResult *second = [engine insertAsset:mp4.assetID
                                        atTime:seconds(3)
                                    videoTrack:v1
                                    audioTrack:0
                                      sourceIn:seconds(2)
                                     sourceOut:seconds(3)];
    XCTAssertTrue(second.ok, @"%@", second.message);
    XCTAssertNotEqualObjects(second.createdIDs.firstObject, first.createdIDs.firstObject,
                             @"a clip created after an undo gets a new id");

    // Undo and redo still restore the exact states.
    NSString *afterSecond = engine.projectJSON;
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine redo]);
    XCTAssertEqualObjects(engine.projectJSON, afterSecond);
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.allAssets.count, 0u);
    XCTAssertFalse(engine.canUndo);
}

// MARK: - Finding 3: multi-clip move across tracks

- (void)testMultiClipMoveToOtherTracksDoesNotCutTheMovedClips {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    XCTAssertTrue([engine addTrackOfKind:VETrackKindVideo name:nil].ok);
    NSArray<NSNumber *> *video = engine.sequence.videoTrackIDs;
    XCTAssertEqual(video.count, 3u);
    // X on V1 [0, 2) from source 0 s; Y on V2 [1, 3) from source 5 s.
    VEEditResult *x = [engine overwriteAsset:h264.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:video[0].longLongValue
                                  audioTrack:0
                                    sourceIn:kCMTimeZero
                                   sourceOut:seconds(2)];
    VEEditResult *y = [engine overwriteAsset:h264.assetID
                                      atTime:seconds(1)
                                  videoTrack:video[1].longLongValue
                                  audioTrack:0
                                    sourceIn:seconds(5)
                                   sourceOut:seconds(7)];
    XCTAssertTrue(x.ok && y.ok, @"%@ %@", x.message, y.message);
    const VEClipID xID = x.createdIDs[0].longLongValue;
    const VEClipID yID = y.createdIDs[0].longLongValue;

    VEEditResult *r = [engine moveClips:@[ @(xID), @(yID) ] byTime:kCMTimeZero trackOffset:1];
    XCTAssertTrue(r.ok, @"%@", r.message);
    VEClipInfo *movedX = [engine clipInfo:xID];
    VEClipInfo *movedY = [engine clipInfo:yID];
    XCTAssertEqual(movedX.trackID, video[1].longLongValue);
    XCTAssertEqual(movedY.trackID, video[2].longLongValue);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(movedX.timelineStart), 0, 1e-9);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(movedX.duration), 2, 1e-9);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(movedY.timelineStart), 1, 1e-9, @"Y was not cut by X");
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(movedY.duration), 2, 1e-9, @"Y was not cut by X");
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(movedY.sourceIn), 5, 1e-9);
    XCTAssertEqual([engine clipsOnTrack:video[0].longLongValue].count, 0u);
    XCTAssertEqual([engine clipsOnTrack:video[1].longLongValue].count, 1u);
    XCTAssertEqual([engine clipsOnTrack:video[2].longLongValue].count, 1u);

    // And back down in one undo step.
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:xID].trackID, video[0].longLongValue);
    XCTAssertEqual([engine clipInfo:yID].trackID, video[1].longLongValue);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:yID].duration), 2, 1e-9);
}

@end
