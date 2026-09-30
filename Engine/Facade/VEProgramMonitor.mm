// VEProgramMonitor: see VEProgramMonitor+Internal.h.

#import "VEProgramMonitor+Internal.h"

#import "VEFacadeSupport+Internal.h"
#import "VEPreviewView.h"
#import "VETypes+Internal.h"

#import "../Render/VEPreviewView+Internal.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>
#include <utility>

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
        [strongSelf->_view renderOnce];
        [strongSelf->_outputView renderOnce];
    };
    _playback->setObserver(dispatch_get_main_queue(), std::move(observer));
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
    _view = view;
    if (view != nil) {
        [view setFrameSource:_playback->frameSource()];
        [view renderOnce];
    }
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
    [view renderOnce];
}

- (void)detachOutputView {
    VE_ASSERT_MAIN();
    VEPreviewView *view = _outputView;
    _outputView = nil;
    if (view != nil) {
        [view setFrameSource:ve::render::PreviewFrameSource{}];
        view.paused = YES;
    }
}

- (nullable VEPreviewView *)outputView {
    VE_ASSERT_MAIN();
    return _outputView;
}

// No main-thread check: the engine's dealloc calls it (the engine only logs a fault when its last
// reference goes away off the main thread), and so does this class's.
- (void)disconnectViews {
    [_view setFrameSource:ve::render::PreviewFrameSource{}];
    [_outputView setFrameSource:ve::render::PreviewFrameSource{}];
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
    if (!_published || _generation != generation) {
        _published = true;
        _generation = generation;
        _playback->setSequence(std::move(snapshot), project.activeSequenceId);
    } else {
        _playback->modelChanged(std::move(snapshot));
    }
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
    return _playback->previewSolo().has_value();
}

- (void)clearPreviewSolo {
    VE_ASSERT_MAIN();
    _playback->setPreviewSolo(std::nullopt);
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
}

- (void)scrubToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    if (CMTIME_IS_NUMERIC(time)) {
        _playback->scrubTo(time);
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

- (void)setIdleLookahead:(BOOL)enabled {
    VE_ASSERT_MAIN();
    _playback->setIdleLookahead(enabled);
}

- (void)registerAsset:(AssetId)asset path:(const std::string &)path {
    VE_ASSERT_MAIN();
    _pool->registerAsset(asset, path);
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
