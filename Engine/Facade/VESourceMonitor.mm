// VESourceMonitor: see VESourceMonitor+Internal.h.

#import "VESourceMonitor+Internal.h"

#import "VEFacadeSupport+Internal.h"
#import "VEPreviewView.h"
#import "VEProgramFrameProvider+Internal.h"
#import "VETypes+Internal.h"

#import "../Render/VEPreviewView+Internal.h"

#include "../Model/SourceProject.h"
#include "../Render/Scheduler.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>
#include <utility>

// This class knows nothing of the engine (VEEngine+Internal.h, "Facade layout"): neither its header nor
// this file may bring in the engine's headers, directly or through another header.
#if defined(VE_ENGINE_HEADER_INCLUDED) || defined(VE_ENGINE_INTERNAL_HEADER_INCLUDED)
#error "VESourceMonitor must not depend on VEEngine: it reaches it only through what the engine passes in"
#endif

using namespace ve;
using namespace ve::facade;

namespace {

/// The ids of the source monitor's private one-clip project: they start at 2^56, never colliding
/// with model ids; kSourceIds.videoClip is its picture's clip in the still graphs too.
const SourceProjectIds kSourceIds = [] {
    SourceProjectIds ids;
    ids.first = uint64_t(1) << 56;
    ids.videoClip = ClipId(ids.first + 10);
    ids.audioClip = ClipId(ids.first + 11);
    return ids;
}();

} // namespace

@implementation VESourceMonitor {
    std::shared_ptr<media::BackendRouter> _router;
    std::shared_ptr<media::FrameCache> _frameCache;
    SourceMonitorConfig _config;
    VESourceMonitorStatusBlock _onStatus;

    // A pool of its own (a playback controller replaces its pool's whole target set), a still
    // provider for scrubbing and a controller over a private one-clip project, created when the
    // monitor first plays. Declared in this order: the controller goes before the pool it uses.
    std::shared_ptr<media::DecodePool> _pool;
    std::shared_ptr<ProgramFrameProvider> _provider;
    std::unique_ptr<playback::PlaybackController> _playback;
    __weak VEPreviewView *_view;
    AssetId _asset;
    CMTime _time;
    std::optional<Project> _project; // for _asset
    bool _sharpening;                // what it last drew with (Project::sharpenScaledDownSources' default)
    AssetId _playbackAsset;          // asset of the controller's sequence
    bool _usesController;            // the view shows the controller's picture
    BOOL _visible;                   // see -visible
    BOOL _idleLookaheadAllowed;      // see -idleLookaheadAllowed
    NSUInteger _pictureRefreshes;    // see -pictureRefreshes
}

- (instancetype)initWithRouter:(std::shared_ptr<media::BackendRouter>)router
                    frameCache:(std::shared_ptr<media::FrameCache>)frameCache
                        config:(SourceMonitorConfig)config
                      onStatus:(VESourceMonitorStatusBlock)onStatus {
    VE_ASSERT_MAIN();
    if ((self = [super init])) {
        _router = std::move(router);
        _frameCache = std::move(frameCache);
        _config = config;
        _onStatus = [onStatus copy];
        media::DecodePool::Config poolConfig;
        poolConfig.budgetFraction = config.poolBudgetShare;
        poolConfig.decodeOptions.highPrecision = true; // deep alpha, RGB and still sources keep their precision
        _pool = std::make_shared<media::DecodePool>(_router, _frameCache, poolConfig);
        _provider = std::make_shared<ProgramFrameProvider>(_pool, config.scrubLaneBase);
        _time = kCMTimeZero;
        _sharpening = true;
        _visible = YES;
        _idleLookaheadAllowed = YES;
    }
    return self;
}

- (void)dealloc {
    // The view may outlive the monitor: it must stop calling into the provider and controller.
    [self disconnectView];
}

// MARK: - View and picture

- (void)attachView:(nullable VEPreviewView *)view project:(const Project &)project {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _view;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _view = view;
    if (view != nil) {
        [view setFrameSource:_usesController && _playback ? _playback->frameSource() : _provider->makeSource()];
        [self refreshPictureInProject:project];
    }
}

// No main-thread check: the engine's dealloc calls it (the engine only logs a fault when its last
// reference goes away off the main thread), and so does this class's.
- (void)disconnectView {
    [_view setFrameSource:ve::render::PreviewFrameSource{}];
}

- (void)handleMemoryPressure {
    VE_ASSERT_MAIN();
    [_view handleMemoryPressure];
}

/// Shows the provider's picture of the asset at _time (black without an asset). `project` is the
/// model a still asset is looked up in.
- (void)refreshPictureInProject:(const Project &)project {
    ++_pictureRefreshes;
    if (_usesController) {
        [_view renderOnce];
        return;
    }
    RenderGraph graph;
    if (_project) {
        const Sequence &sequence = *_project->activeSequence();
        graph = Scheduler::renderGraphAt(sequence, *_project, _time);
        graph.width = sequence.width;
        graph.height = sequence.height;
    } else if (const MediaAsset *asset = project.findAsset(_asset);
               asset != nullptr && asset->isStill()) {
        VideoLayer layer;
        layer.clipId = kSourceIds.videoClip;
        layer.assetId = asset->id;
        layer.isStill = true;
        layer.sourceRotationDegrees = asset->rotationDegrees;
        graph.layers.push_back(layer);
        graph.time = kCMTimeZero;
        graph.width = std::max(1, asset->width);
        graph.height = std::max(1, asset->height);
        graph.sharpenMinified = project.sharpenScaledDownSources;
    }
    if (_view == nil) {
        _provider->cancel();
        return;
    }
    __weak VESourceMonitor *weakSelf = self;
    _provider->show(std::move(graph), [weakSelf] {
        VESourceMonitor *strongSelf = weakSelf;
        if (strongSelf != nil && !strongSelf->_usesController) {
            [strongSelf->_view renderOnce];
        }
    });
}

// MARK: - Asset and position

- (BOOL)showAsset:(const MediaAsset &)asset
           atTime:(CMTime)time
    frameDuration:(CMTime)frameDuration
          project:(const Project &)project {
    VE_ASSERT_MAIN();
    if (asset.id != _asset) {
        [self resetWithProject:project];
        _asset = asset.id;
        _project = makeSourceProject(asset, frameDuration, project.sharpenScaledDownSources, kSourceIds);
    }
    _time = time;
    if (_usesController && _playback) {
        _playback->seek(time, playback::SeekMode::Exact);
        return YES; // the controller reports the new position
    }
    [self refreshPictureInProject:project];
    return NO;
}

- (void)resetWithProject:(const Project &)project {
    VE_ASSERT_MAIN();
    _provider->cancel();
    if (_usesController) {
        _usesController = false;
        [_view setFrameSource:_provider->makeSource()];
    }
    if (_playback && _playbackAsset) {
        // Stops it and drops its private project (and decode targets) until the next play.
        _playback->setSequence(std::make_shared<const Project>(), SequenceId{});
        _playbackAsset = AssetId{};
    }
    _asset = AssetId{};
    _project.reset();
    _time = kCMTimeZero;
    [self refreshPictureInProject:project];
}

- (BOOL)resetIfAssetLeft:(const Project &)project {
    VE_ASSERT_MAIN();
    if (_asset && project.findAsset(_asset) == nullptr) {
        [self resetWithProject:project];
        return YES;
    }
    return NO;
}

- (void)syncSharpeningWith:(const Project &)project {
    VE_ASSERT_MAIN();
    const bool sharpen = project.sharpenScaledDownSources;
    if (_sharpening == sharpen) {
        return;
    }
    _sharpening = sharpen;
    if (_project) {
        _project->sharpenScaledDownSources = sharpen;
        if (_playback && _playbackAsset == _asset) {
            _playback->modelChanged(std::make_shared<const Project>(*_project));
        }
    }
    if (_asset) {
        [self refreshPictureInProject:project];
    }
}

- (AssetId)asset {
    VE_ASSERT_MAIN();
    return _asset;
}

- (CMTime)time {
    VE_ASSERT_MAIN();
    return _usesController && _playback ? _playback->currentTime() : _time;
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return _usesController && _playback ? playbackStateToVE(_playback->state()) : VEPlaybackStateStopped;
}

/// The status to report for `status`, the controller's: the scrub position, stopped, while the
/// view does not show the controller's picture.
- (VEPlaybackStatus *)reportedStatus:(const playback::PlaybackStatus &)status {
    if (_usesController) {
        return makePlaybackStatus(status);
    }
    playback::PlaybackStatus shown;
    shown.time = _time;
    return makePlaybackStatus(shown);
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return [self reportedStatus:_usesController && _playback ? _playback->status() : playback::PlaybackStatus{}];
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return _playback ? makePlaybackStats(_playback->stats(), _playback->lastPresented())
                     : makePlaybackStats(playback::PlaybackStats{}, playback::PresentedFrame{});
}

- (BOOL)isRunning {
    VE_ASSERT_MAIN();
    return _usesController && _playback && isRunning(_playback->state());
}

- (BOOL)isControllerRunning {
    VE_ASSERT_MAIN();
    return _playback && isRunning(_playback->state());
}

// MARK: - Transport

- (BOOL)prepareToPlayWithRouting:(const std::map<AssetId, media::RoutedMediaInfo> &)routing muted:(BOOL)muted {
    VE_ASSERT_MAIN();
    if (!_project) {
        return NO;
    }
    if (!_playback) {
        playback::PlaybackConfig config;
        config.scrubLaneBase = _config.playbackLaneBase;
        _playback = std::make_unique<playback::PlaybackController>(_router, _frameCache, _pool, config);
        _playback->setMuted(muted);
        for (const auto &[asset, routed] : routing) {
            _playback->setAssetRouting(asset, routed);
        }
        [self observeController];
        [self updateIdleLookahead];
    }
    if (_playbackAsset != _asset) {
        _playbackAsset = _asset;
        _playback->setSequence(std::make_shared<const Project>(*_project), _project->activeSequenceId);
    }
    if (!_usesController) {
        _provider->cancel();
        _usesController = true;
        _playback->seek(_time, playback::SeekMode::Exact);
        [_view setFrameSource:_playback->frameSource()];
        [_view renderOnce];
    }
    return YES;
}

- (void)observeController {
    __weak VESourceMonitor *weakSelf = self;
    playback::PlaybackObserver observer;
    observer.statusChanged = [weakSelf](const playback::PlaybackStatus &status) {
        VESourceMonitor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_onStatus([strongSelf reportedStatus:status]);
    };
    observer.needsDisplay = [weakSelf] {
        VESourceMonitor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (strongSelf->_usesController) {
            [strongSelf->_view renderOnce];
        }
    };
    _playback->setObserver(dispatch_get_main_queue(), std::move(observer));
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    _playback->togglePlay();
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    _playback->shuttleForward();
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    _playback->shuttleReverse();
}

- (void)pause {
    VE_ASSERT_MAIN();
    if (_usesController && _playback) {
        _playback->pause();
    }
}

- (void)pauseIfRunning {
    VE_ASSERT_MAIN();
    if (_usesController && _playback && isRunning(_playback->state())) {
        _playback->pause();
    }
}

- (void)pauseController {
    VE_ASSERT_MAIN();
    if (_playback) {
        _playback->pause();
    }
}

- (BOOL)stepControllerFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if (_usesController && _playback) {
        _playback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
        return YES;
    }
    return NO;
}

- (std::optional<CMTime>)timeSteppedByFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if (!_project) {
        return std::nullopt;
    }
    const CMTime fd = _project->activeSequence()->frameDuration;
    const auto steps = static_cast<int32_t>(std::clamp<NSInteger>(frames, INT32_MIN, INT32_MAX));
    return std::max(kCMTimeZero, _time + CMTimeMultiply(fd, steps));
}

- (BOOL)controllerMuted {
    VE_ASSERT_MAIN();
    return _playback && _playback->isMuted();
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    if (_playback) {
        _playback->setMuted(muted);
    }
}

// MARK: - Lookahead, media and epochs

- (BOOL)isVisible {
    VE_ASSERT_MAIN();
    return _visible;
}

- (void)setVisible:(BOOL)visible {
    VE_ASSERT_MAIN();
    _visible = visible;
    [self updateIdleLookahead];
}

- (BOOL)idleLookaheadAllowed {
    VE_ASSERT_MAIN();
    return _idleLookaheadAllowed;
}

- (NSUInteger)pictureRefreshes {
    VE_ASSERT_MAIN();
    return _pictureRefreshes;
}

- (BOOL)controllerIdleLookahead {
    VE_ASSERT_MAIN();
    return _playback && _playback->idleLookahead();
}

- (void)setIdleLookaheadAllowed:(BOOL)allowed {
    VE_ASSERT_MAIN();
    _idleLookaheadAllowed = allowed;
    [self updateIdleLookahead];
}

/// The controller keeps its stopped lookahead only while the monitor is on screen and the
/// lookahead is allowed (a hidden monitor needs no frames ahead; an export gets the decoders).
- (void)updateIdleLookahead {
    if (_playback) {
        _playback->setIdleLookahead(_visible && _idleLookaheadAllowed);
    }
}

- (void)registerAsset:(AssetId)asset path:(const std::string &)path {
    VE_ASSERT_MAIN();
    _pool->registerAsset(asset, path);
}

- (void)registerAsset:(AssetId)asset path:(const std::string &)path routing:(const media::RoutedMediaInfo &)routed {
    VE_ASSERT_MAIN();
    _pool->registerAsset(asset, path, routed);
    if (_playback) {
        _playback->setAssetRouting(asset, routed);
    }
}

- (void)beginMediaEpoch:(media::FrameCache::Epoch)epoch {
    VE_ASSERT_MAIN();
    _pool->beginEpoch(epoch);
}

- (void)forgetMedia {
    VE_ASSERT_MAIN();
    if (_playback) {
        _playback->forgetMedia();
    }
}

@end
