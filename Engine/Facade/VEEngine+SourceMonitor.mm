// VEEngine (SourceMonitor): the source monitor, which shows one asset through a private one-clip
// project: still frames while scrubbing (a ProgramFrameProvider) and its own playback controller
// once it plays.

#import "VEEngine+Internal.h"

#import "VEPreviewView.h"

#import "../Render/VEPreviewView+Internal.h"

#include "../Model/SourceProject.h"
#include "../Render/Scheduler.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>

using namespace ve;
using namespace ve::facade;

namespace {

/// The ids of the source monitor's private one-clip project (never colliding with model ids);
/// kSourceIds.videoClip is its picture's clip in the still graphs too.
constexpr uint64_t kSourceProjectFirstId = uint64_t(1) << 56;
const SourceProjectIds kSourceIds{kSourceProjectFirstId, ClipId(kSourceProjectFirstId + 10),
                                  ClipId(kSourceProjectFirstId + 11)};

} // namespace

@implementation VEEngine (SourceMonitor)

// MARK: - Source monitor

- (void)attachSourceView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _source.view;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _source.view = view;
    if (view != nil) {
        [view setFrameSource:_source.usesController && _source.playback ? _source.playback->frameSource()
                                                                        : _source.provider->makeSource()];
        [self refreshSourcePicture];
    }
}

- (CMTime)frameTimeForAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(AssetId(static_cast<AssetId::ValueType>(assetID)));
    return asset != nullptr ? assetFrameTime(*asset, time, [self activeSequence].frameDuration) : kCMTimeZero;
}

- (void)sourceMonitorShowAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    const MediaAsset *asset = assetID > 0 ? _project.findAsset(id) : nullptr;
    if (asset == nullptr) {
        [self resetSourceMonitor];
        [self notifySourcePlayback:playback::PlaybackStatus{}];
        return;
    }
    const CMTime t = [self frameTimeForAsset:assetID atTime:time];
    if (id != _source.asset) {
        [self resetSourceMonitor];
        _source.asset = id;
        _source.project = makeSourceProject(*asset, [self activeSequence].frameDuration,
                                            _project.sharpenScaledDownSources, kSourceIds);
    }
    _source.time = t;
    if (_source.usesController && _source.playback) {
        _source.playback->seek(t, playback::SeekMode::Exact);
        return; // the controller reports the new position
    }
    [self refreshSourcePicture];
    [self notifySourcePlayback:playback::PlaybackStatus{}];
}

- (VEAssetID)sourceMonitorAssetID {
    VE_ASSERT_MAIN();
    return static_cast<VEAssetID>(_source.asset.value());
}

- (CMTime)sourceMonitorTime {
    VE_ASSERT_MAIN();
    return _source.usesController && _source.playback ? _source.playback->currentTime() : _source.time;
}

- (VEPlaybackState)sourceMonitorPlaybackState {
    VE_ASSERT_MAIN();
    return _source.usesController && _source.playback ? playbackStateToVE(_source.playback->state())
                                                      : VEPlaybackStateStopped;
}

- (VEPlaybackStatus *)sourceMonitorPlaybackStatus {
    VE_ASSERT_MAIN();
    if (_source.usesController && _source.playback) {
        return makePlaybackStatus(_source.playback->status());
    }
    playback::PlaybackStatus shown;
    shown.time = _source.time;
    return makePlaybackStatus(shown);
}

/// Makes the source controller play the monitor's asset and shows its picture. False when the
/// asset cannot play (none, a still, no duration).
- (BOOL)prepareSourcePlayback {
    if (!_source.project) {
        return NO;
    }
    if (!_source.playback) {
        playback::PlaybackConfig config;
        config.scrubLaneBase = kSourcePlaybackLaneBase;
        _source.playback = std::make_unique<playback::PlaybackController>(_services.router, _services.frameCache,
                                                                          _source.pool, config);
        _source.playback->setMuted(_program.playback->isMuted());
        for (const auto &[asset, routed] : _assets.routing) {
            _source.playback->setAssetRouting(asset, routed);
        }
        [self observeController:*_source.playback source:YES];
        [self updateSourceIdleLookahead];
    }
    if (_source.playbackAsset != _source.asset) {
        _source.playbackAsset = _source.asset;
        _source.playback->setSequence(std::make_shared<const Project>(*_source.project),
                                      _source.project->activeSequenceId);
    }
    if (!_source.usesController) {
        _source.provider->cancel();
        _source.usesController = true;
        _source.playback->seek(_source.time, playback::SeekMode::Exact);
        [_source.view setFrameSource:_source.playback->frameSource()];
        [_source.view renderOnce];
    }
    return YES;
}

/// Whether the source monitor may start now: no export runs and its asset can play
/// (prepareSourcePlayback). If so the program is paused first (one monitor plays at a time).
- (BOOL)prepareToStartSource {
    if ([self refusesPlaybackForExport] || ![self prepareSourcePlayback]) {
        return NO;
    }
    [self pauseProgramIfRunning];
    return YES;
}

- (void)sourceMonitorTogglePlay {
    VE_ASSERT_MAIN();
    const bool running = _source.usesController && _source.playback && isRunning(_source.playback->state());
    if (!running && [self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        if (!isRunning(_source.playback->state())) {
            [self pauseProgramIfRunning];
        }
        _source.playback->togglePlay();
    }
}

- (void)sourceMonitorPause {
    VE_ASSERT_MAIN();
    if (_source.usesController && _source.playback) {
        _source.playback->pause();
    }
}

- (BOOL)sourceMonitorVisible {
    VE_ASSERT_MAIN();
    return _source.visible;
}

- (void)setSourceMonitorVisible:(BOOL)visible {
    VE_ASSERT_MAIN();
    _source.visible = visible;
    [self updateSourceIdleLookahead];
}

- (VEPlaybackStats *)sourceMonitorPlaybackStats {
    VE_ASSERT_MAIN();
    return _source.playback ? makePlaybackStats(_source.playback->stats(), _source.playback->lastPresented())
                            : makePlaybackStats(playback::PlaybackStats{}, playback::PresentedFrame{});
}

- (void)sourceMonitorShuttleForward {
    VE_ASSERT_MAIN();
    if ([self prepareToStartSource]) {
        _source.playback->shuttleForward();
    }
}

- (void)sourceMonitorShuttleReverse {
    VE_ASSERT_MAIN();
    if ([self prepareToStartSource]) {
        _source.playback->shuttleReverse();
    }
}

- (void)sourceMonitorStepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if (_source.usesController && _source.playback) {
        _source.playback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
        return;
    }
    if (!_source.project) {
        return;
    }
    const CMTime fd = _source.project->activeSequence()->frameDuration;
    const CMTime t = std::max(
        kCMTimeZero,
        _source.time + CMTimeMultiply(fd, static_cast<int32_t>(std::clamp<NSInteger>(frames, INT32_MIN, INT32_MAX))));
    [self sourceMonitorShowAsset:static_cast<VEAssetID>(_source.asset.value()) atTime:t];
}

@end

@implementation VEEngine (SourceMonitorInternal)

/// Clears the source monitor (no asset, provider picture, controller stopped and emptied).
- (void)resetSourceMonitor {
    _source.provider->cancel();
    if (_source.usesController) {
        _source.usesController = false;
        [_source.view setFrameSource:_source.provider->makeSource()];
    }
    if (_source.playback && _source.playbackAsset) {
        // Stops it and drops its private project (and decode targets) until the next play.
        _source.playback->setSequence(std::make_shared<const Project>(), SequenceId{});
        _source.playbackAsset = AssetId{};
    }
    _source.asset = AssetId{};
    _source.project.reset();
    _source.time = kCMTimeZero;
    [self refreshSourcePicture];
}

/// The source monitor draws with the project's "Sharpen scaled-down sources": its private project
/// follows a change of the setting (an edit, an undo) and the monitor redraws.
- (void)syncSourceSharpening {
    const bool sharpen = _project.sharpenScaledDownSources;
    if (_source.sharpening == sharpen) {
        return;
    }
    _source.sharpening = sharpen;
    if (_source.project) {
        _source.project->sharpenScaledDownSources = sharpen;
        if (_source.playback && _source.playbackAsset == _source.asset) {
            _source.playback->modelChanged(std::make_shared<const Project>(*_source.project));
        }
    }
    if (_source.asset) {
        [self refreshSourcePicture];
    }
}

/// Shows the provider's picture of the source asset at _source.time (black without an asset).
- (void)refreshSourcePicture {
    if (_source.usesController) {
        [_source.view renderOnce];
        return;
    }
    RenderGraph graph;
    if (_source.project) {
        const Sequence &sequence = *_source.project->activeSequence();
        graph = Scheduler::renderGraphAt(sequence, *_source.project, _source.time);
        graph.width = sequence.width;
        graph.height = sequence.height;
    } else if (const MediaAsset *asset = _project.findAsset(_source.asset); asset != nullptr && asset->isStill()) {
        VideoLayer layer;
        layer.clipId = kSourceIds.videoClip;
        layer.assetId = asset->id;
        layer.isStill = true;
        layer.sourceRotationDegrees = asset->rotationDegrees;
        graph.layers.push_back(layer);
        graph.time = kCMTimeZero;
        graph.width = std::max(1, asset->width);
        graph.height = std::max(1, asset->height);
        graph.sharpenMinified = _project.sharpenScaledDownSources;
    }
    if (_source.view == nil) {
        _source.provider->cancel();
        return;
    }
    __weak VEEngine *weakSelf = self;
    _source.provider->show(std::move(graph), [weakSelf] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf != nil && !strongSelf->_source.usesController) {
            [strongSelf->_source.view renderOnce];
        }
    });
}

- (void)notifySourcePlayback:(const playback::PlaybackStatus &)status {
    VEPlaybackStatus *info = makePlaybackStatus(status);
    if (!_source.usesController) {
        // The controller is not what the monitor shows: report the scrub position, stopped.
        playback::PlaybackStatus shown;
        shown.time = _source.time;
        info = makePlaybackStatus(shown);
    }
    [self postNotification:VEEngineSourcePlaybackDidChangeNotification
                  userInfo:@{VEEnginePlaybackStatusKey : info}
            observerMethod:@selector(engine:sourcePlaybackDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self sourcePlaybackDidChange:info];
                    }];
}

/// One monitor plays at a time (as in Premiere): starting the program pauses the source monitor.
- (void)pauseSourceMonitorIfRunning {
    if (_source.usesController && _source.playback && isRunning(_source.playback->state())) {
        _source.playback->pause();
    }
}

/// The source controller keeps its stopped lookahead only while the monitor is on screen and no
/// export runs (the export gets the decoders; a hidden monitor needs no frames ahead).
- (void)updateSourceIdleLookahead {
    if (_source.playback) {
        _source.playback->setIdleLookahead(_source.visible && _export.active == nil);
    }
}

@end
