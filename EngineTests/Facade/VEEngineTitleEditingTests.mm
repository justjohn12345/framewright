// The facade's titles slice 2 API (VEEngine (Titles), VETitles.h): the text layout the program monitor draws its
// caret and selection with and maps clicks through, placed through the clip's Motion (scale, rotation, position) and
// checked against the program monitor's own picture; point text, the anchor and the alignment keeping each title's
// text where it is; Copy Style and Paste Style.

#import <AppKit/AppKit.h>
#import <FramewrightEngine/FramewrightEngine.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"

#include <cmath>
#include <vector>

namespace {

/// What a program view shows, as 8-bit grey levels.
struct Grey {
    size_t width = 0;
    size_t height = 0;
    std::vector<uint8_t> level;

    uint8_t at(long x, long y) const {
        if (x < 0 || y < 0 || size_t(x) >= width || size_t(y) >= height) {
            return 0;
        }
        return level[size_t(y) * width + size_t(x)];
    }
};

Grey greyOf(VEPreviewView *view) {
    Grey grey;
    CGImageRef snapshot = [view snapshot];
    if (snapshot == NULL) {
        return grey;
    }
    grey.width = CGImageGetWidth(snapshot);
    grey.height = CGImageGetHeight(snapshot);
    std::vector<uint8_t> bytes(grey.width * grey.height * 4);
    CGContextRef ctx = CGBitmapContextCreate(bytes.data(), grey.width, grey.height, 8, grey.width * 4,
                                             CGImageGetColorSpace(snapshot),
                                             CGBitmapInfo(kCGImageAlphaNoneSkipFirst) |
                                                 CGBitmapInfo(kCGBitmapByteOrder32Little));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(grey.width), CGFloat(grey.height)), snapshot);
    CGContextRelease(ctx);
    grey.level.resize(grey.width * grey.height);
    for (size_t i = 0; i < grey.width * grey.height; ++i) {
        grey.level[i] = uint8_t(0.2126 * bytes[i * 4 + 2] + 0.7152 * bytes[i * 4 + 1] + 0.0722 * bytes[i * 4 + 0]);
    }
    return grey;
}

/// Whether `p` lies inside `quad` shrunk by `inset` (a fraction of its sides) about its centre.
bool inside(VETitleQuad quad, CGPoint p, double inset) {
    const CGPoint centre = CGPointMake((quad.topLeft.x + quad.bottomRight.x) / 2, (quad.topLeft.y + quad.bottomRight.y) / 2);
    auto shrink = [&](CGPoint corner) {
        return CGPointMake(centre.x + (corner.x - centre.x) * (1 - inset), centre.y + (corner.y - centre.y) * (1 - inset));
    };
    const CGPoint c[4] = {shrink(quad.topLeft), shrink(quad.topRight), shrink(quad.bottomRight), shrink(quad.bottomLeft)};
    int sign = 0;
    for (int i = 0; i < 4; ++i) {
        const CGPoint a = c[i], b = c[(i + 1) % 4];
        const double cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        const int s = cross > 0 ? 1 : cross < 0 ? -1 : 0;
        if (s != 0) {
            if (sign != 0 && s != sign) {
                return false;
            }
            sign = s;
        }
    }
    return true;
}

/// The fraction of the snapshot's pixels inside `quad` (frame coordinates, `scale` snapshot pixels per sequence pixel)
/// that are bright.
double brightFraction(const Grey &grey, VETitleQuad quad, double scale, double inset) {
    size_t total = 0, bright = 0;
    for (size_t y = 0; y < grey.height; ++y) {
        for (size_t x = 0; x < grey.width; ++x) {
            const CGPoint frame = CGPointMake((double(x) + 0.5) / scale, (double(y) + 0.5) / scale);
            if (inside(quad, frame, inset)) {
                ++total;
                bright += grey.level[y * grey.width + x] > 128 ? 1 : 0;
            }
        }
    }
    return total > 0 ? double(bright) / double(total) : -1;
}

} // namespace

@interface VEEngineTitleEditingTests : XCTestCase
@end

@implementation VEEngineTitleEditingTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (VEEngine *)engine {
    return [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
}

/// A title added at 0 with `text` (no shadow) on a new engine's 1920 x 1080 sequence.
- (VEClipID)addTitle:(VEEngine *)engine text:(NSString *)text preset:(VEGeneratedPreset)preset {
    VEEditResult *added = [engine addGeneratedPreset:preset atTime:kCMTimeZero aboveTrack:0];
    XCTAssertTrue(added.ok, @"%@", added.message);
    const VEClipID clip = added.createdIDs.firstObject.longLongValue;
    XCTAssertTrue([engine setTitleText:text clips:@[ @(clip) ]].ok);
    XCTAssertTrue([engine setTitleToggle:NO forParameter:VETitleParameterShadow clips:@[ @(clip) ]].ok);
    return clip;
}

- (void)renderAndWait:(VEPreviewView *)view {
    XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
    [view renderOnceWithCompletion:^(NSError *) {
        [rendered fulfill];
    }];
    [self waitForExpectations:@[ rendered ] timeout:10];
}

/// What `view` shows once it shows a whole picture that no longer changes.
- (Grey)settledPictureOf:(VEPreviewView *)view {
    Grey previous;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (deadline.timeIntervalSinceNow > 0) {
        [self renderAndWait:view];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        Grey grey = greyOf(view);
        if (grey.width > 0 && view.missingLayerCount == 0 && view.lastError == nil && grey.level == previous.level) {
            return grey;
        }
        previous = std::move(grey);
    }
    XCTFail(@"the view did not settle on a picture");
    return previous;
}

// MARK: - The text layout through Motion

- (void)testTheCaretAndSelectionFollowTheMotionOfTheClipAsTheMonitorDrawsIt {
    if (MTLCreateSystemDefaultDevice() == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self engine];
    const VEClipID title = [self addTitle:engine text:@"H H" preset:VEGeneratedPresetTitle];
    XCTAssertTrue([engine setTitleNumber:0.12 forParameter:VETitleParameterSize clips:@[ @(title) ]].ok);
    // Zoomed, turned and moved.
    VEVideoParams motion = [engine clipInfo:title].videoParams;
    motion.scale = 1.4;
    motion.rotationDegrees = 30;
    motion.x = 120;
    motion.y = -60;
    XCTAssertTrue([engine setVideoParams:motion forClip:title].ok);

    VETitleTextLayout *layout = [engine titleTextLayoutOfClip:title atTime:kCMTimeZero];
    XCTAssertNotNil(layout);
    XCTAssertEqualObjects(layout.text, @"H H");
    XCTAssertEqual(layout.length, 3);
    // The canvas-to-frame transform is the Motion: the frame's centre goes to the centre moved by (x, y), and a unit
    // step right on the canvas goes 1.4 along the turned axis.
    const CGAffineTransform t = layout.canvasToFrame;
    const CGPoint centre = CGPointApplyAffineTransform(CGPointMake(960, 540), t);
    XCTAssertEqualWithAccuracy(centre.x, 960 + 120, 1e-9);
    XCTAssertEqualWithAccuracy(centre.y, 540 - 60, 1e-9);
    const CGPoint step = CGPointApplyAffineTransform(CGPointMake(961, 540), t);
    XCTAssertEqualWithAccuracy(step.x - centre.x, 1.4 * std::cos(M_PI / 6), 1e-9);
    XCTAssertEqualWithAccuracy(step.y - centre.y, 1.4 * std::sin(M_PI / 6), 1e-9, @"clockwise on screen (+y down)");
    // A caret on the frame is its canvas caret through the transform.
    const CGRect canvasCaret = [layout canvasCaretAtIndex:2];
    const VETitleCaret caret = [layout caretAtIndex:2];
    const CGPoint top = CGPointApplyAffineTransform(canvasCaret.origin, t);
    XCTAssertEqualWithAccuracy(caret.top.x, top.x, 1e-9);
    XCTAssertEqualWithAccuracy(caret.top.y, top.y, 1e-9);
    XCTAssertEqualWithAccuracy(hypot(caret.bottom.x - caret.top.x, caret.bottom.y - caret.top.y),
                               1.4 * canvasCaret.size.height, 1e-6);

    // The monitor's picture: each H inside its selection quad, nothing in the space between them.
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 960, 540)];
    [engine attachProgramView:view];
    [engine seekToTime:kCMTimeZero];
    const Grey grey = [self settledPictureOf:view];
    const double scale = double(grey.width) / 1920.0;
    auto quadOf = [&](NSUInteger from, NSUInteger to) {
        NSArray<NSValue *> *rects = [layout canvasSelectionRectsForRange:NSMakeRange(from, to - from)];
        XCTAssertEqual(rects.count, 1u);
        return [layout frameQuadOfCanvasRect:NSRectToCGRect(rects.firstObject.rectValue)];
    };
    const VETitleQuad firstH = quadOf(0, 1), space = quadOf(1, 2), secondH = quadOf(2, 3);
    const double inFirst = brightFraction(grey, firstH, scale, 0.0);
    const double inSpace = brightFraction(grey, space, scale, 0.15);
    const double inSecond = brightFraction(grey, secondH, scale, 0.0);
    NSLog(@"TITLE caret mapping: bright in the first H's quad %.3f, the space's %.3f, the second H's %.3f", inFirst,
          inSpace, inSecond);
    XCTAssertGreaterThan(inFirst, 0.2);
    XCTAssertGreaterThan(inSecond, 0.2);
    XCTAssertLessThan(inSpace, 0.01);
    // Everything bright lies inside the block (grown a little for the anti-aliased edge).
    const VETitleQuad block = layout.frameBlock;
    size_t outside = 0;
    for (size_t y = 0; y < grey.height; ++y) {
        for (size_t x = 0; x < grey.width; ++x) {
            if (grey.level[y * grey.width + x] > 128 &&
                !inside(block, CGPointMake((double(x) + 0.5) / scale, (double(y) + 0.5) / scale), -0.05)) {
                ++outside;
            }
        }
    }
    XCTAssertEqual(outside, 0u);
    // Clicks on the frame: the right half of the second H puts the caret after it, the left half of the first before.
    auto along = [](VETitleQuad quad, double fx) {
        const CGPoint left = CGPointMake((quad.topLeft.x + quad.bottomLeft.x) / 2, (quad.topLeft.y + quad.bottomLeft.y) / 2);
        const CGPoint right =
            CGPointMake((quad.topRight.x + quad.bottomRight.x) / 2, (quad.topRight.y + quad.bottomRight.y) / 2);
        return CGPointMake(left.x + fx * (right.x - left.x), left.y + fx * (right.y - left.y));
    };
    XCTAssertEqual([layout indexAtFramePoint:along(secondH, 0.8)], 3);
    XCTAssertEqual([layout indexAtFramePoint:along(firstH, 0.2)], 0);
    XCTAssertEqual([layout indexAtFramePoint:along(space, 0.25)], 1);
    XCTAssertEqual([layout indexAtFramePoint:along(space, 0.75)], 2);
    [engine attachProgramView:nil];
}

- (void)testATitleScaledToNothingTakesNoClick {
    VEEngine *engine = [self engine];
    const VEClipID title = [self addTitle:engine text:@"Title" preset:VEGeneratedPresetTitle];
    VEVideoParams motion = [engine clipInfo:title].videoParams;
    motion.scale = 0;
    XCTAssertTrue([engine setVideoParams:motion forClip:title].ok);
    VETitleTextLayout *layout = [engine titleTextLayoutOfClip:title atTime:kCMTimeZero];
    XCTAssertEqual([layout indexAtFramePoint:CGPointMake(960, 540)], 0);
    XCTAssertNil([engine titleTextLayoutOfClip:4242 atTime:kCMTimeZero]);
}

// MARK: - Keeping the text in place

- (void)testPointTextTheAnchorAndTheAlignmentKeepTheTextWhereItIs {
    VEEngine *engine = [self engine];
    const VEClipID title = [self addTitle:engine text:@"Left aligned\nsecond" preset:VEGeneratedPresetTitle];
    NSArray<NSNumber *> *clips = @[ @(title) ];
    XCTAssertTrue([engine setTitleAlignment:VETitleAlignmentLeft clips:clips].ok);
    const CGRect area = [engine titleBlockOfClip:title];
    XCTAssertEqualWithAccuracy(CGRectGetMidX(area), 0.5 * 1920, 1e-6, @"area text is centred on x whatever it aligns to");

    // Point text: the block shrinks to its widest line, its left edge (the side it aligns to) stays.
    XCTAssertTrue([engine setTitlePointText:YES clips:clips].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Point Text");
    const CGRect point = [engine titleBlockOfClip:title];
    XCTAssertTrue([engine clipInfo:title].title.pointText);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(point), CGRectGetMinX(area), 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMidY(point), CGRectGetMidY(area), 1e-6);
    XCTAssertLessThan(point.size.width, area.size.width);
    XCTAssertEqualWithAccuracy([engine clipInfo:title].title.x * 1920, CGRectGetMinX(point), 1e-6,
                               @"left-aligned point text: x is the block's left edge");

    // Right-aligned: the block stays where it is (its lines align again inside it); x is now its right edge.
    XCTAssertTrue([engine setTitleAlignment:VETitleAlignmentRight clips:clips].ok);
    const CGRect right = [engine titleBlockOfClip:title];
    XCTAssertTrue(CGRectEqualToRect(CGRectIntegral(right), CGRectIntegral(point)), @"%@ %@",
                  NSStringFromRect(NSRectFromCGRect(right)), NSStringFromRect(NSRectFromCGRect(point)));
    XCTAssertEqualWithAccuracy([engine clipInfo:title].title.x * 1920, CGRectGetMaxX(right), 1e-6);

    // Anchored at the top: the block stays; y is now its top, and a line added grows it down.
    XCTAssertTrue([engine setTitleAnchor:VETitleAnchorTop clips:clips].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Vertical Anchor");
    const CGRect top = [engine titleBlockOfClip:title];
    XCTAssertEqualWithAccuracy(CGRectGetMinY(top), CGRectGetMinY(right), 1e-6);
    XCTAssertEqualWithAccuracy([engine clipInfo:title].title.y * 1080, CGRectGetMinY(top), 1e-6);
    XCTAssertTrue([engine setTitleText:@"Left aligned\nsecond\nthird" clips:clips].ok);
    const CGRect grown = [engine titleBlockOfClip:title];
    XCTAssertEqualWithAccuracy(CGRectGetMinY(grown), CGRectGetMinY(top), 1e-6);
    XCTAssertGreaterThan(CGRectGetMaxY(grown), CGRectGetMaxY(top) + 10);

    // Back to area text through the toggle: the right edge stays (it aligns right) and so does the top.
    XCTAssertTrue([engine setTitleToggle:NO forParameter:VETitleParameterPointText clips:clips].ok);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Point Text");
    const CGRect back = [engine titleBlockOfClip:title];
    XCTAssertFalse([engine clipInfo:title].title.pointText);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(back), CGRectGetMinY(grown), 1e-6);
    XCTAssertEqualWithAccuracy(back.size.width, 0.8 * 1920, 1e-6, @"the box width it kept");
    // Each change was one undo step, its position with it.
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine clipInfo:title].title.pointText);
    XCTAssertTrue(CGRectEqualToRect([engine titleBlockOfClip:title], grown));
}

- (void)testSeveralTitlesKeepTheirOwnPlaces {
    VEEngine *engine = [self engine];
    const VEClipID a = [self addTitle:engine text:@"Short" preset:VEGeneratedPresetTitle];
    const VEClipID b = [self addTitle:engine text:@"A much longer title" preset:VEGeneratedPresetTitle];
    XCTAssertTrue([engine setTitlePositionX:0.3 y:0.2 width:NAN clips:@[ @(a) ]].ok);
    NSArray<NSNumber *> *both = @[ @(a), @(b) ];
    XCTAssertTrue([engine setTitleAlignment:VETitleAlignmentLeft clips:both].ok);
    const CGRect beforeA = [engine titleBlockOfClip:a];
    const CGRect beforeB = [engine titleBlockOfClip:b];
    XCTAssertTrue([engine setTitlePointText:YES clips:both].ok);
    XCTAssertEqualWithAccuracy(CGRectGetMinX([engine titleBlockOfClip:a]), CGRectGetMinX(beforeA), 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMinX([engine titleBlockOfClip:b]), CGRectGetMinX(beforeB), 1e-6);
    XCTAssertNotEqualWithAccuracy([engine clipInfo:a].title.x, [engine clipInfo:b].title.x, 1e-3);
    XCTAssertTrue([engine undo]);
    XCTAssertFalse([engine clipInfo:a].title.pointText || [engine clipInfo:b].title.pointText, @"one step for both");
    // Refused: an anchor outside the enum, a clip that is not a title.
    XCTAssertEqual([engine setTitleAnchor:static_cast<VETitleAnchor>(9) clips:@[ @(a) ]].errorCode,
                   VEEditErrorInvalidArgument);
    VEEditResult *matte = [engine addGeneratedPreset:VEGeneratedPresetColourMatte atTime:kCMTimeZero aboveTrack:0];
    XCTAssertFalse([engine setTitlePointText:YES clips:@[ matte.createdIDs.firstObject ]].ok);
}

// MARK: - Presets

- (void)testATitleCardIsAMatteWithItsTitleAboveAsOneUndoStep {
    VEEngine *engine = [self engine];
    const NSUInteger tracks = engine.sequence.videoTrackIDs.count;
    VEEditResult *card = [engine addGeneratedPreset:VEGeneratedPresetTitleCard atTime:kCMTimeZero aboveTrack:0];
    XCTAssertTrue(card.ok, @"%@", card.message);
    XCTAssertEqual(card.createdIDs.count, 2u);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Title Card");
    VEClipInfo *title = [engine clipInfo:card.createdIDs[0].longLongValue];
    VEClipInfo *matte = [engine clipInfo:card.createdIDs[1].longLongValue];
    XCTAssertEqual(title.generatorKind, VEGeneratorKindTitle, @"the title first: the clip to select");
    XCTAssertEqual(matte.generatorKind, VEGeneratorKindColourMatte);
    NSArray<NSNumber *> *trackIDs = engine.sequence.videoTrackIDs;
    XCTAssertGreaterThan([trackIDs indexOfObject:@(title.trackID)], [trackIDs indexOfObject:@(matte.trackID)],
                         @"the title above its matte");
    XCTAssertTrue(CMTimeCompare(title.timelineStart, matte.timelineStart) == 0);
    XCTAssertTrue([engine undo]);
    XCTAssertNil([engine clipInfo:card.createdIDs[0].longLongValue]);
    XCTAssertNil([engine clipInfo:card.createdIDs[1].longLongValue]);
    XCTAssertEqual(engine.sequence.videoTrackIDs.count, tracks, @"the track it added went with it");
    // Dropped on V1: the matte where it was dropped, the title above.
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEEditResult *dropped = [engine placeGeneratedPreset:VEGeneratedPresetTitleCard onTrack:v1 atTime:kCMTimeZero insert:NO];
    XCTAssertTrue(dropped.ok, @"%@", dropped.message);
    XCTAssertEqual(dropped.createdIDs.count, 2u);
    XCTAssertEqual([engine clipInfo:dropped.createdIDs[1].longLongValue].trackID, v1);
    XCTAssertNotEqual([engine clipInfo:dropped.createdIDs[0].longLongValue].trackID, v1);
    XCTAssertEqual([engine clipInfo:dropped.createdIDs[0].longLongValue].generatorKind, VEGeneratorKindTitle);
    // Inserted (rippling): likewise.
    VEEditResult *inserted = [engine placeGeneratedPreset:VEGeneratedPresetTitleCard onTrack:v1 atTime:kCMTimeZero insert:YES];
    XCTAssertTrue(inserted.ok, @"%@", inserted.message);
    XCTAssertEqual(inserted.createdIDs.count, 2u);
    XCTAssertEqual([engine clipInfo:inserted.createdIDs[1].longLongValue].trackID, v1);
    XCTAssertEqual([engine clipInfo:inserted.createdIDs[0].longLongValue].generatorKind, VEGeneratorKindTitle);
}

- (void)testACaptionIsPointTextAnchoredAtItsTopLeft {
    VEEngine *engine = [self engine];
    VEEditResult *added = [engine addGeneratedPreset:VEGeneratedPresetCaption atTime:kCMTimeZero aboveTrack:0];
    XCTAssertTrue(added.ok, @"%@", added.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Add Caption");
    const VEClipID caption = added.createdIDs.firstObject.longLongValue;
    VETitleInfo *info = [engine clipInfo:caption].title;
    XCTAssertTrue(info.pointText);
    XCTAssertEqual(info.anchor, VETitleAnchorTop);
    XCTAssertEqual(info.alignment, VETitleAlignmentLeft);
    // Its block starts at its position, inside title-safe (a 5 % margin), and grows down and right as it is typed.
    const CGRect block = [engine titleBlockOfClip:caption];
    XCTAssertEqualWithAccuracy(CGRectGetMinX(block), info.x * 1920, 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(block), info.y * 1080, 1e-6);
    XCTAssertGreaterThanOrEqual(CGRectGetMinX(block), 0.05 * 1920);
    XCTAssertGreaterThanOrEqual(CGRectGetMinY(block), 0.05 * 1080);
    XCTAssertTrue([engine setTitleText:@"Caption, longer\nand a second line" clips:@[ @(caption) ]].ok);
    const CGRect grown = [engine titleBlockOfClip:caption];
    XCTAssertEqualWithAccuracy(CGRectGetMinX(grown), CGRectGetMinX(block), 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(grown), CGRectGetMinY(block), 1e-6);
    XCTAssertGreaterThan(grown.size.width, block.size.width);
    XCTAssertGreaterThan(grown.size.height, block.size.height);
}

// MARK: - Copy Style, Paste Style

- (void)testPasteStyleGivesTheCopiedStyleButNotTheTextOrPlace {
    VEEngine *engine = [self engine];
    XCTAssertFalse(engine.hasCopiedTitleStyle);
    const VEClipID source = [self addTitle:engine text:@"Source" preset:VEGeneratedPresetLowerThird];
    NSArray<NSNumber *> *sourceClip = @[ @(source) ];
    XCTAssertTrue([engine setTitleFont:[VETitleFont systemFontWithWeight:VESystemFontWeightHeavy] clips:sourceClip].ok);
    const VEColour orange{1, 0.5, 0};
    XCTAssertTrue([engine setTitleColour:orange forParameter:VETitleParameterFillColour clips:sourceClip].ok);
    XCTAssertTrue([engine setTitleToggle:YES forParameter:VETitleParameterOutline clips:sourceClip].ok);
    XCTAssertTrue([engine setTitleNumber:50 forParameter:VETitleParameterTracking clips:sourceClip].ok);
    XCTAssertTrue([engine setTitleAnchor:VETitleAnchorBottom clips:sourceClip].ok);
    const VEClipID first = [self addTitle:engine text:@"First" preset:VEGeneratedPresetTitle];
    const VEClipID second = [self addTitle:engine text:@"Second" preset:VEGeneratedPresetTitle];
    XCTAssertTrue([engine setTitlePositionX:0.2 y:0.3 width:0.5 clips:@[ @(second) ]].ok);
    XCTAssertTrue([engine setTitlePointText:YES clips:@[ @(second) ]].ok);
    VETitleInfo *secondBefore = [engine clipInfo:second].title;

    XCTAssertEqual([engine pasteTitleStyleOntoClips:@[ @(first) ]].errorCode, VEEditErrorInvalidArgument,
                   @"nothing copied yet");
    VEEditResult *matte = [engine addGeneratedPreset:VEGeneratedPresetColourMatte atTime:kCMTimeZero aboveTrack:0];
    XCTAssertFalse([engine copyTitleStyleOfClip:matte.createdIDs.firstObject.longLongValue], @"a matte has no style");
    XCTAssertFalse(engine.hasCopiedTitleStyle);
    XCTAssertTrue([engine copyTitleStyleOfClip:source]);
    XCTAssertTrue(engine.hasCopiedTitleStyle);

    NSArray<NSNumber *> *targets = @[ @(first), @(second) ];
    VEEditResult *pasted = [engine pasteTitleStyleOntoClips:targets];
    XCTAssertTrue(pasted.ok, @"%@", pasted.message);
    XCTAssertEqualObjects(engine.undoActionName, @"Paste Style");
    VETitleInfo *sourceInfo = [engine clipInfo:source].title;
    for (NSNumber *clip in @[ @(first), @(second) ]) {
        VETitleInfo *info = [engine clipInfo:clip.longLongValue].title;
        for (VETitleParameterInfo *row in VETitleParameterInfo.allParameters) {
            const VETitleParameter p = row.parameter;
            const BOOL style = p != VETitleParameterText && p != VETitleParameterPositionX &&
                               p != VETitleParameterPositionY && p != VETitleParameterBoxWidth &&
                               p != VETitleParameterPointText && p != VETitleParameterAnchor;
            if (!style) {
                continue;
            }
            switch (row.type) {
            case VETitleValueTypeNumber:
                XCTAssertEqual([info numberForParameter:p], [sourceInfo numberForParameter:p], @"%@", row.name);
                break;
            case VETitleValueTypeToggle:
                XCTAssertEqual([info toggleForParameter:p], [sourceInfo toggleForParameter:p], @"%@", row.name);
                break;
            case VETitleValueTypeColour: {
                const VEColour x = [info colourForParameter:p], y = [sourceInfo colourForParameter:p];
                XCTAssertTrue(x.red == y.red && x.green == y.green && x.blue == y.blue, @"%@", row.name);
                break;
            }
            default:
                break;
            }
        }
        XCTAssertEqualObjects(info.font, sourceInfo.font);
        XCTAssertEqual(info.alignment, sourceInfo.alignment);
        XCTAssertEqual(info.anchor, VETitleAnchorCentre, @"the anchor is where the text is, not its style");
    }
    // The text, place, width and point text of each stay its own.
    VETitleInfo *secondAfter = [engine clipInfo:second].title;
    XCTAssertEqualObjects(secondAfter.text, @"Second");
    XCTAssertEqual(secondAfter.x, secondBefore.x);
    XCTAssertEqual(secondAfter.y, secondBefore.y);
    XCTAssertEqual(secondAfter.width, 0.5);
    XCTAssertTrue(secondAfter.pointText);
    XCTAssertEqualObjects([engine clipInfo:first].title.text, @"First");
    // One undo step takes both back.
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects([engine clipInfo:first].title.font, [VETitleFont systemFontWithWeight:VESystemFontWeightSemibold]);
    XCTAssertEqualObjects([engine clipInfo:second].title.font, [VETitleFont systemFontWithWeight:VESystemFontWeightSemibold]);
    // A selection with something that is not a title is refused as a whole.
    NSArray<NSNumber *> *mixed = @[ @(first), matte.createdIDs.firstObject ];
    XCTAssertFalse([engine pasteTitleStyleOntoClips:mixed].ok);
    XCTAssertEqualObjects([engine clipInfo:first].title.font, [VETitleFont systemFontWithWeight:VESystemFontWeightSemibold]);
    // What was copied outlives the project.
    [engine newProjectWithName:@"Another"];
    XCTAssertTrue(engine.hasCopiedTitleStyle);
}

@end
