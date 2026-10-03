// The facade's titles API (VEEngine (Titles), VETitles.h; titles design sections 9 and 10; slice 1, item 8): adding a
// title above the footage (one undo step with the hidden generator asset and, when needed, a new track; redo gives
// the same ids), placing one as a dropped bin item, VEClipInfo of titles and mattes, setting parameters with their
// undo names and a typing run as one undo step, the inspector's "Mixed", refusals, the grade leaving titles alone,
// the program monitor's box size, and titles, fonts and load warnings through save and open.
// Uses h264_1080p30.mp4 (10 s, 30 fps, 1920x1080, with audio).

#import <FramewrightEngine/FramewrightEngine.h>
#import <CoreText/CoreText.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <string>

namespace {

CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

VEColour rgb(double red, double green, double blue) {
    return VEColour{red, green, blue};
}

bool sameColour(VEColour a, VEColour b) {
    return a.red == b.red && a.green == b.green && a.blue == b.blue;
}

} // namespace

@interface VEEngineTitleTests : XCTestCase
@end

@implementation VEEngineTitleTests {
    NSURL *_scratch;
    NSURL *_cacheDir;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [_scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

/// An engine whose sequence has 10 s of footage on V1 + A1 (linked); returns the footage's video clip.
- (VEEngine *)engineWithFootage:(VEClipID *)footageOut {
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
    VEEditResult *r = [engine overwriteAsset:asset.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                  audioTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                    sourceIn:kCMTimeZero
                                   sourceOut:frames30(300)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    *footageOut = r.createdIDs[0].longLongValue;
    return engine;
}

- (VETrackID)videoTrack:(VEEngine *)engine index:(NSUInteger)index {
    return engine.sequence.videoTrackIDs[index].longLongValue;
}

- (VEClipID)addTitle:(VEEngine *)engine at:(int64_t)frame {
    VEEditResult *r = [engine addGeneratedPreset:VEGeneratedPresetTitle
                                          atTime:frames30(frame)
                                      aboveTrack:[self videoTrack:engine index:0]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    return r.createdIDs.firstObject.longLongValue;
}

// MARK: - Adding

- (void)testATitleGoesAboveTheFootageAsOneUndoStepWithItsAsset {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const NSUInteger assetsBefore = engine.allAssets.count;
    const NSUInteger tracksBefore = engine.sequence.videoTrackIDs.count;
    XCTAssertEqual(tracksBefore, 2u);
    VEEditResult *added = [engine addGeneratedPreset:VEGeneratedPresetTitle
                                              atTime:frames30(45)
                                          aboveTrack:[self videoTrack:engine index:0]];
    XCTAssertTrue(added.ok, @"%@", added.message);
    XCTAssertEqual(added.createdIDs.count, 1u);
    const VEClipID title = added.createdIDs[0].longLongValue;
    VEClipInfo *info = [engine clipInfo:title];
    XCTAssertEqual(info.trackID, [self videoTrack:engine index:1], @"on V2, above the footage");
    XCTAssertEqual(CMTimeCompare(info.timelineStart, frames30(45)), 0);
    XCTAssertEqual(CMTimeCompare(info.duration, CMTimeMake(5, 1)), 0);
    XCTAssertEqual(info.generatorKind, VEGeneratorKindTitle);
    XCTAssertEqualObjects(info.name, @"Title");
    XCTAssertEqualObjects(info.title.text, @"Title");
    XCTAssertEqual(info.pictureWidth, 1920);
    XCTAssertEqual(info.pictureHeight, 1080);
    XCTAssertFalse(info.hasGrade);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Title");
    // The source monitor shows no generator asset (it has no media), and times none.
    [engine sourceMonitorShowAsset:info.assetID atTime:CMTimeMake(1, 1)];
    XCTAssertEqual(engine.sourceMonitorAssetID, 0);
    XCTAssertEqual(CMTimeCompare([engine frameTimeForAsset:info.assetID atTime:CMTimeMake(1, 1)], kCMTimeZero), 0);
    // The generator asset is hidden from the bin, but the clip refers to it.
    XCTAssertEqual(engine.allAssets.count, assetsBefore);
    VEAssetInfo *generator = [engine assetInfo:info.assetID];
    XCTAssertNotNil(generator);
    XCTAssertEqual(generator.generatorKind, VEGeneratorKindTitle);
    XCTAssertEqual([engine clipInfo:footage].generatorKind, VEGeneratorKindNone);
    XCTAssertNil([engine clipInfo:footage].title);

    // A second title over the first: a new track on top in the same step; one undo removes clip and track.
    VEEditResult *second = [engine addGeneratedPreset:VEGeneratedPresetLowerThird
                                               atTime:frames30(60)
                                           aboveTrack:[self videoTrack:engine index:0]];
    XCTAssertTrue(second.ok, @"%@", second.message);
    const VEClipID lowerThird = second.createdIDs[0].longLongValue;
    XCTAssertEqual(engine.sequence.videoTrackIDs.count, 3u);
    const VETrackID newTrack = [self videoTrack:engine index:2];
    XCTAssertEqual([engine clipInfo:lowerThird].trackID, newTrack);
    XCTAssertEqualObjects([engine trackInfo:newTrack].name, @"V3");
    XCTAssertEqualObjects([engine clipInfo:lowerThird].name, @"Name", @"the first line names the clip");
    XCTAssertEqualObjects(engine.undoActionName, @"Add Lower Third");
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.sequence.videoTrackIDs.count, 2u);
    XCTAssertNil([engine clipInfo:lowerThird]);
    XCTAssertTrue([engine redo]);
    XCTAssertEqual(engine.sequence.videoTrackIDs.count, 3u);
    XCTAssertEqual([engine clipInfo:lowerThird].trackID, newTrack, @"redo gives the same ids");

    // Undoing the first title removes its asset too: the next add makes it again in its own step.
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine undo]);
    XCTAssertNil([engine clipInfo:title]);
    XCTAssertNil([engine assetInfo:info.assetID]);
    XCTAssertTrue([engine redo]);
    XCTAssertEqual([engine clipInfo:title].assetID, info.assetID);
    XCTAssertEqual([engine assetInfo:info.assetID].generatorKind, VEGeneratorKindTitle);
    // A later title reuses the project's title asset.
    const VEClipID third = [self addTitle:engine at:200];
    XCTAssertEqual([engine clipInfo:third].assetID, info.assetID);
}

- (void)testAColourMatteIsAClipOfItsColour {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    VEEditResult *added = [engine addGeneratedPreset:VEGeneratedPresetColourMatte
                                              atTime:frames30(400)
                                          aboveTrack:0];
    XCTAssertTrue(added.ok, @"%@", added.message);
    const VEClipID matte = added.createdIDs[0].longLongValue;
    VEClipInfo *info = [engine clipInfo:matte];
    XCTAssertEqual(info.trackID, [self videoTrack:engine index:0], @"V1 is free after the footage");
    XCTAssertEqual(info.generatorKind, VEGeneratorKindColourMatte);
    XCTAssertEqualObjects(info.name, @"Colour Matte");
    XCTAssertNil(info.title);
    XCTAssertTrue(sameColour(info.matteColour, rgb(0, 0, 0)));
    XCTAssertEqualObjects(engine.undoActionName, @"Add Colour Matte");
    VEEditResult *colour = [engine setMatteColour:rgb(0.2, 0.4, 0.6) clips:@[ @(matte) ]];
    XCTAssertTrue(colour.ok, @"%@", colour.message);
    XCTAssertTrue(sameColour([engine clipInfo:matte].matteColour, rgb(0.2, 0.4, 0.6)));
    XCTAssertEqualObjects(engine.undoActionName, @"Change Matte Colour");
    XCTAssertFalse([engine setMatteColour:rgb(2, 0, 0) clips:@[ @(matte) ]].ok);
    XCTAssertFalse([engine setTitleText:@"x" clips:@[ @(matte) ]].ok, @"a matte has no text");
    XCTAssertFalse([engine setMatteColour:rgb(1, 1, 1) clips:@[ @(footage) ]].ok);
    XCTAssertEqual([engine titleBlockSizeOfClip:matte].width, 0);
}

- (void)testADroppedTitleOverwritesOrInsertsLikeABinItem {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VETrackID v1 = [self videoTrack:engine index:0];
    VEEditResult *overwrite = [engine placeGeneratedPreset:VEGeneratedPresetTitle onTrack:v1 atTime:frames30(30) insert:NO];
    XCTAssertTrue(overwrite.ok, @"%@", overwrite.message);
    const VEClipID title = overwrite.createdIDs[0].longLongValue;
    XCTAssertEqual([engine clipInfo:title].trackID, v1);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:footage].duration, frames30(30)), 0, @"cut where the title lands");
    XCTAssertEqualObjects(engine.undoActionName, @"Add Title");
    XCTAssertTrue([engine undo]);
    XCTAssertNil([engine clipInfo:title]);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:footage].duration, frames30(300)), 0);
    VEEditResult *insert = [engine placeGeneratedPreset:VEGeneratedPresetLowerThird onTrack:v1 atTime:kCMTimeZero insert:YES];
    XCTAssertTrue(insert.ok, @"%@", insert.message);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:footage].timelineStart, CMTimeMake(5, 1)), 0, @"rippled by 5 s");
    XCTAssertEqual([engine clipInfo:insert.createdIDs[0].longLongValue].generatorKind, VEGeneratorKindTitle);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:footage].timelineStart, kCMTimeZero), 0);
    XCTAssertEqual(engine.allClips.count, 2u);
    VEEditResult *onAudio = [engine placeGeneratedPreset:VEGeneratedPresetTitle
                                                 onTrack:engine.sequence.audioTrackIDs[0].longLongValue
                                                  atTime:kCMTimeZero
                                                  insert:NO];
    XCTAssertEqual(onAudio.errorCode, VEEditErrorTrackKindMismatch);
    XCTAssertEqual([engine addGeneratedPreset:static_cast<VEGeneratedPreset>(9) atTime:kCMTimeZero aboveTrack:v1].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine addGeneratedPreset:VEGeneratedPresetTitle atTime:frames30(-3) aboveTrack:v1].errorCode,
                   VEEditErrorInvalidTime);
    XCTAssertEqual(engine.allClips.count, 2u, @"refusals add nothing");
}

// MARK: - Content

- (void)testSettingParametersNamesTheUndoStepAndKeepsWhatDiffers {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID a = [self addTitle:engine at:0];
    const VEClipID b = [self addTitle:engine at:150];
    NSArray<NSNumber *> *both = @[ @(a), @(b) ];
    XCTAssertTrue([engine setTitleText:@"First\nline two" clips:@[ @(a) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Edit Title Text");
    XCTAssertEqualObjects([engine clipInfo:a].name, @"First");
    XCTAssertTrue([engine setTitleNumber:0.1 forParameter:VETitleParameterSize clips:both].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Size");
    XCTAssertTrue([engine setTitleColour:rgb(1, 0, 0) forParameter:VETitleParameterFillColour clips:both].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Fill Colour");
    XCTAssertTrue([engine setTitleToggle:NO forParameter:VETitleParameterShadow clips:@[ @(b) ]].ok);
    XCTAssertTrue([engine setTitleAlignment:VETitleAlignmentLeft clips:both].ok);
    XCTAssertTrue([engine setTitleFont:[VETitleFont fontWithPostScriptName:@"Helvetica-Bold" family:@"Helvetica" style:@"Bold"]
                                 clips:@[ @(a) ]]
                      .ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Font");
    VETitleInfo *first = [engine clipInfo:a].title;
    VETitleInfo *second = [engine clipInfo:b].title;
    XCTAssertEqualObjects(first.text, @"First\nline two");
    XCTAssertEqualObjects(second.text, @"Title", @"the text stays per title");
    XCTAssertEqual(first.size, 0.1);
    XCTAssertEqual(second.size, 0.1);
    XCTAssertTrue(sameColour(second.fillColour, rgb(1, 0, 0)));
    XCTAssertEqual([second numberForParameter:VETitleParameterSize], 0.1);
    XCTAssertTrue(sameColour([second colourForParameter:VETitleParameterFillColour], rgb(1, 0, 0)));
    XCTAssertTrue(std::isnan([second numberForParameter:VETitleParameterText]));
    XCTAssertFalse([second toggleForParameter:VETitleParameterShadow]);
    XCTAssertTrue(first.shadow, @"the title preset has a shadow");
    XCTAssertEqual(first.alignment, VETitleAlignmentLeft);
    XCTAssertEqualObjects(first.font.postScriptName, @"Helvetica-Bold");
    XCTAssertEqualObjects(first.font.displayName, @"Helvetica Bold");
    XCTAssertTrue(first.font.available);
    XCTAssertTrue(second.font.isSystem);
    XCTAssertEqualObjects(second.font.displayName, @"System Semibold");

    // The selection: what agrees, and "Mixed" where the titles differ; the footage is left out.
    VETitleSelection *selection = [engine titleOfClips:@[ @(a), @(footage), @(b) ]];
    XCTAssertEqualObjects(selection.titleClipIDs, both);
    XCTAssertEqual(selection.matteClipIDs.count, 0u);
    XCTAssertFalse([selection isMixed:VETitleParameterSize]);
    XCTAssertTrue([selection isMixed:VETitleParameterText]);
    XCTAssertTrue([selection isMixed:VETitleParameterFont]);
    XCTAssertTrue([selection isMixed:VETitleParameterShadow]);
    XCTAssertEqual(selection.firstTitle.size, 0.1);
    XCTAssertNil([engine titleOfClips:@[ @(footage) ]].firstTitle);

    // Moving the box, and resizing it.
    XCTAssertTrue([engine setTitlePositionX:0.3 y:0.7 width:NAN clips:@[ @(a) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Move Title");
    XCTAssertEqual([engine clipInfo:a].title.x, 0.3);
    XCTAssertEqual([engine clipInfo:a].title.y, 0.7);
    XCTAssertTrue([engine setTitlePositionX:0.3 y:0.7 width:0.5 clips:@[ @(a) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Resize Title");
    XCTAssertEqual([engine clipInfo:a].title.width, 0.5);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual([engine clipInfo:a].title.width, 0.8);
}

- (void)testRefusalsChangeNothing {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID title = [self addTitle:engine at:0];
    NSString *undoName = engine.undoActionName;
    XCTAssertEqual([engine setTitleNumber:2 forParameter:VETitleParameterSize clips:@[ @(title) ]].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setTitleNumber:0.1 forParameter:VETitleParameterFillColour clips:@[ @(title) ]].errorCode,
                   VEEditErrorInvalidArgument, @"a colour is not a number");
    XCTAssertEqual([engine setTitleNumber:0.1 forParameter:static_cast<VETitleParameter>(99) clips:@[ @(title) ]].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setTitleToggle:YES forParameter:VETitleParameterSize clips:@[ @(title) ]].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertEqual([engine setTitleAlignment:static_cast<VETitleAlignment>(5) clips:@[ @(title) ]].errorCode,
                   VEEditErrorInvalidArgument);
    XCTAssertFalse([engine setTitleText:@"x" clips:@[]].ok);
    XCTAssertFalse([engine setTitleText:@"x" clips:@[ @(footage) ]].ok, @"footage is not a title");
    XCTAssertFalse([engine setTitleText:[@"" stringByPaddingToLength:16385 withString:@"a" startingAtIndex:0]
                                  clips:@[ @(title) ]]
                       .ok,
                   @"longer than 16384 bytes");
    XCTAssertTrue([engine setTitleText:[@"" stringByPaddingToLength:16384 withString:@"a" startingAtIndex:0]
                                 clips:@[ @(title) ]]
                      .ok);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.undoActionName, undoName);
    XCTAssertEqualObjects([engine clipInfo:title].title.text, @"Title");
    // Setting what a title already has records no step.
    XCTAssertTrue([engine setTitleText:@"Title" clips:@[ @(title) ]].ok);
    XCTAssertEqualObjects(engine.undoActionName, undoName);
    // A locked track's titles are refused.
    XCTAssertTrue([engine setTrack:[engine clipInfo:title].trackID locked:YES].ok);
    XCTAssertEqual([engine setTitleText:@"x" clips:@[ @(title) ]].errorCode, VEEditErrorTrackLocked);
}

- (void)testATypingRunIsOneUndoStep {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID title = [self addTitle:engine at:0];
    [engine beginCoalescingWithKey:@"title.text"];
    for (NSString *text in @[ @"H", @"He", @"Hel", @"Hell", @"Hello" ]) {
        VEEditResult *step = [engine performInCoalescingGroup:@"title.text"
                                                         edit:^VEEditResult * {
                                                             return [engine setTitleText:text clips:@[ @(title) ]];
                                                         }];
        XCTAssertTrue(step.ok, @"%@", step.message);
        XCTAssertEqualObjects([engine clipInfo:title].title.text, text);
    }
    [engine endCoalescing];
    XCTAssertEqualObjects(engine.undoActionName, @"Edit Title Text");
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects([engine clipInfo:title].title.text, @"Title", @"one undo takes the whole run back");
    XCTAssertEqualObjects(engine.undoActionName, @"Add Title");
    XCTAssertTrue([engine redo]);
    XCTAssertEqualObjects([engine clipInfo:title].title.text, @"Hello");
}

- (void)testTheBoxSizeIsTheTitlesBlockInSequencePixels {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID title = [self addTitle:engine at:0];
    const CGSize one = [engine titleBlockSizeOfClip:title];
    XCTAssertEqualWithAccuracy(one.width, 0.8 * 1920, 1e-9, @"the wrap width");
    XCTAssertGreaterThan(one.height, 0.06 * 1080 * 0.9);
    XCTAssertLessThan(one.height, 0.06 * 1080 * 2);
    XCTAssertTrue([engine setTitleText:@"One\nTwo" clips:@[ @(title) ]].ok);
    const CGSize two = [engine titleBlockSizeOfClip:title];
    XCTAssertEqualWithAccuracy(two.height, 2 * one.height, 1.0, @"two lines");
    XCTAssertTrue([engine setTitleText:@"" clips:@[ @(title) ]].ok);
    XCTAssertEqualWithAccuracy([engine titleBlockSizeOfClip:title].height, one.height, 1e-6,
                               @"an empty text is one empty line, where the caret goes");
    XCTAssertTrue(CGSizeEqualToSize([engine titleBlockSizeOfClip:footage], CGSizeZero));
    XCTAssertTrue(CGSizeEqualToSize([engine titleBlockSizeOfClip:4242], CGSizeZero));
}

// MARK: - The grade

- (void)testTitlesAndMattesAreNotGraded {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID title = [self addTitle:engine at:0];
    XCTAssertTrue([engine setGradeValue:1 forParameter:VEGradeParameterExposure clips:@[ @(footage) ]].ok);
    XCTAssertTrue([engine copyGradeOfClip:footage]);
    XCTAssertFalse([engine copyGradeOfClip:title], @"a title has no grade to copy");
    // Pasting onto footage and a title grades the footage only.
    VEEditResult *pasted = [engine pasteGradeOntoClips:@[ @(title), @(footage) ]];
    XCTAssertTrue(pasted.ok, @"%@", pasted.message);
    XCTAssertFalse([engine clipInfo:title].hasGrade);
    VEEditResult *onlyTitle = [engine pasteGradeOntoClips:@[ @(title) ]];
    XCTAssertFalse(onlyTitle.ok);
    XCTAssertEqualObjects(onlyTitle.message, @"Titles and colour mattes are not graded.");
    VEEditResult *set = [engine setGradeValue:0.5 forParameter:VEGradeParameterSaturation clips:@[ @(title), @(footage) ]];
    XCTAssertTrue(set.ok, @"%@", set.message);
    XCTAssertEqual([engine clipInfo:footage].grade.saturation, 0.5);
    XCTAssertFalse([engine clipInfo:title].hasGrade);
}

// MARK: - Save and open

- (void)testTitlesAndMattesSurviveSaveAndOpen {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID title = [self addTitle:engine at:0];
    XCTAssertTrue([engine setTitleText:@"Saved\nTwice" clips:@[ @(title) ]].ok);
    XCTAssertTrue([engine setTitleToggle:YES forParameter:VETitleParameterOutline clips:@[ @(title) ]].ok);
    XCTAssertTrue([engine setTitleNumber:-20 forParameter:VETitleParameterTracking clips:@[ @(title) ]].ok);
    VEEditResult *matte = [engine addGeneratedPreset:VEGeneratedPresetColourMatte atTime:frames30(300) aboveTrack:0];
    XCTAssertTrue(matte.ok, @"%@", matte.message);
    XCTAssertTrue([engine setMatteColour:rgb(0.25, 0.5, 0.75) clips:matte.createdIDs].ok);
    NSURL *url = [_scratch URLByAppendingPathComponent:@"titles.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);

    VEEngine *opened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([opened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqual(opened.loadWarnings.count, 0u, @"%@", opened.loadWarnings);
    XCTAssertEqual(opened.allAssets.count, 1u, @"the generator assets stay hidden");
    VEClipInfo *reopened = [opened clipInfo:title];
    XCTAssertEqualObjects(reopened.title.text, @"Saved\nTwice");
    XCTAssertTrue(reopened.title.outline);
    XCTAssertEqual(reopened.title.tracking, -20);
    VEClipInfo *reopenedMatte = [opened clipInfo:matte.createdIDs[0].longLongValue];
    XCTAssertTrue(sameColour(reopenedMatte.matteColour, rgb(0.25, 0.5, 0.75)));
    XCTAssertEqual(opened.missingTitleFonts.count, 0u);
}

- (void)testAMissingFontIsReportedOnOpenAndListedForExport {
    VEClipID footage = 0;
    VEEngine *engine = [self engineWithFootage:&footage];
    const VEClipID a = [self addTitle:engine at:0];
    const VEClipID b = [self addTitle:engine at:150];
    VETitleFont *missing = [VETitleFont fontWithPostScriptName:@"NoSuchFont-Bold" family:@"No Such Font" style:@"Bold"];
    XCTAssertFalse(missing.available);
    XCTAssertTrue(([engine setTitleFont:missing clips:@[ @(a), @(b) ]].ok));
    XCTAssertEqual(engine.missingTitleFonts.count, 1u);
    XCTAssertEqualObjects(engine.missingTitleFonts[0].font, missing);
    XCTAssertEqual(engine.missingTitleFonts[0].clipCount, 2);
    // A hidden track's titles are not shown or exported: their fonts are not asked about.
    const VETrackID track = [engine clipInfo:b].trackID;
    XCTAssertEqual([engine clipInfo:a].trackID, track);
    XCTAssertTrue([engine setTrack:track muted:YES].ok);
    XCTAssertEqual(engine.missingTitleFonts.count, 0u);
    XCTAssertTrue([engine setTrack:track muted:NO].ok);
    XCTAssertEqual(engine.missingTitleFonts.count, 1u);
    // The block is measured in the fallback (System Bold), not as an empty title.
    XCTAssertGreaterThan([engine titleBlockSizeOfClip:a].height, 0);
    NSURL *url = [_scratch URLByAppendingPathComponent:@"missing-font.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);

    VEEngine *opened = [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
    XCTAssertTrue([opened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(opened.loadWarnings,
                          @[ @"The font “No Such Font Bold” is not on this Mac: 2 titles use it and are shown in the system "
                             @"font until it is installed." ]);
    XCTAssertEqualObjects([opened clipInfo:a].title.font.postScriptName, @"NoSuchFont-Bold", @"the name is kept");
    XCTAssertEqual(opened.missingTitleFonts.count, 1u);
    // The installed fonts changing is passed on (the app redraws its font badges and the monitors draw again).
    XCTNSNotificationExpectation *changed =
        [[XCTNSNotificationExpectation alloc] initWithName:VEEngineTitleFontsDidChangeNotification object:opened];
    [NSNotificationCenter.defaultCenter postNotificationName:(__bridge NSString *)kCTFontManagerRegisteredFontsChangedNotification
                                                      object:nil];
    [self waitForExpectations:@[ changed ] timeout:5];
}

@end
