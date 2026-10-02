#import "VEWaveformView+Internal.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>

namespace {

constexpr MTLPixelFormat kWaveformFormat = MTLPixelFormatBGRA8Unorm;
/// The view's waveform: up to 2048 columns (one per pixel column of a view up to 2048 pixels wide), 256
/// levels, 360 sampled rows.
constexpr std::uint32_t kMaxWaveformColumns = 2048;
/// The clipping counts reach the main thread at most this often (seconds).
constexpr double kClippingPublishInterval = 0.1;

/// What the render thread's reader shares with the view. The view clears `layer` when it goes away.
struct WaveformState {
    std::mutex mutex;
    std::unique_ptr<ve::render::LumaWaveform> waveform; // under mutex
    std::unique_ptr<ve::render::Histogram> histogram;   // under mutex
    // `begin` under mutex; `read` from completion handlers (thread-safe; the ring lives as long as the state).
    std::unique_ptr<ve::render::ScopeStatsRing> stats;
    CAMetalLayer *layer = nil;                    // under mutex
    id<MTLTexture> (^targetProvider)(void) = nil; // under mutex (tests)
    std::atomic<double> drawableWidth{0};
    std::atomic<double> drawableHeight{0};
    std::atomic<NSUInteger> drawCount{0};
    std::atomic<NSInteger> mode{VEScopeModeWaveform};
    std::atomic<NSInteger> histogramStyle{VEHistogramStyleRGBAndLuma};

    // The clipping counts on their way to the main thread.
    std::mutex clipMutex;
    ve::render::ClipStats latest;    // under clipMutex: the last completed frame's
    bool publishScheduled = false;   // under clipMutex
    double lastPublish = -1.0;       // under clipMutex (CACurrentMediaTime)
    __weak VEWaveformView *owner = nil; // read on the main thread only

    /// A frame's counts arrived (a completion handler's thread): kept as the latest, and published on the
    /// main thread unless a publication is already on its way (it takes the latest when it runs).
    void receive(const ve::render::ClipStats &frameStats, const std::shared_ptr<WaveformState> &self);
};

} // namespace

@interface VEWaveformView ()
- (void)applyClipStats:(ve::render::ClipStats)stats;
@end

namespace {

void WaveformState::receive(const ve::render::ClipStats &frameStats, const std::shared_ptr<WaveformState> &self) {
    std::lock_guard<std::mutex> lock(clipMutex);
    latest = frameStats;
    if (publishScheduled) {
        return;
    }
    publishScheduled = true;
    const double wait = lastPublish < 0 ? 0.0 : std::max(0.0, lastPublish + kClippingPublishInterval - CACurrentMediaTime());
    std::weak_ptr<WaveformState> weakState = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        auto state = weakState.lock();
        if (!state) {
            return;
        }
        ve::render::ClipStats published;
        {
            std::lock_guard<std::mutex> publishLock(state->clipMutex);
            state->publishScheduled = false;
            state->lastPublish = CACurrentMediaTime();
            published = state->latest;
        }
        [state->owner applyClipStats:published];
    });
}

} // namespace

@implementation VEWaveformView {
    std::shared_ptr<WaveformState> _state;
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    NSError *_lastError;
    dispatch_block_t _needsFrame;
    double _clippedHighlightFraction;
    double _clippedShadowFraction;
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
    _state->owner = self;
    ve::render::WaveformSettings settings;
    settings.columns = kMaxWaveformColumns;
    auto waveform = ve::render::LumaWaveform::create(_device, settings);
    auto histogram = ve::render::Histogram::create(_device);
    auto stats = ve::render::ScopeStatsRing::create(_device);
    const ve::media::MediaError *failure = !waveform.ok()    ? &waveform.error()
                                       : !histogram.ok() ? &histogram.error()
                                       : !stats.ok()     ? &stats.error()
                                                         : nullptr;
    if (failure != nullptr) {
        _lastError = [NSError errorWithDomain:@"VEWaveformView"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @(failure->description().c_str())}];
        _device = nil;
        return;
    }
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->waveform = std::move(waveform).value();
    _state->histogram = std::move(histogram).value();
    _state->stats = std::move(stats).value();
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

// MARK: - Mode

- (VEScopeMode)mode {
    return VEScopeMode(_state->mode.load());
}

- (void)setMode:(VEScopeMode)mode {
    if (mode != VEScopeModeWaveform && mode != VEScopeModeHistogram) {
        return;
    }
    if (_state->mode.exchange(mode) != mode && _needsFrame != nil) {
        _needsFrame();
    }
}

- (VEHistogramStyle)histogramStyle {
    return VEHistogramStyle(_state->histogramStyle.load());
}

- (void)setHistogramStyle:(VEHistogramStyle)style {
    if (style != VEHistogramStyleRGBAndLuma && style != VEHistogramStyleLuma && style != VEHistogramStyleParade) {
        return;
    }
    if (_state->histogramStyle.exchange(style) != style && _needsFrame != nil &&
        _state->mode.load() == VEScopeModeHistogram) {
        _needsFrame();
    }
}

// MARK: - Clipping

- (double)clippedHighlightFraction {
    return _clippedHighlightFraction;
}

- (double)clippedShadowFraction {
    return _clippedShadowFraction;
}

- (void)applyClipStats:(ve::render::ClipStats)stats {
    const double highlights = stats.whiteFraction();
    const double shadows = stats.blackFraction();
    if (highlights == _clippedHighlightFraction && shadows == _clippedShadowFraction) {
        return;
    }
    _clippedHighlightFraction = highlights;
    _clippedShadowFraction = shadows;
    if (_clippingHandler != nil) {
        _clippingHandler(highlights, shadows);
    }
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
        if (!state->waveform || !state->histogram || !state->stats ||
            (state->layer == nil && state->targetProvider == nil)) {
            return;
        }
        if (state->targetProvider == nil && (state->drawableWidth.load() < 1 || state->drawableHeight.load() < 1)) {
            return;
        }
        const std::int32_t workingWidth = std::int32_t(working.width);
        const std::int32_t workingHeight = std::int32_t(working.height);
        const ve::render::PixelRect counted = ve::render::clipToTexture(frame, workingWidth, workingHeight);
        if (counted.isEmpty()) {
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
        if (target == nil) {
            return;
        }
        ve::render::ScopeStatsSlot slot;
        bool drawn = false;
        if (state->mode.load() == VEScopeModeHistogram) {
            slot = state->stats->begin(commandBuffer, std::uint64_t(counted.width) * std::uint64_t(counted.height));
            drawn = state->histogram->encodeAccumulate(commandBuffer, working, frame, &slot) &&
                    state->histogram->encodeDisplay(commandBuffer, target,
                                                    ve::render::HistogramStyle(state->histogramStyle.load()));
        } else {
            // One waveform column per pixel column of the view (and no more than the frame has).
            const std::uint32_t columns = std::max<std::uint32_t>(
                1, std::min<std::uint32_t>({std::uint32_t(target.width), kMaxWaveformColumns, std::uint32_t(counted.width)}));
            const std::uint32_t rows = state->waveform->sampleRowsFor(frame, workingWidth, workingHeight);
            slot = state->stats->begin(commandBuffer, std::uint64_t(counted.width) * rows);
            drawn = state->waveform->encodeAccumulate(commandBuffer, working, frame, columns, &slot) &&
                    state->waveform->encodeDisplay(commandBuffer, target);
        }
        if (!drawn) {
            return;
        }
        if (drawable != nil) {
            [commandBuffer presentDrawable:drawable];
        }
        std::weak_ptr<WaveformState> weakState = state;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted) {
                return;
            }
            auto s = weakState.lock();
            if (!s) {
                return;
            }
            s->drawCount.fetch_add(1);
            if (const std::optional<ve::render::ClipStats> stats = s->stats->read(slot)) {
                s->receive(*stats, s);
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
    if (!_state->waveform) {
        return {};
    }
    std::vector<std::uint32_t> counts = _state->waveform->countsSnapshot();
    counts.resize(std::size_t(_state->waveform->columns()) * _state->waveform->settings().levels);
    return counts;
}

- (ve::render::WaveformSettings)settingsForTesting {
    std::lock_guard<std::mutex> lock(_state->mutex);
    if (!_state->waveform) {
        return ve::render::WaveformSettings{};
    }
    ve::render::WaveformSettings settings = _state->waveform->settings();
    settings.columns = _state->waveform->columns();
    return settings;
}

- (std::array<std::uint32_t, ve::render::Histogram::kBins>)histogramCountsForTesting:(ve::render::HistogramChannel)channel {
    std::lock_guard<std::mutex> lock(_state->mutex);
    return _state->histogram ? _state->histogram->counts(channel) : std::array<std::uint32_t, ve::render::Histogram::kBins>{};
}

- (ve::render::ClipStats)clipStatsForTesting {
    std::lock_guard<std::mutex> lock(_state->clipMutex);
    return _state->latest;
}

@end
