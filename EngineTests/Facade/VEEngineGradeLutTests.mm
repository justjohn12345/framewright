// The facade's LUTs (VEEngine (Grade) importLUTAtURL:error:, lutWithID:, setGradeInputLUT:clips:,
// setGradeLook:clips:, setGradeLookStrength:clips:; VELUTInfo; VEGradeSelection's and VEClipInfo's LUTs):
// importing .cube files (a 3D and a 1D one, the same table twice, a malformed and an unreadable file), setting
// them on a selection (one undo step that also takes the LUT out of the project again), the strength, Copy and
// Paste into a new project (the LUT goes with the grade), Reset, and LUTs kept through save and open (schema 9,
// a copy in the file, so the .cube file is not needed). Uses h264_1080p30.mp4.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

#include <simd/simd.h>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

// The text of a 3D LUT of `size` per side applying `f` (red fastest).
NSString *cubeText(int size, simd_float3 (^f)(simd_float3)) {
    NSMutableString *text = [NSMutableString stringWithFormat:@"TITLE \"Test look\"\nLUT_3D_SIZE %d\n", size];
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                const simd_float3 v = f(simd_make_float3(float(r) / float(size - 1), float(g) / float(size - 1),
                                                         float(b) / float(size - 1)));
                [text appendFormat:@"%.6f %.6f %.6f\n", v.x, v.y, v.z];
            }
        }
    }
    return text;
}

} // namespace

@interface VEEngineGradeLutTests : XCTestCase
@end

@implementation VEEngineGradeLutTests {
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

- (NSURL *)write:(NSString *)text named:(NSString *)name {
    NSURL *url = [_scratch URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertTrue([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error], @"%@", error);
    return url;
}

- (void)testImportingLuts {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    NSURL *warm = [self write:cubeText(9, ^simd_float3(simd_float3 v) {
                       return simd_make_float3(std::min(1.0f, v.x * 1.1f), v.y, v.z * 0.9f);
                   })
                        named:@"warm look.cube"];
    NSError *error = nil;
    VELUTInfo *info = [engine importLUTAtURL:warm error:&error];
    XCTAssertNotNil(info, @"%@", error);
    XCTAssertEqual(info.kind, VELUTKind3D);
    XCTAssertEqual(info.size, 9);
    XCTAssertEqualObjects(info.displayName, @"Test look");
    XCTAssertEqualObjects(info.fileName, @"warm look.cube");
    XCTAssertEqualObjects(info.sourcePath, warm.path);
    XCTAssertEqual(info.lutID.length, 16u);
    XCTAssertEqualObjects([engine lutWithID:info.lutID].lutID, info.lutID);
    // The same table from another file: the same id.
    NSURL *copy = [self write:[NSString stringWithContentsOfURL:warm encoding:NSUTF8StringEncoding error:nil]
                        named:@"copy.cube"];
    XCTAssertEqualObjects([engine importLUTAtURL:copy error:&error].lutID, info.lutID);
    // A 1D LUT, named by its file without a title.
    VELUTInfo *shaper = [engine importLUTAtURL:[self write:@"LUT_1D_SIZE 3\n0 0 0\n0.6 0.6 0.6\n1 1 1\n" named:@"shaper.cube"]
                                         error:&error];
    XCTAssertEqual(shaper.kind, VELUTKind1D);
    XCTAssertEqualObjects(shaper.displayName, @"shaper");
    // Malformed and unreadable files: refused, saying why.
    XCTAssertNil([engine importLUTAtURL:[self write:@"LUT_3D_SIZE 2\n0 0 0\n" named:@"short.cube"] error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorImportFailed);
    XCTAssertTrue([error.localizedDescription containsString:@"“short.cube” is not a LUT Framewright can use: the table has 1 "
                                                             @"values; LUT_3D_SIZE 2 needs 8"],
                  @"%@", error.localizedDescription);
    XCTAssertNil([engine importLUTAtURL:[_scratch URLByAppendingPathComponent:@"missing.cube"] error:&error]);
    XCTAssertTrue([error.localizedDescription containsString:@"cannot be read"], @"%@", error.localizedDescription);
    XCTAssertNil([engine lutWithID:@"0000000000000000"]);
}

- (void)testSettingLutsSavingAndOpening {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    const auto second = [self place:engine asset:asset at:30];
    NSError *error = nil;
    VELUTInfo *look = [engine importLUTAtURL:[self write:cubeText(5, ^simd_float3(simd_float3 v) {
                                                  return simd_make_float3(v.z, v.y, v.x);
                                              })
                                                   named:@"swap.cube"]
                                       error:&error];
    XCTAssertNotNil(look, @"%@", error);
    NSArray<NSNumber *> *both = @[ @(first.first), @(second.first) ];
    VEEditResult *r = [engine setGradeLook:look.lutID clips:@[ @(first.first), @(first.second), @(second.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Look");
    XCTAssertEqualObjects([engine clipInfo:first.first].gradeLookLUTID, look.lutID);
    XCTAssertTrue([engine clipInfo:second.first].hasGrade);
    XCTAssertFalse([engine clipInfo:first.second].hasGrade, @"the linked sound is left out");
    XCTAssertEqualObjects([engine gradeOfClips:both].lookLUTID, look.lutID);
    XCTAssertEqualObjects([engine gradeOfClips:both].inputLUTID, @"");
    // The strength over both, as a slider drag: one undo step.
    NSString *key = @"grade.look.strength";
    [engine beginCoalescingWithKey:key];
    for (const double strength : {0.8, 0.6, 0.4}) {
        VEEditResult *step = [engine performInCoalescingGroup:key
                                                         edit:^VEEditResult * {
                                                             return [engine setGradeLookStrength:strength clips:both];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
    }
    [engine endCoalescing];
    XCTAssertEqual([engine clipInfo:second.first].gradeLookStrength, 0.4);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Look Strength");
    XCTAssertTrue([engine setGradeLookStrength:0.5 clips:@[ @(first.first) ]].ok);
    XCTAssertTrue(std::isnan([engine gradeOfClips:both].lookStrength), @"mixed");
    XCTAssertEqual([engine setGradeLookStrength:1.5 clips:both].errorCode, VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setGradeLook:@"0000000000000000" clips:both].errorCode, VEEditErrorInvalidArgument);

    // Saved: schema 9, the table copied into the file; opened without the .cube file.
    NSURL *file = [_scratch URLByAppendingPathComponent:@"luts.framewright"];
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue([text containsString:@"\"schemaVersion\": 9"]);
    XCTAssertTrue([text containsString:@"\"luts\""]);
    XCTAssertTrue([text containsString:look.lutID]);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:[_scratch URLByAppendingPathComponent:@"swap.cube"]
                                                            error:&error]);
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([reopened openProjectAtURL:file error:&error], @"%@", error);
    XCTAssertEqualObjects([reopened clipInfo:second.first].gradeLookLUTID, look.lutID);
    XCTAssertEqual([reopened clipInfo:second.first].gradeLookStrength, 0.4);
    VELUTInfo *held = [reopened lutWithID:look.lutID];
    XCTAssertEqualObjects(held.fileName, @"swap.cube");
    XCTAssertEqual(held.size, 5);

    // Undo of the first assignment takes the LUT out of the project: a save then writes no "luts".
    while (engine.canUndo && ![engine.undoActionName isEqualToString:@"Change Look"]) {
        XCTAssertTrue([engine undo]);
    }
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects([engine clipInfo:first.first].gradeLookLUTID, @"");
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertFalse([text containsString:@"\"luts\""]);
    // The LUT is still known to the session (imported), so it can be set again.
    XCTAssertNotNil([engine lutWithID:look.lutID]);
    XCTAssertTrue([engine setGradeInputLUT:look.lutID clips:both].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Input LUT");
    XCTAssertTrue([engine setGradeInputLUT:nil clips:both].ok);
    XCTAssertEqualObjects([engine clipInfo:first.first].gradeInputLUTID, @"");
}

- (void)testCopyAndPasteCarryTheLutIntoAnotherProject {
    VEAssetInfo *asset = nil;
    VEEngine *engine = [self engineWithAsset:&asset];
    const auto first = [self place:engine asset:asset at:0];
    NSError *error = nil;
    VELUTInfo *look = [engine importLUTAtURL:[self write:cubeText(3, ^simd_float3(simd_float3 v) {
                                                  return v * 0.5f;
                                              })
                                                   named:@"half.cube"]
                                       error:&error];
    XCTAssertTrue([engine setGradeInputLUT:look.lutID clips:@[ @(first.first) ]].ok);
    XCTAssertTrue([engine copyGradeOfClip:first.first]);
    XCTAssertTrue([engine resetGradeOfClips:@[ @(first.first) ]].ok);
    XCTAssertEqualObjects([engine clipInfo:first.first].gradeInputLUTID, @"");
    // A new project in the same engine, a fresh clip: the paste brings the LUT with it.
    [engine newProjectWithName:@"Elsewhere"];
    __block VEAssetInfo *again = nil;
    XCTestExpectation *imported = [self expectationWithDescription:@"import"];
    std::string pathError;
    const std::string path = ve::test::testMediaPath("h264_1080p30.mp4", pathError);
    [engine importMediaAtURLs:@[ [NSURL fileURLWithPath:@(path.c_str())] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *) {
                       again = assets.firstObject;
                       [imported fulfill];
                   }];
    [self waitForExpectations:@[ imported ] timeout:60];
    const auto clip = [self place:engine asset:again at:0];
    VEEditResult *r = [engine pasteGradeOntoClips:@[ @(clip.first) ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Paste Grade");
    XCTAssertEqualObjects([engine clipInfo:clip.first].gradeInputLUTID, look.lutID);
    NSURL *file = [_scratch URLByAppendingPathComponent:@"pasted.framewright"];
    XCTAssertTrue([engine saveProjectToURL:file error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue([text containsString:look.lutID]);
}

@end
