// VEEngine (SourceMonitor): the source monitor, which shows one asset through a private one-clip
// project: still frames while scrubbing (a ProgramFrameProvider) and its own playback controller
// once it plays.

#import "VEEngine+Internal.h"

#import "VEPreviewView.h"

#import "../Render/VEPreviewView+Internal.h"

#include "../Render/Scheduler.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>

using namespace ve;
using namespace ve::facade;

namespace {

/// First id of the source monitor's private one-clip project (never collides with model ids).
constexpr uint64_t kSourceProjectFirstId = uint64_t(1) << 56;
/// Clip id of the source monitor's picture in its still graphs.
const ClipId kSourceVideoClip{kSourceProjectFirstId + 10};

/// The source monitor's private project: `asset` (same id as in the real project, so the
/// frame cache and routing are shared) as one clip over the whole media, video on V1 and audio
/// on A1 (linked), on a sequence at the asset's own frame rate and size, sharpening scaled-down
/// pictures as the real project says (`sharpen`). Nullopt for stills and media without a positive duration.
std::optional<Project> makeSourceProject(const MediaAsset &asset, CMTime fallbackFrameDuration, bool sharpen) {
    if (asset.isStill() || !CMTIME_IS_NUMERIC(asset.duration) || asset.duration <= kCMTimeZero) {
        return std::nullopt;
    }
    Project project;
    project.name = "Source";
    project.ids = IdGenerator(kSourceProjectFirstId);
    project.sharpenScaledDownSources = sharpen;
    project.assets.push_back(asset);
    const CMTime fd = asset.hasVideo() && isPositive(asset.frameDuration) ? asset.frameDuration : fallbackFrameDuration;
    const SequenceId sequenceId = project.addSequence("Source", fd, asset.hasVideo() ? std::max(1, asset.width) : 16,
                                                      asset.hasVideo() ? std::max(1, asset.height) : 9, 1, 1);
    Sequence &sequence = *project.findSequence(sequenceId);
    const CMTime length = snapToFrame(asset.duration, fd, SnapMode::Floor);
    if (length <= kCMTimeZero) {
        return std::nullopt;
    }
    Clip video;
    video.id = kSourceVideoClip;
    video.assetId = asset.id;
    video.trackId = sequence.videoTracks.front().id;
    video.timelineStart = kCMTimeZero;
    video.timelineDuration = length;
    video.sourceIn = kCMTimeZero;
    Clip audio = video;
    audio.id = ClipId(kSourceProjectFirstId + 11);
    audio.trackId = sequence.audioTracks.front().id;
    // The picture ends where the media's video ends (the audio may run on).
    const CMTime videoLength = snapToFrame(asset.videoEnd(), fd, SnapMode::Floor);
    if (videoLength > kCMTimeZero && videoLength < length) {
        video.timelineDuration = videoLength;
    }
    if (asset.hasVideo() && asset.hasAudio()) {
        video.linkedClipId = audio.id;
        audio.linkedClipId = video.id;
    }
    if (asset.hasVideo()) {
        sequence.videoTracks.front().clips.push_back(video);
    }
    if (asset.hasAudio()) {
        sequence.audioTracks.front().clips.push_back(audio);
    }
    return project;
}

} // namespace

@implementation VEEngine (SourceMonitor)

// MARK: - Source monitor

- (void)attachSourceView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _sourceView;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _sourceView = view;
    if (view != nil) {
        [view setFrameSource:_sourceUsesController && _sourcePlayback ? _sourcePlayback->frameSource()
                                                                       : _sourceProvider->makeSource()];
        [self refreshSourcePicture];
    }
}

- (CMTime)frameTimeForAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(AssetId(static_cast<AssetId::ValueType>(assetID)));
    if (asset == nullptr || !CMTIME_IS_NUMERIC(time) || time < kCMTimeZero || asset->isStill()) {
        return kCMTimeZero;
    }
    const CMTime fd = asset->hasVideo() && isPositive(asset->frameDuration) ? asset->frameDuration
                                                                             : [self activeSequence].frameDuration;
    CMTime t = snapToFrame(time, fd, SnapMode::Floor);
    if (CMTIME_IS_NUMERIC(asset->duration) && asset->duration > kCMTimeZero) {
        const CMTime last = snapToFrame(asset->duration, fd, SnapMode::Floor);
        const CMTime lastStart = last == asset->duration ? last - fd : last;
        if (t > lastStart) {
            t = std::max(kCMTimeZero, lastStart);
        }
    }
    return t;
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
    if (id != _sourceAsset) {
        [self resetSourceMonitor];
        _sourceAsset = id;
        _sourceProject = makeSourceProject(*asset, [self activeSequence].frameDuration, _project.sharpenScaledDownSources);
    }
    _sourceTime = t;
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->seek(t, playback::SeekMode::Exact);
        return; // the controller reports the new position
    }
    [self refreshSourcePicture];
    [self notifySourcePlayback:playback::PlaybackStatus{}];
}

- (VEAssetID)sourceMonitorAssetID {
    VE_ASSERT_MAIN();
    return static_cast<VEAssetID>(_sourceAsset.value());
}

- (CMTime)sourceMonitorTime {
    VE_ASSERT_MAIN();
    return _sourceUsesController && _sourcePlayback ? _sourcePlayback->currentTime() : _sourceTime;
}

- (VEPlaybackState)sourceMonitorPlaybackState {
    VE_ASSERT_MAIN();
    return _sourceUsesController && _sourcePlayback ? playbackStateToVE(_sourcePlayback->state())
                                                    : VEPlaybackStateStopped;
}

- (VEPlaybackStatus *)sourceMonitorPlaybackStatus {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        return makePlaybackStatus(_sourcePlayback->status());
    }
    playback::PlaybackStatus shown;
    shown.time = _sourceTime;
    return makePlaybackStatus(shown);
}

/// Makes the source controller play the monitor's asset and shows its picture. False when the
/// asset cannot play (none, a still, no duration).
- (BOOL)prepareSourcePlayback {
    if (!_sourceProject) {
        return NO;
    }
    if (!_sourcePlayback) {
        playback::PlaybackConfig config;
        config.scrubLaneBase = kSourcePlaybackLaneBase;
        _sourcePlayback = std::make_unique<playback::PlaybackController>(_router, _frameCache, _sourcePool, config);
        _sourcePlayback->setMuted(_playback->isMuted());
        for (const auto &[asset, routed] : _routing) {
            _sourcePlayback->setAssetRouting(asset, routed);
        }
        [self observeController:*_sourcePlayback source:YES];
        [self updateSourceIdleLookahead];
    }
    if (_sourcePlaybackAsset != _sourceAsset) {
        _sourcePlaybackAsset = _sourceAsset;
        _sourcePlayback->setSequence(std::make_shared<const Project>(*_sourceProject),
                                     _sourceProject->activeSequenceId);
    }
    if (!_sourceUsesController) {
        _sourceProvider->cancel();
        _sourceUsesController = true;
        _sourcePlayback->seek(_sourceTime, playback::SeekMode::Exact);
        [_sourceView setFrameSource:_sourcePlayback->frameSource()];
        [_sourceView renderOnce];
    }
    return YES;
}

- (void)sourceMonitorTogglePlay {
    VE_ASSERT_MAIN();
    const bool running = _sourceUsesController && _sourcePlayback && isRunning(_sourcePlayback->state());
    if (!running && [self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        if (!isRunning(_sourcePlayback->state())) {
            [self pauseProgramIfRunning];
        }
        _sourcePlayback->togglePlay();
    }
}

- (void)sourceMonitorPause {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->pause();
    }
}

- (BOOL)sourceMonitorVisible {
    VE_ASSERT_MAIN();
    return _sourceMonitorVisible;
}

- (void)setSourceMonitorVisible:(BOOL)visible {
    VE_ASSERT_MAIN();
    _sourceMonitorVisible = visible;
    [self updateSourceIdleLookahead];
}

- (VEPlaybackStats *)sourceMonitorPlaybackStats {
    VE_ASSERT_MAIN();
    return _sourcePlayback ? makePlaybackStats(_sourcePlayback->stats(), _sourcePlayback->lastPresented())
                           : makePlaybackStats(playback::PlaybackStats{}, playback::PresentedFrame{});
}

- (void)sourceMonitorShuttleForward {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        [self pauseProgramIfRunning];
        _sourcePlayback->shuttleForward();
    }
}

- (void)sourceMonitorShuttleReverse {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        [self pauseProgramIfRunning];
        _sourcePlayback->shuttleReverse();
    }
}

- (void)sourceMonitorStepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
        return;
    }
    if (!_sourceProject) {
        return;
    }
    const CMTime fd = _sourceProject->activeSequence()->frameDuration;
    const CMTime t = std::max(kCMTimeZero, _sourceTime + CMTimeMultiply(fd, static_cast<int32_t>(std::clamp<NSInteger>(
                                                                                 frames, INT32_MIN, INT32_MAX))));
    [self sourceMonitorShowAsset:static_cast<VEAssetID>(_sourceAsset.value()) atTime:t];
}

@end

@implementation VEEngine (SourceMonitorInternal)

/// Clears the source monitor (no asset, provider picture, controller stopped and emptied).
- (void)resetSourceMonitor {
    _sourceProvider->cancel();
    if (_sourceUsesController) {
        _sourceUsesController = false;
        [_sourceView setFrameSource:_sourceProvider->makeSource()];
    }
    if (_sourcePlayback && _sourcePlaybackAsset) {
        // Stops it and drops its private project (and decode targets) until the next play.
        _sourcePlayback->setSequence(std::make_shared<const Project>(), SequenceId{});
        _sourcePlaybackAsset = AssetId{};
    }
    _sourceAsset = AssetId{};
    _sourceProject.reset();
    _sourceTime = kCMTimeZero;
    [self refreshSourcePicture];
}

/// The source monitor draws with the project's "Sharpen scaled-down sources": its private project
/// follows a change of the setting (an edit, an undo) and the monitor redraws.
- (void)syncSourceSharpening {
    const bool sharpen = _project.sharpenScaledDownSources;
    if (_sourceSharpening == sharpen) {
        return;
    }
    _sourceSharpening = sharpen;
    if (_sourceProject) {
        _sourceProject->sharpenScaledDownSources = sharpen;
        if (_sourcePlayback && _sourcePlaybackAsset == _sourceAsset) {
            _sourcePlayback->modelChanged(std::make_shared<const Project>(*_sourceProject));
        }
    }
    if (_sourceAsset) {
        [self refreshSourcePicture];
    }
}

/// Shows the provider's picture of the source asset at _sourceTime (black without an asset).
- (void)refreshSourcePicture {
    if (_sourceUsesController) {
        [_sourceView renderOnce];
        return;
    }
    RenderGraph graph;
    if (_sourceProject) {
        const Sequence &sequence = *_sourceProject->activeSequence();
        graph = Scheduler::renderGraphAt(sequence, *_sourceProject, _sourceTime);
        graph.width = sequence.width;
        graph.height = sequence.height;
    } else if (const MediaAsset *asset = _project.findAsset(_sourceAsset); asset != nullptr && asset->isStill()) {
        VideoLayer layer;
        layer.clipId = kSourceVideoClip;
        layer.assetId = asset->id;
        layer.isStill = true;
        layer.sourceRotationDegrees = asset->rotationDegrees;
        graph.layers.push_back(layer);
        graph.time = kCMTimeZero;
        graph.width = std::max(1, asset->width);
        graph.height = std::max(1, asset->height);
        graph.sharpenMinified = _project.sharpenScaledDownSources;
    }
    if (_sourceView == nil) {
        _sourceProvider->cancel();
        return;
    }
    __weak VEEngine *weakSelf = self;
    _sourceProvider->show(std::move(graph), [weakSelf] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf != nil && !strongSelf->_sourceUsesController) {
            [strongSelf->_sourceView renderOnce];
        }
    });
}

- (void)notifySourcePlayback:(const playback::PlaybackStatus &)status {
    VEPlaybackStatus *info = makePlaybackStatus(status);
    if (!_sourceUsesController) {
        // The controller is not what the monitor shows: report the scrub position, stopped.
        playback::PlaybackStatus shown;
        shown.time = _sourceTime;
        info = makePlaybackStatus(shown);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineSourcePlaybackDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEnginePlaybackStatusKey : info}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:sourcePlaybackDidChange:)]) {
            [observer engine:self sourcePlaybackDidChange:info];
        }
    }
}

/// One monitor plays at a time (as in Premiere): starting the program pauses the source monitor.
- (void)pauseSourceMonitorIfRunning {
    if (_sourceUsesController && _sourcePlayback && isRunning(_sourcePlayback->state())) {
        _sourcePlayback->pause();
    }
}

/// The source controller keeps its stopped lookahead only while the monitor is on screen and no
/// export runs (the export gets the decoders; a hidden monitor needs no frames ahead).
- (void)updateSourceIdleLookahead {
    if (_sourcePlayback) {
        _sourcePlayback->setIdleLookahead(_sourceMonitorVisible && _activeExport == nil);
    }
}

@end
