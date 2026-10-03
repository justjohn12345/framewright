import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// Typing a title's text on the program monitor (titles slice 2): the session that starts when the title's box is
/// double-clicked (or Return is pressed with the title selected and the monitor in charge of the keys) and ends with
/// Escape, a click outside the box, the keyboard focus going elsewhere, or the title's box going away (another
/// selection, the playhead leaving the clip).
///
/// The text is edited by a text view that takes the keys (`TitleEditingTextView`, invisible: every key editing text
/// does what it does in any Mac text field, and the editor's single-key shortcuts do not see the keys); every change
/// is a step of the inspector's typing run (`TitleInspectorModel.textChanged`: one undo step per run, the idle commit,
/// `commitOpenEdits()`), so the inspector's text area follows. The caret and the selection are drawn over the picture
/// (`TitleEditingSurfaceView`), never into the title's picture, from the engine's own layout of the text
/// (`VEEngine.titleTextLayout(ofClip:at:)`: the renderer's lines through the clip's Motion at the playhead), so they
/// line up with the drawn glyphs at any monitor size, zoom and rotation. Clicks map through the same layout.
///
/// Geometry here is in sequence pixels on the frame; the surface maps it to the monitor's points.
@MainActor
final class PictureTitleEditor {
    /// What the session starts with.
    enum Start: Equatable {
        /// All the text selected (Return), so typing replaces it.
        case selectAll
        /// The caret where the frame point is (a double-click on the box).
        case caret(atFramePoint: CGPoint)
    }

    private unowned let store: ProjectStore
    let clipID: VEClipID
    private(set) var time: CMTime
    let start: Start
    /// The layout of the title's current text at `time` (nil when the clip is no longer a title).
    private(set) var layout: VETitleTextLayout?
    /// Called after the model or the playhead changed what the layout is (the surface redraws and takes a text that
    /// changed elsewhere, an undo say).
    var onLayoutChange: (() -> Void)?
    /// Set once the session ended (`TitleBoxModel.endEditing`).
    private(set) var isEnded = false

    init(store: ProjectStore, clipID: VEClipID, time: CMTime, start: Start) {
        self.store = store
        self.clipID = clipID
        self.time = time
        self.start = start
        relayout()
    }

    /// The title's text as the model has it.
    var modelText: String { store.clips[clipID]?.title?.text ?? "" }

    /// The text laid out (the layout's; "" without one).
    var text: String { layout?.text ?? "" }

    /// The selection the session starts with, in `text` (UTF-16 offsets).
    var initialSelection: NSRange {
        switch start {
        case .selectAll:
            return NSRange(location: 0, length: (modelText as NSString).length)
        case let .caret(point):
            return NSRange(location: index(atFramePoint: point), length: 0)
        }
    }

    // MARK: Changes

    /// The text view's text changed (a keystroke, a paste, a deletion): a step of the typing run.
    func textChanged(_ text: String) {
        guard !isEnded, text != modelText else { return }
        store.titleInspector.textChanged(text)
        relayout()
    }

    /// The model changed (an edit here or elsewhere, an undo): lay the text out again.
    func modelChanged() {
        guard !isEnded else { return }
        relayout()
        onLayoutChange?()
    }

    /// The program playhead moved: the clip's Motion there places the text.
    func setTime(_ time: CMTime) {
        guard !isEnded, time != self.time else { return }
        self.time = time
        relayout()
        onLayoutChange?()
    }

    func end() {
        isEnded = true
        onLayoutChange = nil
    }

    private func relayout() {
        layout = store.engine.titleTextLayout(ofClip: clipID, at: time)
    }

    // MARK: Geometry (sequence pixels on the frame)

    /// The caret at `index`.
    func caret(at index: Int) -> VETitleCaret? {
        layout?.caret(at: clamped(index))
    }

    /// The quads covering the text in `range`.
    func selectionQuads(_ range: NSRange) -> [VETitleQuad] {
        guard let layout, range.length > 0 else { return [] }
        return layout.canvasSelectionRects(for: range).map { layout.frameQuad(ofCanvasRect: $0.rectValue) }
    }

    /// The text block on the frame.
    var block: VETitleQuad? { layout?.frameBlock }

    /// The caret index nearest a frame point.
    func index(atFramePoint point: CGPoint) -> Int {
        layout.map { clamped($0.index(atFramePoint: point)) } ?? 0
    }

    /// The caret's x on the canvas at `index` (what moving up and down keeps).
    func canvasX(at index: Int) -> CGFloat {
        layout?.canvasCaret(at: clamped(index)).origin.x ?? 0
    }

    /// The index one line above (`up`) or below the caret at `index`, nearest the canvas x `goalX`: the start of the
    /// text above the first line, its end below the last.
    func verticalMove(from index: Int, up: Bool, goalX: CGFloat) -> Int {
        guard let layout else { return index }
        let line = layout.line(ofIndex: clamped(index))
        if up {
            return line == 0 ? 0 : layout.index(onLine: line - 1, nearCanvasX: Double(goalX))
        }
        return line + 1 >= layout.lineCount ? layout.length : layout.index(onLine: line + 1, nearCanvasX: Double(goalX))
    }

    /// The start (or, with `end`, the end: before its line break) of the drawn line the caret at `index` is on.
    func lineBoundary(of index: Int, end: Bool) -> Int {
        guard let layout else { return index }
        let line = layout.line(ofIndex: clamped(index))
        let range = layout.range(ofLine: line)
        guard range.location != NSNotFound else { return index }
        if !end { return range.location }
        return layout.index(onLine: line, nearCanvasX: .greatestFiniteMagnitude)
    }

    /// Whether a frame point is on the text block, or within `margin` sequence pixels of it.
    func blockContains(_ point: CGPoint, margin: CGFloat) -> Bool {
        guard let layout else { return false }
        let block = layout.canvasBlock.insetBy(dx: -margin, dy: -margin)
        let transform = layout.canvasToFrame
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 1e-12 else { return false }
        return block.contains(point.applying(transform.inverted()))
    }

    private func clamped(_ index: Int) -> Int {
        min(max(0, index), layout?.length ?? 0)
    }
}

extension TitleBoxModel {
    /// Why the title's text cannot be typed on the picture now, or nil when it can: the box must show (the playhead in
    /// the clip), no drag be in progress, its track be unlocked.
    var editingProblem: String? {
        guard isVisible else { return "Move the playhead into the title to type on the picture." }
        guard !isDragging, !store.isGestureActive else { return "Finish the current drag first." }
        if let track = store.track(clip.trackID), track.locked { return "“\(track.name)” is locked." }
        guard store.engine.clipInfo(clipID)?.title != nil else { return "The title no longer exists." }
        return nil
    }

    /// Starts typing on the picture (pausing playback). False, with the reason in the status line, when it cannot
    /// (`editingProblem`).
    @discardableResult
    func beginEditing(_ start: PictureTitleEditor.Start) -> Bool {
        if let editor, !editor.isEnded { return true }
        if let problem = editingProblem {
            store.statusMessage = problem
            return false
        }
        store.engine.pause()
        store.inspector.endNudgeBurst()
        store.titleInspector.endBurst()
        editor = PictureTitleEditor(store: store, clipID: clipID, time: time, start: start)
        return true
    }

    /// Ends typing on the picture: the typing run is committed as its undo step.
    func endEditing() {
        guard let editor else { return }
        editor.end()
        self.editor = nil
        store.titleInspector.endTyping()
    }
}
