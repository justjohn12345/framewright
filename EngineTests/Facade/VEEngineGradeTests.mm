// The facade's grade API (VEEngine (Grade)): VEClipInfo.grade, setting parameters on a selection
// (linked sound left out), the mixed query, Copy/Paste/Reset Grade, one undo step each and a control
// drag in one coalescing group, the parameter table, refusals, and grades kept through save and open.
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

} // namespace

@interface VEEngineGradeTests : XCTestCase
@end

@implementation VEEngineGradeTests {
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

/// Places source [inFrame, outFrame) at `atFrame` on V1 + A1 (linked); returns (video, audio).
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

- (void)assertGrade:(VEGradeParams)grade equals:(VEGradeParams)expected {
    for (NSNumber *number in VEGradeParameterInfo.allParameters) {
        const auto parameter = static_cast<VEGradeParameter>(number.integerValue);
        XCTAssertEqual(VEGradeParamsGetValue(grade, parameter), VEGradeParamsGetValue(expected, parameter), @"%@",
                       [VEGradeParameterInfo infoForParameter:parameter].displayName);
    }
}

// MARK: - The parameter table

- (void)testTheParameterTableComesFromTheEngine {
    NSArray<NSNumber *> *all = VEGradeParameterInfo.allParameters;
    XCTAssertEqualObjects(all, (@[ @0, @1, @2, @3, @4 ]));
    VEGradeParameterInfo *exposure = [VEGradeParameterInfo infoForParameter:VEGradeParameterExposure];
    XCTAssertEqualObjects(exposure.name, @"exposure");
    XCTAssertEqualObjects(exposure.displayName, @"Exposure");
    XCTAssertEqualObjects(exposure.unit, @"stops");
    XCTAssertEqual(exposure.neutralValue, 0);
    XCTAssertEqual(exposure.minimum, -5);
    XCTAssertEqual(exposure.maximum, 5);
    VEGradeParameterInfo *saturation = [VEGradeParameterInfo infoForParameter:VEGradeParameterSaturation];
    XCTAssertEqualObjects(saturation.unit, @"×");
    XCTAssertEqual(saturation.neutralValue, 1);
    XCTAssertEqualObjects([VEGradeParameterInfo infoForParameter:VEGradeParameterTint].unit, @"");
    XCTAssertNil([VEGradeParameterInfo infoForParameter:static_cast<VEGradeParameter>(7)]);
    // The accessors name every field once.
    VEGradeParams params = VEGradeParamsUnchanged();
    for (NSNumber *number in all) {
        const auto parameter = static_cast<VEGradeParameter>(number.integerValue);
        XCTAssertTrue(std::isnan(VEGradeParamsGetValue(params, parameter)));
        VEGradeParamsSetValue(&params, 10 + number.doubleValue, parameter);
    }
    XCTAssertEqual(params.exposure, 10);
    XCTAssertEqual(params.contrast, 11);
    XCTAssertEqual(params.temperature, 12);
    XCTAssertEqual(params.tint, 13);
    XCTAssertEqual(params.saturation, 14);
    XCTAssertTrue(std::isnan(VEGradeParamsGetValue(params, static_cast<VEGradeParameter>(-1))));
    const VEGradeParams neutral = VEGradeParamsNeutral();
    XCTAssertEqual(neutral.exposure, 0);
    XCTAssertEqual(neutral.contrast, 1);
    XCTAssertEqual(neutral.saturation, 1);
}

// MARK: - Setting, mixed, undo

- (void)testSettingOneParameterOnASelectionKeepsTheOthersAndIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0 from:0 to:30];
    const auto second = [self place:engine asset:asset at:30 from:60 to:90];
    XCTAssertFalse([engine clipInfo:first.first].hasGrade);
    [self assertGrade:[engine clipInfo:first.first].grade equals:VEGradeParamsNeutral()];

    // Different exposures first.
    XCTAssertTrue([engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[ @(first.first) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Exposure");
    XCTAssertTrue([engine setGradeValue:-1 forParameter:VEGradeParameterExposure clips:@[ @(second.first) ]].ok);
    VEGradeSelection *selection = [engine gradeOfClips:@[ @(first.first), @(first.second), @(second.first) ]];
    XCTAssertEqualObjects(selection.clipIDs, (@[ @(first.first), @(second.first) ]), @"the sound is left out");
    XCTAssertTrue([selection isMixed:VEGradeParameterExposure]);
    XCTAssertTrue(std::isnan(selection.values.exposure));
    XCTAssertFalse([selection isMixed:VEGradeParameterSaturation]);
    XCTAssertEqual(selection.values.saturation, 1);
    XCTAssertTrue(selection.anyGraded);
    XCTAssertFalse(selection.identical, @"different exposures");
    XCTAssertTrue(([engine gradeOfClips:@[ @(first.first), @(first.second) ]].identical), @"one clip (its sound left out)");
    XCTAssertFalse([engine gradeOfClips:@[ @(first.second) ]].identical, @"no clip that can have a grade");

    // A multi-clip set of saturation, the linked sound in the selection: one undo step, exposures kept.
    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine setGradeValue:0.5
                               forParameter:VEGradeParameterSaturation
                                      clips:@[ @(first.first), @(first.second), @(second.first), @(second.second) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(engine.changeCount, before + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Saturation");
    XCTAssertEqual([engine clipInfo:first.first].grade.saturation, 0.5);
    XCTAssertEqual([engine clipInfo:second.first].grade.saturation, 0.5);
    XCTAssertEqual([engine clipInfo:first.first].grade.exposure, 1);
    XCTAssertEqual([engine clipInfo:second.first].grade.exposure, -1);
    XCTAssertFalse([engine clipInfo:first.second].hasGrade, @"sound has no grade");
    selection = [engine gradeOfClips:@[ @(first.first), @(second.first) ]];
    XCTAssertFalse([selection isMixed:VEGradeParameterSaturation]);
    XCTAssertEqual(selection.values.saturation, 0.5);
    XCTAssertFalse(selection.identical, @"the exposures still differ");
    XCTAssertTrue([engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[ @(second.first) ]].ok);
    XCTAssertTrue(([engine gradeOfClips:@[ @(first.first), @(second.first) ]].identical), @"every value agrees");
    XCTAssertTrue([engine undo]);

    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:first.first].grade.saturation, 1);
    XCTAssertEqual([engine clipInfo:second.first].grade.saturation, 1);
    XCTAssertTrue([engine redo]);
    XCTAssertEqual([engine clipInfo:second.first].grade.saturation, 0.5);

    // Several fields at once; NaN fields unchanged.
    VEGradeParams values = VEGradeParamsUnchanged();
    values.temperature = 40;
    values.tint = -10;
    XCTAssertTrue([engine setGradeValues:values forClips:@[ @(first.first) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Grade");
    XCTAssertEqual([engine clipInfo:first.first].grade.temperature, 40);
    XCTAssertEqual([engine clipInfo:first.first].grade.tint, -10);
    XCTAssertEqual([engine clipInfo:first.first].grade.exposure, 1);
}

- (void)testAControlDragIsOneUndoStep {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0 from:0 to:30];
    const auto second = [self place:engine asset:asset at:30 from:60 to:90];
    NSArray<NSNumber *> *clips = @[ @(first.first), @(second.first) ];
    NSString *key = @"grade.contrast";
    [engine beginCoalescingWithKey:key];
    for (const double value : {1.1, 1.3, 1.6, 1.4}) {
        VEEditResult *r = [engine performInCoalescingGroup:key
                                                      edit:^VEEditResult * {
                                                          return [engine setGradeValue:value
                                                                          forParameter:VEGradeParameterContrast
                                                                                 clips:clips];
                                                      }];
        XCTAssertTrue(r.ok, @"%@", r.message);
    }
    [engine endCoalescing];
    XCTAssertEqual([engine clipInfo:first.first].grade.contrast, 1.4);
    XCTAssertEqual([engine clipInfo:second.first].grade.contrast, 1.4);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Contrast");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:first.first].grade.contrast, 1);
    XCTAssertEqual([engine clipInfo:second.first].grade.contrast, 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Overwrite", @"the drag was one step");
}

// MARK: - Copy, paste, reset

- (void)testCopyPasteAndResetGrade {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0 from:0 to:30];
    const auto second = [self place:engine asset:asset at:30 from:60 to:90];
    const auto third = [self place:engine asset:asset at:60 from:120 to:150];
    XCTAssertFalse(engine.hasCopiedGrade);
    [self assertGrade:engine.copiedGrade equals:VEGradeParamsNeutral()];
    VEEditResult *refused = [engine pasteGradeOntoClips:@[ @(second.first) ]];
    XCTAssertFalse(refused.ok);
    XCTAssertEqual(refused.errorCode, VEEditErrorInvalidArgument);

    VEGradeParams look = VEGradeParamsNeutral();
    look.exposure = 0.75;
    look.contrast = 1.2;
    look.temperature = -15;
    look.tint = 5;
    look.saturation = 1.3;
    XCTAssertTrue([engine setGradeValues:look forClips:@[ @(first.first) ]].ok);
    XCTAssertFalse([engine copyGradeOfClip:first.second], @"a sound clip has no grade to copy");
    XCTAssertFalse([engine copyGradeOfClip:987654]);
    XCTAssertFalse(engine.hasCopiedGrade);
    XCTAssertTrue([engine copyGradeOfClip:first.first]);
    XCTAssertTrue(engine.hasCopiedGrade);
    [self assertGrade:engine.copiedGrade equals:look];

    // Paste onto two clips (their sound in the selection): one undo step.
    XCTAssertTrue([engine setGradeValue:-2 forParameter:VEGradeParameterExposure clips:@[ @(third.first) ]].ok);
    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine pasteGradeOntoClips:@[ @(second.first), @(second.second), @(third.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(engine.changeCount, before + 1);
    XCTAssertEqualObjects(engine.undoActionName, @"Paste Grade");
    [self assertGrade:[engine clipInfo:second.first].grade equals:look];
    [self assertGrade:[engine clipInfo:third.first].grade equals:look];
    XCTAssertTrue([engine undo]);
    [self assertGrade:[engine clipInfo:second.first].grade equals:VEGradeParamsNeutral()];
    XCTAssertEqual([engine clipInfo:third.first].grade.exposure, -2);
    XCTAssertTrue([engine redo]);

    // Reset: every value neutral, one step; clips already neutral make none.
    r = [engine resetGradeOfClips:@[ @(first.first), @(third.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Reset Grade");
    XCTAssertFalse([engine clipInfo:first.first].hasGrade);
    XCTAssertFalse([engine clipInfo:third.first].hasGrade);
    XCTAssertTrue([engine clipInfo:second.first].hasGrade);
    const uint64_t afterReset = engine.changeCount;
    XCTAssertTrue([engine resetGradeOfClips:@[ @(first.first) ]].ok);
    XCTAssertEqual(engine.changeCount, afterReset, @"nothing to reset: no undo step");
    // What was copied stays after the source clip changed, and after New.
    [engine newProjectWithName:@"Next"];
    XCTAssertTrue(engine.hasCopiedGrade);
    [self assertGrade:engine.copiedGrade equals:look];
}

// MARK: - Refusals

- (void)testRefusals {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto pair = [self place:engine asset:asset at:0 from:0 to:30];
    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[ @(pair.second) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackKindMismatch, @"only sound selected");
    r = [engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[]];
    XCTAssertFalse(r.ok);
    r = [engine setGradeValue:9 forParameter:VEGradeParameterExposure clips:@[ @(pair.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    XCTAssertTrue([r.message containsString:@"Exposure must be a number from -5 to 5"], @"%@", r.message);
    r = [engine setGradeValue:NAN forParameter:VEGradeParameterExposure clips:@[ @(pair.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeValues:VEGradeParamsUnchanged() forClips:@[ @(pair.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeValue:1 forParameter:static_cast<VEGradeParameter>(9) clips:@[ @(pair.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorInvalidArgument);
    r = [engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[ @(pair.first), @(123456) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorClipNotFound);
    XCTAssertTrue([engine setTrack:engine.sequence.videoTrackIDs[0].longLongValue locked:YES].ok);
    const uint64_t locked = engine.changeCount;
    r = [engine resetGradeOfClips:@[ @(pair.first) ]];
    XCTAssertEqual(r.errorCode, VEEditErrorTrackLocked);
    XCTAssertEqual(engine.changeCount, locked);
    XCTAssertEqual(locked, before + 1, @"only the lock changed anything");
    XCTAssertFalse([engine clipInfo:pair.first].hasGrade);
}

// MARK: - Save and open

- (void)testAGradeIsSavedAndOpened {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto pair = [self place:engine asset:asset at:0 from:0 to:30];
    VEGradeParams look = VEGradeParamsNeutral();
    look.exposure = -0.5;
    look.saturation = 0;
    XCTAssertTrue([engine setGradeValues:look forClips:@[ @(pair.first) ]].ok);
    NSURL *file = [_scratch URLByAppendingPathComponent:@"graded.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue([text containsString:@"\"grade\""]);
    XCTAssertTrue([text containsString:@"\"schemaVersion\": 10"]);

    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([reopened openProjectAtURL:file error:&error], @"%@", error);
    [self assertGrade:[reopened clipInfo:pair.first].grade equals:look];
    XCTAssertTrue([reopened clipInfo:pair.first].hasGrade);
    XCTAssertFalse([reopened clipInfo:pair.second].hasGrade);
}

@end
