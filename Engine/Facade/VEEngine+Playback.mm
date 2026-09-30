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
    VEPreviewView *previous = _program.view;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _program.view = view;
    if (view != nil) {
        [view setFrameSource:_program.playback->frameSource()];
        [view renderOnce];
    }
}

- (nullable VEPreviewView *)programView {
    VE_ASSERT_MAIN();
    return _program.view;
}

- (BOOL)setProgramPreviewSoloClip:(VEClipID)clipID identityMotion:(BOOL)identityMotion {
    VE_ASSERT_MAIN();
    // The controller has the current model (every model change is published to it at once).
    _program.playback->setPreviewSolo(
        playback::PlaybackController::PreviewSolo{toClipId(clipID), identityMotion == YES});
    return _program.playback->previewSolo().has_value();
}

- (void)clearProgramPreviewSolo {
    VE_ASSERT_MAIN();
    _program.playback->setPreviewSolo(std::nullopt);
}

- (VEClipID)programPreviewSoloClipID {
    VE_ASSERT_MAIN();
    const auto solo = _program.playback->previewSolo();
    return solo ? static_cast<VEClipID>(solo->clip.value()) : 0;
}

- (BOOL)programPreviewSoloIdentityMotion {
    VE_ASSERT_MAIN();
    const auto solo = _program.playback->previewSolo();
    return solo && solo->identityMotion ? YES : NO;
}

- (void)attachOutputView:(VEPreviewView *)view {
    VE_ASSERT_MAIN();
    if (_program.outputView != nil && _program.outputView != view) {
        [self detachOutputView];
    }
    _program.outputView = view;
    // A mirror source: the same frames as the program view, without adding to its counters.
    [view setFrameSource:_program.playback->frameSource(playback::PlaybackController::SourceRole::Mirror)];
    view.paused = !isRunning(_program.playback->state());
    [view renderOnce];
}

- (void)detachOutputView {
    VE_ASSERT_MAIN();
    VEPreviewView *view = _program.outputView;
    _program.outputView = nil;
    if (view != nil) {
        [view setFrameSource:ve::render::PreviewFrameSource{}];
        view.paused = YES;
    }
}

- (nullable VEPreviewView *)outputView {
    VE_ASSERT_MAIN();
    return _program.outputView;
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
    [self pauseSourceMonitorIfRunning];
    return YES;
}

- (void)play {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    _program.playback->play();
}

- (void)pause {
    VE_ASSERT_MAIN();
    _program.playback->pause();
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    if (!isRunning(_program.playback->state()) && ![self prepareToStartProgram]) {
        return;
    }
    _program.playback->togglePlay();
}

- (void)seekToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    _program.playback->seek(CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero, playback::SeekMode::Exact);
}

- (void)setRate:(double)rate {
    VE_ASSERT_MAIN();
    if (rate != 0 && ![self prepareToStartProgram]) {
        return;
    }
    _program.playback->setRate(rate);
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    _program.playback->shuttleForward();
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    if (![self prepareToStartProgram]) {
        return;
    }
    _program.playback->shuttleReverse();
}

- (void)shuttleStop {
    VE_ASSERT_MAIN();
    _program.playback->pause();
}

- (void)stepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    _program.playback->stepFrames(clampToInt(frames));
}

- (void)scrubToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    if (CMTIME_IS_NUMERIC(time)) {
        _program.playback->scrubTo(time);
    }
}

- (void)endScrub {
    VE_ASSERT_MAIN();
    _program.playback->endScrub();
}

- (BOOL)isMuted {
    VE_ASSERT_MAIN();
    return _program.playback->isMuted();
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    _program.playback->setMuted(muted);
    if (_source.playback) {
        _source.playback->setMuted(muted);
    }
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return playbackStateToVE(_program.playback->state());
}

- (double)playbackRate {
    VE_ASSERT_MAIN();
    return _program.playback->rate();
}

- (CMTime)currentTime {
    VE_ASSERT_MAIN();
    return _program.playback->currentTime();
}

- (NSString *)playbackError {
    VE_ASSERT_MAIN();
    const playback::PlaybackStatus status = _program.playback->status();
    return status.lastError ? toNS(status.lastError->message) : @"";
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return makePlaybackStatus(_program.playback->status());
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return makePlaybackStats(_program.playback->stats(), _program.playback->lastPresented());
}

@end

@implementation VEEngine (PlaybackInternal)

/// Hands the program controller the model: the active sequence of a new project (setSequence,
/// which stops and moves to frame 0), or the edited snapshot (modelChanged, which keeps playing).
- (void)publishPlaybackSnapshot {
    auto snapshot = std::make_shared<const Project>(_project);
    if (!_program.published || _program.generation != _document.generation) {
        _program.published = true;
        _program.generation = _document.generation;
        _program.playback->setSequence(std::move(snapshot), _project.activeSequenceId);
    } else {
        _program.playback->modelChanged(std::move(snapshot));
    }
}

- (void)detachProgramFromProject {
    _program.playback->setSequence(std::make_shared<const Project>(), SequenceId{});
    _program.published = false;
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
            if (strongSelf->_source.usesController) {
                [strongSelf->_source.view renderOnce];
            }
        } else {
            [strongSelf->_program.view renderOnce];
            [strongSelf->_program.outputView renderOnce];
        }
    };
    controller.setObserver(dispatch_get_main_queue(), std::move(observer));
}

- (void)notifyPlayback:(const playback::PlaybackStatus &)status {
    if (VEPreviewView *output = _program.outputView) {
        // The output view's render loop follows the program's transport (the owner of the
        // program view does this for it).
        const BOOL paused = !isRunning(status.state);
        if (output.paused != paused) {
            output.paused = paused;
        }
    }
    VEPlaybackStatus *info = makePlaybackStatus(status);
    [self postNotification:VEEnginePlaybackDidChangeNotification
                  userInfo:@{VEEnginePlaybackStatusKey : info}
            observerMethod:@selector(engine:playbackDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self playbackDidChange:info];
                    }];
}

/// Starting the source monitor pauses the program.
- (void)pauseProgramIfRunning {
    if (isRunning(_program.playback->state())) {
        _program.playback->pause();
    }
}

@end
