// VEPreviewView: off-screen renderOnce + snapshot content (letterboxed), no rendering while
// paused, and display-link driven rendering when on screen.

#import <XCTest/XCTest.h>

#import <VidEditEngine/VidEditEngine.h>

#import "../../Engine/Render/VEPreviewView+Internal.h"
#include "CompositorTestSupport.h"

#include <atomic>
#include <cmath>
#include <memory>

// EngineTests does not list AppKit/CoreGraphics in project.yml and Objective-C++ does not auto-link it.
__asm__(".linker_option \"-framework\", \"AppKit\"");
__asm__(".linker_option \"-framework\", \"CoreGraphics\"");

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

struct Pixel {
    uint8_t r, g, b;
};

Pixel imagePixel(CGImageRef image, size_t x, size_t y) {
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    std::vector<uint8_t> data(width * height * 4);
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image);
    // Draw into a context in the image's own colour space so values are not colour matched.
    CGContextRef ctx = CGBitmapContextCreate(data.data(), width, height, 8, width * 4, colorSpace,
                                             static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipLast));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);
    const uint8_t *p = data.data() + (y * width + x) * 4;
    return {p[0], p[1], p[2]};
}

// A source showing one BGRA picture as a single-layer 1920x1080 graph; counts its calls.
struct CountingSource {
    media::PixelBuffer picture;
    std::atomic<int> calls{0};
};

PreviewFrameSource makeSource(std::shared_ptr<CountingSource> state) {
    return [state](const PreviewFrameRequest &request, PreviewFrame &frame) {
        state->calls.fetch_add(1);
        auto textures = request.textureCache->textures(state->picture);
        if (!textures.ok()) {
            return false;
        }
        frame.graph = makeGraph(1920, 1080);
        frame.graph.layers.assign(1, makeLayer(1));
        frame.textures.assign(1, textures.value());
        return true;
    };
}

} // namespace

@interface CompositorPreviewViewTests : XCTestCase
@end

@implementation CompositorPreviewViewTests

- (VEPreviewView *)makeViewWithSize:(NSSize)size source:(std::shared_ptr<CountingSource>)source {
    NSError *error = nil;
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                        device:device()
                                                         error:&error];
    XCTAssertNotNil(view, @"%@", error);
    [view setFrameSource:makeSource(std::move(source))];
    return view;
}

- (void)renderOnce:(VEPreviewView *)view {
    XCTestExpectation *done = [self expectationWithDescription:@"rendered"];
    [view renderOnceWithCompletion:^(NSError *error) {
        XCTAssertNil(error);
        [done fulfill];
    }];
    [self waitForExpectations:@[ done ] timeout:5];
}

// (j) Off-screen renderOnce produces a snapshot with the right, letterboxed content.
- (void)testRenderOnceSnapshotOffscreen {
    auto source = std::make_shared<CountingSource>();
    source->picture = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(source->picture, {220, 40, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(400, 400) source:source];
    XCTAssertTrue(view.isPaused);
    XCTAssertNil((__bridge id)[view snapshot], @"nothing rendered yet");

    [self renderOnce:view];
    XCTAssertEqual(view.renderCount, 1u);
    XCTAssertEqual(source->calls.load(), 1);
    XCTAssertNil(view.lastError);

    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image == NULL) {
        return;
    }
    const CGSize size = view.drawableSize;
    XCTAssertEqual(CGImageGetWidth(image), size_t(size.width));
    XCTAssertEqual(CGImageGetHeight(image), size_t(size.height));
    const size_t w = CGImageGetWidth(image);
    const size_t h = CGImageGetHeight(image);
    // 16:9 in a square: bars above and below, picture in the middle.
    const Pixel centre = imagePixel(image, w / 2, h / 2);
    XCTAssertEqual(centre.r, 220);
    XCTAssertEqual(centre.g, 40);
    XCTAssertEqual(centre.b, 30);
    const Pixel top = imagePixel(image, w / 2, 2);
    const Pixel bottom = imagePixel(image, w / 2, h - 3);
    XCTAssertEqual(top.r + top.g + top.b, 0);
    XCTAssertEqual(bottom.r + bottom.g + bottom.b, 0);
    const PixelRect fitted = fitRect(1920, 1080, int32_t(w), int32_t(h));
    const Pixel firstRow = imagePixel(image, w / 2, size_t(fitted.y));
    const Pixel aboveFirstRow = imagePixel(image, w / 2, size_t(fitted.y - 1));
    XCTAssertEqual(firstRow.r, 220);
    XCTAssertEqual(aboveFirstRow.r, 0);
}

// (j) A paused view performs no renders (and does not poll its frame source).
- (void)testPausedViewDoesNotRender {
    auto source = std::make_shared<CountingSource>();
    source->picture = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(source->picture, {10, 20, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    // Put it on screen so the display link could fire if it were running.
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 180)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = view;
    [window orderFront:nil];
    [self renderOnce:view];
    const NSUInteger rendersAfterOnce = view.renderCount;
    const int callsAfterOnce = source->calls.load();
    XCTAssertEqual(rendersAfterOnce, 1u);

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    XCTAssertEqual(view.renderCount, rendersAfterOnce);
    XCTAssertEqual(source->calls.load(), callsAfterOnce);
    [window orderOut:nil];
    [window close];
}

// The temporary placeholder source (what the app shows today) renders the expected blend.
- (void)testPlaceholderTestSourceRenders {
    NSError *error = nil;
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 960, 540) device:device() error:&error];
    XCTAssertNotNil(view, @"%@", error);
    [view installPlaceholderTestSource];
    XCTAssertNil(view.lastError);
    [self renderOnce:view];
    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image == NULL) {
        return;
    }
    const size_t w = CGImageGetWidth(image);
    const size_t h = CGImageGetHeight(image);
    const PixelRect fitted = fitRect(1920, 1080, int32_t(w), int32_t(h));
    auto at = [&](double sx, double sy) {
        return imagePixel(image, size_t(fitted.x + sx / 1920.0 * fitted.width),
                          size_t(fitted.y + sy / 1080.0 * fitted.height));
    };
    auto near3 = [](Pixel p, double r, double g, double b) {
        return std::fabs(p.r - r) <= 4 && std::fabs(p.g - g) <= 4 && std::fabs(p.b - b) <= 4;
    };
    // Bottom '420v' layer {60,150,60} at 50 %; top BGRA layer {60,60,200} at 50 % over it,
    // centred at (1080, 600) whatever its rotation.
    const Pixel both = at(1080, 600);
    const Pixel bottomOnly = at(100, 1000);
    XCTAssertTrue(near3(both, 0.5 * 60 + 0.25 * 60, 0.5 * 60 + 0.25 * 150, 0.5 * 200 + 0.25 * 60), @"%d %d %d",
                  both.r, both.g, both.b);
    XCTAssertTrue(near3(bottomOnly, 30, 75, 30), @"%d %d %d", bottomOnly.r, bottomOnly.g, bottomOnly.b);
}

// Unpaused and on screen, the display link drives renders; pausing stops them.
- (void)testDisplayLinkRendersWhileRunning {
    if (NSScreen.screens.count == 0 || CGDisplayIsAsleep(CGMainDisplayID())) {
        XCTSkip(@"no awake display: the display link cannot fire");
    }
    auto source = std::make_shared<CountingSource>();
    source->picture = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(source->picture, {10, 20, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 180)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = view;
    [window orderFront:nil];
    view.paused = NO;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    const NSUInteger running = view.renderCount;
    XCTAssertGreaterThan(running, 5u, @"display link should render every vsync while running");

    view.paused = YES;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; // in-flight frames land
    const NSUInteger afterPause = view.renderCount;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    XCTAssertEqual(view.renderCount, afterPause);
    [window orderOut:nil];
    [window close];
}

@end
