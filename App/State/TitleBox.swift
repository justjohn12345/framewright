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

    private unowned let store: ProjectStore
    let clipID: VEClipID
    @Published private(set) var clip: VEClipInfo
    /// The text block on the frame at the playhead, through the clip's Motion there (sequence pixels).
    @Published private(set) var box: KenBurnsBox
    /// Whether the playhead is inside the clip (the box is drawn only then).
    @Published private(set) var isVisible: Bool
    /// The other titles' blocks at the playhead.
    @Published private(set) var outlines: [Outline] = []
    @Published private(set) var isDragging = false
    /// Why the last drag was refused or stopped (nil when it went as asked).
    @Published private(set) var note: String?

    private(set) var time: CMTime
    /// The title's values and the clip's Motion when the drag started.
    private var dragOrigin: (x: Double, y: Double, width: Double, motion: VEVideoParams)?
    /// The drag in progress was cancelled (Escape, or another edit ended its group): the rest of the gesture writes
    /// nothing until it ends.
    private(set) var dragCancelled = false

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

    /// The clip changed (an edit, an undo): re-read the box and the outlines. A drag in progress keeps its origin.
    func update(clip: VEClipInfo) {
        guard clip.clipID == clipID else { return }
        self.clip = clip
        read()
    }

    /// The program playhead moved.
    func setPlayhead(_ time: CMTime) {
        guard time != self.time else { return }
        self.time = time
        read()
    }

    private func read() {
        let visible = clip.timelineStart <= time && time < clip.timelineEnd
        if visible != isVisible { isVisible = visible }
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

    /// The text block of the title `clip` on the frame at `time` (sequence pixels), through its composed Motion there.
    static func block(of clip: VEClipInfo, at time: CMTime, store: ProjectStore) -> KenBurnsBox? {
        guard let title = clip.title else { return nil }
        let sequence = CGSize(width: store.sequence.width, height: store.sequence.height)
        let measured = store.engine.titleBlockSize(ofClip: clip.clipID)
        let height = max(measured.height, CGFloat(title.size) * sequence.height * minimumHeightFraction)
        return block(center: CGPoint(x: title.x, y: title.y),
                     size: CGSize(width: CGFloat(title.width) * sequence.width, height: height),
                     motion: clip.motion(at: time), sequence: sequence)
    }

    /// A block centred at `center` (fractions of the frame) of `size` (sequence pixels) on the title's frame-sized
    /// canvas, placed by `motion`: the canvas is the frame scaled about its centre, moved and turned as the
    /// compositor places a clip (`KenBurnsModel.box(for:picture:sequence:)`), so a canvas point p from the canvas's
    /// centre lands at the placed centre + R(θ) s p.
    static func block(center: CGPoint, size: CGSize, motion: VEVideoParams, sequence: CGSize) -> KenBurnsBox {
        let canvas = KenBurnsModel.box(for: motion, picture: sequence, sequence: sequence)
        let scale = motion.scale.isFinite ? max(0, CGFloat(motion.scale)) : 0
        let local = CGPoint(x: (center.x - 0.5) * sequence.width * scale, y: (center.y - 0.5) * sequence.height * scale)
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

    // MARK: Hit testing

    /// What a press at `point` grabs on `box` (view points), or nil (outside it and its handles): a corner or the
    /// left or right edge (within `KenBurnsHit.cornerRadius` / `edgeBand`) resizes, the rest of the box (its top and
    /// bottom edges included) moves. Tested in the box's own axes, so a turned box's edges turn with it.
    static func target(at point: CGPoint, box: KenBurnsBox) -> Target? {
        let p = box.local(point)
        let w = box.size.width / 2
        let h = box.size.height / 2
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

    // MARK: Dragging

    /// A step of the drag of `target`, now `translation` (sequence pixels on the frame) from where it started. The
    /// first step that moves opens the drag's coalescing group; every step writes the title's position (and, for an
    /// edge, its width) inside it, from the values when the drag started. Refused during another gesture.
    func applyDrag(_ target: Target, translation: CGSize) {
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
        switch target {
        case .body:
            x = min(max(origin.x + Double(moved.width / sequence.width), xRange.lowerBound), xRange.upperBound)
            y = min(max(origin.y + Double(moved.height / sequence.height), yRange.lowerBound), yRange.upperBound)
        case let .edge(right):
            // About the centre: the grabbed edge follows the pointer, the other moves the other way.
            let change = 2 * Double(moved.width / sequence.width) * (right ? 1 : -1)
            width = min(max(origin.width + change, widthRange.lowerBound), widthRange.upperBound)
        }
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
        dragOrigin = (title.x, title.y, title.width, clip.motion(at: time))
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
        store.cancelActiveGesture = nil
        if let clip = store.engine.clipInfo(clipID) { update(clip: clip) }
    }
}
