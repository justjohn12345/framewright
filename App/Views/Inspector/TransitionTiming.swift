import CoreMedia
import Foundation

/// Where a transition sits relative to its cut, as the Transition inspector shows it: the cut's
/// timecode and how far the transition reaches before and after it ("Cut at 00:00:04:13",
/// "−7f / +8f"), since the duration is what the user edits and the cut is what it hangs on.
struct TransitionTiming: Equatable {
    /// The cut (the outgoing clip's end).
    let cut: CMTime
    /// Whole sequence frames before and after the cut (a centred transition of n frames:
    /// n / 2 before, the rest after, as the engine places it).
    let framesBefore: Int64
    let framesAfter: Int64

    /// The timing of a transition covering [start, end) on a cut at `cut`, on a `frameDuration`
    /// grid.
    init(start: CMTime, end: CMTime, cut: CMTime, frameDuration: CMTime) {
        self.cut = cut
        framesBefore = Self.frames(CMTimeSubtract(cut, start), frameDuration)
        framesAfter = Self.frames(CMTimeSubtract(end, cut), frameDuration)
    }

    init(cut: CMTime, framesBefore: Int64, framesAfter: Int64) {
        self.cut = cut
        self.framesBefore = framesBefore
        self.framesAfter = framesAfter
    }

    /// "Cut at 00:00:04:13".
    func cutText(frameDuration: CMTime) -> String {
        "Cut at " + Timecode.string(cut, frameDuration: frameDuration)
    }

    /// "−7f / +8f" (or "−00:00:00:07 / +00:00:00:08", "−0.23 s / +0.27 s") in the duration display
    /// preference.
    func offsetsText(frameDuration: CMTime, display: DurationDisplay) -> String {
        let before = DurationFormat.string(frames: framesBefore, frameDuration: frameDuration, display: display)
        let after = DurationFormat.string(frames: framesAfter, frameDuration: frameDuration, display: display)
        return "\u{2212}\(before) / +\(after)"
    }

    private static func frames(_ time: CMTime, _ frameDuration: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0, time.isNumeric else { return 0 }
        return max(0, Int64((time.seconds / frame).rounded()))
    }
}
