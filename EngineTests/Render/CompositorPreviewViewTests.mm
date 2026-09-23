// VEPreviewView: off-screen renderOnce + snapshot content (letterboxed), resize/collapse/restore,
// no rendering while paused, display-link driven rendering when on screen, occlusion, renderOnce
// coalescing, setFrameSource while a source call is running, the busy-GPU and no-drawable paths
// (deferred and retried), error reporting (skipped layers, source errors, GPU failures), memory
// pressure and teardown.

#import <XCTest/XCTest.h>

#import <FramewrightEngine/FramewrightEngine.h>

#import "../../Engine/Render/VEPreviewView+Internal.h"
#include "../Media/RouterTestSupport.h"
#include "CompositorTestSupport.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <functional>
#include <memory>
#include <optional>

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

// A source showing one BGRA picture as a single-layer 1920x1080 graph; counts its calls and runs
// an optional hook first (on the render thread).
struct CountingSource {
    media::PixelBuffer picture;
    std::atomic<int> calls{0};
    std::function<void()> onCall;
};

PreviewFrameSource makeSource(std::shared_ptr<CountingSource> state) {
    return [state](const PreviewFrameRequest &request, PreviewFrame &frame) {
        state->calls.fetch_add(1);
        if (state->onCall) {
            state->onCall();
        }
        auto textures = request.textureCache->textures(state->picture);
        if (!textures.ok()) {
            return false;
        }
        frame.graph = makeGraph(1920, 1080);
        frame.graph.layers.assign(1, makeLayer(1));
        frame.textures.assign(1, textures.value());
        frame.status = media::okStatus();
        return true;
    };
}

std::shared_ptr<CountingSource> solidSource(RGBA8 color) {
    auto source = std::make_shared<CountingSource>();
    source->picture = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(source->picture, color);
    return source;
}

// Spins the main run loop until `done` or the timeout; returns done().
bool spinUntil(const std::function<bool()> &done, double timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

} // namespace

@interface CompositorPreviewViewTests : XCTestCase
@end

@implementation CompositorPreviewViewTests {
    NSMutableArray<NSWindow *> *_windows;
}

- (void)setUp {
    _windows = [NSMutableArray array];
}

- (void)tearDown {
    for (NSWindow *window in _windows) {
        [window orderOut:nil];
        [window close];
    }
    [_windows removeAllObjects];
}

- (VEPreviewView *)makeViewWithSize:(NSSize)size source:(std::shared_ptr<CountingSource>)source {
    NSError *error = nil;
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                        device:device()
                                                         error:&error];
    XCTAssertNotNil(view, @"%@", error);
    if (source) {
        [view setFrameSource:makeSource(std::move(source))];
    }
    return view;
}

- (NSError *)renderOnce:(VEPreviewView *)view {
    XCTestExpectation *done = [self expectationWithDescription:@"rendered"];
    __block NSError *result = nil;
    [view renderOnceWithCompletion:^(NSError *error) {
        result = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[ done ] timeout:5];
    return result;
}

- (NSWindow *)showInWindow:(VEPreviewView *)view {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:view.frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = view;
    [window orderFront:nil];
    [_windows addObject:window];
    return window;
}

// Puts the view on screen, un-paused, and waits for the display link to render. Skips the test
// (instead of failing, or passing without having tested anything) when it cannot fire: no
// display, display asleep, screen locked or the window occluded.
- (void)requireRunningDisplayLink:(VEPreviewView *)view {
    if (NSScreen.screens.count == 0 || CGDisplayIsAsleep(CGMainDisplayID())) {
        XCTSkip(@"no awake display: the display link cannot fire");
    }
    if (view.window == nil) {
        [self showInWindow:view];
    }
    view.paused = NO;
    const NSUInteger before = view.renderCount;
    if (!spinUntil([view, before] { return view.renderCount > before + 2; }, 2.0)) {
        view.paused = YES;
        XCTSkip(@"the display link did not fire (screen locked or window occluded?): renderLoopRunning=%d",
                view.isRenderLoopRunning);
    }
}

// (j) Off-screen renderOnce produces a snapshot with the right, letterboxed content.
- (void)testRenderOnceSnapshotOffscreen {
    auto source = solidSource({220, 40, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(400, 400) source:source];
    XCTAssertTrue(view.isPaused);
    XCTAssertFalse(view.isRenderLoopRunning);
    XCTAssertNil((__bridge id)[view snapshot], @"nothing rendered yet");

    XCTAssertNil([self renderOnce:view]);
    XCTAssertEqual(view.renderCount, 1u);
    XCTAssertEqual(source->calls.load(), 1);
    XCTAssertNil(view.lastError);
    XCTAssertEqual(view.skippedLayerCount, 0u);

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

// Collapsing the view to zero height (split-view collapse, a SwiftUI zero-size layout pass) and
// restoring it must keep rendering: the drawable size comes back and frames render again.
- (void)testCollapseToZeroAndRestoreKeepsRendering {
    auto source = solidSource({30, 160, 90, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    [self renderOnce:view];
    const CGSize original = view.drawableSize;
    XCTAssertGreaterThanOrEqual(original.width, 320);
    XCTAssertEqual(view.renderCount, 1u);

    [view setFrameSize:NSMakeSize(320, 0)];
    XCTAssertEqual(view.drawableSize.height, 0);
    [self renderOnce:view]; // nothing visible: completes without drawing
    XCTAssertTrue((__bridge id)[view snapshot] == nil, @"a collapsed view has nothing to snapshot");

    [view setFrameSize:NSMakeSize(320, 180)];
    XCTAssertTrue(CGSizeEqualToSize(view.drawableSize, original), @"%@", NSStringFromSize(view.drawableSize));
    const NSUInteger before = view.renderCount;
    [self renderOnce:view];
    XCTAssertGreaterThan(view.renderCount, before, @"restored view must render again");
    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image != NULL) {
        XCTAssertEqual(CGImageGetWidth(image), size_t(original.width));
        XCTAssertEqual(CGImageGetHeight(image), size_t(original.height));
        const Pixel centre = imagePixel(image, CGImageGetWidth(image) / 2, CGImageGetHeight(image) / 2);
        XCTAssertEqual(centre.g, 160);
    }

    // Zero width, then a different size: renders at the new size.
    [view setFrameSize:NSMakeSize(0, 180)];
    XCTAssertEqual(view.drawableSize.width, 0);
    [view setFrameSize:NSMakeSize(200, 200)];
    XCTAssertGreaterThan(view.drawableSize.width, 0);
    [self renderOnce:view];
    image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image != NULL) {
        XCTAssertEqual(CGImageGetWidth(image), size_t(view.drawableSize.width));
        XCTAssertEqual(CGImageGetHeight(image), size_t(view.drawableSize.height));
    }
}

// (j) A paused view performs no renders (and does not poll its frame source). The display link
// is first shown to fire in this environment, so the check is not vacuous.
- (void)testPausedViewDoesNotRender {
    auto source = solidSource({10, 20, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    [self requireRunningDisplayLink:view];

    view.paused = YES;
    XCTAssertFalse(view.isRenderLoopRunning);
    spinUntil([] { return false; }, 0.1); // frames in flight land
    [self renderOnce:view];
    const NSUInteger rendersAfterOnce = view.renderCount;
    const int callsAfterOnce = source->calls.load();

    spinUntil([] { return false; }, 0.5);
    XCTAssertEqual(view.renderCount, rendersAfterOnce);
    XCTAssertEqual(source->calls.load(), callsAfterOnce);
}

// Unpaused and on screen, the display link drives renders; pausing stops them.
- (void)testDisplayLinkRendersWhileRunning {
    auto source = solidSource({10, 20, 30, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    [self requireRunningDisplayLink:view];
    XCTAssertTrue(view.isRenderLoopRunning);
    const NSUInteger start = view.renderCount;
    spinUntil([] { return false; }, 0.5);
    XCTAssertGreaterThan(view.renderCount, start + 5, @"display link should render every vsync while running");
    XCTAssertNil(view.lastError);

    view.paused = YES;
    spinUntil([] { return false; }, 0.1); // in-flight frames land
    const NSUInteger afterPause = view.renderCount;
    spinUntil([] { return false; }, 0.5);
    XCTAssertEqual(view.renderCount, afterPause);
}

// An occluded window stops the render loop; renderOnce is deferred until it is visible again,
// and then the frame is drawn without another request. (Drives the occlusion handling directly:
// the window server decides when a real window is occluded.)
- (void)testOcclusionStopsTheLoopAndRedrawsWhenVisible {
    auto source = solidSource({50, 60, 70, 255});
    // Off screen, so the window server's own occlusion notifications cannot interfere.
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    [view applyWindowVisible:YES];
    view.paused = NO;
    XCTAssertTrue(view.isRenderLoopRunning);
    [view applyWindowVisible:NO];
    XCTAssertFalse(view.isRenderLoopRunning, @"an occluded window must not run the display link");
    view.paused = YES;

    const NSUInteger before = view.renderCount;
    [view renderOnce];
    spinUntil([] { return false; }, 0.2);
    XCTAssertEqual(view.renderCount, before, @"no drawing into an occluded window");
    [view applyWindowVisible:YES];
    XCTAssertTrue(spinUntil([view, before] { return view.renderCount > before; }, 3.0),
                  @"the deferred frame is drawn when the window is visible again");
    XCTAssertFalse(view.isRenderLoopRunning, @"still paused");
}

// renderOnce requests made while one is queued coalesce into one render.
- (void)testRenderOnceCoalesces {
    auto source = solidSource({1, 2, 3, 255});
    auto entered = std::make_shared<test::Gate>();
    auto release = std::make_shared<test::Gate>();
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    source->onCall = [entered, release, first = std::make_shared<std::atomic<bool>>(true)] {
        if (first->exchange(false)) {
            entered->open();
            release->pass();
        }
    };
    // The first render blocks inside the source; ten requests arrive meanwhile.
    XCTestExpectation *firstDone = [self expectationWithDescription:@"first"];
    [view renderOnceWithCompletion:^(NSError *) {
        [firstDone fulfill];
    }];
    XCTAssertTrue(entered->pass(std::chrono::seconds(5)));
    for (int i = 0; i < 10; ++i) {
        [view renderOnce];
    }
    release->open();
    [self waitForExpectations:@[ firstDone ] timeout:5];
    [self renderOnce:view]; // queued behind the coalesced one: when it is done, so is that
    XCTAssertEqual(source->calls.load(), 3, @"blocked render + one coalesced + the final one");
    XCTAssertEqual(view.renderCount, 3u);
}

// setFrameSource waits for a source call in progress: when it returns, the old source is never
// called again, and the next render uses the new one.
- (void)testSetFrameSourceWaitsForTheRunningSourceCall {
    auto oldSource = solidSource({200, 0, 0, 255});
    auto newSource = solidSource({0, 0, 200, 255});
    auto entered = std::make_shared<test::Gate>();
    auto release = std::make_shared<test::Gate>();
    oldSource->onCall = [entered, release] {
        entered->open();
        release->pass();
    };
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:oldSource];
    [view renderOnce];
    XCTAssertTrue(entered->pass(std::chrono::seconds(5)));
    auto released = std::make_shared<std::atomic<bool>>(false);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        released->store(true);
        release->open();
    });
    [view setFrameSource:makeSource(newSource)];
    XCTAssertTrue(released->load(), @"setFrameSource returned while the old source was still running");
    const int oldCalls = oldSource->calls.load();
    [self renderOnce:view];
    XCTAssertEqual(oldSource->calls.load(), oldCalls);
    XCTAssertEqual(newSource->calls.load(), 1);
    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image != NULL) {
        XCTAssertEqual(imagePixel(image, CGImageGetWidth(image) / 2, CGImageGetHeight(image) / 2).b, 200);
    }
}

// Swapping sources while the display link renders: each swap returns promptly and the replaced
// source is not called afterwards.
- (void)testSetFrameSourceWhileRunning {
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:solidSource({9, 9, 9, 255})];
    [self requireRunningDisplayLink:view];
    std::shared_ptr<CountingSource> previous;
    double worstMs = 0;
    for (int i = 0; i < 20; ++i) {
        auto next = solidSource({uint8_t(i * 10), 0, 0, 255});
        const auto start = std::chrono::steady_clock::now();
        [view setFrameSource:makeSource(next)];
        worstMs = std::max(worstMs, std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() * 1000);
        if (previous) {
            const int frozen = previous->calls.load();
            spinUntil([] { return false; }, 0.03);
            XCTAssertEqual(previous->calls.load(), frozen, @"swap %d: replaced source still called", i);
        }
        previous = next;
        spinUntil([] { return false; }, 0.02);
    }
    NSLog(@"setFrameSource while running: worst %.2f ms", worstMs);
    XCTAssertLessThan(worstMs, 50.0);
    XCTAssertGreaterThan(previous->calls.load(), 0, @"the last source is in use");
    view.paused = YES;
}

// Every frame slot on the GPU: renderOnce does not block the render thread for long; the frame
// is deferred (busyCount), not dropped, and drawn by the view's own retry once a slot frees up.
// It is not an error.
- (void)testBusyGPUDefersTheFrameAndRetries {
    auto source = solidSource({0, 180, 0, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    Compositor *compositor = [view compositorForTesting];
    XCTAssertTrue(compositor != nullptr);
    if (compositor == nullptr) {
        return;
    }
    XCTAssertEqual(compositor->holdSlotsForTesting(Compositor::kFramesInFlight, 1.0), Compositor::kFramesInFlight);
    NSError *error = [self renderOnce:view];
    XCTAssertNotNil(error, @"the attempt reports that it was deferred");
    XCTAssertGreaterThanOrEqual(view.busyCount, 1u);
    XCTAssertEqual(view.renderCount, 0u);
    XCTAssertNil(view.lastError, @"a busy GPU is transient, not an error");
    compositor->releaseHeldSlotsForTesting();
    XCTAssertTrue(spinUntil([view] { return view.renderCount >= 1; }, 5.0), @"the deferred frame is retried");
    XCTAssertNil(view.lastError);
    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image != NULL) {
        XCTAssertEqual(imagePixel(image, CGImageGetWidth(image) / 2, CGImageGetHeight(image) / 2).g, 180);
    }
}

// The window server gives no drawable: the fresh frame is not lost; it is retried and shown,
// and lastError stays clear (transient).
- (void)testMissingDrawableIsRetried {
    auto source = solidSource({0, 0, 170, 255});
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
    auto failures = std::make_shared<std::atomic<int>>(2);
    [view setDrawableProviderForTesting:^id<CAMetalDrawable>(CAMetalLayer *layer) {
        if (failures->fetch_sub(1) > 0) {
            return nil;
        }
        return [layer nextDrawable];
    }];
    NSError *error = [self renderOnce:view];
    XCTAssertNotNil(error);
    XCTAssertEqual(view.renderCount, 0u);
    XCTAssertTrue(spinUntil([view] { return view.renderCount >= 1; }, 5.0), @"the frame is retried without a new request");
    XCTAssertEqual(view.drawableFailureCount, 2u);
    XCTAssertEqual(source->calls.load(), 3, @"each attempt asks the source (the first one's frame is kept)");
    XCTAssertNil(view.lastError);
    CGImageRef image = [view snapshot];
    XCTAssertTrue(image != NULL);
    if (image != NULL) {
        XCTAssertEqual(imagePixel(image, CGImageGetWidth(image) / 2, CGImageGetHeight(image) / 2).b, 170);
    }

    // A window server that never gives one: retrying stops and lastError says so.
    [view setDrawableProviderForTesting:^id<CAMetalDrawable>(CAMetalLayer *) {
        return nil;
    }];
    [view renderOnce];
    XCTAssertTrue(spinUntil([view] { return view.lastError != nil; }, 10.0), @"gives up after bounded retries");
    const NSUInteger failuresAtGiveUp = view.drawableFailureCount;
    spinUntil([] { return false; }, 0.6);
    XCTAssertEqual(view.drawableFailureCount, failuresAtGiveUp, @"no retries after giving up");
    [view setDrawableProviderForTesting:nil];
    XCTAssertNil([self renderOnce:view]);
    XCTAssertNil(view.lastError, @"a successful frame clears the error");
}

// Missing pictures are counted; a frame source's error becomes lastError while its frame is on
// screen and is cleared by the next good frame; a GPU-side failure is reported the same way.
- (void)testSkippedLayersSourceErrorsAndFailuresAreReported {
    media::PixelBuffer picture = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(picture, {100, 100, 100, 255});
    struct Script {
        bool missingSecondLayer = true;
        std::optional<media::MediaError> error;
    };
    auto script = std::make_shared<Script>();
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:nullptr];
    [view setFrameSource:PreviewFrameSource([script, picture](const PreviewFrameRequest &request, PreviewFrame &frame) {
        frame.graph = makeGraph(1920, 1080);
        frame.graph.layers = {makeLayer(1), makeLayer(2)};
        frame.textures.assign(2, TextureSet{});
        frame.textures[0] = request.textureCache->textures(picture).value();
        if (!script->missingSecondLayer) {
            frame.textures[1] = frame.textures[0];
        }
        frame.status = script->error ? media::Status(*script->error) : media::okStatus();
        return true;
    })];
    XCTAssertNil([self renderOnce:view]);
    XCTAssertEqual(view.skippedLayerCount, 1u);
    XCTAssertEqual(view.missingLayerCount, 1u);
    XCTAssertNil(view.lastError, @"a picture that is not decoded yet is not an error");

    script->error = media::makeError(media::MediaErrorCode::DecodeFailed, "clip 2: corrupt frame");
    NSError *error = [self renderOnce:view];
    XCTAssertNotNil(error);
    XCTAssertEqual(view.lastError.code, NSInteger(media::MediaErrorCode::DecodeFailed));
    XCTAssertTrue([view.lastError.localizedDescription containsString:@"corrupt frame"], @"%@", view.lastError);
    XCTAssertEqual(view.skippedLayerCount, 2u);

    script->error.reset();
    script->missingSecondLayer = false;
    XCTAssertNil([self renderOnce:view]);
    XCTAssertNil(view.lastError, @"the next good frame clears it");
    XCTAssertEqual(view.missingLayerCount, 0u);
    XCTAssertEqual(view.skippedLayerCount, 2u);

    // A frame that cannot be encoded (injected command-buffer failure) is an error too.
    Compositor *compositor = [view compositorForTesting];
    compositor->injectFaultForTesting(Compositor::Fault::CommandBuffer);
    error = [self renderOnce:view];
    XCTAssertNotNil(error);
    XCTAssertNotNil(view.lastError);
    XCTAssertEqual(compositor->freeSlotCount(), Compositor::kFramesInFlight);
    XCTAssertNil([self renderOnce:view]);
    XCTAssertNil(view.lastError);
}

// Memory pressure releases the pooled pre-scale textures; rendering goes on.
- (void)testHandleMemoryPressureReleasesScratch {
    auto source = std::make_shared<CountingSource>();
    source->picture = makeBurnIn420v(4, 1920, 1080);
    VEPreviewView *view = [self makeViewWithSize:NSMakeSize(240, 135) source:source]; // minified
    XCTAssertNil([self renderOnce:view]);
    Compositor *compositor = [view compositorForTesting];
    XCTAssertGreaterThan(compositor->stats().scratchTextures, 0u);
    [view handleMemoryPressure];
    XCTAssertEqual(compositor->stats().scratchTextures, 0u);
    XCTAssertNil([self renderOnce:view]);
    XCTAssertEqual(view.renderCount, 2u);
    view.paused = NO; // pausing again flushes the texture cache; must be harmless
    view.paused = YES;
    XCTAssertNil([self renderOnce:view]);
}

// Releasing the view (with a frame on the GPU) stops its render thread and frees its state,
// including the frame source.
- (void)testTeardownStopsTheRenderThreadAndReleasesTheSource {
    std::weak_ptr<CountingSource> weakSource;
    NSThread *thread = nil;
    __weak VEPreviewView *weakView = nil;
    @autoreleasepool {
        auto source = solidSource({1, 1, 1, 255});
        weakSource = source;
        VEPreviewView *view = [self makeViewWithSize:NSMakeSize(320, 180) source:source];
        source.reset();
        weakView = view;
        thread = [view renderThreadForTesting];
        [self renderOnce:view];
        [view renderOnce]; // one more queued while the view goes away
        view = nil;
    }
    XCTAssertTrue(spinUntil([&] { return weakView == nil; }, 2.0), @"the view must deallocate");
    XCTAssertTrue(spinUntil([&] { return thread.isFinished; }, 5.0), @"the render thread must exit");
    XCTAssertTrue(spinUntil([&] { return weakSource.expired(); }, 5.0), @"the frame source must be released");
}

@end
