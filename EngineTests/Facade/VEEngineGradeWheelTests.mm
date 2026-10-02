// The facade's colour wheels (VEEngine (Grade) setGradeWheel:forWheel:clips:, VEGradeWheelInfo,
// VEGradeSelection's wheels, VEClipInfo.gradeWheel): a wheel set on a selection (linked sound left out)
// keeping the other values, mixed and agreeing wheels, a drag in one coalescing group, Copy/Paste/Reset Grade
// carrying the wheels, refusals, and wheels kept through save and open. Uses h264_1080p30.mp4.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

VEGradeWheelValue wheelValue(double level, double cb, double cr) {
    return VEGradeWheelValue{level, cb, cr};
}

bool sameWheel(VEGradeWheelValue a, VEGradeWheelValue b) {
    return a.level == b.level && a.cb == b.cb && a.cr == b.cr;
}

} // namespace

@interface VEEngineGradeWheelTests : XCTestCase
@end

@implementation VEEngineGradeWheelTests {
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

- (void)testTheWheelTable {
    XCTAssertEqualObjects(VEGradeWheelInfo.allWheels, (@[ @0, @1, @2 ]));
    VEGradeWheelInfo *lift = [VEGradeWheelInfo infoForWheel:VEGradeWheelLift];
    XCTAssertEqualObjects(lift.name, @"lift");
    XCTAssertEqualObjects(lift.displayName, @"Lift");
    XCTAssertEqualObjects(lift.tonalRange, @"shadows");
    XCTAssertEqualObjects([VEGradeWheelInfo infoForWheel:VEGradeWheelGain].tonalRange, @"highlights");
    XCTAssertNil([VEGradeWheelInfo infoForWheel:static_cast<VEGradeWheel>(3)]);
    XCTAssertTrue(sameWheel(VEGradeWheelValueNeutral(), wheelValue(0, 0, 0)));
}

- (void)testAWheelOnASelectionKeepsTheRestAndADragIsOneStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    XCTAssertTrue([engine setGradeValue:0.5 forParameter:VEGradeParameterExposure clips:@[ @(first.first) ]].ok);
    const VEGradeWheelValue warm{0.25, -0.2, 0.4};
    VEEditResult *r = [engine setGradeWheel:warm
                                   forWheel:VEGradeWheelGain
                                      clips:@[ @(first.first), @(first.second), @(second.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Gain");
    XCTAssertTrue(sameWheel([[engine clipInfo:first.first] gradeWheel:VEGradeWheelGain], warm));
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelGain], warm));
    XCTAssertEqual([engine clipInfo:first.first].grade.exposure, 0.5, @"kept");
    XCTAssertTrue([engine clipInfo:second.first].hasGrade, @"a wheel alone is a grade");
    XCTAssertFalse([engine clipInfo:first.second].hasGrade, @"the linked sound is left out");

    NSArray<NSNumber *> *clipsOfBoth = @[ @(first.first), @(second.first) ];
    // Agreeing and mixed.
    VEGradeSelection *selection = [engine gradeOfClips:@[ @(first.first), @(second.first) ]];
    XCTAssertTrue(sameWheel([selection valueForWheel:VEGradeWheelGain], warm));
    XCTAssertFalse([selection isWheelMixed:VEGradeWheelGain]);
    XCTAssertTrue(selection.identical == NO, @"their exposures differ");
    XCTAssertTrue([engine setGradeWheel:wheelValue(0, 0.5, 0) forWheel:VEGradeWheelLift clips:@[ @(second.first) ]].ok);
    selection = [engine gradeOfClips:@[ @(first.first), @(second.first) ]];
    XCTAssertTrue([selection isWheelMixed:VEGradeWheelLift]);
    XCTAssertTrue(std::isnan([selection valueForWheel:VEGradeWheelLift].cb));
    XCTAssertTrue(std::isnan([selection valueForWheel:static_cast<VEGradeWheel>(5)].level));
    XCTAssertFalse([selection isWheelMixed:static_cast<VEGradeWheel>(5)]);

    // The colour alone over clips of different levels keeps each level; the level alone keeps each colour.
    XCTAssertTrue([engine setGradeWheel:wheelValue(0.5, 0, 0) forWheel:VEGradeWheelLift clips:@[ @(first.first) ]].ok);
    XCTAssertTrue([engine setGradeWheel:wheelValue(NAN, -0.3, 0.3) forWheel:VEGradeWheelLift clips:clipsOfBoth].ok);
    XCTAssertTrue(sameWheel([[engine clipInfo:first.first] gradeWheel:VEGradeWheelLift], wheelValue(0.5, -0.3, 0.3)));
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelLift], wheelValue(0, -0.3, 0.3)));
    XCTAssertTrue([engine setGradeWheel:wheelValue(-0.2, NAN, NAN) forWheel:VEGradeWheelLift clips:clipsOfBoth].ok);
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelLift], wheelValue(-0.2, -0.3, 0.3)));

    // A drag over both clips: one undo step.
    NSArray<NSNumber *> *clips = @[ @(first.first), @(second.first) ];
    NSString *key = @"grade.wheel.gamma";
    [engine beginCoalescingWithKey:key];
    for (const double cr : {0.1, 0.3, 0.6}) {
        VEEditResult *step = [engine performInCoalescingGroup:key
                                                         edit:^VEEditResult * {
                                                             return [engine setGradeWheel:wheelValue(0.1, 0, cr)
                                                                                 forWheel:VEGradeWheelGamma
                                                                                    clips:clips];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
    }
    [engine endCoalescing];
    XCTAssertEqual([[engine clipInfo:second.first] gradeWheel:VEGradeWheelGamma].cr, 0.6);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Gamma");
    XCTAssertTrue([engine undo]);
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelGamma], VEGradeWheelValueNeutral()));
    XCTAssertEqualObjects(engine.undoActionName, @"Change Lift", @"the drag was one step");
}

- (void)testCopyPasteResetAndRefusals {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    XCTAssertTrue([engine setGradeWheel:wheelValue(-0.3, 0.1, 0.1) forWheel:VEGradeWheelLift clips:@[ @(first.first) ]].ok);
    XCTAssertTrue([engine copyGradeOfClip:first.first]);
    XCTAssertTrue([engine pasteGradeOntoClips:@[ @(second.first) ]].ok);
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelLift], wheelValue(-0.3, 0.1, 0.1)));
    NSArray<NSNumber *> *both = @[ @(first.first), @(second.first) ];
    XCTAssertTrue([engine gradeOfClips:both].identical);
    // Reset Wheels keeps the basic values.
    XCTAssertTrue([engine setGradeValue:0.25 forParameter:VEGradeParameterExposure clips:both].ok);
    XCTAssertTrue([engine resetGradeWheelsOfClips:both].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Reset Wheels");
    XCTAssertTrue(sameWheel([[engine clipInfo:second.first] gradeWheel:VEGradeWheelLift], VEGradeWheelValueNeutral()));
    XCTAssertEqual([engine clipInfo:second.first].grade.exposure, 0.25);
    const uint64_t afterWheels = engine.changeCount;
    XCTAssertTrue([engine resetGradeWheelsOfClips:both].ok);
    XCTAssertEqual(engine.changeCount, afterWheels, @"nothing to reset: no undo step");
    XCTAssertTrue([engine resetGradeOfClips:both].ok);
    XCTAssertFalse([engine clipInfo:first.first].hasGrade);
    XCTAssertFalse([engine clipInfo:second.first].hasGrade);

    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine setGradeWheel:wheelValue(1.5, 0, 0) forWheel:VEGradeWheelGain clips:@[ @(first.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"The Gain wheel's level must be a number from -1 to 1"], @"%@", r.message);
    r = [engine setGradeWheel:wheelValue(0, 0.8, 0.8) forWheel:VEGradeWheelGain clips:@[ @(first.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeWheel:wheelValue(NAN, NAN, NAN) forWheel:VEGradeWheelGain clips:@[ @(first.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument, @"nothing to set");
    r = [engine setGradeWheel:wheelValue(NAN, 0.2, NAN) forWheel:VEGradeWheelGain clips:@[ @(first.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument, @"half a colour");
    r = [engine setGradeWheel:wheelValue(0.1, 0, 0) forWheel:static_cast<VEGradeWheel>(4) clips:@[ @(first.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeWheel:wheelValue(0.1, 0, 0) forWheel:VEGradeWheelLift clips:@[ @(first.second) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertEqual(engine.changeCount, before);
}

- (void)testWheelsAreSavedAndOpened {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto pair = [self place:engine asset:asset at:0];
    XCTAssertTrue([engine setGradeWheel:wheelValue(0.4, -0.6, 0.8) forWheel:VEGradeWheelGamma clips:@[ @(pair.first) ]].ok);
    NSURL *file = [_scratch URLByAppendingPathComponent:@"wheels.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue([text containsString:@"\"gammaLevel\": 0.4"], @"%@", text);
    XCTAssertTrue([text containsString:@"\"gammaCb\": -0.6"]);
    XCTAssertFalse([text containsString:@"liftLevel"], @"neutral wheels are not written");
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([reopened openProjectAtURL:file error:&error], @"%@", error);
    XCTAssertTrue(sameWheel([[reopened clipInfo:pair.first] gradeWheel:VEGradeWheelGamma], wheelValue(0.4, -0.6, 0.8)));
    XCTAssertTrue([reopened clipInfo:pair.first].hasGrade);
}

@end
