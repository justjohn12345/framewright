// Keyframed Motion through the facade: keyframes at the playhead (the frame's source span, speed
// included), Premiere's auto-keyframe for animated values, refusals with reasons, next/previous
// frame times from VEKeyframe, the Ken Burns helper, the static-value setters keeping keyframes,
// a Video reset clearing them, undo, coalescing, and save/open keeping them. Uses h264_1080p30.mp4
// (10 s, 30 fps, with audio).

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

} // namespace

@interface VEEngineKeyframeTests : XCTestCase
@end

@implementation VEEngineKeyframeTests {
    NSURL *_scratch;
    NSURL *_cacheDir;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [_scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
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

/// Source [inFrame, outFrame) at `atFrame` on V1 + A1; returns (video clip, audio clip).
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
    return {r.createdIDs[0].longLongValue, r.createdIDs[1].longLongValue};
}

- (void)testKeyframesAtThePlayheadFollowTheFramesSourceSpan {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:30 from:60 to:150];
    const VEClipID video = clip.first;

    // A keyframe added mid-frame lands on the frame's start and keeps the picture.
    VEEditResult *r = [engine addKeyframeToClip:video parameter:VEMotionParameterScale atTime:CMTimeMake(81, 60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Keyframe");
    VEClipInfo *info = [engine clipInfo:video];
    XCTAssertTrue(info.hasKeyframes);
    XCTAssertTrue([info isAnimated:VEMotionParameterScale]);
    XCTAssertFalse([info isAnimated:VEMotionParameterPositionX]);
    NSArray<VEKeyframe *> *scale = [info keyframesForParameter:VEMotionParameterScale];
    XCTAssertEqual(scale.count, 1u);
    XCTAssertEqual(CMTimeCompare(scale[0].sourceTime, frames30(70)), 0); // timeline frame 40 -> source 70
    XCTAssertEqual(CMTimeCompare(scale[0].frameTime, frames30(40)), 0);
    XCTAssertTrue(scale[0].isInsideClip);
    XCTAssertEqual(scale[0].value, 1);
    XCTAssertEqual(scale[0].interpolation, VEKeyframeInterpolationLinear);
    XCTAssertNotNil([info keyframeForParameter:VEMotionParameterScale atTime:CMTimeMake(1209, 900)]);
    XCTAssertNil([info keyframeForParameter:VEMotionParameterScale atTime:frames30(41)]);

    // A second keyframe at frame 70 with a new value; in between the value is interpolated.
    r = [engine addKeyframeToClip:video parameter:VEMotionParameterScale atTime:frames30(70)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    r = [engine setMotionValue:2 parameter:VEMotionParameterScale clip:video atTime:frames30(70)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Keyframe");
    info = [engine clipInfo:video];
    XCTAssertEqualWithAccuracy([info videoParamsAtTime:frames30(55)].scale, 1.5, 1e-12);
    XCTAssertEqual([info videoParamsAtTime:frames30(30)].scale, 1, @"before the first keyframe: its value");
    XCTAssertEqual([info videoParamsAtTime:frames30(110)].scale, 2, @"after the last: its value");
    XCTAssertEqual(info.videoParams.scale, 1, @"the static value is kept, unused");

    // An animated value set between keyframes adds one there (Premiere's stopwatch behaviour).
    r = [engine setMotionValue:3 parameter:VEMotionParameterScale clip:video atTime:frames30(50)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Keyframe");
    XCTAssertEqual([[engine clipInfo:video] keyframesForParameter:VEMotionParameterScale].count, 3u);
    // A parameter without keyframes changes its static value wherever the playhead is.
    r = [engine setMotionValue:0.5 parameter:VEMotionParameterOpacity clip:video atTime:kCMTimeZero];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([engine clipInfo:video].videoParams.opacity, 0.5);
    XCTAssertFalse([[engine clipInfo:video] isAnimated:VEMotionParameterOpacity]);

    // Interpolation, a move and a removal, all at the playhead.
    r = [engine setKeyframeInterpolation:VEKeyframeInterpolationEaseInOut
                               parameter:VEMotionParameterScale
                                    clip:video
                                  atTime:frames30(40)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([[engine clipInfo:video] keyframeForParameter:VEMotionParameterScale atTime:frames30(40)].interpolation,
                   VEKeyframeInterpolationEaseInOut);
    r = [engine moveKeyframeOfClip:video parameter:VEMotionParameterScale fromTime:frames30(50) toTime:frames30(60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertNotNil([[engine clipInfo:video] keyframeForParameter:VEMotionParameterScale atTime:frames30(60)]);
    r = [engine removeKeyframeFromClip:video parameter:VEMotionParameterScale atTime:frames30(60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Delete Keyframe");
    XCTAssertTrue([engine undo]);
    XCTAssertNotNil([[engine clipInfo:video] keyframeForParameter:VEMotionParameterScale atTime:frames30(60)]);
    XCTAssertTrue([engine redo]);

    // All keyframes in time order, for the timeline's markers.
    NSArray<VEKeyframe *> *all = [engine clipInfo:video].allKeyframes;
    XCTAssertEqual(all.count, 2u);
    XCTAssertEqual(CMTimeCompare(all[0].frameTime, frames30(40)), 0);
    XCTAssertEqual(CMTimeCompare(all[1].frameTime, frames30(70)), 0);

    // Turning the animation off keeps the value at the playhead.
    r = [engine removeAnimationFromClip:video parameter:VEMotionParameterScale atTime:frames30(70)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Remove Animation");
    info = [engine clipInfo:video];
    XCTAssertFalse(info.hasKeyframes);
    XCTAssertEqual(info.videoParams.scale, 2);
}

- (void)testRefusalsSayWhy {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:30 from:0 to:60];
    VEEditResult *r = [engine addKeyframeToClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(10)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime);
    XCTAssertTrue([r.message containsString:@"playhead over the clip"], @"%@", r.message);
    r = [engine addKeyframeToClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(90)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime, @"the frame after the clip");
    r = [engine addKeyframeToClip:clip.second parameter:VEMotionParameterPositionX atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    r = [engine addKeyframeToClip:9999 parameter:VEMotionParameterPositionX atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorClipNotFound);
    XCTAssertTrue([engine addKeyframeToClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(40)].ok);
    r = [engine addKeyframeToClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorAlreadyExists);
    XCTAssertTrue([r.message containsString:@"Position X"], @"%@", r.message);
    r = [engine removeKeyframeFromClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(41)];
    XCTAssertEqual(r.errorCode, VEEditErrorKeyframeNotFound);
    r = [engine setMotionValue:-1 parameter:VEMotionParameterScale clip:clip.first atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setMotionValue:10 parameter:VEMotionParameterPositionX clip:clip.first atTime:frames30(5)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime, @"an animated value needs the playhead over the clip");
    r = [engine setKeyframeInterpolation:VEKeyframeInterpolationCustom
                               parameter:VEMotionParameterPositionX
                                    clip:clip.first
                                  atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine removeAnimationFromClip:clip.first parameter:VEMotionParameterRotation atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorKeyframeNotFound);
    XCTAssertTrue([engine setTrack:engine.sequence.videoTrackIDs[0].longLongValue locked:YES].ok);
    r = [engine removeKeyframeFromClip:clip.first parameter:VEMotionParameterPositionX atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackLocked);
}

- (void)testSpeedMovesKeyframesWithTheirPictures {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:0 from:0 to:120];
    XCTAssertTrue([engine addKeyframeToClip:clip.first parameter:VEMotionParameterRotation atTime:frames30(60)].ok);
    XCTAssertTrue([engine setSpeedNumerator:2 denominator:1 forClip:clip.first].ok);
    VEKeyframe *moved = [[engine clipInfo:clip.first] keyframesForParameter:VEMotionParameterRotation].firstObject;
    XCTAssertEqual(CMTimeCompare(moved.sourceTime, frames30(60)), 0);
    XCTAssertEqual(CMTimeCompare(moved.frameTime, frames30(30)), 0, @"at 2x the picture plays at frame 30");
    XCTAssertNotNil([[engine clipInfo:clip.first] keyframeForParameter:VEMotionParameterRotation atTime:frames30(30)]);
}

- (void)testKenBurnsSetsPositionAndScaleOnTheFirstAndLastFrames {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:30 from:0 to:90];
    XCTAssertTrue([engine setMotionValue:15 parameter:VEMotionParameterRotation clip:clip.first atTime:frames30(30)].ok);
    const VEMotionFraming start{-100, 50, 1.25};
    const VEMotionFraming end{200, -80, 2};
    VEEditResult *r = [engine applyKenBurnsToClip:clip.first
                                            start:start
                                              end:end
                                    interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Ken Burns");
    VEClipInfo *info = [engine clipInfo:clip.first];
    for (VEMotionParameter p : {VEMotionParameterPositionX, VEMotionParameterPositionY, VEMotionParameterScale}) {
        NSArray<VEKeyframe *> *keys = [info keyframesForParameter:p];
        XCTAssertEqual(keys.count, 2u);
        XCTAssertEqual(CMTimeCompare(keys[0].frameTime, frames30(30)), 0);
        XCTAssertEqual(CMTimeCompare(keys[1].frameTime, frames30(119)), 0);
        XCTAssertEqual(keys[0].interpolation, VEKeyframeInterpolationEaseInOut);
    }
    XCTAssertFalse([info isAnimated:VEMotionParameterRotation]);
    const VEVideoParams first = [info videoParamsAtTime:frames30(30)];
    const VEVideoParams last = [info videoParamsAtTime:frames30(119)];
    const VEVideoParams middle = [info videoParamsAtTime:CMTimeMake(149, 60)];
    XCTAssertEqual(first.x, -100);
    XCTAssertEqual(first.scale, 1.25);
    XCTAssertEqual(last.y, -80);
    XCTAssertEqual(last.scale, 2);
    XCTAssertEqualWithAccuracy(middle.x, 50, 1e-9, @"ease in and out is symmetric about the middle");
    XCTAssertEqual(first.rotationDegrees, 15, @"rotation is kept");
    // Applying it again replaces the move; undo restores the previous one.
    XCTAssertTrue([engine applyKenBurnsToClip:clip.first start:end end:start interpolation:VEKeyframeInterpolationLinear].ok);
    XCTAssertEqual([[engine clipInfo:clip.first] videoParamsAtTime:frames30(30)].x, 200);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([[engine clipInfo:clip.first] videoParamsAtTime:frames30(30)].x, -100);

    const auto single = [self place:engine asset:asset at:200 from:0 to:1];
    r = [engine applyKenBurnsToClip:single.first start:start end:end interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"two frames"], @"%@", r.message);
}

- (void)testKenBurnsOverARangeHoldsTheEndFramingAndKeepsKeyframesOutsideIt {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    // The whole 10 s movie at timeline frame 30: frames [30, 330).
    const auto clip = [self place:engine asset:asset at:30 from:0 to:300];
    const VEClipID video = clip.first;
    const VEMotionFraming whole{0, 0, 1};
    const VEMotionFraming pushed{-120, 60, 1.5};

    // 5 s from a time inside frame 30: keyframes on frames 30 and 179, then the end framing holds.
    VEEditResult *r = [engine applyKenBurnsToClip:video
                                            start:whole
                                              end:pushed
                                    interpolation:VEKeyframeInterpolationEaseInOut
                                       rangeStart:CMTimeMake(61, 60)
                                         duration:CMTimeMake(5, 1)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"");
    XCTAssertEqualObjects(engine.undoActionName, @"Ken Burns");
    VEClipInfo *info = [engine clipInfo:video];
    for (VEMotionParameter p : {VEMotionParameterPositionX, VEMotionParameterPositionY, VEMotionParameterScale}) {
        NSArray<VEKeyframe *> *keys = [info keyframesForParameter:p];
        XCTAssertEqual(keys.count, 2u);
        XCTAssertEqual(CMTimeCompare(keys[0].frameTime, frames30(30)), 0);
        XCTAssertEqual(CMTimeCompare(keys[1].frameTime, frames30(179)), 0);
        XCTAssertEqual(keys[0].interpolation, VEKeyframeInterpolationEaseInOut);
    }
    XCTAssertEqual([info videoParamsAtTime:frames30(30)].x, 0);
    XCTAssertLessThan([info videoParamsAtTime:frames30(100)].x, 0);
    XCTAssertGreaterThan([info videoParamsAtTime:frames30(100)].x, -120);
    for (int64_t f : {179, 180, 250, 329}) {
        const VEVideoParams shown = [info videoParamsAtTime:frames30(f)];
        XCTAssertEqual(shown.x, -120, @"frame %lld holds the end framing", f);
        XCTAssertEqual(shown.y, 60, @"frame %lld", f);
        XCTAssertEqual(shown.scale, 1.5, @"frame %lld", f);
    }

    // A second move later in the clip from the framing held there keeps the first move.
    const VEMotionFraming closer{80, -20, 2};
    r = [engine applyKenBurnsToClip:video
                              start:pushed
                                end:closer
                      interpolation:VEKeyframeInterpolationLinear
                         rangeStart:frames30(260)
                           duration:frames30(60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"", @"the framing holds between the moves");
    info = [engine clipInfo:video];
    NSArray<VEKeyframe *> *scale = [info keyframesForParameter:VEMotionParameterScale];
    XCTAssertEqual(scale.count, 4u);
    XCTAssertEqual(CMTimeCompare(scale[2].frameTime, frames30(260)), 0);
    XCTAssertEqual(CMTimeCompare(scale[3].frameTime, frames30(319)), 0);
    XCTAssertEqual([info videoParamsAtTime:frames30(220)].scale, 1.5);
    XCTAssertEqual([info videoParamsAtTime:frames30(325)].scale, 2);
    // Undo takes back the second move only (one step).
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([[engine clipInfo:video] keyframesForParameter:VEMotionParameterScale].count, 2u);
    XCTAssertTrue([engine redo]);

    // A move between them from another framing: the note says where the framing no longer holds.
    const VEMotionFraming other{0, 0, 1.25};
    r = [engine applyKenBurnsToClip:video
                              start:other
                                end:other
                      interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(200)
                           duration:frames30(30)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertTrue([r.note containsString:@"does not hold before the move"], @"%@", r.note);
    XCTAssertTrue([r.note containsString:@"Position X, Position Y and Scale keyframes at 00:00:05:29 lead into"], @"%@", r.note);
    XCTAssertTrue([r.note containsString:@"does not hold after the move"], @"%@", r.note);
    XCTAssertTrue([r.note containsString:@"at 00:00:08:20"], @"%@", r.note);
    XCTAssertTrue([engine undo]);

    // Refusals: outside the clip, too short, past the end.
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(10)
                           duration:frames30(30)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime);
    XCTAssertTrue([r.message containsString:@"start on a frame of the clip"], @"%@", r.message);
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(330)
                           duration:frames30(30)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime);
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(100)
                           duration:frames30(1)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"two frames"], @"%@", r.message);
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(100)
                           duration:kCMTimeInvalid];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(100)
                           duration:frames30(231)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime);
    XCTAssertTrue([r.message containsString:@"230 frames left"], @"%@", r.message);
    r = [engine applyKenBurnsToClip:clip.second start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(100)
                           duration:frames30(30)];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertEqual([[engine clipInfo:video] keyframesForParameter:VEMotionParameterScale].count, 4u,
                   @"refusals change nothing");

    // A duration off the frame grid rounds to whole frames (4.99 s = 149.7 frames: 150), and a
    // range reaching the clip's end is allowed.
    r = [engine applyKenBurnsToClip:video start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut
                         rangeStart:frames30(180)
                           duration:CMTimeMake(499, 100)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    NSArray<VEKeyframe *> *x = [[engine clipInfo:video] keyframesForParameter:VEMotionParameterPositionX];
    XCTAssertEqual(CMTimeCompare(x.lastObject.frameTime, frames30(329)), 0);
}

- (void)testMatchingANeighboursFramingIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    // V1: A [0, 60) and B [60, 120) touch; C [150, 180) after a gap.
    const VEClipID a = [self place:engine asset:asset at:0 from:0 to:60].first;
    const auto bPair = [self place:engine asset:asset at:60 from:100 to:160];
    const VEClipID b = bPair.first;
    const VEClipID c = [self place:engine asset:asset at:150 from:0 to:30].first;
    XCTAssertEqual([engine adjacentClipOfClip:b atEdge:VEClipEdgeStart], a);
    XCTAssertEqual([engine adjacentClipOfClip:a atEdge:VEClipEdgeEnd], b);
    XCTAssertEqual([engine adjacentClipOfClip:b atEdge:VEClipEdgeEnd], 0);
    XCTAssertEqual([engine adjacentClipOfClip:c atEdge:VEClipEdgeStart], 0);
    XCTAssertEqual([engine adjacentClipOfClip:a atEdge:VEClipEdgeStart], 0);

    // An unanimated clip takes the previous clip's end as its static values.
    const VEVideoParams placed{100, -20, 1.5, 10, 0.5};
    XCTAssertTrue([engine setVideoParams:placed forClip:a].ok);
    VEEditResult *r = [engine matchMotionOfClip:b toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Match Previous Clip");
    XCTAssertEqualObjects(r.note, @"Matched the previous clip's end: set as this clip's static values.");
    VEVideoParams shown = [engine clipInfo:b].videoParams;
    XCTAssertEqual(shown.x, 100);
    XCTAssertEqual(shown.y, -20);
    XCTAssertEqual(shown.scale, 1.5);
    XCTAssertEqual(shown.rotationDegrees, 10);
    XCTAssertEqual(shown.opacity, 0.5);
    XCTAssertFalse([engine clipInfo:b].hasKeyframes);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:b].videoParams.x, 0, @"one undo step takes it all back");
    XCTAssertEqual([engine clipInfo:b].videoParams.opacity, 1);

    // An animated clip takes it as a keyframe on its first frame for what it animates (Scale), as
    // static values for the rest; the value comes from A's last frame as the monitor shows it.
    const VEMotionFraming unmoved{0, 0, 1};
    const VEMotionFraming pushed{-120, 60, 1.8};
    r = [engine applyKenBurnsToClip:a start:unmoved end:pushed interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertTrue([engine addKeyframeToClip:b parameter:VEMotionParameterScale atTime:frames30(60)].ok);
    r = [engine setKeyframeInterpolation:VEKeyframeInterpolationEaseOut
                               parameter:VEMotionParameterScale
                                    clip:b
                                  atTime:frames30(60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertTrue([engine setMotionValue:2 parameter:VEMotionParameterScale clip:b atTime:frames30(100)].ok);
    r = [engine matchMotionOfClip:b toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"Matched the previous clip's end: Scale got keyframes on this clip's first frame; "
                                  @"Position X, Position Y, Rotation and Opacity became static values.");
    VEClipInfo *info = [engine clipInfo:b];
    NSArray<VEKeyframe *> *scale = [info keyframesForParameter:VEMotionParameterScale];
    XCTAssertEqual(scale.count, 2u);
    XCTAssertEqual(scale[0].value, 1.8);
    XCTAssertEqual(scale[0].interpolation, VEKeyframeInterpolationEaseOut, @"the keyframe keeps its interpolation");
    const VEVideoParams end = [[engine clipInfo:a] videoParamsAtTime:frames30(59)];
    const VEVideoParams start = [info videoParamsAtTime:frames30(60)];
    XCTAssertEqual(start.x, end.x);
    XCTAssertEqual(start.y, end.y);
    XCTAssertEqual(start.scale, end.scale);
    XCTAssertEqual(start.rotationDegrees, end.rotationDegrees);
    XCTAssertEqual(start.opacity, end.opacity);
    XCTAssertEqual([info videoParamsAtTime:frames30(100)].scale, 2, @"the rest of the animation stays");
    // Nothing left to match: success without an undo step.
    const uint64_t changes = engine.changeCount;
    r = [engine matchMotionOfClip:b toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"This clip already matches the previous clip's end.");
    XCTAssertEqual(engine.changeCount, changes);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([[engine clipInfo:b] keyframesForParameter:VEMotionParameterScale][0].value, 1,
                   @"one undo step");
    XCTAssertEqual([engine clipInfo:b].videoParams.x, 0);

    // The next clip's start onto A's last frame: A animates position and scale there.
    r = [engine matchMotionOfClip:a toAdjacentAtEdge:VEClipEdgeEnd];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Match Next Clip");
    XCTAssertEqual([[engine clipInfo:a] videoParamsAtTime:frames30(59)].scale, 1, @"B's first frame");
    XCTAssertEqual([[engine clipInfo:a] keyframesForParameter:VEMotionParameterScale].count, 2u);

    // Refusals.
    r = [engine matchMotionOfClip:c toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertEqual(r.errorCode, VEEditErrorNotAdjacent);
    XCTAssertTrue([r.message containsString:@"No clip ends where this clip starts"], @"%@", r.message);
    r = [engine matchMotionOfClip:bPair.second toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertTrue([engine setTrack:engine.sequence.videoTrackIDs[0].longLongValue locked:YES].ok);
    r = [engine matchMotionOfClip:b toAdjacentAtEdge:VEClipEdgeStart];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackLocked);
    r = [engine matchMotionOfClip:a toAdjacentAtEdge:VEClipEdgeEnd];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackLocked, @"also when nothing would change");
}

- (void)testTheMotionKeyframeToggleAddsTheMissingOnesOrRemovesAllInOneStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:30 from:0 to:90];
    XCTAssertTrue([engine setMotionValue:0.5 parameter:VEMotionParameterOpacity clip:clip.first atTime:frames30(40)].ok);
    XCTAssertTrue([engine addKeyframeToClip:clip.first parameter:VEMotionParameterScale atTime:frames30(40)].ok);

    VEEditResult *r = [engine toggleMotionKeyframesOfClip:clip.first atTime:CMTimeMake(81, 60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"Keyframes added on 4 parameters", @"scale had one already");
    XCTAssertEqualObjects(engine.undoActionName, @"Add Keyframes");
    VEClipInfo *info = [engine clipInfo:clip.first];
    for (VEMotionParameter p : {VEMotionParameterPositionX, VEMotionParameterPositionY, VEMotionParameterScale,
                                VEMotionParameterRotation, VEMotionParameterOpacity}) {
        XCTAssertNotNil([info keyframeForParameter:p atTime:frames30(40)], @"parameter %ld", static_cast<long>(p));
    }
    XCTAssertEqual([info keyframeForParameter:VEMotionParameterOpacity atTime:frames30(40)].value, 0.5);

    r = [engine toggleMotionKeyframesOfClip:clip.first atTime:frames30(40)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"Keyframes removed");
    XCTAssertEqualObjects(engine.undoActionName, @"Remove Keyframes");
    XCTAssertFalse([engine clipInfo:clip.first].hasKeyframes);
    XCTAssertEqual([engine clipInfo:clip.first].videoParams.opacity, 0.5);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:clip.first].allKeyframes.count, 5u, @"one undo step brings all five back");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:clip.first].allKeyframes.count, 1u, @"and one takes the four added away");

    r = [engine toggleMotionKeyframesOfClip:clip.first atTime:frames30(10)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidTime);
    r = [engine toggleMotionKeyframesOfClip:clip.second atTime:frames30(40)];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
}

- (void)testStaticSettersKeepKeyframesAndAVideoResetClearsThem {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:0 from:0 to:60];
    XCTAssertTrue([engine addKeyframeToClip:clip.first parameter:VEMotionParameterOpacity atTime:frames30(10)].ok);
    VEVideoParams params = [engine clipInfo:clip.first].videoParams;
    params.x = 33;
    XCTAssertTrue([engine setVideoParams:params forClip:clip.first].ok);
    XCTAssertTrue([[engine clipInfo:clip.first] isAnimated:VEMotionParameterOpacity]);
    VEClipParamsBatch *batch = [[VEClipParamsBatch alloc] init];
    params.y = 12;
    [batch setVideoParams:params forClip:clip.first];
    XCTAssertTrue([engine applyClipParams:batch].ok);
    XCTAssertTrue([[engine clipInfo:clip.first] isAnimated:VEMotionParameterOpacity]);
    XCTAssertEqual([engine clipInfo:clip.first].videoParams.y, 12);

    VEClipParamsBatch *reset = [[VEClipParamsBatch alloc] init];
    [reset setVideoParams:VEVideoParamsIdentity() clearingKeyframesForClip:clip.first];
    XCTAssertTrue([engine applyClipParams:reset].ok);
    XCTAssertFalse([engine clipInfo:clip.first].hasKeyframes);
    XCTAssertEqual([engine clipInfo:clip.first].videoParams.x, 0);
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine clipInfo:clip.first].hasKeyframes);
}

- (void)testSliderStepsCoalesceIntoOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:0 from:0 to:60];
    XCTAssertTrue([engine addKeyframeToClip:clip.first parameter:VEMotionParameterPositionY atTime:frames30(0)].ok);
    const uint64_t before = engine.changeCount;
    [engine beginCoalescingWithKey:@"slider"];
    for (int i = 1; i <= 10; ++i) {
        VEEditResult *r = [engine performInCoalescingGroup:@"slider"
                                                      edit:^VEEditResult * {
                                                          return [engine setMotionValue:i * 5
                                                                              parameter:VEMotionParameterPositionY
                                                                                   clip:clip.first
                                                                                 atTime:frames30(20)];
                                                      }];
        XCTAssertTrue(r.ok, @"%@", r.message);
    }
    [engine endCoalescing];
    XCTAssertGreaterThan(engine.changeCount, before);
    NSArray<VEKeyframe *> *keys = [[engine clipInfo:clip.first] keyframesForParameter:VEMotionParameterPositionY];
    XCTAssertEqual(keys.count, 2u, @"the drag added one keyframe, not ten");
    XCTAssertEqual(keys[1].value, 50);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([[engine clipInfo:clip.first] keyframesForParameter:VEMotionParameterPositionY].count, 1u,
                   @"one undo removes the whole drag");
}

- (void)testSaveAndOpenKeepKeyframes {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto clip = [self place:engine asset:asset at:0 from:0 to:60];
    const VEMotionFraming from{0, 0, 1};
    const VEMotionFraming to{120, 40, 1.5};
    VEEditResult *kenBurns = [engine applyKenBurnsToClip:clip.first
                                                   start:from
                                                     end:to
                                           interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertTrue(kenBurns.ok, @"%@", kenBurns.message);
    XCTAssertTrue([engine splitClip:clip.first atTime:frames30(25)].ok, @"a split leaves custom curves");
    NSURL *url = [_scratch URLByAppendingPathComponent:@"keyframes.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    NSString *json = engine.projectJSON;
    XCTAssertTrue([json containsString:@"\"schemaVersion\": 4"]);
    XCTAssertTrue([json containsString:@"\"bezier\""]);
    NSMutableArray<VEClipInfo *> *before = [NSMutableArray array];
    for (VEClipInfo *info in engine.allClips) {
        [before addObject:info];
    }
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(reopened.projectJSON, json);
    for (VEClipInfo *info in before) {
        VEClipInfo *again = [reopened clipInfo:info.clipID];
        for (int64_t f = 0; f < 60; ++f) {
            const VEVideoParams a = [info videoParamsAtTime:frames30(f)];
            const VEVideoParams b = [again videoParamsAtTime:frames30(f)];
            XCTAssertEqual(a.x, b.x);
            XCTAssertEqual(a.scale, b.scale);
        }
    }
}

@end
