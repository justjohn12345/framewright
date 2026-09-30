// VEEngine (Playback): the program monitor's API (its view, the output view that mirrors it, the
// preview solo clip, the transport). The monitor itself is VEProgramMonitor
// (VEProgramMonitor+Internal.h); the engine hands it the model and applies the rules between the
// areas: no playback while an export runs, and one monitor playing at a time.

#import "VEEngine+Internal.h"

#import "VEProgramMonitor+Internal.h"
#import "VESourceMonitor+Internal.h"

#include <optional>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (Playback)

// MARK: - Playback

- (void)attachProgramView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    [_programMonitor attachView:view];
}

- (nullable VEPreviewView *)programView {
    VE_ASSERT_MAIN();
    return _programMonitor.view;
}

- (BOOL)setProgramPreviewSoloClip:(VEClipID)clipID identityMotion:(BOOL)identityMotion {
    VE_ASSERT_MAIN();
    return [_programMonitor setPreviewSoloClip:toClipId(clipID) identityMotion:identityMotion];
}

- (void)clearProgramPreviewSolo {
    VE_ASSERT_MAIN();
    [_programMonitor clearPreviewSolo];
}

- (VEClipID)programPreviewSoloClipID {
    VE_ASSERT_MAIN();
    const auto solo = _programMonitor.previewSolo;
    return solo ? static_cast<VEClipID>(solo->clip.value()) : 0;
}

- (BOOL)programPreviewSoloIdentityMotion {
    VE_ASSERT_MAIN();
    const auto solo = _programMonitor.previewSolo;
    return solo && solo->identityMotion ? YES : NO;
}

- (void)attachOutputView:(VEPreviewView *)view {
    VE_ASSERT_MAIN();
    [_programMonitor attachOutputView:view];
}

- (void)detachOutputView {
    VE_ASSERT_MAIN();
    [_programMonitor detachOutputView];
}

- (nullable VEPreviewView *)outputView {
    VE_ASSERT_MAIN();
    return _programMonitor.outputView;
}

- (void)showProgramFrameAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    [self seekToTime:time];
}

/// Whether the program may start now (no export runs); if so the source monitor is paused first
/// (one monitor plays at a time).
- (BOOL)prepareToStartProgram {
    if ([self refusesPlaybackForExport]) {
        return NO;
    }
    [_sourceMonitor pauseIfRunning];
    return YES;
}

- (void)play {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    [_programMonitor play];
}

- (void)pause {
    VE_ASSERT_MAIN();
    [_programMonitor pause];
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    if (!_programMonitor.running && ![self prepareToStartProgram]) {
        return;
    }
    [_programMonitor togglePlay];
}

- (void)seekToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    [_programMonitor seekToTime:time];
}

- (void)setRate:(double)rate {
    VE_ASSERT_MAIN();
    if (rate != 0 && ![self prepareToStartProgram]) {
        return;
    }
    [_programMonitor setRate:rate];
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    [_programMonitor shuttleForward];
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    [_programMonitor shuttleReverse];
}

- (void)shuttleStop {
    VE_ASSERT_MAIN();
    [_programMonitor pause];
}

- (void)stepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    [_programMonitor stepFrames:frames];
}

- (void)scrubToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    [_programMonitor scrubToTime:time];
}

- (void)endScrub {
    VE_ASSERT_MAIN();
    [_programMonitor endScrub];
}

- (BOOL)isMuted {
    VE_ASSERT_MAIN();
    return _programMonitor.muted;
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    _programMonitor.muted = muted;
    [_sourceMonitor setMuted:muted];
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return _programMonitor.playbackState;
}

- (double)playbackRate {
    VE_ASSERT_MAIN();
    return _programMonitor.rate;
}

- (CMTime)currentTime {
    VE_ASSERT_MAIN();
    return _programMonitor.currentTime;
}

- (NSString *)playbackError {
    VE_ASSERT_MAIN();
    return _programMonitor.playbackError;
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return _programMonitor.playbackStatus;
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return _programMonitor.playbackStats;
}

@end

@implementation VEEngine (PlaybackInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

/// Hands the program monitor the model: the active sequence of a new project (a new document
/// generation, or after New/Open detached it), or the edited snapshot (which keeps playing).
- (void)publishPlaybackSnapshot {
    [_programMonitor publishProject:_project generation:_document.generation];
}

- (void)postPlaybackStatus:(VEPlaybackStatus *)info {
    [self postNotification:VEEnginePlaybackDidChangeNotification
                  userInfo:@{VEEnginePlaybackStatusKey : info}
            observerMethod:@selector(engine:playbackDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self playbackDidChange:info];
                    }];
}

@end
