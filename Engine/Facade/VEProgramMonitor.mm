// VEProgramMonitor: see VEProgramMonitor+Internal.h.

#import "VEProgramMonitor+Internal.h"

#import "VEFacadeSupport+Internal.h"
#import "VEPreviewView.h"
#import "VETypes+Internal.h"
#import "VEWaveformView+Internal.h"

#import "../Render/VEPreviewView+Internal.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>
#include <utility>

// This class knows nothing of the engine (VEEngine+Internal.h, "Facade layout"): neither its header nor
// this file may bring in the engine's headers, directly or through another header.
#if defined(VE_ENGINE_HEADER_INCLUDED) || defined(VE_ENGINE_INTERNAL_HEADER_INCLUDED)
#error "VEProgramMonitor must not depend on VEEngine: it reaches it only through what the engine passes in"
#endif

using namespace ve;
using namespace ve::facade;

@implementation VEProgramMonitor {
    VEProgramMonitorStatusBlock _onStatus;
    // Declared in this order: the controller goes before the pool it uses.
    std::shared_ptr<media::DecodePool> _pool;
    std::unique_ptr<playback::PlaybackController> _playback;
    uint64_t _generation; // project generation the controller's sequence belongs to
    bool _published;      // the controller has the current project's sequence
    __weak VEPreviewView *_view;
    __weak VEPreviewView *_outputView; // mirrors the program (a second display)
    __weak VEWaveformView *_waveformView; // draws the program view's scope
    BOOL _showsClippingOverlay;           // the program view tints clipped pixels
    CGSize _sequenceSize;                 // of the published sequence, for the views' scale (0 x 0: none)
}

- (instancetype)initWithRouter:(std::shared_ptr<media::BackendRouter>)router
                    frameCache:(std::shared_ptr<media::FrameCache>)frameCache
                        config:(ProgramMonitorConfig)config
                      onStatus:(VEProgramMonitorStatusBlock)onStatus {
    VE_ASSERT_MAIN();
    if ((self = [super init])) {
        _onStatus = [onStatus copy];
        media::DecodePool::Config poolConfig;
        poolConfig.budgetFraction = config.poolBudgetShare;
        poolConfig.decodeOptions.highPrecision = true; // deep alpha, RGB and still sources keep their precision
        _pool = std::make_shared<media::DecodePool>(router, frameCache, poolConfig);
        playback::PlaybackConfig playbackConfig;
        playbackConfig.scrubLaneBase = config.scrubLaneBase;
        _playback = std::make_unique<playback::PlaybackController>(router, frameCache, _pool, playbackConfig);
        [self observeController];
    }
    return self;
}

- (void)dealloc {
    // The views may outlive the monitor: they must stop calling into the controller first.
    [self disconnectViews];
}

- (void)observeController {
    __weak VEProgramMonitor *weakSelf = self;
    playback::PlaybackObserver observer;
    observer.statusChanged = [weakSelf](const playback::PlaybackStatus &status) {
        VEProgramMonitor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf controllerStatusChanged:status];
    };
    observer.needsDisplay = [weakSelf] {
        VEProgramMonitor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Often already drawn by -presentChange (the change was made on this thread): then nothing is drawn.
        [strongSelf->_view renderIfChanged];
        [strongSelf->_outputView renderIfChanged];
    };
    _playback->setObserver(dispatch_get_main_queue(), std::move(observer));
}

/// The paused picture may have changed (an edit, a seek, a step, the solo): the views draw it now, on their render
/// threads, rather than when the controller's redraw request reaches the main queue. That request waits for the
/// rest of this turn of the main thread, which during a drag is SwiftUI updating the window for the edit (several
/// milliseconds, tens in a Debug build); a box dragged on the monitor would show its picture that much later. A
/// picture still being decoded or rendered is not drawn: the source keeps the previous one until it lands (the
/// controller's request then draws it). While running, the display link draws every frame.
- (void)presentChange {
    if (isRunning(_playback->state())) {
        return;
    }
    [_view renderIfChanged];
    [_outputView renderIfChanged];
}

- (void)controllerStatusChanged:(const playback::PlaybackStatus &)status {
    if (VEPreviewView *output = _outputView) {
        // The output view's render loop follows the program's transport (the owner of the
        // program view does this for it).
        const BOOL paused = !isRunning(status.state);
        if (output.paused != paused) {
            output.paused = paused;
        }
    }
    _onStatus(makePlaybackStatus(status));
}

// MARK: - Views

- (void)attachView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _view;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    if (previous != nil && previous != view) {
        [previous setWorkingFrameReader:ve::render::WorkingFrameReader{}];
    }
    if (previous != nil && previous != view) {
        previous.clippingOverlay = NO;
    }
    if (previous != nil && previous != view) {
        previous.drawableSizeHandler = nil;
    }
    _view = view;
    if (view != nil) {
        [view setFrameSource:_playback->frameSource()];
        view.clippingOverlay = _showsClippingOverlay;
        [self installWaveformReader];
        [self followDrawableSizeOf:view];
        [view renderOnce];
    }
    [self updateGeneratedOutputScale];
}

/// Titles are rendered for the largest view showing the program (PlaybackController::setGeneratedOutputScale):
/// follows `view`'s size.
- (void)followDrawableSizeOf:(VEPreviewView *)view {
    __weak VEProgramMonitor *weakSelf = self;
    view.drawableSizeHandler = ^(CGSize) {
      [weakSelf updateGeneratedOutputScale];
    };
}

/// The output scale for the controller's generated pictures: monitorOutputScale of the largest attached view (in
/// drawable pixels per sequence pixel, as the view fits the sequence into its drawable).
- (void)updateGeneratedOutputScale {
    VE_ASSERT_MAIN();
    double largest = 0.0;
    VEPreviewView *views[] = {_view, _outputView};
    for (VEPreviewView *view : views) {
        if (view == nil || !(_sequenceSize.width > 0) || !(_sequenceSize.height > 0)) {
            continue;
        }
        const CGSize drawable = view.drawableSize;
        largest = std::max(largest, std::min(drawable.width / _sequenceSize.width, drawable.height / _sequenceSize.height));
    }
    _playback->setGeneratedOutputScale(playback::monitorOutputScale(largest));
}

- (void)attachWaveformView:(nullable VEWaveformView *)view {
    VE_ASSERT_MAIN();
    VEWaveformView *previous = _waveformView;
    if (previous != nil && previous != view) {
        [previous setNeedsFrameHandler:nil];
    }
    _waveformView = view;
    if (view != nil) {
        __weak VEProgramMonitor *weakSelf = self;
        [view setNeedsFrameHandler:^{
            VEProgramMonitor *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_view renderOnce];
            }
        }];
    }
    [self installWaveformReader];
    [_view renderOnce];
}

- (nullable VEWaveformView *)waveformView {
    VE_ASSERT_MAIN();
    return _waveformView;
}

- (BOOL)showsClippingOverlay {
    VE_ASSERT_MAIN();
    return _showsClippingOverlay;
}

- (void)setShowsClippingOverlay:(BOOL)shows {
    VE_ASSERT_MAIN();
    if (shows == _showsClippingOverlay) {
        return;
    }
    _showsClippingOverlay = shows;
    _view.clippingOverlay = shows;
    [_view renderOnce];
}

/// The program view reads its working frame into the waveform view, or nothing.
- (void)installWaveformReader {
    VEWaveformView *waveform = _waveformView;
    [_view setWorkingFrameReader:waveform != nil ? [waveform workingFrameReader] : ve::render::WorkingFrameReader{}];
}

- (nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    return _view;
}

- (void)attachOutputView:(VEPreviewView *)view {
    VE_ASSERT_MAIN();
    if (_outputView != nil && _outputView != view) {
        [self detachOutputView];
    }
    _outputView = view;
    // A mirror source: the same frames as the program view, without adding to its counters.
    [view setFrameSource:_playback->frameSource(playback::PlaybackController::SourceRole::Mirror)];
    view.paused = !isRunning(_playback->state());
    [self followDrawableSizeOf:view];
    [self updateGeneratedOutputScale];
    [view renderOnce];
}

- (void)detachOutputView {
    VE_ASSERT_MAIN();
    VEPreviewView *view = _outputView;
    _outputView = nil;
    if (view != nil) {
        [view setFrameSource:ve::render::PreviewFrameSource{}];
        view.paused = YES;
        view.drawableSizeHandler = nil;
    }
    [self updateGeneratedOutputScale];
}

- (nullable VEPreviewView *)outputView {
    VE_ASSERT_MAIN();
    return _outputView;
}

// No main-thread check: the engine's dealloc calls it (the engine only logs a fault when its last
// reference goes away off the main thread), and so does this class's.
- (void)disconnectViews {
    [_view setFrameSource:ve::render::PreviewFrameSource{}];
    [_view setWorkingFrameReader:ve::render::WorkingFrameReader{}];
    [_outputView setFrameSource:ve::render::PreviewFrameSource{}];
    [_waveformView setNeedsFrameHandler:nil];
}

- (void)handleMemoryPressure {
    VE_ASSERT_MAIN();
    [_view handleMemoryPressure];
    [_outputView handleMemoryPressure];
}

// MARK: - The model

- (void)publishProject:(const Project &)project generation:(uint64_t)generation {
    VE_ASSERT_MAIN();
    auto snapshot = std::make_shared<const Project>(project);
    const Sequence *sequence = project.activeSequence();
    const CGSize size = sequence ? CGSizeMake(sequence->width, sequence->height) : CGSizeZero;
    const bool resized = !CGSizeEqualToSize(size, _sequenceSize);
    _sequenceSize = size;
    if (!_published || _generation != generation) {
        _published = true;
        _generation = generation;
        _playback->setSequence(std::move(snapshot), project.activeSequenceId);
    } else {
        _playback->modelChanged(std::move(snapshot));
    }
    if (resized) {
        [self updateGeneratedOutputScale];
    }
    [self presentChange];
}

- (void)detachFromProject {
    VE_ASSERT_MAIN();
    _playback->setSequence(std::make_shared<const Project>(), SequenceId{});
    _published = false;
}

// MARK: - Preview solo

- (BOOL)setPreviewSoloClip:(ClipId)clip identityMotion:(BOOL)identityMotion {
    VE_ASSERT_MAIN();
    // The controller has the current model (every model change is published to it at once).
    _playback->setPreviewSolo(playback::PlaybackController::PreviewSolo{clip, identityMotion == YES});
    [self presentChange];
    return _playback->previewSolo().has_value();
}

- (void)clearPreviewSolo {
    VE_ASSERT_MAIN();
    _playback->setPreviewSolo(std::nullopt);
    [self presentChange];
}

- (std::optional<playback::PlaybackController::PreviewSolo>)previewSolo {
    VE_ASSERT_MAIN();
    return _playback->previewSolo();
}

// MARK: - Transport

- (void)play {
    VE_ASSERT_MAIN();
    _playback->play();
}

- (void)pause {
    VE_ASSERT_MAIN();
    _playback->pause();
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    _playback->togglePlay();
}

- (void)seekToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    _playback->seek(CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero, playback::SeekMode::Exact);
    [self presentChange];
}

- (void)setRate:(double)rate {
    VE_ASSERT_MAIN();
    _playback->setRate(rate);
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    _playback->shuttleForward();
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    _playback->shuttleReverse();
}

- (void)stepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    _playback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
    [self presentChange];
}

- (void)scrubToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    if (CMTIME_IS_NUMERIC(time)) {
        _playback->scrubTo(time);
        [self presentChange];
    }
}

- (void)endScrub {
    VE_ASSERT_MAIN();
    _playback->endScrub();
}

- (void)pauseIfRunning {
    VE_ASSERT_MAIN();
    if (isRunning(_playback->state())) {
        _playback->pause();
    }
}

- (BOOL)isRunning {
    VE_ASSERT_MAIN();
    return isRunning(_playback->state());
}

- (BOOL)isMuted {
    VE_ASSERT_MAIN();
    return _playback->isMuted();
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    _playback->setMuted(muted);
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return playbackStateToVE(_playback->state());
}

- (double)rate {
    VE_ASSERT_MAIN();
    return _playback->rate();
}

- (CMTime)currentTime {
    VE_ASSERT_MAIN();
    return _playback->currentTime();
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return makePlaybackStatus(_playback->status());
}

- (NSString *)playbackError {
    VE_ASSERT_MAIN();
    const playback::PlaybackStatus status = _playback->status();
    return status.lastError ? toNS(status.lastError->message) : @"";
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return makePlaybackStats(_playback->stats(), _playback->lastPresented());
}

// MARK: - Lookahead, media and epochs

- (BOOL)controllerIdleLookahead {
    VE_ASSERT_MAIN();
    return _playback->idleLookahead();
}

- (void)setIdleLookahead:(BOOL)enabled {
    VE_ASSERT_MAIN();
    _playback->setIdleLookahead(enabled);
}

- (void)registerAsset:(AssetId)asset path:(const std::string &)path {
    VE_ASSERT_MAIN();
    _pool->registerAsset(asset, path);
}

- (void)invalidateGeneratedAsset:(AssetId)asset {
    VE_ASSERT_MAIN();
    _pool->invalidate(asset);
}

- (void)registerAsset:(AssetId)asset path:(const std::string &)path routing:(const media::RoutedMediaInfo &)routed {
    VE_ASSERT_MAIN();
    _pool->registerAsset(asset, path, routed);
    _playback->setAssetRouting(asset, routed);
}

- (void)beginMediaEpoch:(media::FrameCache::Epoch)epoch {
    VE_ASSERT_MAIN();
    _pool->beginEpoch(epoch);
}

- (void)forgetMedia {
    VE_ASSERT_MAIN();
    _playback->forgetMedia();
}

@end
