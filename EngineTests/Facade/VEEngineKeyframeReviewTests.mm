// Keyframed Motion through the facade after the motion/photos review: adding keyframes keeps every
// frame (finding 1), a value typed on a frame whose keyframe is not on its start shows exactly on that
// frame (finding 4, including an Accumulate nudge burst), refusals for an unknown parameter (21), and
// the review's facade test gaps: stills (keyframes, head trims, Ken Burns), a marker drag back to its
// origin, a crowded frame, Motion commands while another coalescing group is open, duration rounding
// at half frames and a whole-clip Ken Burns on a two-frame clip. Uses h264_1080p30.mp4 (10 s, 30 fps,
// with audio) and still.png.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>
#include <vector>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

void expectClose(double a, double b, NSString *what) {
    XCTAssertLessThanOrEqual(std::fabs(a - b), 1e-9 * std::max(1.0, std::max(std::fabs(a), std::fabs(b))), @"%@: %.12g vs %.12g",
                             what, a, b);
}

} // namespace

@interface VEEngineKeyframeReviewTests : XCTestCase
@end

@implementation VEEngineKeyframeReviewTests {
    NSURL *_scratch;
    NSURL *_cacheDir;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [_scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

- (VEAssetInfo *)import:(const char *)name into:(VEEngine *)engine {
    std::string error;
    const std::string path = ve::test::testMediaPath(name, error);
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
    return asset;
}

- (VEEngine *)engine {
    return [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
}

/// Source [inFrame, outFrame) at `atFrame` on V1 (+ A1 for media with audio); returns the video clip.
- (VEClipID)place:(VEEngine *)engine asset:(VEAssetInfo *)asset at:(int64_t)atFrame from:(int64_t)inFrame to:(int64_t)outFrame {
    VEEditResult *r = [engine overwriteAsset:asset.assetID
                                      atTime:frames30(atFrame)
                                  videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                  audioTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                    sourceIn:frames30(inFrame)
                                   sourceOut:frames30(outFrame)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    return r.createdIDs[0].longLongValue;
}

/// What every frame of the clip shows.
- (std::vector<VEVideoParams>)framesOf:(VEEngine *)engine clip:(VEClipID)clip {
    VEClipInfo *info = [engine clipInfo:clip];
    std::vector<VEVideoParams> frames;
    for (CMTime t = info.timelineStart; CMTimeCompare(t, CMTimeAdd(info.timelineStart, info.duration)) < 0;
         t = CMTimeAdd(t, frames30(1))) {
        frames.push_back([info videoParamsAtTime:t]);
    }
    return frames;
}

- (void)expect:(const std::vector<VEVideoParams> &)after equals:(const std::vector<VEVideoParams> &)before {
    XCTAssertEqual(after.size(), before.size());
    for (size_t i = 0; i < std::min(after.size(), before.size()); ++i) {
        NSString *frame = [NSString stringWithFormat:@"frame %zu", i];
        expectClose(after[i].x, before[i].x, frame);
        expectClose(after[i].y, before[i].y, frame);
        expectClose(after[i].scale, before[i].scale, frame);
        expectClose(after[i].rotationDegrees, before[i].rotationDegrees, frame);
        expectClose(after[i].opacity, before[i].opacity, frame);
    }
}

- (void)testAddingKeyframesInsideAHoldAndAnEaseKeepsEveryFrame {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    // An eased Ken Burns move over the whole clip, and rotation holding 0 then jumping to 45.
    const VEMotionFraming whole{0, 0, 1};
    const VEMotionFraming pushed{-200, 90, 1.8};
    XCTAssertTrue([engine applyKenBurnsToClip:clip start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut].ok);
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterRotation atTime:frames30(0)].ok);
    XCTAssertTrue([engine setKeyframeInterpolation:VEKeyframeInterpolationHold
                                         parameter:VEMotionParameterRotation
                                              clip:clip
                                            atTime:frames30(0)]
                      .ok);
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterRotation atTime:frames30(80)].ok);
    XCTAssertTrue([engine setMotionValue:45 parameter:VEMotionParameterRotation clip:clip atTime:frames30(80)].ok);
    const std::vector<VEVideoParams> before = [self framesOf:engine clip:clip];

    // The diamond, Control-K and a value typed equal to what the frame shows, at three frames.
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterPositionX atTime:frames30(33)].ok);
    [self expect:[self framesOf:engine clip:clip] equals:before];
    XCTAssertTrue([engine toggleMotionKeyframesOfClip:clip atTime:frames30(51)].ok);
    [self expect:[self framesOf:engine clip:clip] equals:before];
    const double shown = [[engine clipInfo:clip] videoParamsAtTime:frames30(70)].scale;
    XCTAssertTrue([engine setMotionValue:shown parameter:VEMotionParameterScale clip:clip atTime:frames30(70)].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Keyframe");
    [self expect:[self framesOf:engine clip:clip] equals:before];

    // The hold stayed a hold (the diamond at 51 reads Hold); the ease became custom parts.
    VEClipInfo *info = [engine clipInfo:clip];
    XCTAssertEqual([info keyframeForParameter:VEMotionParameterRotation atTime:frames30(51)].interpolation,
                   VEKeyframeInterpolationHold);
    XCTAssertEqual([info keyframeForParameter:VEMotionParameterPositionX atTime:frames30(33)].interpolation,
                   VEKeyframeInterpolationCustom);
    XCTAssertEqual([info keyframeForParameter:VEMotionParameterPositionX atTime:frames30(0)].interpolation,
                   VEKeyframeInterpolationCustom);
}

- (void)testAValueTypedOnASplitsLastFrameShowsExactlyAndANudgeBurstIsOneStep {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:41];
    // x linear 0 -> -150 over source frames [0, 40]: keyframes on frames 0 and 40.
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterPositionX atTime:frames30(0)].ok);
    XCTAssertTrue([engine setMotionValue:-150 parameter:VEMotionParameterPositionX clip:clip atTime:frames30(40)].ok);
    XCTAssertTrue([engine trimClipTail:clip toTime:frames30(40) clamp:NO].ok, @"the 40 frame keyframe on the out point");
    XCTAssertTrue([engine splitClip:clip atTime:frames30(20)].ok);
    // The left piece's last frame (19) shows -71.25 and owns the keyframe the split left on its out
    // point (-75 at source 20).
    VEClipInfo *left = [engine clipInfo:clip];
    XCTAssertEqual(CMTimeCompare(CMTimeAdd(left.timelineStart, left.duration), frames30(20)), 0);
    VEKeyframe *owned = [left keyframeForParameter:VEMotionParameterPositionX atTime:frames30(19)];
    XCTAssertEqual(CMTimeCompare(owned.sourceTime, frames30(20)), 0);
    expectClose([left videoParamsAtTime:frames30(19)].x, -71.25, @"before");

    // A +1 nudge of the value the inspector shows: the frame shows exactly that.
    VEEditResult *r = [engine setMotionValue:-70.25 parameter:VEMotionParameterPositionX clip:clip atTime:frames30(19)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Keyframe");
    left = [engine clipInfo:clip];
    XCTAssertEqual([left videoParamsAtTime:frames30(19)].x, -70.25);
    NSArray<VEKeyframe *> *keys = [left keyframesForParameter:VEMotionParameterPositionX];
    XCTAssertEqual(keys.count, 2u);
    XCTAssertEqual(CMTimeCompare(keys[1].sourceTime, frames30(19)), 0, @"on the frame's start");
    XCTAssertTrue([engine undo]);
    expectClose([[engine clipInfo:clip] videoParamsAtTime:frames30(19)].x, -71.25, @"undone");

    // Keyboard nudges: an Accumulate burst of three +1 steps is one undo step and lands exactly.
    [engine beginCoalescingWithKey:@"nudge" mode:VECoalescingModeAccumulate];
    for (int i = 1; i <= 3; ++i) {
        r = [engine performInCoalescingGroup:@"nudge"
                                        edit:^VEEditResult * {
                                            const double now =
                                                [[engine clipInfo:clip] videoParamsAtTime:frames30(19)].x;
                                            return [engine setMotionValue:now + 1
                                                                parameter:VEMotionParameterPositionX
                                                                     clip:clip
                                                                   atTime:frames30(19)];
                                        }];
        XCTAssertTrue(r.ok, @"%@", r.message);
    }
    [engine endCoalescing];
    expectClose([[engine clipInfo:clip] videoParamsAtTime:frames30(19)].x, -71.25 + 3, @"three nudges");
    XCTAssertTrue([engine undo]);
    expectClose([[engine clipInfo:clip] videoParamsAtTime:frames30(19)].x, -71.25, @"one undo step");
    XCTAssertEqual(CMTimeCompare([[engine clipInfo:clip] keyframesForParameter:VEMotionParameterPositionX][1].sourceTime,
                                 frames30(20)),
                   0, @"the out point's keyframe is back");
}

- (void)testAValueTypedOnAFrameOfASpedUpClipShowsExactly {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterPositionY atTime:frames30(0)].ok);
    XCTAssertTrue([engine setMotionValue:100 parameter:VEMotionParameterPositionY clip:clip atTime:frames30(16)].ok);
    XCTAssertTrue([engine setMotionValue:200 parameter:VEMotionParameterPositionY clip:clip atTime:frames30(60)].ok);
    // At 1.5x source frame 16 plays inside timeline frame 10 (source [15, 16.5)), not on its start.
    VEEditResult *speed = [engine setSpeedNumerator:3 denominator:2 forClip:clip];
    XCTAssertTrue(speed.ok, @"%@", speed.message);
    VEClipInfo *info = [engine clipInfo:clip];
    VEKeyframe *owned = [info keyframeForParameter:VEMotionParameterPositionY atTime:frames30(10)];
    XCTAssertEqual(CMTimeCompare(owned.sourceTime, frames30(16)), 0);
    const double shown = [info videoParamsAtTime:frames30(10)].y;
    XCTAssertLessThan(shown, 100);
    XCTAssertTrue([engine setMotionValue:shown + 1 parameter:VEMotionParameterPositionY clip:clip atTime:frames30(10)].ok);
    XCTAssertEqual([[engine clipInfo:clip] videoParamsAtTime:frames30(10)].y, shown + 1);
}

- (void)testAnUnknownMotionParameterIsRefusedNotTreatedAsPositionX {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:30];
    const auto unknown = static_cast<VEMotionParameter>(42);
    VEEditResult *r = [engine addKeyframeToClip:clip parameter:unknown atTime:frames30(5)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"not a Motion parameter"], @"%@", r.message);
    XCTAssertEqual([engine setMotionValue:3 parameter:unknown clip:clip atTime:frames30(5)].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine removeAnimationFromClip:clip parameter:unknown atTime:frames30(5)].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertFalse([engine clipInfo:clip].hasKeyframes, @"nothing reached Position X");
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterPositionX atTime:frames30(5)].ok);
    VEClipInfo *info = [engine clipInfo:clip];
    XCTAssertFalse([info isAnimated:unknown]);
    XCTAssertEqual([info keyframesForParameter:unknown].count, 0u);
    XCTAssertNil([info keyframeForParameter:unknown atTime:frames30(5)]);
}

- (void)testAStillsKeyframesKenBurnsAndHeadTrims {
    VEEngine *engine = [self engine];
    VEAssetInfo *still = [self import:"still.png" into:engine];
    VEEditResult *placed = [engine overwriteAsset:still.assetID
                                           atTime:frames30(30)
                                       videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                       audioTrack:0
                                         sourceIn:kCMTimeZero
                                        sourceOut:frames30(90)];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    const VEClipID clip = placed.createdIDs[0].longLongValue;
    XCTAssertEqual(CMTimeCompare([engine clipInfo:clip].duration, frames30(90)), 0);

    // Ken Burns over the whole still: keyframes on its first and last frames.
    const VEMotionFraming whole{0, 0, 1};
    const VEMotionFraming pushed{100, -50, 2};
    XCTAssertTrue([engine applyKenBurnsToClip:clip start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut].ok);
    NSArray<VEKeyframe *> *scale = [[engine clipInfo:clip] keyframesForParameter:VEMotionParameterScale];
    XCTAssertEqual(scale.count, 2u);
    XCTAssertEqual(CMTimeCompare(scale[0].frameTime, frames30(30)), 0);
    XCTAssertEqual(CMTimeCompare(scale[1].frameTime, frames30(119)), 0);
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterOpacity atTime:frames30(60)].ok);
    const std::vector<VEVideoParams> before = [self framesOf:engine clip:clip];

    // Head trims forward and back: every remaining frame keeps its picture on the timeline.
    XCTAssertTrue([engine trimClipHead:clip toTime:frames30(50) clamp:NO].ok);
    std::vector<VEVideoParams> after = [self framesOf:engine clip:clip];
    [self expect:after equals:std::vector<VEVideoParams>(before.begin() + 20, before.end())];
    XCTAssertTrue([engine trimClipHead:clip toTime:frames30(30) clamp:NO].ok);
    [self expect:[self framesOf:engine clip:clip] equals:before];
    // Past every keyframe but the last, then extended again: the hidden ones come back.
    XCTAssertTrue([engine trimClipHead:clip toTime:frames30(118) clamp:NO].ok);
    XCTAssertFalse([[engine clipInfo:clip] keyframesForParameter:VEMotionParameterScale][0].isInsideClip);
    XCTAssertTrue([engine trimClipHead:clip toTime:frames30(30) clamp:NO].ok);
    [self expect:[self framesOf:engine clip:clip] equals:before];
    // Undo of each trim restores the same pictures.
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine undo]);
    [self expect:[self framesOf:engine clip:clip] equals:before];

    // A split on a keyframe's frame: both pieces show what the still showed.
    VEEditResult *split = [engine splitClip:clip atTime:frames30(60)];
    XCTAssertTrue(split.ok, @"%@", split.message);
    const VEClipID right = split.createdIDs[0].longLongValue;
    std::vector<VEVideoParams> pieces = [self framesOf:engine clip:clip];
    const std::vector<VEVideoParams> rightFrames = [self framesOf:engine clip:right];
    pieces.insert(pieces.end(), rightFrames.begin(), rightFrames.end());
    [self expect:pieces equals:before];
}

- (void)testAMarkerDragBackToItsOriginLeavesNoUndoStep {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterScale atTime:frames30(40)].ok);
    NSString *undoBefore = engine.undoActionName;
    const BOOL couldUndo = engine.canUndo;
    [engine beginCoalescingWithKey:@"marker"];
    for (int64_t frame : {45, 52, 40}) {
        VEEditResult *r = [engine performInCoalescingGroup:@"marker"
                                                      edit:^VEEditResult * {
                                                          return [engine moveKeyframeGroupOfClip:clip
                                                                                        fromTime:frames30(40)
                                                                                          toTime:frames30(frame)];
                                                      }];
        XCTAssertTrue(r.ok, @"%@", r.message);
    }
    [engine endCoalescing];
    XCTAssertEqualObjects(engine.undoActionName, undoBefore, @"the drag back to its origin is no step");
    XCTAssertEqual(engine.canUndo, couldUndo);
    VEKeyframe *key = [[engine clipInfo:clip] keyframesForParameter:VEMotionParameterScale].firstObject;
    XCTAssertEqual(CMTimeCompare(key.frameTime, frames30(40)), 0);
}

- (void)testACrowdedFrameCannotBeMovedAndSaysWhy {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterRotation atTime:frames30(30)].ok);
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterRotation atTime:frames30(31)].ok);
    // At 3x both source frames play inside timeline frame 10.
    XCTAssertTrue([engine setSpeedNumerator:3 denominator:1 forClip:clip].ok);
    VEKeyframeGroup *group = [engine keyframeGroupOfClip:clip atTime:frames30(10)];
    XCTAssertNotNil(group);
    XCTAssertFalse(group.canMove);
    XCTAssertTrue([group.reason containsString:@"several Rotation keyframes"], @"%@", group.reason);
    VEEditResult *r = [engine moveKeyframeGroupOfClip:clip fromTime:frames30(10) toTime:frames30(12)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
}

- (void)testMotionCommandsWithAnotherGroupOpenCommitItFirst {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    const VEClipID next = [self place:engine asset:asset at:90 from:0 to:30];
    XCTAssertTrue([engine addKeyframeToClip:clip parameter:VEMotionParameterScale atTime:frames30(0)].ok);
    NSArray<VEEditResult * (^)(void)> *commands = @[
        ^VEEditResult * {
            return [engine toggleMotionKeyframesOfClip:clip atTime:frames30(20)];
        },
        ^VEEditResult * {
            const VEMotionFraming whole{0, 0, 1};
            const VEMotionFraming pushed{10, 10, 1.2};
            return [engine applyKenBurnsToClip:clip start:whole end:pushed interpolation:VEKeyframeInterpolationEaseInOut];
        },
        ^VEEditResult * {
            return [engine matchMotionOfClip:next toAdjacentAtEdge:VEClipEdgeStart];
        },
        ^VEEditResult * {
            return [engine removeAnimationFromClip:clip parameter:VEMotionParameterScale atTime:frames30(10)];
        },
    ];
    __block double opacity = 1.0;
    for (VEEditResult * (^command)(void) in commands) {
        opacity -= 0.1; // a real change each time
        [engine beginCoalescingWithKey:@"slider"];
        VEEditResult *step = [engine performInCoalescingGroup:@"slider"
                                                         edit:^VEEditResult * {
                                                             return [engine setMotionValue:opacity
                                                                                 parameter:VEMotionParameterOpacity
                                                                                      clip:clip
                                                                                    atTime:frames30(5)];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
        NSString *stepName = engine.undoActionName;
        VEEditResult *r = command();
        XCTAssertTrue(r.ok, @"%@", r.message);
        XCTAssertFalse(engine.isCoalescing, @"the command committed the open group first");
        NSString *commandName = engine.undoActionName;
        XCTAssertNotEqualObjects(commandName, stepName, @"its own undo step");
        XCTAssertEqual([engine performInCoalescingGroup:@"slider"
                                                   edit:^VEEditResult * {
                                                       return [engine setMotionValue:opacity / 2
                                                                           parameter:VEMotionParameterOpacity
                                                                                clip:clip
                                                                              atTime:frames30(5)];
                                                   }]
                           .errorCode,
                       VEEditErrorBusy, @"the gesture's later steps are refused");
        // Undo takes back the command, then the gesture's step, separately.
        XCTAssertTrue([engine undo]);
        XCTAssertEqualObjects(engine.undoActionName, stepName);
        XCTAssertTrue([engine redo]);
    }
}

- (void)testKenBurnsDurationsRoundToWholeFramesAndATwoFrameClipTakesAWholeMove {
    VEEngine *engine = [self engine];
    VEAssetInfo *asset = [self import:"h264_1080p30.mp4" into:engine];
    const VEClipID clip = [self place:engine asset:asset at:0 from:0 to:90];
    const VEMotionFraming start{0, 0, 1};
    const VEMotionFraming end{50, 20, 1.5};
    // 2.5 frames round up (halves go toward +infinity): the end keyframe on frame 12 of 10, 11, 12.
    VEEditResult *r = [engine applyKenBurnsToClip:clip
                                            start:start
                                              end:end
                                    interpolation:VEKeyframeInterpolationLinear
                                       rangeStart:frames30(10)
                                         duration:CMTimeMake(5, 60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    NSArray<VEKeyframe *> *x = [[engine clipInfo:clip] keyframesForParameter:VEMotionParameterPositionX];
    XCTAssertEqual(x.count, 2u);
    XCTAssertEqual(CMTimeCompare(x[1].frameTime, frames30(12)), 0);
    // 1.5 frames round to two: the smallest move.
    r = [engine applyKenBurnsToClip:clip
                              start:start
                                end:end
                      interpolation:VEKeyframeInterpolationLinear
                         rangeStart:frames30(40)
                           duration:CMTimeMake(3, 60)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    // Just under 1.5 frames rounds to one: refused.
    r = [engine applyKenBurnsToClip:clip
                              start:start
                                end:end
                      interpolation:VEKeyframeInterpolationLinear
                         rangeStart:frames30(60)
                           duration:CMTimeMake(149, 3000)];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);

    const VEClipID pair = [self place:engine asset:asset at:200 from:0 to:2];
    r = [engine applyKenBurnsToClip:pair start:start end:end interpolation:VEKeyframeInterpolationEaseInOut];
    XCTAssertTrue(r.ok, @"%@", r.message);
    VEClipInfo *info = [engine clipInfo:pair];
    XCTAssertEqual([info videoParamsAtTime:frames30(200)].x, 0);
    XCTAssertEqual([info videoParamsAtTime:frames30(201)].x, 50);
}

@end
