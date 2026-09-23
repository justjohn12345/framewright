// Phase 6 facade edits: multi-clip parameter batches, Accumulate coalescing (keyboard nudges),
// transition limits and their user-facing refusals, a dissolve with its linked crossfade as one
// undo step, transition duration bounds and multi-clip speed changes. Uses h264_1080p30.mp4
// (10 s, 30 fps, with audio).

#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

} // namespace

@interface VEEngineEffectsTests : XCTestCase
@end

@implementation VEEngineEffectsTests {
    NSURL *_cacheDir;
}

- (void)setUp {
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

- (VEEngine *)engineWithAsset:(VEAssetInfo *__autoreleasing *)assetOut {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    std::string error;
    const std::string path = ve::test::testMediaPath("h264_1080p30.mp4", error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ [NSURL fileURLWithPath:@(path.c_str())] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertNotNil(asset);
    *assetOut = asset;
    return engine;
}

/// Places source [inFrame, outFrame) of the asset at `atFrame` on V1 + A1 (linked); returns
/// (video clip, audio clip).
- (std::pair<VEClipID, VEClipID>)place:(VEEngine *)engine
                                 asset:(VEAssetInfo *)asset
                                    at:(int64_t)atFrame
                                  from:(int64_t)inFrame
                                    to:(int64_t)outFrame {
    VEEditResult *r = [engine overwriteAsset:asset.assetID
                                      atTime:frames30(atFrame)
                                  videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                  audioTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                    sourceIn:frames30(inFrame)
                                   sourceOut:frames30(outFrame)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(r.createdIDs.count, 2u);
    return {r.createdIDs[0].longLongValue, r.createdIDs[1].longLongValue};
}

// MARK: - Parameter batches and Accumulate coalescing

- (void)testAMultiClipParameterBatchIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0 from:0 to:30];
    const auto second = [self place:engine asset:asset at:30 from:60 to:90];
    const uint64_t before = engine.changeCount;

    VEClipParamsBatch *batch = [[VEClipParamsBatch alloc] init];
    VEVideoParams video = VEVideoParamsIdentity();
    video.opacity = 0.25;
    [batch setVideoParams:video forClip:first.first];
    video.x = 40;
    [batch setVideoParams:video forClip:second.first];
    VEAudioParams audio = VEAudioParamsDefault();
    audio.gainDb = -6;
    [batch setAudioParams:audio forClip:first.second];
    XCTAssertEqual(batch.count, 3u);
    VEEditResult *r = [engine applyClipParams:batch];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(engine.changeCount, before + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Clip Settings");
    XCTAssertEqual([engine clipInfo:first.first].videoParams.opacity, 0.25);
    XCTAssertEqual([engine clipInfo:second.first].videoParams.x, 40);
    XCTAssertEqual([engine clipInfo:first.second].audioParams.gainDb, -6);

    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:first.first].videoParams.opacity, 1);
    XCTAssertEqual([engine clipInfo:second.first].videoParams.x, 0);
    XCTAssertEqual([engine clipInfo:first.second].audioParams.gainDb, 0);
    XCTAssertEqualObjects(engine.undoActionName, @"Overwrite", @"the whole batch was one step");
    XCTAssertTrue([engine redo]);
    XCTAssertEqual([engine clipInfo:second.first].videoParams.x, 40);
}

- (void)testABatchIsRefusedAsAWholeForTheWrongTrackKind {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto pair = [self place:engine asset:asset at:0 from:0 to:30];
    VEClipParamsBatch *batch = [[VEClipParamsBatch alloc] init];
    VEVideoParams video = VEVideoParamsIdentity();
    video.scale = 2;
    [batch setVideoParams:video forClip:pair.first];
    [batch setVideoParams:video forClip:pair.second]; // an audio clip
    VEEditResult *r = [engine applyClipParams:batch];
    XCTAssertFalse(r.ok);
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertEqual([engine clipInfo:pair.first].videoParams.scale, 1, @"nothing changed");
    XCTAssertFalse([engine applyClipParams:[[VEClipParamsBatch alloc] init]].ok);
}

- (void)testTenNudgesInAnAccumulateGroupAreOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0 from:0 to:30];
    const auto second = [self place:engine asset:asset at:30 from:60 to:90];
    NSString *key = @"nudge.x";
    [engine beginCoalescingWithKey:key mode:VECoalescingModeAccumulate];
    XCTAssertEqualObjects(engine.coalescingKey, key);
    for (int i = 0; i < 10; ++i) {
        VEClipParamsBatch *batch = [[VEClipParamsBatch alloc] init];
        for (VEClipID clip : {first.first, second.first}) {
            VEVideoParams params = [engine clipInfo:clip].videoParams;
            params.x += 1; // relative to the current state: accumulates
            [batch setVideoParams:params forClip:clip];
        }
        VEEditResult *r = [engine performInCoalescingGroup:key
                                                      edit:^VEEditResult * {
                                                          return [engine applyClipParams:batch];
                                                      }];
        XCTAssertTrue(r.ok, @"%@", r.message);
    }
    [engine endCoalescing];
    XCTAssertNil(engine.coalescingKey);
    XCTAssertEqual([engine clipInfo:first.first].videoParams.x, 10);
    XCTAssertEqual([engine clipInfo:second.first].videoParams.x, 10);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Video Settings");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:first.first].videoParams.x, 0, @"ten nudges were one undo step");
    XCTAssertEqual([engine clipInfo:second.first].videoParams.x, 0);
    XCTAssertEqualObjects(engine.undoActionName, @"Overwrite");

    // Nudges that cancel out leave no undo step.
    [engine beginCoalescingWithKey:key mode:VECoalescingModeAccumulate];
    for (double step : {1.0, -1.0}) {
        VEVideoParams params = [engine clipInfo:first.first].videoParams;
        params.x += step;
        XCTAssertTrue([engine performInCoalescingGroup:key
                                                  edit:^VEEditResult * {
                                                      return [engine setVideoParams:params forClip:first.first];
                                                  }]
                          .ok);
    }
    [engine endCoalescing];
    XCTAssertEqualObjects(engine.undoActionName, @"Overwrite");

    // Another edit during the burst commits it first; the burst's next step is refused as Busy.
    [engine beginCoalescingWithKey:key mode:VECoalescingModeAccumulate];
    VEVideoParams params = [engine clipInfo:first.first].videoParams;
    params.x = 5;
    XCTAssertTrue([engine performInCoalescingGroup:key
                                              edit:^VEEditResult * {
                                                  return [engine setVideoParams:params forClip:first.first];
                                              }]
                      .ok);
    XCTAssertTrue([engine unlinkClip:first.first].ok);
    VEEditResult *late = [engine performInCoalescingGroup:key
                                                     edit:^VEEditResult * {
                                                         return [engine setVideoParams:params forClip:first.first];
                                                     }];
    XCTAssertEqual(late.errorCode, VEEditErrorBusy);
    XCTAssertEqualObjects(engine.undoActionName, @"Unlink");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:first.first].videoParams.x, 5, @"the burst was committed as its own step");
}

// MARK: - Transitions

- (void)testTransitionLimitAndRefusalsExplainTheMissingMedia {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    // A: source [0, 60) at 0; B: source [15, 90) at 60, so B has 15 frames before its in point.
    const auto a = [self place:engine asset:asset at:0 from:0 to:60];
    const auto b = [self place:engine asset:asset at:60 from:15 to:90];
    VETransitionLimit *limit = [engine transitionLimitFromClip:a.first toClip:b.first];
    XCTAssertEqual(limit.maximumFrames, 31, @"floor(31/2) = 15 frames before B's in point");
    XCTAssertEqual(CMTimeCompare(limit.maximumDuration, frames30(31)), 0);
    XCTAssertEqual(limit.limitingError, VEEditErrorInsufficientHandles);
    XCTAssertEqual(limit.limitingClipID, b.first);
    XCTAssertTrue([limit.reason containsString:@"h264_1080p30.mp4"], @"%@", limit.reason);
    XCTAssertTrue([limit.reason containsString:@"before its in point"], @"%@", limit.reason);

    // Too long: refused with the reason and the longest possible duration.
    const uint64_t before = engine.changeCount;
    VEEditResult *refused = [engine addTransitionFromClip:a.first toClip:b.first duration:frames30(40)];
    XCTAssertFalse(refused.ok);
    XCTAssertEqual(refused.errorCode, VEEditErrorInsufficientHandles);
    XCTAssertTrue([refused.message containsString:@"before its in point"], @"%@", refused.message);
    XCTAssertTrue([refused.message containsString:@"31 frames"], @"%@", refused.message);
    XCTAssertEqual(engine.changeCount, before);

    // Fit to the cut: shortened, with a note saying why.
    VEEditResult *fitted = [engine addTransitionFromClip:a.first
                                                  toClip:b.first
                                                duration:frames30(40)
                                                 options:VETransitionOptionFitToCut];
    XCTAssertTrue(fitted.ok, @"%@", fitted.message);
    XCTAssertTrue([fitted.note containsString:@"Shortened to 31 frames"], @"%@", fitted.note);
    VETransitionInfo *added = [engine transitionInfo:fitted.createdIDs[0].longLongValue];
    XCTAssertEqual(CMTimeCompare(added.duration, frames30(31)), 0);

    // No media beyond the cut on either side (a one-frame transition needs one frame after the
    // outgoing clip's out point): C ends at the end of the media, D starts at its beginning.
    const auto c = [self place:engine asset:asset at:200 from:270 to:300];
    const auto d = [self place:engine asset:asset at:230 from:0 to:30];
    VETransitionLimit *none = [engine transitionLimitFromClip:c.first toClip:d.first];
    XCTAssertEqual(none.maximumFrames, 0);
    VEEditResult *noMedia = [engine addTransitionFromClip:c.first
                                                   toClip:d.first
                                                 duration:frames30(30)
                                                  options:VETransitionOptionFitToCut];
    XCTAssertFalse(noMedia.ok);
    XCTAssertEqual(noMedia.errorCode, VEEditErrorInsufficientHandles);
    XCTAssertTrue([noMedia.message hasPrefix:@"No transition fits this cut"], @"%@", noMedia.message);

    // A cut that already has one.
    VETransitionLimit *taken = [engine transitionLimitFromClip:a.first toClip:b.first];
    XCTAssertEqual(taken.maximumFrames, 0);
    XCTAssertEqual(taken.limitingError, VEEditErrorAlreadyExists);
}

- (void)testADissolveWithItsLinkedCrossfadeIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto a = [self place:engine asset:asset at:0 from:0 to:60];
    const auto b = [self place:engine asset:asset at:60 from:90 to:150];
    VEEditResult *r = [engine addTransitionFromClip:a.first
                                             toClip:b.first
                                           duration:frames30(30)
                                            options:VETransitionOptionIncludeLinked | VETransitionOptionFitToCut];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(r.createdIDs.count, 2u);
    XCTAssertEqualObjects(r.note, @"");
    VETransitionInfo *video = [engine transitionInfo:r.createdIDs[0].longLongValue];
    VETransitionInfo *audio = [engine transitionInfo:r.createdIDs[1].longLongValue];
    XCTAssertEqual(video.trackID, engine.sequence.videoTrackIDs[0].longLongValue);
    XCTAssertEqual(audio.trackID, engine.sequence.audioTrackIDs[0].longLongValue);
    XCTAssertEqual(audio.fromClipID, a.second);
    XCTAssertEqual(audio.toClipID, b.second);
    XCTAssertEqual(CMTimeCompare(audio.duration, frames30(30)), 0);
    XCTAssertEqual(engine.sequence.transitions.count, 2u);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.sequence.transitions.count, 0u, @"both came off in one undo");
    XCTAssertTrue([engine redo]);
    XCTAssertEqual(engine.sequence.transitions.count, 2u);

    // Unlinked audio: only the dissolve, and the note says why.
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine unlinkClip:b.first].ok);
    VEEditResult *single = [engine addTransitionFromClip:a.first
                                                  toClip:b.first
                                                duration:frames30(30)
                                                 options:VETransitionOptionIncludeLinked];
    XCTAssertTrue(single.ok, @"%@", single.message);
    XCTAssertEqual(single.createdIDs.count, 1u);
    XCTAssertTrue([single.note containsString:@"do not meet at a cut"], @"%@", single.note);

    // Asymmetric room (review finding 1): each transition is fitted to its own cut. A = [0, 60),
    // B = [60, 120), C = [120, 180) on V1 + A1, with plenty of media beyond every cut; a 100-frame
    // crossfade [70, 170) on the audio B|C cut leaves the audio A|B cut room for 20 frames only.
    VEAssetInfo *asset2 = nil;
    VEEngine *tight = [self engineWithAsset:&asset2];
    const auto ta = [self place:tight asset:asset2 at:0 from:0 to:60];
    const auto tb = [self place:tight asset:asset2 at:60 from:90 to:150];
    const auto tc = [self place:tight asset:asset2 at:120 from:200 to:260];
    VEEditResult *neighbour = [tight addTransitionFromClip:tb.second toClip:tc.second duration:frames30(100)];
    XCTAssertTrue(neighbour.ok, @"%@", neighbour.message);
    XCTAssertEqual([tight transitionLimitFromClip:ta.second toClip:tb.second].maximumFrames, 20);
    XCTAssertGreaterThanOrEqual([tight transitionLimitFromClip:ta.first toClip:tb.first].maximumFrames, 30);
    const uint64_t beforeFit = tight.changeCount;
    VEEditResult *fitted = [tight addTransitionFromClip:ta.first
                                                 toClip:tb.first
                                               duration:frames30(30)
                                                options:VETransitionOptionIncludeLinked | VETransitionOptionFitToCut];
    XCTAssertTrue(fitted.ok, @"%@", fitted.message);
    XCTAssertEqual(fitted.createdIDs.count, 2u);
    XCTAssertEqual(CMTimeCompare([tight transitionInfo:fitted.createdIDs[0].longLongValue].duration, frames30(30)), 0,
                   @"the video dissolve keeps the requested length: its own cut has room");
    XCTAssertEqual(CMTimeCompare([tight transitionInfo:fitted.createdIDs[1].longLongValue].duration, frames30(20)), 0,
                   @"the audio crossfade is shortened to what its cut allows");
    XCTAssertTrue([fitted.note containsString:@"The linked clips' transition was shortened to 20 frames"], @"%@",
                  fitted.note);
    XCTAssertFalse([fitted.note containsString:@"Shortened to"], @"the dissolve was not shortened: %@", fitted.note);
    XCTAssertEqual(tight.changeCount, beforeFit + 1, @"one undo step");
    XCTAssertEqual(tight.sequence.transitions.count, 3u);
    XCTAssertTrue([tight undo]);
    XCTAssertEqual(tight.sequence.transitions.count, 1u, @"both came off in one undo");

    // The other way round: the video cut is the tight one (a neighbouring dissolve on B|C), the
    // audio crossfade keeps the requested length; each shortening is noted on its own.
    XCTAssertTrue([tight undo]); // the audio neighbour
    XCTAssertTrue([tight addTransitionFromClip:tb.first toClip:tc.first duration:frames30(100)].ok);
    VEEditResult *swapped = [tight addTransitionFromClip:ta.first
                                                  toClip:tb.first
                                                duration:frames30(30)
                                                 options:VETransitionOptionIncludeLinked | VETransitionOptionFitToCut];
    XCTAssertTrue(swapped.ok, @"%@", swapped.message);
    XCTAssertEqual(swapped.createdIDs.count, 2u);
    XCTAssertEqual(CMTimeCompare([tight transitionInfo:swapped.createdIDs[0].longLongValue].duration, frames30(20)), 0);
    XCTAssertEqual(CMTimeCompare([tight transitionInfo:swapped.createdIDs[1].longLongValue].duration, frames30(30)), 0);
    XCTAssertTrue([swapped.note hasPrefix:@"Shortened to 20 frames"], @"%@", swapped.note);
    XCTAssertFalse([swapped.note containsString:@"linked clips"], @"%@", swapped.note);
}

- (void)testTransitionDurationIsBoundedByTheCut {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto a = [self place:engine asset:asset at:0 from:0 to:60];
    const auto b = [self place:engine asset:asset at:60 from:15 to:90];
    VEEditResult *added = [engine addTransitionFromClip:a.first toClip:b.first duration:frames30(10)];
    XCTAssertTrue(added.ok, @"%@", added.message);
    const VETransitionID transition = added.createdIDs[0].longLongValue;
    VETransitionLimit *limit = [engine transitionLimitForTransition:transition];
    XCTAssertEqual(limit.maximumFrames, 31, @"the transition itself does not limit its resize");

    XCTAssertTrue([engine setDuration:frames30(31) forTransition:transition].ok);
    VEEditResult *tooLong = [engine setDuration:frames30(32) forTransition:transition];
    XCTAssertFalse(tooLong.ok);
    XCTAssertEqual(tooLong.errorCode, VEEditErrorInsufficientHandles);
    XCTAssertTrue([tooLong.message containsString:@"The longest it allows is 31 frames"], @"%@", tooLong.message);
    XCTAssertEqual(CMTimeCompare([engine transitionInfo:transition].duration, frames30(31)), 0);
    XCTAssertFalse([engine setDuration:kCMTimeZero forTransition:transition].ok, @"at least one frame");

    // A neighbouring transition limits both: T1 = [55, 65) on the A|B cut; B = [60, 135).
    XCTAssertTrue([engine setDuration:frames30(10) forTransition:transition].ok);
    const auto c = [self place:engine asset:asset at:135 from:200 to:300];
    // 150 frames on the B|C cut would start at 60, inside T1.
    VEEditResult *next = [engine addTransitionFromClip:b.first toClip:c.first duration:frames30(150)];
    XCTAssertFalse(next.ok);
    XCTAssertEqual(next.errorCode, VEEditErrorOverlap);
    XCTAssertTrue([next.message containsString:@"neighbouring transition"], @"%@", next.message);
    XCTAssertTrue([next.message containsString:@"The longest it allows is 141 frames"], @"%@", next.message);
    VEEditResult *nextFitted = [engine addTransitionFromClip:b.first
                                                      toClip:c.first
                                                    duration:frames30(150)
                                                     options:VETransitionOptionFitToCut];
    XCTAssertTrue(nextFitted.ok, @"%@", nextFitted.message);
    XCTAssertEqual(CMTimeCompare([engine transitionInfo:nextFitted.createdIDs[0].longLongValue].duration,
                                 frames30(141)),
                   0, @"[65, 206) starts where T1 ends");
    VETransitionLimit *first = [engine transitionLimitForTransition:transition];
    XCTAssertEqual(first.maximumFrames, 10, @"T1 cannot grow past the start of its neighbour");
    XCTAssertEqual(first.limitingError, VEEditErrorOverlap, @"%@", first.reason);
}

// MARK: - Speed

- (void)testMultiClipSpeedIsOneStepAndRipplesAsAsked {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto a = [self place:engine asset:asset at:0 from:0 to:30];
    const auto b = [self place:engine asset:asset at:30 from:60 to:90];
    const auto c = [self place:engine asset:asset at:60 from:120 to:150];
    // Half speed on A and B with ripple: each doubles, C moves right by 60 frames.
    VEEditResult *r = [engine setSpeedNumerator:1
                                    denominator:2
                                       forClips:@[ @(a.first), @(a.second), @(b.first) ]
                                         ripple:YES
                                          scope:VERippleScopeSyncedTracks];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:a.first].duration, frames30(60)), 0);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:b.second].duration, frames30(60)), 0, @"the partner follows");
    XCTAssertEqual(CMTimeCompare([engine clipInfo:c.first].timelineStart, frames30(120)), 0);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Speed");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:a.first].duration, frames30(30)), 0);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:c.first].timelineStart, frames30(60)), 0, @"one undo step");

    // Without ripple, slowing a clip into its neighbour is refused.
    VEEditResult *blocked = [engine setSpeedNumerator:1
                                          denominator:2
                                             forClips:@[ @(a.first) ]
                                               ripple:NO
                                                scope:VERippleScopeAllTracks];
    XCTAssertFalse(blocked.ok);
    XCTAssertGreaterThan(blocked.message.length, 0u);
    // Speeding up without ripple leaves a gap and succeeds.
    XCTAssertTrue([engine setSpeedNumerator:2 denominator:1 forClips:@[ @(a.first) ] ripple:NO scope:VERippleScopeAllTracks].ok);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:b.first].timelineStart, frames30(30)), 0);
    XCTAssertFalse([engine setSpeedNumerator:0 denominator:1 forClips:@[ @(a.first) ] ripple:NO scope:VERippleScopeAllTracks].ok);
}

@end
