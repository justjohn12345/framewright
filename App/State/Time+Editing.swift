import CoreMedia
import Foundation

extension CMTime {
    /// Seconds as a Double; 0 for invalid or indefinite times.
    var secondsOrZero: Double {
        guard isNumeric else { return 0 }
        let value = seconds
        return value.isFinite ? value : 0
    }

    /// `seconds` on the frame grid of `frameDuration` (rounded to the nearest frame, never negative).
    static func onFrameGrid(seconds: Double, frameDuration: CMTime) -> CMTime {
        let frame = frameDuration.secondsOrZero
        guard frame > 0, seconds.isFinite else { return .zero }
        let index = max(0, (seconds / frame).rounded())
        return CMTimeMultiply(frameDuration, multiplier: Int32(clamping: Int64(index)))
    }
}

/// Timecode formatting for a frame rate (non-drop-frame, like the rest of the MVP).
enum Timecode {
    /// Frames per second used for the frame field (29.97 counts as 30).
    static func framesPerSecond(_ frameDuration: CMTime) -> Int {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 30 }
        return max(1, Int((1 / frame).rounded()))
    }

    /// "HH:MM:SS:FF".
    static func string(_ time: CMTime, frameDuration: CMTime) -> String {
        let fps = framesPerSecond(frameDuration)
        let frame = frameDuration.secondsOrZero
        let totalFrames = frame > 0 ? Int((time.secondsOrZero / frame + 1e-6).rounded(.down)) : 0
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames)
    }

    /// Short ruler label: "0:05", "1:00:00", or "0:05:12" (frames) at fine zoom.
    static func rulerLabel(seconds: Double, showFrames: Bool, fps: Int) -> String {
        let clamped = max(0, seconds)
        let whole = Int((clamped + 1e-9).rounded(.down))
        let hours = whole / 3600
        let minutes = (whole / 60) % 60
        let secs = whole % 60
        var text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
        if showFrames {
            let frames = Int(((clamped - Double(whole)) * Double(fps)).rounded()) % max(fps, 1)
            text += String(format: ":%02d", frames)
        }
        return text
    }

    /// "12.5 s", "1:02.0" for durations in the inspector and media bin.
    static func duration(_ time: CMTime) -> String {
        let s = time.secondsOrZero
        if s < 60 {
            return String(format: "%.2f s", s)
        }
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}
