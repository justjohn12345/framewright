// The effect span facade (VEEngine "Effect spans" and "Transitions"): every call returns the span
// as it is after the edit, is one undo step (one change), refuses with a code and a reason (an
// overlap with the nearest free range), coalesces in gesture groups, survives a save and an open;
// the Ken Burns move and matching a neighbour's edge on spans (a move holds its end framing after
// its end; a second move on its lane starts from that framing); transitions as lane-0 spans with
// their shares of the cut, fades, and linked pairs keeping the same range relative to the cut.
// Uses h264_1080p30.mp4 (10 s, 30 fps, with audio).

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

CMTimeRange framesRange(int64_t start, int64_t end) {
    return CMTimeRangeFromTimeToTime(frames30(start), frames30(end));
}

VESpanValues values(double x, double scale) {
    VESpanValues v = VESpanValuesUnchanged();
    v.x = x;
    v.scale = scale;
    return v;
}

} // namespace

@interface VEEngineSpanTests : XCTestCase
@end

@implementation VEEngineSpanTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (VEEngine *)engineWithAsset:(VEAssetInfo *__autoreleasing *)assetOut {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
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

/// Source [inFrame, outFrame) at `atFrame` on V1 + A1 (linked): (video clip, audio clip).
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

// MARK: - Spans

- (void)testEverySpanCallReturnsTheSpanAndIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [video, audio] = [self place:engine asset:asset at:0 from:30 to:120];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    XCTAssertEqual([engine laneCountForTrack:v1], 1);

    uint64_t changes = engine.changeCount;
    VEEditResult *added = [engine addSpanOfKind:VESpanKindMotion lane:2 clip:video range:framesRange(10, 40)];
    XCTAssertTrue(added.ok, @"%@", added.message);
    XCTAssertEqual(engine.changeCount, changes + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Motion Span");
    VEEffectSpan *span = added.span;
    XCTAssertNotNil(span);
    XCTAssertEqualObjects(added.createdIDs, @[ @(span.spanID) ]);
    XCTAssertEqual(span.clipID, video);
    XCTAssertEqual(span.trackID, v1);
    XCTAssertEqual(span.lane, 2);
    XCTAssertEqual(span.kind, VESpanKindMotion);
    XCTAssertEqual(CMTimeCompare(span.start, frames30(10)), 0);
    XCTAssertEqual(CMTimeCompare(span.end, frames30(40)), 0);
    XCTAssertEqual(CMTimeCompare(span.clipRelativeStart, frames30(40)), 0, @"source frame 30 + 10");
    XCTAssertEqual(span.startValues.scale, 1.0);
    XCTAssertEqual(span.endValues.x, 0.0);
    XCTAssertTrue(std::isnan(span.startValues.opacity), @"not a Motion parameter");
    XCTAssertEqual(span.interpolation, VEKeyframeInterpolationLinear);
    XCTAssertEqual([engine laneCountForTrack:v1], 3, @"lanes 0 to 2");
    XCTAssertEqual([engine spansForClip:video].count, 1u);
    XCTAssertEqual([engine spansForTrack:v1].count, 1u);
    XCTAssertEqual([engine spanInfo:span.spanID].lane, 2);
    XCTAssertEqual([engine clipInfo:video].spans.count, 1u);
    XCTAssertTrue([engine clipInfo:video].hasEffectSpans);

    // Values: NaN fields stay; the picture composes the span onto the static values.
    changes = engine.changeCount;
    VEEditResult *set = [engine setValuesOfSpan:span.spanID start:values(-60, NAN) end:values(90, 2)];
    XCTAssertTrue(set.ok, @"%@", set.message);
    XCTAssertEqual(engine.changeCount, changes + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Span Values");
    XCTAssertEqual(set.span.startValues.x, -60);
    XCTAssertEqual(set.span.startValues.scale, 1);
    XCTAssertEqual(set.span.endValues.scale, 2);
    VEClipInfo *info = [engine clipInfo:video];
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(25)].x, -60 + 150 * 0.5, 1e-9, @"halfway, linear");
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(25)].scale, 1.5, 1e-12);
    XCTAssertEqual([info videoParamsAtTime:frames30(9)].x, 0, @"nothing before the span");
    XCTAssertEqual([info videoParamsAtTime:frames30(40)].x, 90, @"from its end the end value holds");
    XCTAssertEqual([info videoParamsAtTime:frames30(89)].scale, 2, @"to the clip's end");

    VEEditResult *eased = [engine setInterpolationOfSpan:span.spanID interpolation:VEKeyframeInterpolationEaseIn];
    XCTAssertTrue(eased.ok);
    XCTAssertEqual(eased.span.interpolation, VEKeyframeInterpolationEaseIn);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Span Interpolation");

    VEEditResult *moved = [engine setRangeOfSpan:span.spanID range:framesRange(50, 80)];
    XCTAssertTrue(moved.ok, @"%@", moved.message);
    XCTAssertEqual(CMTimeCompare(moved.span.start, frames30(50)), 0);
    XCTAssertEqual(moved.span.endValues.scale, 2, @"values keep their places");
    XCTAssertEqualObjects(engine.undoActionName, @"Change Span Range");

    VEEditResult *lane = [engine moveSpan:span.spanID toLane:1];
    XCTAssertTrue(lane.ok);
    XCTAssertEqual(lane.span.lane, 1);
    XCTAssertEqual([engine laneCountForTrack:v1], 2);

    changes = engine.changeCount;
    VEEditResult *removed = [engine removeSpan:span.spanID];
    XCTAssertTrue(removed.ok);
    XCTAssertEqual(engine.changeCount, changes + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Remove Span");
    XCTAssertNil([engine spanInfo:span.spanID]);
    XCTAssertEqual([engine laneCountForTrack:v1], 1);

    // Undo walks back one call at a time.
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine spanInfo:span.spanID].lane, 1);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine spanInfo:span.spanID].lane, 2);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(CMTimeCompare([engine spanInfo:span.spanID].start, frames30(10)), 0);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine spanInfo:span.spanID].interpolation, VEKeyframeInterpolationLinear);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine spanInfo:span.spanID].endValues.scale, 1);
    XCTAssertTrue([engine undo]);
    XCTAssertNil([engine spanInfo:span.spanID]);

    // A Gain span on the audio clip.
    VEEditResult *gain = [engine addSpanOfKind:VESpanKindGain lane:1 clip:audio range:framesRange(0, 30)];
    XCTAssertTrue(gain.ok, @"%@", gain.message);
    VESpanValues duck = VESpanValuesUnchanged();
    duck.gainDb = -12;
    XCTAssertTrue([engine setValuesOfSpan:gain.span.spanID start:VESpanValuesUnchanged() end:duck].ok);
    XCTAssertEqualWithAccuracy([[engine clipInfo:audio] gainDbAtTime:frames30(15)], -6, 1e-9);
}

- (void)testSpanRefusalsCarryCodesAndTheNearestFreeRange {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [video, audio] = [self place:engine asset:asset at:0 from:0 to:90];
    VEEditResult *first = [engine addSpanOfKind:VESpanKindMotion lane:1 clip:video range:framesRange(10, 40)];
    XCTAssertTrue(first.ok);
    const uint64_t changes = engine.changeCount;

    VEEditResult *overlap = [engine addSpanOfKind:VESpanKindOpacity lane:1 clip:video range:framesRange(30, 60)];
    XCTAssertEqual(overlap.errorCode, VEEditErrorOverlap);
    XCTAssertTrue(CMTIMERANGE_IS_VALID(overlap.freeRange));
    XCTAssertEqual(CMTimeCompare(overlap.freeRange.start, frames30(40)), 0);
    XCTAssertEqual(CMTimeCompare(CMTimeRangeGetEnd(overlap.freeRange), frames30(90)), 0);
    XCTAssertTrue([overlap.message containsString:@"nearest free range"], @"%@", overlap.message);
    XCTAssertNil(overlap.span);

    XCTAssertEqual([engine addSpanOfKind:VESpanKindGain lane:2 clip:video range:framesRange(0, 10)].errorCode,
                   VEEditErrorTrackKindMismatch);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindMotion lane:1 clip:audio range:framesRange(0, 10)].errorCode,
                   VEEditErrorTrackKindMismatch);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindMotion lane:0 clip:video range:framesRange(0, 10)].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindTransition lane:1 clip:video range:framesRange(0, 10)].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindMotion lane:2 clip:video range:framesRange(80, 100)].errorCode,
                   VEEditErrorInvalidTime);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindMotion lane:2 clip:video range:kCMTimeRangeInvalid].errorCode,
                   VEEditErrorInvalidTime);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindMotion lane:2 clip:999 range:framesRange(0, 10)].errorCode,
                   VEEditErrorClipNotFound);
    XCTAssertEqual([engine removeSpan:999].errorCode, VEEditErrorSpanNotFound);
    XCTAssertEqual([engine setRangeOfSpan:999 range:framesRange(0, 5)].errorCode, VEEditErrorSpanNotFound);
    VESpanValues bad = VESpanValuesUnchanged();
    bad.scale = -1;
    XCTAssertEqual([engine setValuesOfSpan:first.span.spanID start:bad end:VESpanValuesUnchanged()].errorCode,
                   VEEditErrorInvalidArgument);
    VESpanValues wrongKind = VESpanValuesUnchanged();
    wrongKind.gainDb = 3;
    XCTAssertEqual([engine setValuesOfSpan:first.span.spanID start:wrongKind end:VESpanValuesUnchanged()].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setInterpolationOfSpan:first.span.spanID interpolation:VEKeyframeInterpolationCustom].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine moveSpan:first.span.spanID toLane:4].errorCode, VEEditErrorInvalidArgument);
    XCTAssertEqual(engine.changeCount, changes, @"no refusal changes anything");

    XCTAssertTrue([engine setTrack:engine.sequence.videoTrackIDs[0].longLongValue locked:YES].ok);
    XCTAssertEqual([engine removeSpan:first.span.spanID].errorCode, VEEditErrorTrackLocked);
    XCTAssertEqual([engine addSpanOfKind:VESpanKindOpacity lane:2 clip:video range:framesRange(0, 5)].errorCode,
                   VEEditErrorTrackLocked);
}

- (void)testASpanDragCoalescesIntoOneStepAndAnotherEditEndsIt {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [video, audio] = [self place:engine asset:asset at:0 from:0 to:90];
    (void)audio;
    const VESpanID span = [engine addSpanOfKind:VESpanKindMotion lane:1 clip:video range:framesRange(0, 20)].span.spanID;
    [engine beginCoalescingWithKey:@"span.drag"];
    for (int64_t end = 21; end <= 40; ++end) {
        VEEditResult *step = [engine performInCoalescingGroup:@"span.drag"
                                                         edit:^VEEditResult * {
                                                             return [engine setRangeOfSpan:span range:framesRange(0, end)];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
    }
    [engine endCoalescing];
    XCTAssertEqual(CMTimeCompare([engine spanInfo:span].end, frames30(40)), 0);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(CMTimeCompare([engine spanInfo:span].end, frames30(20)), 0, @"the drag was one step");

    // Another edit during the drag ends its group; the drag's later steps are refused as Busy.
    [engine beginCoalescingWithKey:@"span.drag"];
    XCTAssertTrue([engine performInCoalescingGroup:@"span.drag"
                                              edit:^VEEditResult * {
                                                  return [engine setRangeOfSpan:span range:framesRange(0, 25)];
                                              }]
                      .ok);
    XCTAssertTrue([engine moveSpan:span toLane:3].ok);
    VEEditResult *late = [engine performInCoalescingGroup:@"span.drag"
                                                     edit:^VEEditResult * {
                                                         return [engine setRangeOfSpan:span range:framesRange(0, 30)];
                                                     }];
    XCTAssertEqual(late.errorCode, VEEditErrorBusy);
    XCTAssertEqual(CMTimeCompare([engine spanInfo:span].end, frames30(25)), 0);
    XCTAssertEqual([engine spanInfo:span].lane, 3);
}

- (void)testSpansSurviveASaveAndAnOpen {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [video, audio] = [self place:engine asset:asset at:0 from:0 to:90];
    VEEditResult *motion = [engine addSpanOfKind:VESpanKindMotion lane:2 clip:video range:framesRange(5, 50)];
    XCTAssertTrue([engine setValuesOfSpan:motion.span.spanID start:values(10, 1.25) end:values(-30, 0.75)].ok);
    XCTAssertTrue([engine setInterpolationOfSpan:motion.span.spanID interpolation:VEKeyframeInterpolationEaseInOut].ok);
    VEEditResult *gain = [engine addSpanOfKind:VESpanKindGain lane:1 clip:audio range:framesRange(30, 60)];
    XCTAssertTrue(gain.ok);
    VEEditResult *fade = [engine addTransitionAtEdge:VEClipEdgeEnd
                                              ofClip:audio
                                            duration:frames30(12)
                                             options:VETransitionOptionNone];
    XCTAssertTrue(fade.ok, @"%@", fade.message);
    NSURL *url = [_scratch URLByAppendingPathComponent:@"spans.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);

    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches2"]];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    VEEffectSpan *back = [reopened spanInfo:motion.span.spanID];
    XCTAssertNotNil(back);
    XCTAssertEqual(back.lane, 2);
    XCTAssertEqual(back.startValues.x, 10);
    XCTAssertEqual(back.endValues.scale, 0.75);
    XCTAssertEqual(back.interpolation, VEKeyframeInterpolationEaseInOut);
    XCTAssertEqual(CMTimeCompare(back.start, frames30(5)), 0);
    XCTAssertNotNil([reopened spanInfo:gain.span.spanID]);
    VETransitionInfo *transition = [reopened transitionInfo:fade.createdIDs[0].longLongValue];
    XCTAssertEqual(transition.style, VETransitionStyleFadeOut);
    XCTAssertEqual(CMTimeCompare(transition.duration, frames30(12)), 0);
    for (int64_t f = 0; f < 90; f += 7) {
        XCTAssertEqual([[reopened clipInfo:video] videoParamsAtTime:frames30(f)].x,
                       [[engine clipInfo:video] videoParamsAtTime:frames30(f)].x, @"frame %lld", f);
    }
}

// MARK: - Ken Burns and matching

- (void)testKenBurnsSetsTheFramingsGivenTheOtherLanes {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [video, audio] = [self place:engine asset:asset at:0 from:0 to:90];
    (void)audio;
    const VEVideoParams placed{40, 0, 1.5, 0, 1};
    XCTAssertTrue([engine setVideoParams:placed forClip:video].ok);
    const VESpanID zoom = [engine addSpanOfKind:VESpanKindMotion lane:2 clip:video range:framesRange(0, 90)].span.spanID;
    XCTAssertTrue([engine setValuesOfSpan:zoom start:values(NAN, 1) end:values(NAN, 0.5)].ok);
    const VESpanID move = [engine addSpanOfKind:VESpanKindMotion lane:1 clip:video range:framesRange(30, 60)].span.spanID;
    const VEMotionFraming start{-200, 100, 2};
    const VEMotionFraming end{150, -50, 1.2};
    const uint64_t changes = engine.changeCount;
    VEEditResult *kb = [engine applyKenBurnsToSpan:move start:start end:end interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertTrue(kb.ok, @"%@", kb.message);
    XCTAssertEqual(engine.changeCount, changes + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Ken Burns");
    XCTAssertEqual(kb.span.interpolation, VEKeyframeInterpolationEaseInOut);
    VEClipInfo *info = [engine clipInfo:video];
    // The first frame shows the start framing; the end framing is reached at the span's end.
    const VEVideoParams first = [info videoParamsAtTime:frames30(30)];
    XCTAssertEqualWithAccuracy(first.x, -200, 1e-9);
    XCTAssertEqualWithAccuracy(first.y, 100, 1e-9);
    XCTAssertEqualWithAccuracy(first.scale, 2, 1e-12);
    for (const BOOL atEnd : {NO, YES}) {
        VEVideoParams edge = VEVideoParamsIdentity();
        XCTAssertTrue([info getMotion:&edge atEdgeOfSpan:move atEnd:atEnd frameDuration:frames30(1)]);
        const VEMotionFraming &want = atEnd ? end : start;
        XCTAssertEqualWithAccuracy(edge.x, want.x, 1e-9);
        XCTAssertEqualWithAccuracy(edge.y, want.y, 1e-9);
        XCTAssertEqualWithAccuracy(edge.scale, want.scale, 1e-12);
    }
    VEVideoParams unchanged = VEVideoParamsIdentity();
    XCTAssertFalse([info getMotion:&unchanged atEdgeOfSpan:999 atEnd:NO frameDuration:frames30(1)]);
    XCTAssertEqual(unchanged.scale, 1);

    const VESpanID opacity = [engine addSpanOfKind:VESpanKindOpacity lane:3 clip:video range:framesRange(0, 10)].span.spanID;
    XCTAssertEqual([engine applyKenBurnsToSpan:opacity start:start end:end interpolation:VEKeyframeInterpolationLinear]
                       .errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine applyKenBurnsToSpan:move start:start end:end interpolation:VEKeyframeInterpolationCustom]
                       .errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine applyKenBurnsToSpan:999 start:start end:end interpolation:VEKeyframeInterpolationLinear]
                       .errorCode,
                   VEEditErrorSpanNotFound);
}

- (void)testAKenBurnsMoveHoldsItsEndFramingAndTheNextMoveStartsThere {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    // The 10 s movie over 300 frames; a move over [60, 150) and a later one on the same lane over
    // [210, 270).
    const auto [video, audio] = [self place:engine asset:asset at:0 from:0 to:300];
    (void)audio;
    const VESpanID first =
        [engine addSpanOfKind:VESpanKindMotion lane:1 clip:video range:framesRange(60, 150)].span.spanID;
    const VEMotionFraming own{0, 0, 1};
    const VEMotionFraming pushed{-150, 80, 1.8};
    XCTAssertTrue(
        [engine applyKenBurnsToSpan:first start:own end:pushed interpolation:VEKeyframeInterpolationEaseInOut].ok);
    VEClipInfo *info = [engine clipInfo:video];
    VEVideoParams end = VEVideoParamsIdentity();
    XCTAssertTrue([info getMotion:&end atEdgeOfSpan:first atEnd:YES frameDuration:frames30(1)]);
    XCTAssertEqualWithAccuracy(end.scale, 1.8, 1e-12);
    // motion(at:): the clip's framing before the move, the end framing from its end to the clip's end.
    for (const int64_t f : {0, 30, 59}) {
        const VEVideoParams shown = [info videoParamsAtTime:frames30(f)];
        XCTAssertEqual(shown.x, 0, @"frame %lld", f);
        XCTAssertEqual(shown.scale, 1, @"frame %lld", f);
    }
    XCTAssertLessThan([info videoParamsAtTime:frames30(149)].scale, 1.8, @"the last frame is a frame short");
    for (const int64_t f : {150, 200, 299, 305}) {
        const VEVideoParams shown = [info videoParamsAtTime:frames30(f)];
        XCTAssertEqual(shown.x, end.x, @"frame %lld", f);
        XCTAssertEqual(shown.y, end.y, @"frame %lld", f);
        XCTAssertEqual(shown.scale, end.scale, @"frame %lld", f);
    }

    // A second move on the same lane: its start edge reads the held framing, so a move from there
    // keeps its start values neutral and continues without a jump.
    VEEditResult *added = [engine addSpanOfKind:VESpanKindMotion lane:1 clip:video range:framesRange(210, 270)];
    XCTAssertTrue(added.ok, @"%@", added.message);
    const VESpanID second = added.span.spanID;
    info = [engine clipInfo:video];
    VEVideoParams start = VEVideoParamsIdentity();
    XCTAssertTrue([info getMotion:&start atEdgeOfSpan:second atEnd:NO frameDuration:frames30(1)]);
    XCTAssertEqual(start.x, end.x);
    XCTAssertEqual(start.scale, end.scale);
    const VEMotionFraming from{start.x, start.y, start.scale};
    const VEMotionFraming panned{150, 80, 1.8};
    VEEditResult *kb = [engine applyKenBurnsToSpan:second
                                             start:from
                                               end:panned
                                     interpolation:VEKeyframeInterpolationLinear];
    XCTAssertTrue(kb.ok, @"%@", kb.message);
    XCTAssertEqualWithAccuracy(kb.span.startValues.x, 0, 1e-9);
    XCTAssertEqualWithAccuracy(kb.span.startValues.scale, 1, 1e-12);
    info = [engine clipInfo:video];
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(210)].x, [info videoParamsAtTime:frames30(209)].x,
                               1e-9);
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(240)].x, -150 + 300 * 0.5, 1e-9, @"halfway, linear");
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(299)].x, 150, 1e-9, @"the second end framing holds");
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(299)].scale, 1.8, 1e-12);
    // The first move's framings still read back as applied.
    VEVideoParams again = VEVideoParamsIdentity();
    XCTAssertTrue([info getMotion:&again atEdgeOfSpan:first atEnd:YES frameDuration:frames30(1)]);
    XCTAssertEqualWithAccuracy(again.x, pushed.x, 1e-9);
    XCTAssertEqualWithAccuracy(again.scale, pushed.scale, 1e-12);
}

- (void)testMatchingASpanEdgeContinuesTheNeighbour {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [a, aa] = [self place:engine asset:asset at:0 from:0 to:60];
    const auto [b, ba] = [self place:engine asset:asset at:60 from:120 to:180];
    (void)aa;
    (void)ba;
    const VEVideoParams placed{100, -30, 1.4, 12, 0.7};
    XCTAssertTrue([engine setVideoParams:placed forClip:a].ok);
    const VESpanID span = [engine addSpanOfKind:VESpanKindMotion lane:1 clip:b range:framesRange(60, 90)].span.spanID;
    VEEditResult *matched = [engine matchSpanEdge:span toAdjacentClipAtEdge:VEClipEdgeStart];
    XCTAssertTrue(matched.ok, @"%@", matched.message);
    const VEVideoParams aLast = [[engine clipInfo:a] videoParamsAtTime:frames30(59)];
    const VEVideoParams bFirst = [[engine clipInfo:b] videoParamsAtTime:frames30(60)];
    XCTAssertEqualWithAccuracy(bFirst.x, aLast.x, 1e-9);
    XCTAssertEqualWithAccuracy(bFirst.y, aLast.y, 1e-9);
    XCTAssertEqualWithAccuracy(bFirst.scale, aLast.scale, 1e-12);
    XCTAssertEqualWithAccuracy(bFirst.rotationDegrees, aLast.rotationDegrees, 1e-9);
    XCTAssertEqualWithAccuracy(matched.span.startValues.scale, 1.4, 1e-12);
    const uint64_t changes = engine.changeCount;
    VEEditResult *again = [engine matchSpanEdge:span toAdjacentClipAtEdge:VEClipEdgeStart];
    XCTAssertTrue(again.ok);
    XCTAssertEqual(engine.changeCount, changes, @"nothing to change: no undo step");
    XCTAssertTrue(again.note.length > 0, @"the note says it already matches");
    XCTAssertEqual([engine matchSpanEdge:span toAdjacentClipAtEdge:VEClipEdgeEnd].errorCode, VEEditErrorNotAdjacent);
}

// MARK: - Transitions as lane-0 spans

- (void)testAsymmetricTransitionsFadesAndLinkedPairs {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto [a, aa] = [self place:engine asset:asset at:0 from:30 to:90];
    const auto [b, ba] = [self place:engine asset:asset at:60 from:120 to:180];
    (void)b;
    VEEditResult *added = [engine addTransitionFromClip:a
                                                 toClip:b
                                               duration:frames30(10)
                                                options:VETransitionOptionIncludeLinked];
    XCTAssertTrue(added.ok, @"%@", added.message);
    XCTAssertEqual(added.createdIDs.count, 2u);
    const VETransitionID dissolve = added.createdIDs[0].longLongValue;
    const VETransitionID crossfade = added.createdIDs[1].longLongValue;
    XCTAssertEqual([engine linkedTransitionForTransition:dissolve], crossfade);
    VEEffectSpan *span = [engine spanInfo:dissolve];
    XCTAssertEqual(span.kind, VESpanKindTransition);
    XCTAssertEqual(span.lane, 0);
    XCTAssertEqual(span.transitionStyle, VETransitionStyleCrossDissolve);
    XCTAssertEqual(span.partnerClipID, b);
    XCTAssertEqual(CMTimeCompare(span.shareBeforeCut, frames30(5)), 0);
    XCTAssertEqual(CMTimeCompare(span.shareAfterCut, frames30(5)), 0);

    // 70/30 with the linked crossfade: the same range relative to the cut, one undo step.
    const uint64_t changes = engine.changeCount;
    VEEditResult *ranged = [engine setRangeOfTransition:dissolve range:framesRange(53, 63) includingLinked:YES];
    XCTAssertTrue(ranged.ok, @"%@", ranged.message);
    XCTAssertEqual(engine.changeCount, changes + 1);
    for (const VETransitionID t : {dissolve, crossfade}) {
        VETransitionInfo *info = [engine transitionInfo:t];
        XCTAssertEqual(CMTimeCompare(info.shareBeforeCut, frames30(7)), 0);
        XCTAssertEqual(CMTimeCompare(info.shareAfterCut, frames30(3)), 0);
        XCTAssertEqual(CMTimeCompare(info.start, frames30(53)), 0);
    }
    // Ending on the cut it becomes a fade out, and the note says so.
    VEEditResult *fade = [engine setRangeOfTransition:dissolve range:framesRange(50, 60) includingLinked:NO];
    XCTAssertTrue(fade.ok, @"%@", fade.message);
    XCTAssertEqual([engine transitionInfo:dissolve].style, VETransitionStyleFadeOut);
    XCTAssertTrue(fade.note.length > 0);
    XCTAssertEqual([engine transitionInfo:crossfade].style, VETransitionStyleCrossDissolve, @"the linked one stays");

    // A fade in where nothing touches the start; refused on B, whose start A touches.
    VEEditResult *fadeIn = [engine addTransitionAtEdge:VEClipEdgeStart ofClip:aa duration:frames30(15)
                                               options:VETransitionOptionNone];
    XCTAssertTrue(fadeIn.ok, @"%@", fadeIn.message);
    XCTAssertEqual([engine transitionInfo:fadeIn.createdIDs[0].longLongValue].style, VETransitionStyleFadeIn);
    XCTAssertEqual([engine addTransitionAtEdge:VEClipEdgeStart ofClip:ba duration:frames30(5)
                                       options:VETransitionOptionNone]
                       .errorCode,
                   VEEditErrorInvalidArgument);
    // The audio fades show in VEAudioParams too.
    XCTAssertEqual(CMTimeCompare([engine clipInfo:aa].audioParams.fadeInDuration, frames30(15)), 0);

    // Removing the dissolve with its linked crossfade is one step.
    XCTAssertTrue([engine setRangeOfTransition:dissolve range:framesRange(55, 65) includingLinked:NO].ok);
    XCTAssertTrue([engine removeTransition:dissolve includingLinked:YES].ok);
    XCTAssertNil([engine spanInfo:dissolve]);
    XCTAssertNil([engine spanInfo:crossfade]);
    XCTAssertEqualObjects(engine.undoActionName, @"Remove Transitions");
    XCTAssertTrue([engine undo]);
    XCTAssertNotNil([engine spanInfo:dissolve]);
    XCTAssertNotNil([engine spanInfo:crossfade]);
}

@end
