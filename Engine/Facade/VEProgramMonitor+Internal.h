// VEProgramMonitor: the program monitor. It owns the active sequence's playback controller on a
// decode pool of its own, which snapshot of the model the controller has (the project generation
// it belongs to), and the views showing it: the program view and the output view that mirrors it
// (whose render loop it runs and pauses with the transport). It knows nothing of the engine: the
// engine hands it the model and the project generation, applies the rules between the areas (one
// monitor plays at a time, no playback during an export, the stopped lookahead given up during an
// export) and posts the playback notification from the status block it gives the monitor.
// Threading: main thread only. The controller's audio clock, render callbacks and decode threads
// are the controller's own (PlaybackController.h); the monitor only calls its main-thread API and
// hears from it on the main queue.
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
#include <memory>
#include <optional>
#include <string>

@class VEPreviewView;

namespace ve::facade {

/// How VEProgramMonitor sets up its decode pool and lanes.
struct ProgramMonitorConfig {
    /// Share of the frame cache budget the monitor's pool may fill with lookahead windows.
    double poolBudgetShare = 0.5;
    /// Lanes of the controller's layers (layer i on scrubLaneBase + i).
    uint64_t scrubLaneBase = 0;
};

} // namespace ve::facade

NS_ASSUME_NONNULL_BEGIN

/// The controller's status; called on the main thread when it changes (after the output view's
/// render loop has followed it).
typedef void (^VEProgramMonitorStatusBlock)(VEPlaybackStatus *status);

/// Final: the engine coordinates it as it is (no subclass can change its contract).
__attribute__((objc_subclassing_restricted))
@interface VEProgramMonitor : NSObject

/// `router` and `frameCache` are the engine's shared services (the monitor's pool and controller
/// decode through them); `onStatus` reports the controller's status changes.
- (instancetype)initWithRouter:(std::shared_ptr<ve::media::BackendRouter>)router
                    frameCache:(std::shared_ptr<ve::media::FrameCache>)frameCache
                        config:(ve::facade::ProgramMonitorConfig)config
                      onStatus:(VEProgramMonitorStatusBlock)onStatus NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// MARK: Views

/// Shows the controller's picture in `view` (nil detaches the current one).
- (void)attachView:(nullable VEPreviewView *)view;
@property (nonatomic, readonly, weak, nullable) VEPreviewView *view;
/// Mirrors the program in `view` (replacing an earlier output view): a mirror frame source, its
/// render loop running while the controller plays or pre-rolls.
- (void)attachOutputView:(VEPreviewView *)view;
/// The output view stops showing frames and its render loop is paused.
- (void)detachOutputView;
@property (nonatomic, readonly, weak, nullable) VEPreviewView *outputView;
/// Both views stop calling into the controller (the engine's dealloc; also done when the monitor is
/// released).
- (void)disconnectViews;
/// Passes memory pressure to both views.
- (void)handleMemoryPressure;

// MARK: The model

/// Hands the controller the model: the active sequence of a new project (setSequence, which stops
/// and moves to frame 0) the first time after detachFromProject or when `generation` (the
/// project's) changed, else the edited snapshot (modelChanged, which keeps playing).
- (void)publishProject:(const ve::Project &)project generation:(uint64_t)generation;
/// Stops the controller using the project's media (New/Open): it gets an empty project until the
/// next publishProject:generation:.
- (void)detachFromProject;

// MARK: Preview solo

/// Shows `clip` alone in the program view (the Ken Burns editor's picture; see the engine's
/// setProgramPreviewSoloClip:identityMotion:); YES when the override took.
- (BOOL)setPreviewSoloClip:(ve::ClipId)clip identityMotion:(BOOL)identityMotion;
- (void)clearPreviewSolo;
@property (nonatomic, readonly) std::optional<ve::playback::PlaybackController::PreviewSolo> previewSolo;

// MARK: Transport

- (void)play;
- (void)pause;
- (void)togglePlay;
/// Exact seek (a time that is not numeric seeks to 0).
- (void)seekToTime:(CMTime)time;
- (void)setRate:(double)rate;
- (void)shuttleForward;
- (void)shuttleReverse;
- (void)stepFrames:(NSInteger)frames;
/// Scrubs to a numeric `time` (other times are ignored).
- (void)scrubToTime:(CMTime)time;
- (void)endScrub;
/// Pauses while the controller plays or pre-rolls.
- (void)pauseIfRunning;
/// Whether the controller plays or pre-rolls.
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, getter=isMuted) BOOL muted;
@property (nonatomic, readonly) VEPlaybackState playbackState;
@property (nonatomic, readonly) double rate;
@property (nonatomic, readonly) CMTime currentTime;
@property (nonatomic, readonly) VEPlaybackStatus *playbackStatus;
/// The most recent audio problem ("" when none).
@property (nonatomic, readonly, copy) NSString *playbackError;
@property (nonatomic, readonly) VEPlaybackStats *playbackStats;

// MARK: Lookahead, media and epochs

/// Whether the controller keeps its stopped lookahead (the engine turns it off during an export).
- (void)setIdleLookahead:(BOOL)enabled;
/// What the controller was last told (PlaybackController::idleLookahead).
@property (nonatomic, readonly) BOOL controllerIdleLookahead;
/// Registers `asset`'s file with the monitor's pool, and its routing with the pool and the
/// controller.
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
