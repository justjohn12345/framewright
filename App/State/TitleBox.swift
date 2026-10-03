import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// The title box on the program monitor (titles design section 9; slice 1): drawn while exactly one title clip is
/// selected, no span is selected (a selected Motion span keeps opening the Ken Burns editor) and the playhead is
/// inside the clip. It is the title's text block (its wrap width by the height of its lines), placed on the frame
/// through the clip's composed Motion at the playhead, so a zoomed or turned title's box zooms and turns with it;
/// the other titles at the playhead are outlined thinly.
///
/// Dragging the body moves the text block (the title's position); dragging its left or right edge, or a corner,
/// changes the wrap width about the block's centre. A drag converts the pointer's movement through the inverse of
/// the clip's scale and rotation at the playhead, so the block follows the pointer under a Ken Burns zoom. Each drag
/// is one undo step ("Move Title", "Resize Title": a coalescing group, `beginDrag`, `applyDrag`, `endDrag`), and
/// Escape cancels it (`cancelDrag`, through `ProjectStore.cancelActiveGesture`), as the Ken Burns boxes do. Moving
/// renders nothing new: the title's picture does not depend on where it is.
///
/// Positions here are sequence pixels (origin at the frame's top-left, +y down) like `KenBurnsBox`'s; the title
/// stores its block's centre as fractions of the frame and its width as a fraction of the frame's width.
@MainActor
final class TitleBoxModel: ObservableObject {
    /// What a press on the box grabs.
    enum Target: Equatable {
        /// The body (or the top or bottom edge): moves the block.
        case body
        /// The left or right edge, or a corner on that side: changes the wrap width about the centre.
        case edge(right: Bool)
    }

    /// Another title at the playhead, outlined thinly.
    struct Outline: Equatable {
        let clipID: VEClipID
        let box: KenBurnsBox
    }

    /// The coalescing group of a box drag.
    static let dragGroup = "titleBox.drag"
    /// The smallest height the box is drawn with, as a fraction of the title's font size (an empty title still has a
    /// box to grab).
    static let minimumHeightFraction: CGFloat = 1

    unowned let store: ProjectStore
    let clipID: VEClipID
    @Published private(set) var clip: VEClipInfo
    /// The text block on the frame at the playhead, through the clip's Motion there (sequence pixels).
    @Published private(set) var box: KenBurnsBox
    /// Whether the playhead is inside the clip (the box is drawn only then).
    @Published private(set) var isVisible: Bool
    /// Whether the box's width can be dragged: area text (point text is as wide as its text).
    var isResizable: Bool { !(clip.title?.pointText ?? false) }
    /// The other titles' blocks at the playhead.
    @Published private(set) var outlines: [Outline] = []
    @Published private(set) var isDragging = false
    /// Why the last drag was refused or stopped (nil when it went as asked).
    @Published private(set) var note: String?
    /// The guide lines the drag in progress snapped to (`TitleSnapping`), drawn across the frame while it lasts.
    @Published private(set) var snapLines: [SafeAreas.Line] = []
    /// Typing on the picture in progress (`beginEditing`, `endEditing`; TitleTextEditing.swift), else nil.
    @Published var editor: PictureTitleEditor?

    private(set) var time: CMTime
    /// The title's values and the clip's Motion when the drag started, and its block relative to its position (sequence
    /// pixels on the canvas; a move does not change it).
    private var dragOrigin: (x: Double, y: Double, width: Double, motion: VEVideoParams, block: CGRect)?
    /// The drag in progress was cancelled (Escape, or another edit ended its group): the rest of the gesture writes
    /// nothing until it ends.
    private(set) var dragCancelled = false
    /// The presses on the box counted as clicks (`pressBegan`, `pressEnded`): a double-click starts typing.
    private var clicks = ClickCounter()

    /// Nil unless `clip` is a title on a sequence with a frame size.
    init?(store: ProjectStore, clip: VEClipInfo, time: CMTime) {
        guard clip.generatorKind == .title, clip.title != nil, store.sequence.width > 0, store.sequence.height > 0 else {
            return nil
        }
        self.store = store
        clipID = clip.clipID
        self.clip = clip
        self.time = time
        box = KenBurnsBox(center: .zero, size: .zero, rotationDegrees: 0)
        isVisible = false
        read()
    }

    private var sequenceSize: CGSize { CGSize(width: store.sequence.width, height: store.sequence.height) }

    // MARK: Reading

    /// The clip changed (an edit, an undo): re-read the box and the outlines. A drag in progress keeps its origin;
    /// typing on the picture lays the text out again.
    func update(clip: VEClipInfo) {
        guard clip.clipID == clipID else { return }
        self.clip = clip
        read()
        editor?.modelChanged()
    }

    /// The program playhead moved: typing on the picture follows the clip's Motion there, and ends when the playhead
    /// leaves the clip.
    func setPlayhead(_ time: CMTime) {
        guard time != self.time else { return }
        self.time = time
        read()
        editor?.setTime(time)
    }

    private func read() {
        let visible = clip.timelineStart <= time && time < clip.timelineEnd
        if visible != isVisible { isVisible = visible }
        if !visible, editor != nil { endEditing() }
        let placed = Self.block(of: clip, at: time, store: store) ?? box
        if placed != box { box = placed }
        let others: [Outline] = store.clips.values
            .filter { $0.clipID != clipID && $0.generatorKind == .title && $0.timelineStart <= time && time < $0.timelineEnd }
            .sorted { $0.clipID < $1.clipID }
            .compactMap { other in
                guard let track = store.track(other.trackID), !track.muted,
                      let block = Self.block(of: other, at: time, store: store) else { return nil }
                return Outline(clipID: other.clipID, box: block)
            }
        if others != outlines { outlines = others }
    }

    /// The text block of the title `clip` on the frame at `time` (sequence pixels), through its composed Motion there:
    /// where the engine lays it out around the title's position (`VEEngine.titleBlock(ofClip:)`: area text centred on
    /// it, point text at its alignment's edge, anchored at its top, centre or bottom), at least a line of its font
    /// tall and half its font size wide (an empty point text still has a box to grab).
    static func block(of clip: VEClipInfo, at time: CMTime, store: ProjectStore) -> KenBurnsBox? {
        guard let title = clip.title else { return nil }
        let sequence = CGSize(width: store.sequence.width, height: store.sequence.height)
        let measured = store.engine.titleBlock(ofClip: clip.clipID)
        guard !measured.isNull else { return nil }
        let fontSize = CGFloat(title.size) * sequence.height
        let size = CGSize(width: max(measured.width, fontSize * 0.5),
                          height: max(measured.height, fontSize * minimumHeightFraction))
        return block(canvasCenter: CGPoint(x: measured.midX, y: measured.midY), size: size,
                     motion: clip.motion(at: time), sequence: sequence)
    }

    /// A block centred at `canvasCenter` (sequence pixels on the title's frame-sized canvas) of `size` (sequence
    /// pixels), placed by `motion`: the canvas is the frame scaled about its centre, moved and turned as the
    /// compositor places a clip (`KenBurnsModel.box(for:picture:sequence:)`), so a canvas point p from the canvas's
    /// centre lands at the placed centre + R(θ) s p.
    static func block(canvasCenter center: CGPoint, size: CGSize, motion: VEVideoParams, sequence: CGSize) -> KenBurnsBox {
        let canvas = KenBurnsModel.box(for: motion, picture: sequence, sequence: sequence)
        let scale = motion.scale.isFinite ? max(0, CGFloat(motion.scale)) : 0
        let local = CGPoint(x: (center.x - sequence.width / 2) * scale, y: (center.y - sequence.height / 2) * scale)
        return KenBurnsBox(center: canvas.point(local: local),
                           size: CGSize(width: size.width * scale, height: size.height * scale),
                           rotationDegrees: motion.rotationDegrees)
    }

    /// `translation` (sequence pixels on the frame) in the canvas's own pixels: turned back by the clip's rotation
    /// and divided by its scale. Nil for a clip at scale 0 (nothing of it is on screen).
    static func canvasTranslation(_ translation: CGSize, motion: VEVideoParams) -> CGSize? {
        guard motion.scale.isFinite, motion.scale > 0 else { return nil }
        let theta = motion.rotationDegrees * .pi / 180
        let c = cos(theta)
        let s = sin(theta)
        let x = Double(translation.width)
        let y = Double(translation.height)
        // R(-θ)(x, y) = (c x + s y, -s x + c y).
        return CGSize(width: (c * x + s * y) / motion.scale, height: (-s * x + c * y) / motion.scale)
    }

    /// The axis-aligned bounds of `box` (a turned box's corners).
    static func bounds(of box: KenBurnsBox) -> CGRect {
        let corners = box.corners
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Hit testing

    /// What a press at `point` grabs on `box` (view points), or nil (outside it and its handles): a corner or the
    /// left or right edge (within `KenBurnsHit.cornerRadius` / `edgeBand`) resizes, the rest of the box (its top and
    /// bottom edges included) moves. Tested in the box's own axes, so a turned box's edges turn with it. A box that is
    /// not `resizable` (point text, as wide as its text) moves wherever it is grabbed.
    static func target(at point: CGPoint, box: KenBurnsBox, resizable: Bool = true) -> Target? {
        let p = box.local(point)
        let w = box.size.width / 2
        let h = box.size.height / 2
        if !resizable {
            let reach = KenBurnsHit.edgeBand
            return abs(p.x) <= w + reach && abs(p.y) <= h + reach ? .body : nil
        }
        for corner in KenBurnsModel.Corner.allCases {
            let c = box.corner(corner)
            if hypot(point.x - c.x, point.y - c.y) <= KenBurnsHit.cornerRadius {
                return .edge(right: corner == .topRight || corner == .bottomRight)
            }
        }
        guard p.y >= -h - KenBurnsHit.edgeBand, p.y <= h + KenBurnsHit.edgeBand else { return nil }
        if abs(p.x - w) <= KenBurnsHit.edgeBand { return .edge(right: true) }
        if abs(p.x + w) <= KenBurnsHit.edgeBand { return .edge(right: false) }
        guard abs(p.x) <= w + KenBurnsHit.edgeBand else { return nil }
        return .body
    }

    /// Whether a press released at `location` (view points), having moved by `movedBy`, ending `clickCount` clicks,
    /// starts typing on the picture: a double-click (or more) that moved no more than a click may
    /// (`ClickCounter.isClick`), on the box or its handles.
    static func doubleClickStartsTyping(at location: CGPoint, movedBy: CGSize, clickCount: Int, box: KenBurnsBox,
                                        resizable: Bool) -> Bool {
        clickCount >= 2 && ClickCounter.isClick(movedBy) && target(at: location, box: box, resizable: resizable) != nil
    }

    // MARK: Clicks

    /// The click count of the last press on the box (`pressBegan`; diagnostics and tests).
    var clickCount: Int { clicks.count }

    /// A press on the box (the first step of the overlay's drag gesture) at `location` (view points) at `time` (seconds,
    /// the event's), `interval` the user's double-click interval (`NSEvent.doubleClickInterval`): counted as a click.
    func pressBegan(at location: CGPoint, time: TimeInterval, interval: TimeInterval) {
        clicks.press(at: location, time: time, interval: interval)
    }

    /// The press on the box was released at `location` (view points), `movedBy` from where it was pressed; `box` is the
    /// box in view points and `framePoint` the release on the frame (sequence pixels). The drag ends (one undo step);
    /// a release that ends a double-click (or more) on the box (`doubleClickStartsTyping`) instead takes back the little
    /// the press moved the title (a click's jitter is not a move) and starts typing on the picture with the caret
    /// there. Returns whether typing started.
    @discardableResult
    func pressEnded(at location: CGPoint, movedBy: CGSize, box: KenBurnsBox, framePoint: CGPoint) -> Bool {
        let count = clicks.release(movedBy: movedBy)
        guard Self.doubleClickStartsTyping(at: location, movedBy: movedBy, clickCount: count, box: box,
                                           resizable: isResizable) else {
            endDrag()
            return false
        }
        cancelDrag()
        endDrag()
        // The next press starts a new run: a click soon after the session ends is a single click.
        clicks = ClickCounter()
        return beginEditing(.caret(atFramePoint: framePoint))
    }

    // MARK: Dragging

    /// A step of the drag of `target`, now `translation` (sequence pixels on the frame) from where it started. The
    /// first step that moves opens the drag's coalescing group; every step writes the title's position (and, for an
    /// edge, its width) inside it, from the values when the drag started. Refused during another gesture.
    ///
    /// With `snapping` (the overlay's drags snap unless Command is held), a moved box snaps to the frame's guide lines
    /// within `snapThreshold` sequence pixels (`TitleSnapping`); a dragged edge of an unturned box snaps its x.
    func applyDrag(_ target: Target, translation: CGSize, snapping: Bool = false, snapThreshold: CGFloat = 8) {
        guard translation != .zero, !dragCancelled else { return }
        if !isDragging, !beginDrag() { return }
        guard let origin = dragOrigin else { return }
        guard let moved = Self.canvasTranslation(translation, motion: origin.motion) else {
            note = "The title is scaled to nothing here: it cannot be dragged."
            return
        }
        let sequence = sequenceSize
        let xRange = range(.positionX)
        let yRange = range(.positionY)
        let widthRange = range(.boxWidth)
        var x = origin.x
        var y = origin.y
        var width = Double.nan
        var lines: [SafeAreas.Line] = []
        switch target {
        case .body:
            x = origin.x + Double(moved.width / sequence.width)
            y = origin.y + Double(moved.height / sequence.height)
            if snapping {
                // The moved block's bounds on the frame, snapped; the snap's offset on the frame taken back to the
                // canvas (the Motion is affine: moving the position by it moves the box on the frame by the offset).
                let canvas = origin.block.offsetBy(dx: CGFloat(x) * sequence.width, dy: CGFloat(y) * sequence.height)
                let placed = Self.block(canvasCenter: CGPoint(x: canvas.midX, y: canvas.midY), size: canvas.size,
                                        motion: origin.motion, sequence: sequence)
                let snap = TitleSnapping.snap(bounds: Self.bounds(of: placed), to: store.safeAreas.lines,
                                              threshold: snapThreshold)
                if snap.offset != .zero, let back = Self.canvasTranslation(snap.offset, motion: origin.motion) {
                    x += Double(back.width / sequence.width)
                    y += Double(back.height / sequence.height)
                }
                lines = snap.lines
            }
            x = min(max(x, xRange.lowerBound), xRange.upperBound)
            y = min(max(y, yRange.lowerBound), yRange.upperBound)
        case let .edge(right):
            guard isResizable else { return }
            // About the centre: the grabbed edge follows the pointer, the other moves the other way.
            let change = 2 * Double(moved.width / sequence.width) * (right ? 1 : -1)
            width = origin.width + change
            let scale = CGFloat(origin.motion.scale)
            let unturned = origin.motion.rotationDegrees.truncatingRemainder(dividingBy: 360) == 0
            if snapping, unturned, scale > 0 {
                // The grabbed edge's x on the frame, snapped; the width follows about the block's centre.
                let canvas = origin.block.offsetBy(dx: CGFloat(origin.x) * sequence.width,
                                                   dy: CGFloat(origin.y) * sequence.height)
                let centre = Self.block(canvasCenter: CGPoint(x: canvas.midX, y: canvas.midY), size: canvas.size,
                                        motion: origin.motion, sequence: sequence).center.x
                let half = CGFloat(width) * sequence.width * scale / 2
                if let snapped = TitleSnapping.snapEdge(x: centre + (right ? half : -half), to: store.safeAreas.lines,
                                                        threshold: snapThreshold) {
                    width = Double(2 * abs(snapped.x - centre) / (sequence.width * scale))
                    lines = [snapped.line]
                }
            }
            width = min(max(width, widthRange.lowerBound), widthRange.upperBound)
        }
        if lines != snapLines { snapLines = lines }
        let result = store.engine.performInCoalescingGroup(Self.dragGroup) {
            self.store.engine.setTitlePosition(x: x, y: y, width: width, clips: [NSNumber(value: self.clipID)])
        }
        guard !result.ok else { return }
        note = result.message
        if result.errorCode == .busy {
            // Another edit ended the group (committing what the drag did): the rest of the gesture is ignored.
            finishDrag()
            dragCancelled = true
        }
    }

    private func range(_ parameter: VETitleParameter) -> ClosedRange<Double> {
        let info = VETitleParameterInfo.info(for: parameter)
        return info.minimum ... info.maximum
    }

    /// Opens the drag's coalescing group (one undo step) and makes Escape cancel it; false (with the note) while
    /// another gesture is in progress or the clip is no longer a title.
    @discardableResult
    func beginDrag() -> Bool {
        guard !isDragging else { return true }
        guard !store.isGestureActive else {
            note = "Finish the current drag first."
            return false
        }
        guard let title = store.engine.clipInfo(clipID)?.title else {
            note = "The title no longer exists."
            return false
        }
        if let track = store.track(clip.trackID), track.locked {
            note = "“\(track.name)” is locked."
            return false
        }
        store.inspector.endNudgeBurst()
        store.titleInspector.endTyping()
        let block = store.engine.titleBlock(ofClip: clipID)
        guard !block.isNull else {
            note = "The title no longer exists."
            return false
        }
        dragOrigin = (title.x, title.y, title.width, clip.motion(at: time),
                      block.offsetBy(dx: -CGFloat(title.x) * sequenceSize.width, dy: -CGFloat(title.y) * sequenceSize.height))
        store.engine.beginCoalescing(withKey: Self.dragGroup)
        store.cancelActiveGesture = { [weak self] in self?.cancelDrag() }
        isDragging = true
        note = nil
        return true
    }

    /// The drag was released: its group ends (one undo step). A cancelled drag's gesture ends here too.
    func endDrag() {
        dragCancelled = false
        guard isDragging else { return }
        if store.engine.coalescingKey == Self.dragGroup {
            store.engine.endCoalescing()
        }
        finishDrag()
    }

    /// Escape (or Undo) mid-drag: reverts what the drag did; the rest of the gesture is ignored until it ends.
    func cancelDrag() {
        guard isDragging else { return }
        if store.engine.coalescingKey == Self.dragGroup {
            store.engine.cancelCoalescing()
        }
        finishDrag()
        dragCancelled = true
    }

    /// The gesture went away without a release: a drag in progress is reverted and the gesture is over.
    func gestureAbandoned() {
        cancelDrag()
        dragCancelled = false
    }

    private func finishDrag() {
        isDragging = false
        dragOrigin = nil
        if !snapLines.isEmpty { snapLines = [] }
        store.cancelActiveGesture = nil
        if let clip = store.engine.clipInfo(clipID) { update(clip: clip) }
    }
}

/// Counts a run of clicks from the presses and releases a gesture reports, as AppKit counts a mouse's clicks
/// (`NSEvent.clickCount`): a press is the next click of the run when it comes within the double-click interval of the
/// run's previous press and within `slop` of where that was, and that press was released as a click (it moved no more
/// than `slop`); any other press starts a new run. The title box counts its own clicks because its drag gesture's
/// callbacks are SwiftUI's: AppKit's current event when one runs need not be the press or release it reports (a
/// synthesized event sent to a window never is), and `NSEvent.clickCount` raises for an event that is not a mouse event.
struct ClickCounter {
    /// How far (points) the pointer may move during a click, and between the presses of a double-click.
    static let slop: CGFloat = 4

    /// The click count of the last press (0 before any).
    private(set) var count = 0
    private var previous: (time: TimeInterval, location: CGPoint)?
    /// Whether the last press was released as a click (false until its release is seen).
    private var previousWasClick = false
    /// A press waits for its release.
    private var isPressed = false

    /// Whether a press that moved by `moved` before its release is a click rather than a drag.
    static func isClick(_ moved: CGSize) -> Bool {
        hypot(moved.width, moved.height) <= slop
    }

    /// A press at `location` at `time` (seconds), `interval` the double-click interval: returns its click count.
    @discardableResult
    mutating func press(at location: CGPoint, time: TimeInterval, interval: TimeInterval) -> Int {
        if let previous, previousWasClick, time >= previous.time, time - previous.time <= interval,
           hypot(location.x - previous.location.x, location.y - previous.location.y) <= Self.slop {
            count += 1
        } else {
            count = 1
        }
        previous = (time, location)
        previousWasClick = false
        isPressed = true
        return count
    }

    /// The last press was released having moved by `movedBy`: its click count, or 0 when it was a drag (the next press
    /// starts a new run) or no press waits for its release.
    @discardableResult
    mutating func release(movedBy: CGSize) -> Int {
        guard isPressed else { return 0 }
        isPressed = false
        previousWasClick = Self.isClick(movedBy)
        return previousWasClick ? count : 0
    }
}
