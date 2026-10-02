#import "VEWaveformView+Internal.h"

#import <QuartzCore/QuartzCore.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>

namespace {

constexpr MTLPixelFormat kWaveformFormat = MTLPixelFormatBGRA8Unorm;

/// What the render thread's reader shares with the view. The view clears `layer` when it goes away.
struct WaveformState {
    std::mutex mutex;
    std::unique_ptr<ve::render::LumaWaveform> waveform; // under mutex
    CAMetalLayer *layer = nil;                         // under mutex
    id<MTLTexture> (^targetProvider)(void) = nil;      // under mutex (tests)
    std::atomic<double> drawableWidth{0};
    std::atomic<double> drawableHeight{0};
    std::atomic<NSUInteger> drawCount{0};
};

} // namespace

@implementation VEWaveformView {
    std::shared_ptr<WaveformState> _state;
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    NSError *_lastError;
    dispatch_block_t _needsFrame;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        [self commonSetup];
    }
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self commonSetup];
    }
    return self;
}

- (void)commonSetup {
    _state = std::make_shared<WaveformState>();
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.pixelFormat = kWaveformFormat;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.maximumDrawableCount = 3;
    _metalLayer.allowsNextDrawableTimeout = YES;
    _metalLayer.opaque = YES;
    _metalLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _metalLayer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

    _device = MTLCreateSystemDefaultDevice();
    if (_device == nil) {
        _lastError = [NSError errorWithDomain:@"VEWaveformView"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"No Metal device."}];
        return;
    }
    _metalLayer.device = _device;
    auto waveform = ve::render::LumaWaveform::create(_device);
    if (!waveform.ok()) {
        _lastError = [NSError
            errorWithDomain:@"VEWaveformView"
                       code:2
                   userInfo:@{NSLocalizedDescriptionKey : @(waveform.error().description().c_str())}];
        _device = nil;
        return;
    }
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->waveform = std::move(waveform).value();
    _state->layer = _metalLayer;
}

- (void)dealloc {
    // A reader still installed on the program view keeps the state: it stops drawing.
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->layer = nil;
}

- (CALayer *)makeBackingLayer {
    return _metalLayer;
}

- (nullable id<MTLDevice>)device {
    return _device;
}

- (NSUInteger)drawCount {
    return _state->drawCount.load();
}

- (nullable NSError *)lastError {
    return _lastError;
}

// MARK: - Size

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
    const bool changed = size.width != _state->drawableWidth.load() || size.height != _state->drawableHeight.load();
    if (size.width >= 1 && size.height >= 1 && !CGSizeEqualToSize(size, _metalLayer.drawableSize)) {
        _metalLayer.drawableSize = size;
    }
    _state->drawableWidth.store(size.width);
    _state->drawableHeight.store(size.height);
    if (changed && size.width >= 1 && size.height >= 1 && _needsFrame != nil) {
        _needsFrame();
    }
}

// MARK: - Internal

- (ve::render::WorkingFrameReader)workingFrameReader {
    std::shared_ptr<WaveformState> state = _state;
    return [state](id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const ve::render::PixelRect &frame) {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->waveform || (state->layer == nil && state->targetProvider == nil)) {
            return;
        }
        if (state->targetProvider == nil && (state->drawableWidth.load() < 1 || state->drawableHeight.load() < 1)) {
            return;
        }
        if (!state->waveform->encodeAccumulate(commandBuffer, working, frame)) {
            return;
        }
        id<CAMetalDrawable> drawable = nil;
        id<MTLTexture> target = nil;
        if (state->targetProvider != nil) {
            target = state->targetProvider();
        } else {
            drawable = [state->layer nextDrawable];
            target = drawable.texture;
        }
        if (target == nil || !state->waveform->encodeDisplay(commandBuffer, target)) {
            return;
        }
        if (drawable != nil) {
            [commandBuffer presentDrawable:drawable];
        }
        std::weak_ptr<WaveformState> weakState = state;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status == MTLCommandBufferStatusCompleted) {
                if (auto s = weakState.lock()) {
                    s->drawCount.fetch_add(1);
                }
            }
        }];
    };
}

- (void)setNeedsFrameHandler:(nullable dispatch_block_t)handler {
    _needsFrame = [handler copy];
}

- (void)setTargetProviderForTesting:(nullable id<MTLTexture> (^)(void))provider {
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->targetProvider = [provider copy];
}

- (std::vector<std::uint32_t>)countsForTesting {
    std::lock_guard<std::mutex> lock(_state->mutex);
    return _state->waveform ? _state->waveform->countsSnapshot() : std::vector<std::uint32_t>{};
}

- (ve::render::WaveformSettings)settingsForTesting {
    std::lock_guard<std::mutex> lock(_state->mutex);
    return _state->waveform ? _state->waveform->settings() : ve::render::WaveformSettings{};
}

@end
