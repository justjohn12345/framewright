import AppKit
import CoreGraphics

/// How the timeline answers the scroll wheel and a trackpad (review M4). The mapping never depends
/// on how tall the tracks are, so adding a lane never changes what the wheel does:
/// - Option or Command: zoom about the pointer.
/// - A notched mouse wheel scrolls time; with Shift (AppKit turns Shift + wheel into a horizontal
///   delta) or over the track headers it scrolls the tracks.
/// - A trackpad (or another device with precise deltas) scrolls both axes from its own deltas over
///   the tracks, the tracks only over the headers, and time only over the ruler.
enum TimelineScrolling {
    enum Action: Equatable {
        /// Multiply the zoom by `factor` about `anchorX` (track-area x).
        case zoom(factor: Double, anchorX: CGFloat)
        /// Change the scroll offsets by `dx` (time) and `dy` (tracks), in points.
        case pan(dx: CGFloat, dy: CGFloat)
    }

    /// What `scroll` (in the timeline's coordinates: the headers are the first `headerWidth` points,
    /// the ruler the first `rulerHeight`) does.
    static func action(for scroll: ScrollWheelCatcher.Scroll, headerWidth: CGFloat, rulerHeight: CGFloat) -> Action {
        let overRuler = scroll.location.y <= rulerHeight
        let overHeaders = !overRuler && scroll.location.x < headerWidth
        if scroll.modifiers.contains(.option) || scroll.modifiers.contains(.command) {
            let delta = scroll.deltaY != 0 ? scroll.deltaY : scroll.deltaX
            return .zoom(factor: exp(Double(delta) * 0.01), anchorX: max(0, scroll.location.x - headerWidth))
        }
        if !scroll.isPrecise {
            // A notched wheel has one axis; Shift turns it into the horizontal one.
            let amount = scroll.deltaY != 0 ? scroll.deltaY : scroll.deltaX
            if overHeaders || (scroll.modifiers.contains(.shift) && !overRuler) {
                return .pan(dx: 0, dy: -amount)
            }
            return .pan(dx: -amount, dy: 0)
        }
        if overHeaders {
            return .pan(dx: 0, dy: -scroll.deltaY)
        }
        if overRuler {
            return .pan(dx: -(scroll.deltaX != 0 ? scroll.deltaX : scroll.deltaY), dy: 0)
        }
        return .pan(dx: -scroll.deltaX, dy: -scroll.deltaY)
    }
}

/// A scroll bar's knob along a track `length` points long showing `visible` points of `content`
/// scrolled by `offset` (review M5; the horizontal bar and the vertical one share it).
struct ScrollBarGeometry: Equatable {
    static let minimumKnob: CGFloat = 30

    let content: CGFloat
    let visible: CGFloat
    let length: CGFloat

    /// The content is longer than what shows (the bar has something to scroll).
    var isScrollable: Bool { content > visible + 0.5 }
    /// The largest offset.
    var maximumOffset: CGFloat { max(0, content - visible) }
    /// The knob's length: the visible share of the track, at least `minimumKnob` (or the track).
    var knobLength: CGFloat {
        guard content > 0 else { return length }
        return min(length, max(Self.minimumKnob, length * min(1, visible / content)))
    }

    private var travel: CGFloat { max(0, length - knobLength) }

    /// Where the knob starts for `offset` (clamped).
    func knobStart(offset: CGFloat) -> CGFloat {
        guard maximumOffset > 0, travel > 0 else { return 0 }
        return min(travel, max(0, offset / maximumOffset * travel))
    }

    /// The offset that puts the knob's centre at `position` along the track (clamped).
    func offset(knobCentreAt position: CGFloat) -> CGFloat {
        guard maximumOffset > 0, travel > 0 else { return 0 }
        let start = position - knobLength / 2
        return min(maximumOffset, max(0, start / travel * maximumOffset))
    }
}
