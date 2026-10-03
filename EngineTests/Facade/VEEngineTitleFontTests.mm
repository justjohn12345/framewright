// A font activated or removed while a title shows it redraws the title (titles design section 7; slice 1 review fix
// round, findings 1 and 4): a title naming a font this Mac lacks is drawn in the fallback; registering the font
// (a box font the test makes, TestFont.h, registered for this process as Font Book activates one) draws it in that
// font on the program monitor, and removing it again draws the fallback. The font change is a change of the titles'
// keys (media::titleFontGeneration), so the picture rendered before the change is never shown after it.

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <FramewrightEngine/FramewrightEngine.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Media/TitleRenderer.h"
#include "../Media/TestFont.h"
#include "../Media/TestMedia.h"

#include <string>
#include <vector>

namespace {

/// The mean grey level (0...255) of what `view` shows, and whether it shows anything.
std::pair<bool, double> meanOfView(VEPreviewView *view) {
    CGImageRef snapshot = [view snapshot];
    if (snapshot == NULL) {
        return {false, 0};
    }
    const size_t w = CGImageGetWidth(snapshot), h = CGImageGetHeight(snapshot);
    std::vector<uint8_t> bytes(w * h * 4);
    CGContextRef ctx = CGBitmapContextCreate(bytes.data(), w, h, 8, w * 4, CGImageGetColorSpace(snapshot),
                                             CGBitmapInfo(kCGImageAlphaNoneSkipFirst) |
                                                 CGBitmapInfo(kCGBitmapByteOrder32Little));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(w), CGFloat(h)), snapshot);
    CGContextRelease(ctx);
    double sum = 0;
    for (size_t i = 0; i < w * h; ++i) {
        sum += 0.2126 * bytes[i * 4 + 2] + 0.7152 * bytes[i * 4 + 1] + 0.0722 * bytes[i * 4 + 0];
    }
    return {true, sum / double(w * h)};
}

} // namespace

@interface VEEngineTitleFontTests : XCTestCase
@end

@implementation VEEngineTitleFontTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (void)renderAndWait:(VEPreviewView *)view {
    XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
    [view renderOnceWithCompletion:^(NSError *) {
        [rendered fulfill];
    }];
    [self waitForExpectations:@[ rendered ] timeout:10];
}

/// Renders `view` until it shows a whole picture (no layer missing) with the same mean twice, and returns the mean.
- (double)settledMeanOf:(VEPreviewView *)view {
    double previous = -1;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (deadline.timeIntervalSinceNow > 0) {
        [self renderAndWait:view];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        const auto [shown, mean] = meanOfView(view);
        if (shown && view.missingLayerCount == 0 && view.lastError == nil && mean == previous) {
            return mean;
        }
        previous = shown ? mean : -1;
    }
    XCTFail(@"the view did not settle on a picture");
    return previous;
}

- (void)waitForFontChangeOf:(VEEngine *)engine {
    XCTNSNotificationExpectation *changed =
        [[XCTNSNotificationExpectation alloc] initWithName:VEEngineTitleFontsDidChangeNotification object:engine];
    [self waitForExpectations:@[ changed ] timeout:10];
}

- (void)testAFontActivatedOrRemovedRedrawsTheTitle {
    if (MTLCreateSystemDefaultDevice() == nil) {
        XCTSkip(@"no Metal device");
    }
    // A font no Mac has, named for this test run.
    NSString *postScriptName = [NSString stringWithFormat:@"FramewrightTestBox%u-Regular", arc4random_uniform(1000000)];
    NSString *family = [postScriptName stringByReplacingOccurrencesOfString:@"-Regular" withString:@""];
    NSURL *fontURL = [_scratch URLByAppendingPathComponent:[postScriptName stringByAppendingString:@".ttf"]];
    const std::string written = ve::test::writeBoxFont(fontURL.path.UTF8String, family.UTF8String,
                                                       postScriptName.UTF8String);
    XCTAssertTrue(written.empty(), @"%s", written.c_str());

    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    VEEditResult *added = [engine addGeneratedPreset:VEGeneratedPresetTitle atTime:kCMTimeZero aboveTrack:0];
    XCTAssertTrue(added.ok, @"%@", added.message);
    NSArray<NSNumber *> *title = added.createdIDs;
    XCTAssertTrue([engine setTitleText:@"IIII" clips:title].ok);
    XCTAssertTrue([engine setTitleNumber:0.3 forParameter:VETitleParameterSize clips:title].ok);
    XCTAssertTrue([engine setTitleToggle:NO forParameter:VETitleParameterShadow clips:title].ok);
    VETitleFont *font = [VETitleFont fontWithPostScriptName:postScriptName family:family style:@"Regular"];
    XCTAssertTrue([engine setTitleFont:font clips:title].ok);
    XCTAssertFalse(font.available, @"not on this Mac yet");

    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270)];
    [engine attachProgramView:view];
    [engine seekToTime:kCMTimeZero];
    const double fallback = [self settledMeanOf:view];
    XCTAssertGreaterThan(fallback, 0.5, @"the title shows (in the fallback, thin strokes)");

    // Activated: the title is drawn in boxes, far more of the frame white.
    CFErrorRef error = NULL;
    XCTAssertTrue(CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &error),
                  @"%@", (__bridge NSError *)error);
    [self waitForFontChangeOf:engine];
    XCTAssertTrue(font.available);
    XCTAssertEqual(engine.missingTitleFonts.count, 0u);
    const double boxes = [self settledMeanOf:view];
    XCTAssertGreaterThan(boxes, fallback * 2, @"the title is drawn in the activated font (fallback %.2f)", fallback);

    // Removed again: back to the fallback.
    XCTAssertTrue(CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &error),
                  @"%@", (__bridge NSError *)error);
    [self waitForFontChangeOf:engine];
    XCTAssertFalse(font.available);
    const double again = [self settledMeanOf:view];
    XCTAssertEqualWithAccuracy(again, fallback, 0.01, @"the fallback again (boxes %.2f)", boxes);
    [engine attachProgramView:nil];
}

/// One change of the Mac's fonts posts Core Text's notification and AppKit's, often several times: titles are drawn
/// again once (review fix round, finding 10), whatever the number of engines.
- (void)testOneFontChangeRedrawsTitlesOnce {
    VEEngine *first = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    VEEngine *second = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    __block int firstChanges = 0;
    __block int secondChanges = 0;
    id a = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineTitleFontsDidChangeNotification
                                                           object:first
                                                            queue:nil
                                                       usingBlock:^(NSNotification *) {
                                                         ++firstChanges;
                                                       }];
    id b = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineTitleFontsDidChangeNotification
                                                           object:second
                                                            queue:nil
                                                       usingBlock:^(NSNotification *) {
                                                         ++secondChanges;
                                                       }];
    const std::uint32_t before = ve::media::titleFontGeneration();
    for (int i = 0; i < 3; ++i) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:(__bridge NSString *)kCTFontManagerRegisteredFontsChangedNotification
                          object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:NSFontSetChangedNotification object:nil];
    }
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTAssertEqual(firstChanges, 1);
    XCTAssertEqual(secondChanges, 1);
    XCTAssertEqual(ve::media::titleFontGeneration(), before + 1, @"one new generation of the titles' keys");
    [NSNotificationCenter.defaultCenter removeObserver:a];
    [NSNotificationCenter.defaultCenter removeObserver:b];
}

@end
