// VEEngine (SourceMonitor): the source monitor's API. The monitor itself is VESourceMonitor
// (VESourceMonitor+Internal.h); the engine hands it the asset and the model, and applies the rules
// between the areas: no playback while an export runs, one monitor playing at a time, the stopped
// lookahead given up during an export, the monitor cleared when its asset leaves the model.

#import "VEEngine+Internal.h"

#import "VEExporter+Internal.h"
#import "VEMediaLibrary+Internal.h"
#import "VESourceMonitor+Internal.h"

#include "../Model/SourceProject.h"

#include <optional>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (SourceMonitor)

// MARK: - Source monitor

- (void)attachSourceView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    [_sourceMonitor attachView:view project:_project];
}

- (CMTime)frameTimeForAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(toAssetId(assetID));
    return asset != nullptr ? assetFrameTime(*asset, time, [self activeSequence].frameDuration) : kCMTimeZero;
}

- (void)sourceMonitorShowAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const AssetId id = toAssetId(assetID);
    const MediaAsset *asset = assetID > 0 ? _project.findAsset(id) : nullptr;
    if (asset == nullptr) {
        [_sourceMonitor resetWithProject:_project];
        [self postSourcePlaybackStatus:_sourceMonitor.playbackStatus];
        return;
    }
    const CMTime t = [self frameTimeForAsset:assetID atTime:time];
    if (![_sourceMonitor showAsset:*asset
                            atTime:t
                     frameDuration:[self activeSequence].frameDuration
                           project:_project]) {
        // The still picture shows the new position (a controller showing the monitor reports it).
        [self postSourcePlaybackStatus:_sourceMonitor.playbackStatus];
    }
}

- (VEAssetID)sourceMonitorAssetID {
    VE_ASSERT_MAIN();
    return static_cast<VEAssetID>(_sourceMonitor.asset.value());
}

- (CMTime)sourceMonitorTime {
    VE_ASSERT_MAIN();
    return _sourceMonitor.time;
}

- (VEPlaybackState)sourceMonitorPlaybackState {
    VE_ASSERT_MAIN();
    return _sourceMonitor.playbackState;
}

- (VEPlaybackStatus *)sourceMonitorPlaybackStatus {
    VE_ASSERT_MAIN();
    return _sourceMonitor.playbackStatus;
}

/// Makes the source controller play the monitor's asset and shows its picture (muted like the
/// program, with every asset's routing). False when the asset cannot play (none, a still, no
/// duration).
- (BOOL)prepareSourcePlayback {
    return [_sourceMonitor prepareToPlayWithRouting:_media.routing muted:_program.playback->isMuted()];
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
    const BOOL running = _sourceMonitor.running;
    if (!running && [self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        if (!_sourceMonitor.controllerRunning) {
            [self pauseProgramIfRunning];
        }
        [_sourceMonitor togglePlay];
    }
}

- (void)sourceMonitorPause {
    VE_ASSERT_MAIN();
    [_sourceMonitor pause];
}

- (BOOL)sourceMonitorVisible {
    VE_ASSERT_MAIN();
    return _sourceMonitor.visible;
}

- (void)setSourceMonitorVisible:(BOOL)visible {
    VE_ASSERT_MAIN();
    _sourceMonitor.visible = visible;
}

- (VEPlaybackStats *)sourceMonitorPlaybackStats {
    VE_ASSERT_MAIN();
    return _sourceMonitor.playbackStats;
}

- (void)sourceMonitorShuttleForward {
    VE_ASSERT_MAIN();
    if ([self prepareToStartSource]) {
        [_sourceMonitor shuttleForward];
    }
}

- (void)sourceMonitorShuttleReverse {
    VE_ASSERT_MAIN();
    if ([self prepareToStartSource]) {
        [_sourceMonitor shuttleReverse];
    }
}

- (void)sourceMonitorStepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if ([_sourceMonitor stepControllerFrames:frames]) {
        return;
    }
    if (const std::optional<CMTime> t = [_sourceMonitor timeSteppedByFrames:frames]) {
        [self sourceMonitorShowAsset:static_cast<VEAssetID>(_sourceMonitor.asset.value()) atTime:*t];
    }
}

@end

@implementation VEEngine (SourceMonitorInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

- (void)sourceMonitorModelChanged {
    // The source monitor's asset may have been removed (undo of its import).
    if ([_sourceMonitor resetIfAssetLeft:_project]) {
        [self postSourcePlaybackStatus:_sourceMonitor.playbackStatus];
    }
    // It draws with the project's "Sharpen scaled-down sources" (an edit, an undo).
    [_sourceMonitor syncSharpeningWith:_project];
}

- (void)postSourcePlaybackStatus:(VEPlaybackStatus *)info {
    [self postNotification:VEEngineSourcePlaybackDidChangeNotification
                  userInfo:@{VEEnginePlaybackStatusKey : info}
            observerMethod:@selector(engine:sourcePlaybackDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self sourcePlaybackDidChange:info];
                    }];
}

/// The source controller keeps its stopped lookahead only while the monitor is on screen (the
/// monitor's own rule) and no export runs (the export gets the decoders).
- (void)updateSourceIdleLookahead {
    _sourceMonitor.idleLookaheadAllowed = !_exporter.isExporting;
}

@end
