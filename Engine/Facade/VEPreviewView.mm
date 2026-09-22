#import "VEPreviewView.h"

#include "../Render/Compositor.h"
#import "../Render/VEPreviewView+Internal.h"

#import <QuartzCore/QuartzCore.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>

using namespace ve;
using namespace ve::render;

namespace {

NSString *const kVEPreviewErrorDomain = @"VidEditEngine.PreviewView";

NSError *makeNSError(const media::MediaError &error) {
    return [NSError errorWithDomain:kVEPreviewErrorDomain
                               code:static_cast<NSInteger>(error.code)
                           userInfo:@{NSLocalizedDescriptionKey : @(error.description().c_str())}];
}

NSError *makeNSError(NSString *message) {
    return [NSError errorWithDomain:kVEPreviewErrorDomain
                               code:static_cast<NSInteger>(media::MediaErrorCode::Internal)
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Everything the render thread touches. Shared by the view, the display-link proxy and the
// blocks posted to the render thread, so none of them needs the view to be alive.
struct PreviewState {
    id<MTLDevice> device = nil;
    CAMetalLayer *layer = nil;
    std::unique_ptr<Compositor> compositor;

    // Guards the frame source, the frame and the compositor. The display-link path only
    // try-locks it (never blocks); renderOnce, snapshot and setFrameSource lock it.
    std::mutex renderMutex;
    PreviewFrameSource source;
    PreviewFrame frame;
    std::atomic<bool> hasRendered{false};

    std::atomic<NSUInteger> renderCount{0};
    std::atomic<bool> renderOncePending{false};
    std::atomic<bool> forceRedraw{false};
    std::atomic<double> drawableWidth{0};
    std::atomic<double> drawableHeight{0};

    std::mutex errorMutex;
    NSError *lastError = nil;

    // The compositor waits for its in-flight frames, whose completions touch the members
    // below; destroy it first.
    ~PreviewState() { compositor.reset(); }

    void setError(NSError *error) {
        std::lock_guard<std::mutex> lock(errorMutex);
        lastError = error;
    }
};

bool lookupFromFrame(const PreviewFrame &frame, std::size_t index, TextureSet &out) {
    if (index < frame.textures.size() && frame.textures[index]) {
        out = frame.textures[index];
        return true;
    }
    return false;
}

// Renders on the render thread. `once`: renderOnce semantics (blocking lock, always renders).
// `completion` (may be nil) is called on the main queue.
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
        finish(makeNSError(@"VEPreviewView: Metal is not available"));
        return;
    }
    std::unique_lock<std::mutex> lock(st.renderMutex, std::defer_lock);
    if (once) {
        lock.lock();
    } else if (!lock.try_lock()) {
        return; // a snapshot or source change is in progress; skip this vsync
    }
    const bool forced = st.forceRedraw.exchange(false);
    PreviewFrameRequest request;
    request.targetTimestamp = timestamp;
    request.isRenderOnce = once;
    request.textureCache = &st.compositor->textureCache();
    const bool fresh = st.source ? st.source(request, st.frame) : false;
    if (!fresh && !once && !forced) {
        return;
    }
    if (st.drawableWidth.load() < 1 || st.drawableHeight.load() < 1) {
        finish(nil); // nothing visible to draw into
        return;
    }
    id<CAMetalDrawable> drawable = [st.layer nextDrawable];
    if (drawable == nil) {
        NSError *error = makeNSError(@"VEPreviewView: no drawable available");
        st.setError(error);
        finish(error);
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
    options.waitForFreeSlot = once;
    auto submitted = st.compositor->render(
        st.frame.graph, lookup, target,
        [raw, completion](const RenderResult &result) {
            raw->renderCount.fetch_add(1, std::memory_order_relaxed);
            NSError *error = nil;
            if (!result.status.ok()) {
                error = makeNSError(result.status.error());
                raw->setError(error);
            }
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
        st.forceRedraw.store(true); // GPU is behind; try again next vsync
        return;
    }
    st.hasRendered = true;
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
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
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
            *error = makeNSError(@"VEPreviewView: no Metal device");
        }
        return NO;
    }
    auto compositor = Compositor::create(chosen);
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
    if (CGSizeEqualToSize(size, _metalLayer.drawableSize)) {
        return;
    }
    if (size.width >= 1 && size.height >= 1) {
        _metalLayer.drawableSize = size;
    }
    _state->drawableWidth.store(size.width);
    _state->drawableHeight.store(size.height);
    [self requestRedraw];
}

// Redraw the current frame at the new size: next vsync when running, or once when paused.
- (void)requestRedraw {
    if (!_state->hasRendered && !_state->source) {
        return;
    }
    if (_paused) {
        [self renderOnce];
    } else {
        _state->forceRedraw.store(true);
    }
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
    CADisplayLink *link = _displayLink;
    const BOOL linkPaused = paused || !_state->compositor;
    [self performOnRenderThread:^{
        link.paused = linkPaused;
    } wait:NO];
}

- (void)renderOnce {
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
    std::shared_ptr<PreviewState> state = _state;
    [self performOnRenderThread:^{
        renderPreviewFrame(state, true, CACurrentMediaTime(), completion);
    } wait:NO];
}

- (NSUInteger)renderCount {
    return _state->renderCount.load(std::memory_order_relaxed);
}

- (CGSize)drawableSize {
    return CGSizeMake(_state->drawableWidth.load(), _state->drawableHeight.load());
}

- (NSError *)lastError {
    std::lock_guard<std::mutex> lock(_state->errorMutex);
    return _state->lastError;
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
        st.setError(makeNSError(@"VEPreviewView: cannot allocate the snapshot texture"));
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

@end
