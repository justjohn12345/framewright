// VEEngine (Playback): the program monitor (its view, the output view that mirrors it, the preview
// solo clip) and the transport of the active sequence's playback controller.

#import "VEEngine+Internal.h"

#import "VEPreviewView.h"

#import "../Render/VEPreviewView+Internal.h"

#include <algorithm>
#include <climits>
#include <memory>
#include <optional>

using namespace ve;
using namespace ve::facade;

namespace ve::facade {

bool isRunning(playback::PlaybackState state) {
    return state == playback::PlaybackState::Playing || state == playback::PlaybackState::Prerolling;
}

} // namespace ve::facade

@implementation VEEngine (Playback)

// MARK: - Playback

- (void)attachProgramView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _programView;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _programView = view;
    if (view != nil) {
        [view setFrameSource:_playback->frameSource()];
        [view renderOnce];
    }
}

- (nullable VEPreviewView *)programView {
    VE_ASSERT_MAIN();
    return _programView;
}

- (BOOL)setProgramPreviewSoloClip:(VEClipID)clipID identityMotion:(BOOL)identityMotion {
    VE_ASSERT_MAIN();
    // The controller has the current model (every model change is published to it at once).
    _playback->setPreviewSolo(playback::PlaybackController::PreviewSolo{ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                                        identityMotion == YES});
    return _playback->previewSolo().has_value();
}

- (void)clearProgramPreviewSolo {
    VE_ASSERT_MAIN();
    _playback->setPreviewSolo(std::nullopt);
}

- (VEClipID)programPreviewSoloClipID {
    VE_ASSERT_MAIN();
    const auto solo = _playback->previewSolo();
    return solo ? static_cast<VEClipID>(solo->clip.value()) : 0;
}

- (BOOL)programPreviewSoloIdentityMotion {
    VE_ASSERT_MAIN();
    const auto solo = _playback->previewSolo();
    return solo && solo->identityMotion ? YES : NO;
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

- (void)showProgramFrameAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    [self seekToTime:time];
}

- (void)play {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->play();
}

- (void)pause {
    VE_ASSERT_MAIN();
    _playback->pause();
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    if (!isRunning(_playback->state())) {
        if ([self refusesPlaybackForExport]) {
            return;
        }
        [self pauseSourceMonitorIfRunning];
    }
    _playback->togglePlay();
}

- (void)seekToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    _playback->seek(CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero, playback::SeekMode::Exact);
}

- (void)setRate:(double)rate {
    VE_ASSERT_MAIN();
    if (rate != 0) {
        if ([self refusesPlaybackForExport]) {
            return;
        }
        [self pauseSourceMonitorIfRunning];
    }
    _playback->setRate(rate);
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->shuttleForward();
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->shuttleReverse();
}

- (void)shuttleStop {
    VE_ASSERT_MAIN();
    _playback->pause();
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

- (BOOL)isMuted {
    VE_ASSERT_MAIN();
    return _playback->isMuted();
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    _playback->setMuted(muted);
    if (_sourcePlayback) {
        _sourcePlayback->setMuted(muted);
    }
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return playbackStateToVE(_playback->state());
}

- (double)playbackRate {
    VE_ASSERT_MAIN();
    return _playback->rate();
}

- (CMTime)currentTime {
    VE_ASSERT_MAIN();
    return _playback->currentTime();
}

- (NSString *)playbackError {
    VE_ASSERT_MAIN();
    const playback::PlaybackStatus status = _playback->status();
    return status.lastError ? toNS(status.lastError->message) : @"";
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return makePlaybackStatus(_playback->status());
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return makePlaybackStats(_playback->stats(), _playback->lastPresented());
}

@end

@implementation VEEngine (PlaybackInternal)

/// Hands the controllers the model: the active sequence of a new project (setSequence, which
/// stops and moves to frame 0), or the edited snapshot (modelChanged, which keeps playing).
- (void)publishPlaybackSnapshot {
    auto snapshot = std::make_shared<const Project>(_project);
    if (!_playbackPublished || _playbackGeneration != _projectGeneration) {
        _playbackPublished = true;
        _playbackGeneration = _projectGeneration;
        _playback->setSequence(std::move(snapshot), _project.activeSequenceId);
    } else {
        _playback->modelChanged(std::move(snapshot));
    }
    // The source monitor's asset may have been removed (undo of its import).
    if (_sourceAsset && _project.findAsset(_sourceAsset) == nullptr) {
        [self resetSourceMonitor];
        [self notifySourcePlayback:_sourcePlayback ? _sourcePlayback->status() : playback::PlaybackStatus{}];
    }
}

- (void)observeController:(playback::PlaybackController &)controller source:(BOOL)isSource {
    __weak VEEngine *weakSelf = self;
    playback::PlaybackObserver observer;
    observer.statusChanged = [weakSelf, isSource](const playback::PlaybackStatus &status) {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (isSource) {
            [strongSelf notifySourcePlayback:status];
        } else {
            [strongSelf notifyPlayback:status];
        }
    };
    observer.needsDisplay = [weakSelf, isSource] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (isSource) {
            if (strongSelf->_sourceUsesController) {
                [strongSelf->_sourceView renderOnce];
            }
        } else {
            [strongSelf->_programView renderOnce];
            [strongSelf->_outputView renderOnce];
        }
    };
    controller.setObserver(dispatch_get_main_queue(), std::move(observer));
}

- (void)notifyPlayback:(const playback::PlaybackStatus &)status {
    if (VEPreviewView *output = _outputView) {
        // The output view's render loop follows the program's transport (the owner of the
        // program view does this for it).
        const BOOL paused = !isRunning(status.state);
        if (output.paused != paused) {
            output.paused = paused;
        }
    }
    VEPlaybackStatus *info = makePlaybackStatus(status);
    [NSNotificationCenter.defaultCenter postNotificationName:VEEnginePlaybackDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEnginePlaybackStatusKey : info}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:playbackDidChange:)]) {
            [observer engine:self playbackDidChange:info];
        }
    }
}

/// Starting the source monitor pauses the program.
- (void)pauseProgramIfRunning {
    if (isRunning(_playback->state())) {
        _playback->pause();
    }
}

@end
