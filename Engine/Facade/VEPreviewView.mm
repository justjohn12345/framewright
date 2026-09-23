#import "VEPreviewView.h"

#include "../Render/Compositor.h"
#import "../Render/VEPreviewView+Internal.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>

using namespace ve;
using namespace ve::render;

namespace {

NSString *const kVEPreviewErrorDomain = @"VidEditEngine.PreviewView";

// The drawable format (see the header): 10 bits per channel, same size as BGRA8.
constexpr MTLPixelFormat kDrawableFormat = MTLPixelFormatBGR10A2Unorm;

// renderOnce waits this long for a frame slot before deferring (the display-link path never
// waits).
constexpr double kOnceSlotWaitSeconds = 0.1;
// A frame that could not be presented while the render loop is stopped is retried after
// 16 ms, doubling up to 0.5 s, at most this many times in a row.
constexpr int kMaxRetries = 8;

NSError *makeNSError(const media::MediaError &error) {
    return [NSError errorWithDomain:kVEPreviewErrorDomain
                               code:static_cast<NSInteger>(error.code)
                           userInfo:@{NSLocalizedDescriptionKey : @(error.description().c_str())}];
}

NSError *makeNSError(media::MediaErrorCode code, NSString *message) {
    return [NSError errorWithDomain:kVEPreviewErrorDomain
                               code:static_cast<NSInteger>(code)
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Everything the render thread touches. Shared by the view, the display-link proxy and the
// blocks posted to the render thread, so none of them needs the view to be alive.
struct PreviewState {
    id<MTLDevice> device = nil;
    CAMetalLayer *layer = nil;
    std::unique_ptr<Compositor> compositor;

    // Guards the frame source, the frame and the compositor. The display-link path only
    // try-locks it (never blocks); renderOnce, snapshot, setFrameSource and memory pressure
    // lock it. Never held while waiting for a drawable or a frame slot.
    std::mutex renderMutex;
    PreviewFrameSource source;
    PreviewFrame frame;
    std::atomic<bool> hasRendered{false};

    std::atomic<NSUInteger> renderCount{0};
    std::atomic<NSUInteger> skippedLayers{0};
    std::atomic<NSUInteger> missingLayers{0};
    std::atomic<NSUInteger> busyCount{0};
    std::atomic<NSUInteger> drawableFailures{0};
    std::atomic<bool> renderOncePending{false};
    // A frame must be (re)drawn even if the source reports no change: a resize, or a frame that
    // could not be presented.
    std::atomic<bool> redrawPending{false};
    std::atomic<bool> loopRunning{false}; // display link running (set on the main thread)
    std::atomic<bool> occluded{false};    // window not visible (set on the main thread)
    std::atomic<int> retryAttempts{0};
    std::atomic<bool> retryScheduled{false};
    std::atomic<double> drawableWidth{0};
    std::atomic<double> drawableHeight{0};

    std::mutex errorMutex;
    NSError *lastError = nil;

    std::mutex hookMutex;
    id<CAMetalDrawable> (^drawableProvider)(CAMetalLayer *) = nil;

    // The compositor waits for its in-flight frames, whose completions touch the members
    // below; destroy it first.
    ~PreviewState() { compositor.reset(); }

    void setError(NSError *error) {
        std::lock_guard<std::mutex> lock(errorMutex);
        lastError = error;
    }

    id<CAMetalDrawable> nextDrawable() {
        id<CAMetalDrawable> (^provider)(CAMetalLayer *) = nil;
        {
            std::lock_guard<std::mutex> lock(hookMutex);
            provider = drawableProvider;
        }
        return provider != nil ? provider(layer) : [layer nextDrawable];
    }
};

bool lookupFromFrame(const PreviewFrame &frame, std::size_t index, TextureSet &out) {
    if (index < frame.textures.size() && frame.textures[index]) {
        out = frame.textures[index];
        return true;
    }
    return false;
}

void renderPreviewFrame(const std::shared_ptr<PreviewState> &statePtr, bool once, CFTimeInterval timestamp,
                        void (^completion)(NSError *));

// Render thread: a frame could not be presented. While the display link runs the next vsync
// redraws it; while it is stopped a timer on the render thread retries (unless the window is
// occluded: becoming visible redraws).
void deferRedraw(const std::shared_ptr<PreviewState> &statePtr) {
    PreviewState &st = *statePtr;
    st.redrawPending.store(true);
    if (st.loopRunning.load() || st.occluded.load() || st.retryScheduled.load()) {
        return;
    }
    const int attempt = st.retryAttempts.fetch_add(1);
    if (attempt >= kMaxRetries) {
        st.setError(makeNSError(media::MediaErrorCode::Timeout,
                                @"VEPreviewView: could not present the frame (no drawable or GPU busy)"));
        return;
    }
    st.retryScheduled.store(true);
    const double delay = std::min(0.016 * double(1 << attempt), 0.5);
    std::shared_ptr<PreviewState> state = statePtr;
    [NSTimer scheduledTimerWithTimeInterval:delay
                                    repeats:NO
                                      block:^(NSTimer *) {
                                          state->retryScheduled.store(false);
                                          if (state->redrawPending.load() && !state->loopRunning.load()) {
                                              renderPreviewFrame(state, true, CACurrentMediaTime(), nil);
                                          }
                                      }];
}

// Renders on the render thread. `once`: renderOnce semantics (blocking lock, bounded wait for a
// frame slot, always renders). `completion` (may be nil) is called on the main queue.
void renderPreviewFrame(const std::shared_ptr<PreviewState> &statePtr, bool once, CFTimeInterval timestamp,
                        void (^completion)(NSError *)) {
    PreviewState &st = *statePtr;
    auto finish = [completion](NSError *error) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error);
            });
        }
    };
    if (!st.compositor) {
        finish(makeNSError(media::MediaErrorCode::InvalidState, @"VEPreviewView: Metal is not available"));
        return;
    }
    // 1. A free frame slot first: with every slot on the GPU, neither the source's fresh frame
    // nor a drawable is taken, and the frame is drawn later.
    if (!st.compositor->waitForFreeSlot(once ? kOnceSlotWaitSeconds : 0.0)) {
        st.busyCount.fetch_add(1);
        deferRedraw(statePtr);
        finish(makeNSError(media::MediaErrorCode::Timeout, @"VEPreviewView: the GPU is busy; the frame is deferred"));
        return;
    }

    // 2. Ask the source (under the lock: setFrameSource waits for a call in progress).
    std::unique_lock<std::mutex> lock(st.renderMutex, std::defer_lock);
    if (once) {
        lock.lock();
    } else if (!lock.try_lock()) {
        return; // a snapshot or source change is in progress; nothing consumed, try next vsync
    }
    const bool pending = st.redrawPending.exchange(false);
    PreviewFrameRequest request;
    request.targetTimestamp = timestamp;
    request.isRenderOnce = once;
    request.textureCache = &st.compositor->textureCache();
    const bool fresh = st.source ? st.source(request, st.frame) : false;
    if (!fresh && !once && !pending) {
        return;
    }
    if (st.drawableWidth.load() < 1 || st.drawableHeight.load() < 1) {
        finish(nil); // nothing visible to draw into; a size change requests a redraw
        return;
    }
    NSError *sourceError = st.frame.status.ok() ? nil : makeNSError(st.frame.status.error());
    lock.unlock();

    // 3. The drawable, without the lock (this can wait for the window server).
    id<CAMetalDrawable> drawable = st.nextDrawable();
    if (drawable == nil) {
        st.drawableFailures.fetch_add(1);
        deferRedraw(statePtr);
        finish(makeNSError(media::MediaErrorCode::Timeout, @"VEPreviewView: no drawable available; the frame is deferred"));
        return;
    }

    // 4. Composite and present.
    if (once) {
        lock.lock();
    } else if (!lock.try_lock()) {
        deferRedraw(statePtr);
        return;
    }
    TextureTarget target;
    target.texture = drawable.texture;
    target.drawable = drawable;
    PreviewState *raw = statePtr.get(); // the compositor (owned by the state) outlives its completions
    const PreviewFrame &frame = st.frame;
    auto lookup = [&frame](const VideoLayer &, std::size_t index, TextureSet &out) {
        return lookupFromFrame(frame, index, out);
    };
    RenderOptions options;
    options.waitForFreeSlot = false;
    auto submitted = st.compositor->render(
        st.frame.graph, lookup, target,
        [raw, completion, sourceError](const RenderResult &result) {
            raw->skippedLayers.fetch_add(result.skippedLayers.size(), std::memory_order_relaxed);
            raw->missingLayers.store(result.skippedLayers.size(), std::memory_order_relaxed);
            NSError *error = result.status.ok() ? sourceError : makeNSError(result.status.error());
            raw->setError(error); // nil: the frame on screen is complete, clear the last error
            raw->renderCount.fetch_add(1, std::memory_order_release);
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(error);
                });
            }
        },
        options);
    if (!submitted.ok()) {
        NSError *error = makeNSError(submitted.error());
        st.setError(error);
        finish(error);
        return;
    }
    if (submitted.value() == Submission::Busy) {
        // Only possible if a slot was taken since step 1 (slots held for testing).
        st.busyCount.fetch_add(1);
        deferRedraw(statePtr);
        finish(makeNSError(media::MediaErrorCode::Timeout, @"VEPreviewView: the GPU is busy; the frame is deferred"));
        return;
    }
    st.hasRendered = true;
    st.retryAttempts.store(0);
}

} // namespace

// Runs posted blocks on the render thread.
@interface VEPreviewBlockRunner : NSObject
+ (void)run:(dispatch_block_t)block;
@end

@implementation VEPreviewBlockRunner
+ (void)run:(dispatch_block_t)block {
    @autoreleasepool {
        block();
    }
}
@end

// Display-link target: holds the render state, not the view (the display link retains its target).
@interface VEPreviewDisplayLinkProxy : NSObject {
  @public
    std::shared_ptr<PreviewState> _state;
}
- (void)tick:(CADisplayLink *)link;
@end

@implementation VEPreviewDisplayLinkProxy
- (void)tick:(CADisplayLink *)link {
    @autoreleasepool {
        renderPreviewFrame(_state, false, link.targetTimestamp, nil);
    }
}
@end

@implementation VEPreviewView {
    std::shared_ptr<PreviewState> _state;
    NSThread *_renderThread;
    CADisplayLink *_displayLink;
    CAMetalLayer *_metalLayer;
    BOOL _paused;
    id _occlusionObserver;
}

// MARK: - Lifetime

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        NSError *error = nil;
        if (![self commonSetupWithDevice:nil error:&error]) {
            _state->setError(error);
        }
    }
    return self;
}

- (nullable instancetype)initWithFrame:(NSRect)frameRect
                                device:(nullable id<MTLDevice>)device
                                 error:(NSError *_Nullable *_Nullable)error {
    self = [super initWithFrame:frameRect];
    if (self) {
        NSError *setupError = nil;
        if (![self commonSetupWithDevice:device error:&setupError]) {
            if (error != nullptr) {
                *error = setupError;
            }
            return nil;
        }
    }
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        NSError *error = nil;
        if (![self commonSetupWithDevice:nil error:&error]) {
            _state->setError(error);
        }
    }
    return self;
}

- (BOOL)commonSetupWithDevice:(id<MTLDevice>)device error:(NSError **)error {
    _state = std::make_shared<PreviewState>();
    _paused = YES;

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.pixelFormat = kDrawableFormat;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.displaySyncEnabled = YES;
    _metalLayer.maximumDrawableCount = 3;
    _metalLayer.allowsNextDrawableTimeout = YES;
    _metalLayer.opaque = YES;
    _metalLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _metalLayer.needsDisplayOnBoundsChange = YES;
    // The compositor outputs gamma-encoded BT.709 R'G'B'; let the window server colour-match it.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _metalLayer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    _state->layer = _metalLayer;

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layerContentsPlacement = NSViewLayerContentsPlacementScaleProportionallyToFit;

    _renderThread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
            [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode]; // keeps the loop alive
            while (!NSThread.currentThread.isCancelled) {
                @autoreleasepool {
                    [runLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
                }
            }
        }
    }];
    _renderThread.name = @"VidEdit preview render";
    _renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_renderThread start];

    VEPreviewDisplayLinkProxy *proxy = [VEPreviewDisplayLinkProxy new];
    proxy->_state = _state;
    _displayLink = [self displayLinkWithTarget:proxy selector:@selector(tick:)];
    CADisplayLink *link = _displayLink;
    link.paused = YES;
    [self performOnRenderThread:^{
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    } wait:NO];

    id<MTLDevice> chosen = device ?: MTLCreateSystemDefaultDevice();
    if (chosen == nil) {
        if (error != nullptr) {
            *error = makeNSError(media::MediaErrorCode::InvalidState, @"VEPreviewView: no Metal device");
        }
        return NO;
    }
    // Only the drawable's pipelines up front (snapshots build their BGRA8 ones on first use).
    auto compositor = Compositor::create(chosen, {kDrawableFormat});
    if (!compositor.ok()) {
        if (error != nullptr) {
            *error = makeNSError(compositor.error());
        }
        return NO;
    }
    _state->device = chosen;
    _state->compositor = std::move(compositor).value();
    _metalLayer.device = chosen;
    [self updateDrawableSize];
    return YES;
}

- (void)dealloc {
    if (_occlusionObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:_occlusionObserver];
    }
    CADisplayLink *link = _displayLink;
    NSThread *thread = _renderThread;
    [self performOnRenderThread:^{
        [link invalidate];
        [thread cancel]; // the run loop exits after this block returns
    } wait:NO];
}

- (void)performOnRenderThread:(dispatch_block_t)block wait:(BOOL)wait {
    [VEPreviewBlockRunner performSelector:@selector(run:)
                                 onThread:_renderThread
                               withObject:[block copy]
                            waitUntilDone:wait
                                    modes:@[ NSRunLoopCommonModes ]];
}

// MARK: - Layer

- (CALayer *)makeBackingLayer {
    return _metalLayer;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    [self requestRedraw];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (_occlusionObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:_occlusionObserver];
        _occlusionObserver = nil;
    }
    NSWindow *window = self.window;
    if (window != nil) {
        __weak VEPreviewView *weakSelf = self;
        _occlusionObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:window
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        VEPreviewView *strongSelf = weakSelf;
                        NSWindow *changed = note.object;
                        if (strongSelf != nil && changed == strongSelf.window) {
                            [strongSelf applyWindowVisible:(changed.occlusionState & NSWindowOcclusionStateVisible) != 0];
                        }
                    }];
    }
    // Off-screen (no window) counts as visible: renderOnce and snapshots still work. The window
    // server only tracks occlusion for a running application (in a plain tool process every
    // window reads as occluded and no notification ever arrives), so without one the window is
    // taken as visible.
    const bool occlusionTracked = NSApp != nil && NSApp.isRunning;
    [self applyWindowVisible:window == nil || !occlusionTracked ||
                             (window.occlusionState & NSWindowOcclusionStateVisible) != 0];
    [self updateDrawableSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawableSize];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateDrawableSize];
}

- (void)updateDrawableSize {
    if (_metalLayer == nil) {
        return;
    }
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    if (scale <= 0) {
        scale = 1;
    }
    _metalLayer.contentsScale = scale;
    const NSSize bounds = self.bounds.size;
    const CGSize size = CGSizeMake(std::floor(bounds.width * scale), std::floor(bounds.height * scale));
    // Compare against the stored size, not the layer's: a collapse to zero is recorded in the
    // state but leaves the layer's drawable size alone (it cannot be zero), so restoring the
    // previous size must still be seen as a change.
    const bool changed = size.width != _state->drawableWidth.load() || size.height != _state->drawableHeight.load();
    if (size.width >= 1 && size.height >= 1 && !CGSizeEqualToSize(size, _metalLayer.drawableSize)) {
        _metalLayer.drawableSize = size;
    }
    if (!changed) {
        return;
    }
    _state->drawableWidth.store(size.width);
    _state->drawableHeight.store(size.height);
    [self requestRedraw];
}

// Redraw the current frame (at a new size, or after it could not be presented): next vsync when
// running, once now when stopped, when visible again when occluded.
- (void)requestRedraw {
    if (!_state->hasRendered && !_state->source) {
        return;
    }
    _state->redrawPending.store(true);
    if (!_state->loopRunning.load() && !_state->occluded.load()) {
        [self renderOnce];
    }
}

- (void)updateRenderLoop {
    const bool run = !_paused && !_state->occluded.load() && _state->compositor != nullptr;
    _state->loopRunning.store(run);
    CADisplayLink *link = _displayLink;
    [self performOnRenderThread:^{
        link.paused = !run;
    } wait:NO];
}

// MARK: - Public API

- (id<MTLDevice>)device {
    return _state->device;
}

- (BOOL)isPaused {
    return _paused;
}

- (void)setPaused:(BOOL)paused {
    if (paused == _paused) {
        return;
    }
    _paused = paused;
    [self updateRenderLoop];
    if (paused && _state->compositor) {
        // Playback stopped: frames it mapped are no longer needed (thread-safe).
        _state->compositor->textureCache().flush();
    }
}

- (void)renderOnce {
    if (_state->occluded.load()) {
        _state->redrawPending.store(true); // drawn when the window becomes visible
        return;
    }
    _state->retryAttempts.store(0); // a new request: retry afresh if it cannot be presented
    if (_state->renderOncePending.exchange(true)) {
        return; // one already queued; it will pick up the latest frame
    }
    std::shared_ptr<PreviewState> state = _state;
    [self performOnRenderThread:^{
        state->renderOncePending.store(false);
        renderPreviewFrame(state, true, CACurrentMediaTime(), nil);
    } wait:NO];
}

- (void)renderOnceWithCompletion:(void (^)(NSError *))completion {
    _state->retryAttempts.store(0);
    std::shared_ptr<PreviewState> state = _state;
    [self performOnRenderThread:^{
        renderPreviewFrame(state, true, CACurrentMediaTime(), completion);
    } wait:NO];
}

- (NSUInteger)renderCount {
    return _state->renderCount.load(std::memory_order_acquire);
}

- (NSUInteger)skippedLayerCount {
    return _state->skippedLayers.load(std::memory_order_relaxed);
}

- (NSUInteger)missingLayerCount {
    return _state->missingLayers.load(std::memory_order_relaxed);
}

- (CGSize)drawableSize {
    return CGSizeMake(_state->drawableWidth.load(), _state->drawableHeight.load());
}

- (NSError *)lastError {
    std::lock_guard<std::mutex> lock(_state->errorMutex);
    return _state->lastError;
}

- (void)handleMemoryPressure {
    PreviewState &st = *_state;
    if (!st.compositor) {
        return;
    }
    std::lock_guard<std::mutex> lock(st.renderMutex);
    st.compositor->releaseScratchMemory();
}

- (CGImageRef)snapshot {
    NSAssert(NSThread.currentThread != _renderThread, @"-snapshot must not be called on the render thread");
    PreviewState &st = *_state;
    if (!st.compositor) {
        return NULL;
    }
    std::lock_guard<std::mutex> lock(st.renderMutex);
    const auto width = static_cast<NSUInteger>(st.drawableWidth.load());
    const auto height = static_cast<NSUInteger>(st.drawableHeight.load());
    if (!st.hasRendered || width == 0 || height == 0) {
        return NULL;
    }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [st.device newTextureWithDescriptor:desc];
    if (texture == nil) {
        st.setError(makeNSError(media::MediaErrorCode::Internal, @"VEPreviewView: cannot allocate the snapshot texture"));
        return NULL;
    }
    TextureTarget target;
    target.texture = texture;
    const PreviewFrame &frame = st.frame;
    auto lookup = [&frame](const VideoLayer &, std::size_t index, TextureSet &out) {
        return lookupFromFrame(frame, index, out);
    };
    auto result = st.compositor->renderAndWait(st.frame.graph, lookup, target);
    if (!result.ok() || !result->status.ok()) {
        st.setError(makeNSError(result.ok() ? result->status.error() : result.error()));
        return NULL;
    }
    const size_t bytesPerRow = width * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * height];
    [texture getBytes:data.mutableBytes bytesPerRow:bytesPerRow fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace,
                                     static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) |
                                         static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little),
                                     provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (image == NULL) {
        return NULL;
    }
    return (CGImageRef)CFAutorelease(image);
}

@end

@implementation VEPreviewView (Internal)

- (void)setFrameSource:(PreviewFrameSource)source {
    std::lock_guard<std::mutex> lock(_state->renderMutex);
    _state->source = std::move(source);
}

- (const TextureCache *)textureCache {
    return _state->compositor ? &_state->compositor->textureCache() : nullptr;
}

- (void)applyWindowVisible:(BOOL)visible {
    const bool wasOccluded = _state->occluded.exchange(!visible);
    if (wasOccluded == !visible) {
        return;
    }
    [self updateRenderLoop];
    if (visible && _state->redrawPending.load()) {
        _state->retryAttempts.store(0);
        [self requestRedraw];
    }
}

- (NSUInteger)busyCount {
    return _state->busyCount.load();
}

- (NSUInteger)drawableFailureCount {
    return _state->drawableFailures.load();
}

- (BOOL)isRenderLoopRunning {
    return _state->loopRunning.load();
}

- (void)setDrawableProviderForTesting:(id<CAMetalDrawable> (^)(CAMetalLayer *))provider {
    std::lock_guard<std::mutex> lock(_state->hookMutex);
    _state->drawableProvider = [provider copy];
}

- (Compositor *)compositorForTesting {
    return _state->compositor.get();
}

- (NSThread *)renderThreadForTesting {
    return _renderThread;
}

@end
