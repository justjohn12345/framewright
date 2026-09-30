// VESourceMonitor: the source monitor, which shows one asset through a private one-clip project:
// still frames while scrubbing (a ProgramFrameProvider on the monitor's own decode pool) and its own
// playback controller once it plays (created when it first plays). It owns its pool, provider,
// controller, private project and view. It knows nothing of the engine: the engine passes the asset
// and the model it needs per call, applies the rules between the areas (one monitor plays at a
// time, no playback during an export, the stopped lookahead given up during an export) and posts
// the source playback notification from the status block it gives the monitor.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import <Foundation/Foundation.h>

#import "VETypes.h"

#include "../Media/BackendRouter.h"
#include "../Media/DecodePool.h"
#include "../Media/FrameCache.h"
#include "../Model/Project.h"
#include "../Playback/PlaybackController.h"

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>

@class VEPreviewView;

namespace ve::facade {

/// How VESourceMonitor sets up its decode pool and lanes.
struct SourceMonitorConfig {
    /// Share of the frame cache budget the monitor's pool may fill with lookahead windows.
    double poolBudgetShare = 0.25;
    /// Lanes of the still provider (layer i on scrubLaneBase + i) and of the controller's scrubs.
    uint64_t scrubLaneBase = 0;
    uint64_t playbackLaneBase = 0;
};

} // namespace ve::facade

NS_ASSUME_NONNULL_BEGIN

/// The status the source monitor reports (its controller's while the view shows the controller's
/// picture, else the scrub position, stopped); called on the main thread when the controller's
/// status changes.
typedef void (^VESourceMonitorStatusBlock)(VEPlaybackStatus *status);

/// Main thread only.
@interface VESourceMonitor : NSObject

/// `router` and `frameCache` are the engine's shared services (the monitor's pool and controller
/// decode through them); `onStatus` reports the controller's status changes.
- (instancetype)initWithRouter:(std::shared_ptr<ve::media::BackendRouter>)router
                    frameCache:(std::shared_ptr<ve::media::FrameCache>)frameCache
                        config:(ve::facade::SourceMonitorConfig)config
                      onStatus:(VESourceMonitorStatusBlock)onStatus NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// MARK: View and picture

/// Shows the monitor in `view` (nil detaches); `project` is the model (a still asset's picture).
- (void)attachView:(nullable VEPreviewView *)view project:(const ve::Project &)project;
/// The view stops calling into the provider and the controller (the engine's dealloc; also done when
/// the monitor is released).
- (void)disconnectView;
/// Passes memory pressure to the view.
- (void)handleMemoryPressure;

// MARK: Asset and position

/// Shows `asset` at source time `time` (on the asset's frame grid); a different asset replaces the
/// private project (made at `frameDuration` for media without a frame rate of its own and with
/// `project`'s sharpening) and stops the controller. Returns YES when the controller shows the
/// monitor (it was seeked and reports the new position itself), NO when the still picture was
/// refreshed (the caller reports the status).
- (BOOL)showAsset:(const ve::MediaAsset &)asset
           atTime:(CMTime)time
    frameDuration:(CMTime)frameDuration
          project:(const ve::Project &)project;
/// Clears the monitor: no asset, the still provider's (black) picture, the controller stopped and
/// emptied until the next play. `project` is the model (the picture is refreshed in it).
- (void)resetWithProject:(const ve::Project &)project;
/// Clears the monitor when its asset is no longer in `project` (the undo of its import); YES if
/// it did.
- (BOOL)resetIfAssetLeft:(const ve::Project &)project;
/// Follows `project`'s "Sharpen scaled-down sources": the private project and the picture follow a
/// change of the setting.
- (void)syncSharpeningWith:(const ve::Project &)project;
@property (nonatomic, readonly) ve::AssetId asset;
/// The shown source time (the clock while the controller shows the monitor).
@property (nonatomic, readonly) CMTime time;
@property (nonatomic, readonly) VEPlaybackState playbackState;
/// The status the monitor reports (see VESourceMonitorStatusBlock).
@property (nonatomic, readonly) VEPlaybackStatus *playbackStatus;
/// The controller's counters (zero until it first plays).
@property (nonatomic, readonly) VEPlaybackStats *playbackStats;
/// Whether the controller shows the monitor and is playing or pre-rolling.
@property (nonatomic, readonly, getter=isRunning) BOOL running;
/// Whether the controller exists and is playing or pre-rolling (whatever the view shows).
@property (nonatomic, readonly, getter=isControllerRunning) BOOL controllerRunning;

// MARK: Transport

/// Makes the controller play the monitor's asset and shows its picture, creating the controller
/// the first time (muted as `muted`, with every asset's `routing`). NO when the asset cannot play
/// (none, a still, no duration).
- (BOOL)prepareToPlayWithRouting:(const std::map<ve::AssetId, ve::media::RoutedMediaInfo> &)routing
                           muted:(BOOL)muted;
/// The controller's transport (after prepareToPlayWithRouting:muted: returned YES).
- (void)togglePlay;
- (void)shuttleForward;
- (void)shuttleReverse;
/// Pauses while the controller shows the monitor.
- (void)pause;
/// Pauses while the controller shows the monitor and is running.
- (void)pauseIfRunning;
/// Pauses the controller if there is one, whatever the view shows.
- (void)pauseController;
/// Steps the controller by `frames` while it shows the monitor; NO (nothing done) otherwise.
- (BOOL)stepControllerFrames:(NSInteger)frames;
/// The scrub position moved by `frames` frames of the private project (not before 0), or nullopt
/// without one.
- (std::optional<CMTime>)timeSteppedByFrames:(NSInteger)frames;
- (void)setMuted:(BOOL)muted;

// MARK: Lookahead, media and epochs

/// Whether the monitor is on screen (default YES). The controller keeps its stopped lookahead only
/// while the monitor is visible and the lookahead is allowed.
@property (nonatomic, getter=isVisible) BOOL visible;
/// Whether the stopped lookahead is allowed (default YES; the engine disallows it during an export).
@property (nonatomic) BOOL idleLookaheadAllowed;
/// Registers `asset`'s file with the monitor's pool, and its routing with the pool and the
/// controller when there is one.
- (void)registerAsset:(ve::AssetId)asset path:(const std::string &)path;
- (void)registerAsset:(ve::AssetId)asset
                 path:(const std::string &)path
              routing:(const ve::media::RoutedMediaInfo &)routed;
/// Starts media epoch `epoch` on the monitor's pool (New/Open).
- (void)beginMediaEpoch:(ve::media::FrameCache::Epoch)epoch;
/// The controller forgets the old project's media (New/Open, after the new epoch).
- (void)forgetMedia;

@end

NS_ASSUME_NONNULL_END
