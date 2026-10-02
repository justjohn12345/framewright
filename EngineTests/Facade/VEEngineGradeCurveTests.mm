// The facade's curves (VEEngine (Grade) setGradeCurvePoints:forCurve:clips:, resetGradeCurvesOfClips:,
// VEGradeCurveInfo, VEGradeCurveSample, VEGradeSelection's curves, VEClipInfo.gradeCurvePoints): a curve set
// on a selection (linked sound left out) keeping the rest, mixed and agreeing curves, a point drag in one
// coalescing group, Copy/Paste/Reset carrying the curves, refusals, and curves kept through save and open.
// Uses h264_1080p30.mp4.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

NSArray<NSValue *> *pointsOf(std::initializer_list<std::pair<double, double>> points) {
    NSMutableArray<NSValue *> *values = [NSMutableArray array];
    for (const auto &[x, y] : points) {
        [values addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
    }
    return values;
}

} // namespace

@interface VEEngineGradeCurveTests : XCTestCase
@end

@implementation VEEngineGradeCurveTests {
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

- (std::pair<VEClipID, VEClipID>)place:(VEEngine *)engine asset:(VEAssetInfo *)asset at:(int64_t)atFrame {
    VEEditResult *r = [engine overwriteAsset:asset.assetID
                                      atTime:frames30(atFrame)
                                  videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                  audioTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                    sourceIn:frames30(atFrame)
                                   sourceOut:frames30(atFrame + 30)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    return {r.createdIDs[0].longLongValue, r.createdIDs[1].longLongValue};
}

- (void)testTheCurveTableAndSampling {
    XCTAssertEqualObjects(VEGradeCurveInfo.allCurves, (@[ @0, @1, @2, @3 ]));
    XCTAssertEqual(VEGradeCurveInfo.maximumPointCount, 16);
    XCTAssertEqualObjects([VEGradeCurveInfo infoForCurve:VEGradeCurveLuma].name, @"curveLuma");
    XCTAssertEqualObjects([VEGradeCurveInfo infoForCurve:VEGradeCurveBlue].displayName, @"Blue");
    XCTAssertNil([VEGradeCurveInfo infoForCurve:static_cast<VEGradeCurve>(4)]);
    double samples[5] = {};
    VEGradeCurveSample(@[], samples, 5);
    XCTAssertEqual(samples[2], 0.5, @"no points: the identity");
    VEGradeCurveSample(pointsOf({{0, 1}, {1, 0}}), samples, 5);
    XCTAssertEqualWithAccuracy(samples[1], 0.75, 1e-12);
    // Points out of order and out of range are made valid first.
    VEGradeCurveSample(pointsOf({{1, 2}, {0, 0.2}}), samples, 3);
    XCTAssertEqualWithAccuracy(samples[0], 0.2, 1e-12);
    XCTAssertEqualWithAccuracy(samples[2], 1.0, 1e-12);
}

- (void)testACurveOnASelectionMixedAndADrag {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    NSArray<NSValue *> *sCurve = pointsOf({{0, 0}, {0.3, 0.2}, {0.7, 0.85}, {1, 1}});
    VEEditResult *r = [engine setGradeCurvePoints:sCurve
                                         forCurve:VEGradeCurveLuma
                                            clips:@[ @(first.first), @(first.second), @(second.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Luma Curve");
    XCTAssertEqualObjects([[engine clipInfo:first.first] gradeCurvePoints:VEGradeCurveLuma], sCurve);
    XCTAssertTrue([engine clipInfo:second.first].hasGrade);
    XCTAssertFalse([engine clipInfo:first.second].hasGrade, @"the linked sound is left out");
    XCTAssertEqualObjects([[engine clipInfo:first.first] gradeCurvePoints:VEGradeCurveRed], @[]);
    NSArray<NSNumber *> *both = @[ @(first.first), @(second.first) ];
    VEGradeSelection *selection = [engine gradeOfClips:both];
    XCTAssertEqualObjects([selection pointsForCurve:VEGradeCurveLuma], sCurve);
    XCTAssertFalse([selection isCurveMixed:VEGradeCurveLuma]);
    XCTAssertTrue([engine setGradeCurvePoints:pointsOf({{0, 0.1}, {1, 1}}) forCurve:VEGradeCurveRed clips:@[ @(second.first) ]].ok);
    selection = [engine gradeOfClips:both];
    XCTAssertTrue([selection isCurveMixed:VEGradeCurveRed]);
    XCTAssertNil([selection pointsForCurve:VEGradeCurveRed]);
    XCTAssertEqualObjects([selection pointsForCurve:VEGradeCurveGreen], @[]);
    XCTAssertNil([selection pointsForCurve:static_cast<VEGradeCurve>(8)]);

    // A point dragged: one undo step.
    NSString *key = @"grade.curve.green";
    [engine beginCoalescingWithKey:key];
    for (const double y : {0.55, 0.6, 0.7}) {
        NSArray<NSValue *> *points = pointsOf({{0, 0}, {0.5, y}, {1, 1}});
        VEEditResult *step = [engine performInCoalescingGroup:key
                                                         edit:^VEEditResult * {
                                                             return [engine setGradeCurvePoints:points
                                                                                       forCurve:VEGradeCurveGreen
                                                                                          clips:both];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
    }
    [engine endCoalescing];
    XCTAssertEqualObjects(engine.undoActionName, @"Change Green Curve");
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects([[engine clipInfo:second.first] gradeCurvePoints:VEGradeCurveGreen], @[]);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Red Curve", @"the drag was one step");
    // An identity curve is no curve.
    XCTAssertTrue([engine setGradeCurvePoints:pointsOf({{0, 0}, {1, 1}}) forCurve:VEGradeCurveLuma clips:both].ok);
    XCTAssertEqualObjects([[engine clipInfo:first.first] gradeCurvePoints:VEGradeCurveLuma], @[]);
    XCTAssertFalse([engine clipInfo:first.first].hasGrade);
}

- (void)testCopyPasteResetAndRefusals {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    NSArray<NSValue *> *lifted = pointsOf({{0, 0.15}, {1, 0.9}});
    XCTAssertTrue([engine setGradeCurvePoints:lifted forCurve:VEGradeCurveBlue clips:@[ @(first.first) ]].ok);
    XCTAssertTrue([engine copyGradeOfClip:first.first]);
    XCTAssertTrue([engine pasteGradeOntoClips:@[ @(second.first) ]].ok);
    XCTAssertEqualObjects([[engine clipInfo:second.first] gradeCurvePoints:VEGradeCurveBlue], lifted);
    NSArray<NSNumber *> *both = @[ @(first.first), @(second.first) ];
    XCTAssertTrue([engine setGradeValue:-0.5 forParameter:VEGradeParameterExposure clips:both].ok);
    XCTAssertTrue([engine resetGradeCurvesOfClips:both].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Reset Curves");
    XCTAssertEqualObjects([[engine clipInfo:second.first] gradeCurvePoints:VEGradeCurveBlue], @[]);
    XCTAssertEqual([engine clipInfo:second.first].grade.exposure, -0.5, @"the rest of the grade stays");
    const uint64_t afterReset = engine.changeCount;
    XCTAssertTrue([engine resetGradeCurvesOfClips:both].ok);
    XCTAssertEqual(engine.changeCount, afterReset, @"nothing to reset: no undo step");

    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine setGradeCurvePoints:pointsOf({{0.5, 0.5}}) forCurve:VEGradeCurveLuma clips:both];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"The Luma curve is not valid"], @"%@", r.message);
    r = [engine setGradeCurvePoints:pointsOf({{0.6, 0}, {0.4, 1}}) forCurve:VEGradeCurveLuma clips:both];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeCurvePoints:pointsOf({{0, 0}, {1, 1.5}}) forCurve:VEGradeCurveLuma clips:both];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeCurvePoints:lifted forCurve:static_cast<VEGradeCurve>(9) clips:both];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeCurvePoints:lifted forCurve:VEGradeCurveLuma clips:@[ @(first.second) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertEqual(engine.changeCount, before);
}

- (void)testHueCurves {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    NSArray<NSNumber *> *both = @[ @(first.first), @(second.first) ];
    NSArray<NSValue *> *pale = pointsOf({{0.2, 0.5}, {0.29, 0.1}, {0.4, 0.5}});
    VEEditResult *r = [engine setGradeHueCurvePoints:pale forHueCurve:VEGradeHueCurveSaturation clips:both];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Hue vs Saturation Curve");
    XCTAssertEqualObjects([[engine clipInfo:second.first] gradeHueCurvePoints:VEGradeHueCurveSaturation], pale);
    XCTAssertEqualObjects([[engine gradeOfClips:both] pointsForHueCurve:VEGradeHueCurveSaturation], pale);
    XCTAssertTrue([engine setGradeHueCurvePoints:pointsOf({{0.5, 0.8}}) forHueCurve:VEGradeHueCurveLuma clips:@[ @(first.first) ]].ok);
    XCTAssertTrue([[engine gradeOfClips:both] isHueCurveMixed:VEGradeHueCurveLuma]);
    XCTAssertNil([[engine gradeOfClips:both] pointsForHueCurve:VEGradeHueCurveLuma]);
    XCTAssertEqual([engine setGradeHueCurvePoints:pointsOf({{1.0, 0.2}}) forHueCurve:VEGradeHueCurveHue clips:both].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setGradeHueCurvePoints:pale forHueCurve:static_cast<VEGradeHueCurve>(5) clips:both].errorCode,
                   VEEditErrorInvalidArgument);
    double samples[4] = {};
    VEGradeHueCurveSample(pointsOf({{0.25, 1.0}}), samples, 4);
    XCTAssertEqual(samples[2], 1.0, @"one point: a constant");
    VEGradeHueCurveSample(@[], samples, 4);
    XCTAssertEqual(samples[1], 0.5, @"no points: no change");
    // Reset Curves takes the hue curves too.
    XCTAssertTrue([engine resetGradeCurvesOfClips:both].ok);
    XCTAssertEqualObjects([[engine clipInfo:first.first] gradeHueCurvePoints:VEGradeHueCurveLuma], @[]);
    XCTAssertFalse([engine clipInfo:second.first].hasGrade);
}

- (void)testCurvesAreSavedAndOpened {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto pair = [self place:engine asset:asset at:0];
    NSArray<NSValue *> *sCurve = pointsOf({{0, 0}, {0.25, 0.2}, {0.75, 0.8}, {1, 1}});
    XCTAssertTrue([engine setGradeCurvePoints:sCurve forCurve:VEGradeCurveGreen clips:@[ @(pair.first) ]].ok);
    NSURL *file = [_scratch URLByAppendingPathComponent:@"curves.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue([text containsString:@"\"curveGreen\""], @"%@", text);
    XCTAssertFalse([text containsString:@"curveLuma"]);
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([reopened openProjectAtURL:file error:&error], @"%@", error);
    XCTAssertEqualObjects([[reopened clipInfo:pair.first] gradeCurvePoints:VEGradeCurveGreen], sCurve);
}

@end
