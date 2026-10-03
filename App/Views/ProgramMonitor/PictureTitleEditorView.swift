import AppKit
import FramewrightEngine
import QuartzCore
import SwiftUI

/// Typing a title's text on the program monitor (`PictureTitleEditor`; titles slice 2): an AppKit surface over the whole
/// picture area while the session lasts. It draws the caret (blinking) and the selection over the picture from the
/// engine's layout of the title's text, takes the clicks (a click puts the caret, Shift-click extends, a double-click
/// selects a word, a triple-click a paragraph, a drag selects; a click outside the box ends the session), and holds
/// the invisible text view that takes the keys (`TitleEditingTextView`).
struct PictureTitleEditorView: NSViewRepresentable {
    let model: TitleBoxModel
    let editor: PictureTitleEditor
    let viewport: KenBurnsViewport

    func makeNSView(context: Context) -> TitleEditingSurfaceView {
        let surface = TitleEditingSurfaceView()
        surface.configure(box: model, editor: editor, viewport: viewport)
        return surface
    }

    func updateNSView(_ surface: TitleEditingSurfaceView, context: Context) {
        surface.configure(box: model, editor: editor, viewport: viewport)
    }

    static func dismantleNSView(_ surface: TitleEditingSurfaceView, coordinator: ()) {
        surface.detach()
    }
}

/// The surface of a typing session on the program monitor (see `PictureTitleEditorView`). Flipped, so its coordinates
/// are the overlay's (the viewport's monitor points).
@MainActor
final class TitleEditingSurfaceView: NSView, NSTextViewDelegate {
    private(set) weak var box: TitleBoxModel?
    private(set) var editor: PictureTitleEditor?
    private(set) var viewport = KenBurnsViewport(sequence: .zero, monitor: .zero, margin: 0)
    /// The invisible text view that takes the keys.
    let textView = TitleEditingTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    /// How near the text block (points) a click still edits the text rather than ending the session.
    static let clickMargin: CGFloat = 12
    /// The text view's container: wider than any title's line.
    static let unbounded: CGFloat = 1.0e7
    /// The caret's blink: shown, then hidden, half a period each.
    static let blinkPeriod: CFTimeInterval = 1.06

    private let selectionLayer = CAShapeLayer()
    private let caretLayer = CALayer()
    private let caretOutline = CAShapeLayer()
    private let caretLine = CAShapeLayer()
    /// Where a click or a drag started the selection, and how it selects (characters, words, paragraphs).
    private var clickAnchor = NSRange(location: 0, length: 0)
    private var clickGranularity = NSSelectionGranularity.selectByCharacter
    /// The selection's moving end (the other end stays when it is extended).
    private(set) var activeIndex = 0
    /// The canvas x a run of up and down moves keeps.
    private var goalX: CGFloat?
    private var isMovingVertically = false
    /// The selection when the text view last asked to change the text (restored when the change is refused).
    private var selectionBeforeChange: NSRange?
    private var isEnding = false
    /// Times the caret and selection were drawn (tests).
    private(set) var drawCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        selectionLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
        selectionLayer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        selectionLayer.lineWidth = 0.5
        caretOutline.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        caretOutline.lineWidth = 3.5
        caretOutline.lineCap = .round
        caretLine.strokeColor = NSColor.white.cgColor
        caretLine.lineWidth = 1.5
        caretLine.lineCap = .round
        caretLayer.addSublayer(caretOutline)
        caretLayer.addSublayer(caretLine)
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(caretLayer)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isFieldEditor = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        // Its own lines are paragraphs: a container no line reaches (a 1-point-wide one would break a line at every
        // glyph, and the text view's own commands that follow lines would act on single glyphs). The moves and
        // deletions that depend on lines follow the title's drawn lines instead (TitleEditingTextView).
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        textView.alphaValue = 0 // it takes the keys; the surface draws the caret and the selection
        textView.delegate = self
        textView.surface = self
        textView.setAccessibilityIdentifier("TitleEditingTextView")
        addSubview(textView)
        setAccessibilityIdentifier("TitleEditingSurface")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every click on the picture area is the session's (a click outside the box ends it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: The session

    func configure(box: TitleBoxModel, editor: PictureTitleEditor, viewport: KenBurnsViewport) {
        self.box = box
        let viewportChanged = viewport != self.viewport
        self.viewport = viewport
        if editor !== self.editor {
            self.editor = editor
            editor.onLayoutChange = { [weak self] in self?.layoutChanged() }
            textView.string = editor.modelText
            let start = editor.initialSelection
            select(start, active: NSMaxRange(start))
            focus()
            redraw()
        } else if viewportChanged {
            redraw()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus()
        redraw()
    }

    /// Gives the text view the keys.
    private func focus() {
        guard let window, editor != nil, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
    }

    /// The surface is going away: the text view gives up the keys.
    func detach() {
        isEnding = true
        if let window, window.firstResponder === textView {
            window.makeFirstResponder(nil)
        }
        editor = nil
    }

    /// Ends the session (Escape, a click outside the box): the typing run is committed, the editor's shortcuts get
    /// the keys again.
    func endEditing() {
        guard !isEnding else { return }
        isEnding = true
        box?.endEditing()
        if let window, window.firstResponder === textView {
            window.makeFirstResponder(nil)
        }
    }

    /// The text view gave up the keys (a click elsewhere in the window): the session ends.
    func textViewResigned() {
        guard !isEnding else { return }
        isEnding = true
        box?.endEditing()
    }

    /// The model or the playhead changed the layout: a text changed elsewhere (an undo) is taken, and the caret and
    /// selection are drawn again.
    private func layoutChanged() {
        guard let editor else { return }
        let text = editor.modelText
        if textView.string != text, !textView.hasMarkedText() {
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            select(NSRange(location: location, length: min(selected.length, length - location)),
                   active: min(activeIndex, length))
        }
        redraw()
    }

    // MARK: Text changes

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if !textView.hasMarkedText() { selectionBeforeChange = textView.selectedRange() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !textView.hasMarkedText(), let editor else { return }
        if !editor.textChanged(textView.string) {
            // Refused (the status line says why): the title's text and the selection before the edit come back.
            let text = editor.modelText
            let length = (text as NSString).length
            textView.string = text
            let before = selectionBeforeChange ?? NSRange(location: length, length: 0)
            let location = min(before.location, length)
            select(NSRange(location: location, length: min(before.length, length - location)),
                   active: min(NSMaxRange(before), length))
        }
        redraw()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let new = textView.selectedRange()
        if let old = (notification.userInfo?["NSOldSelectedCharacterRange"] as? NSValue)?.rangeValue {
            // The end that moved is the active one (Shift-arrows extend from the other).
            activeIndex = new.location != old.location && NSMaxRange(new) == NSMaxRange(old) ? new.location
                : NSMaxRange(new)
        } else {
            activeIndex = NSMaxRange(new)
        }
        if !isMovingVertically { goalX = nil }
        redraw()
    }

    /// Selects `range` with `active` as its moving end.
    private func select(_ range: NSRange, active: Int) {
        textView.setSelectedRange(range)
        activeIndex = active
    }

    /// The selection's fixed end.
    private var anchorIndex: Int {
        let selected = textView.selectedRange()
        return activeIndex == selected.location ? NSMaxRange(selected) : selected.location
    }

    // MARK: Moves the drawn lines decide (the text view's own lines are not the title's)

    func moveVertically(up: Bool, extend: Bool) {
        guard let editor else { return }
        let selected = textView.selectedRange()
        let from = extend || selected.length == 0 ? activeIndex : (up ? selected.location : NSMaxRange(selected))
        let goal = goalX ?? editor.canvasX(at: from)
        let to = editor.verticalMove(from: from, up: up, goalX: goal)
        isMovingVertically = true
        moveSelection(to: to, extend: extend)
        isMovingVertically = false
        goalX = goal
    }

    func moveToLineBoundary(end: Bool, extend: Bool) {
        guard let editor else { return }
        let selected = textView.selectedRange()
        let from = extend || selected.length == 0 ? activeIndex : (end ? NSMaxRange(selected) : selected.location)
        moveSelection(to: editor.lineBoundary(of: from, end: end), extend: extend)
    }

    /// Command-Delete and Command-Forward-Delete: the text from the caret to the start (or end) of its drawn line is
    /// deleted (a selection is deleted as it is; at the line's edge one character goes, as the text view does).
    func deleteToLineBoundary(end: Bool) {
        guard let editor else { return }
        let selected = textView.selectedRange()
        var range = selected
        if selected.length == 0 {
            let boundary = editor.lineBoundary(of: selected.location, end: end)
            range = end ? NSRange(location: selected.location, length: max(0, boundary - selected.location))
                : NSRange(location: boundary, length: max(0, selected.location - boundary))
            if range.length == 0 {
                if end { textView.deleteForward(nil) } else { textView.deleteBackward(nil) }
                return
            }
        }
        guard textView.shouldChangeText(in: range, replacementString: "") else { return }
        textView.replaceCharacters(in: range, with: "")
        select(NSRange(location: range.location, length: 0), active: range.location)
        textView.didChangeText()
    }

    /// Selects the drawn line the caret is on.
    func selectDrawnLine() {
        guard let editor else { return }
        let selected = textView.selectedRange()
        let start = editor.lineBoundary(of: selected.location, end: false)
        let end = max(start, editor.lineBoundary(of: NSMaxRange(selected), end: true))
        select(NSRange(location: start, length: end - start), active: end)
    }

    func moveToDocumentBoundary(end: Bool, extend: Bool) {
        moveSelection(to: end ? (textView.string as NSString).length : 0, extend: extend)
    }

    private func moveSelection(to index: Int, extend: Bool) {
        if extend {
            let anchor = anchorIndex
            select(NSRange(location: min(anchor, index), length: abs(index - anchor)), active: index)
        } else {
            select(NSRange(location: index, length: 0), active: index)
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let framePoint = viewport.sequence(point)
        let margin = viewport.sequence(CGSize(width: Self.clickMargin, height: 0)).width
        guard editor.blockContains(framePoint, margin: margin) else {
            endEditing()
            return
        }
        focus()
        let index = editor.index(atFramePoint: framePoint)
        switch event.clickCount {
        case 2:
            clickGranularity = .selectByWord
        case 3...:
            clickGranularity = .selectByParagraph
        default:
            clickGranularity = .selectByCharacter
        }
        if event.modifierFlags.contains(.shift), clickGranularity == .selectByCharacter {
            let anchor = anchorIndex
            clickAnchor = NSRange(location: anchor, length: 0)
            select(NSRange(location: min(anchor, index), length: abs(index - anchor)), active: index)
            return
        }
        clickAnchor = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                              granularity: clickGranularity)
        select(clickAnchor, active: NSMaxRange(clickAnchor))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor else { return }
        let index = editor.index(atFramePoint: viewport.sequence(convert(event.locationInWindow, from: nil)))
        let here = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                           granularity: clickGranularity)
        let reach = clickGranularity == .selectByCharacter ? NSRange(location: index, length: 0) : here
        let start = min(clickAnchor.location, reach.location)
        let end = max(NSMaxRange(clickAnchor), NSMaxRange(reach))
        select(NSRange(location: start, length: end - start), active: reach.location < clickAnchor.location ? start : end)
    }

    // MARK: Drawing

    /// The caret (blinking) or the selection, from the editor's geometry, placed by the viewport.
    func redraw() {
        guard let editor else {
            selectionLayer.path = nil
            caretLayer.isHidden = true
            return
        }
        drawCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let selected = textView.selectedRange()
        let selection = CGMutablePath()
        for quad in editor.selectionQuads(selected) {
            selection.addLines(between: [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map(viewport.view))
            selection.closeSubpath()
        }
        selectionLayer.path = selection
        if selected.length == 0, let caret = editor.caret(at: selected.location) {
            let line = CGMutablePath()
            line.move(to: viewport.view(caret.top))
            line.addLine(to: viewport.view(caret.bottom))
            caretOutline.path = line
            caretLine.path = line
            caretLayer.isHidden = false
            restartBlink()
        } else {
            caretLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// The caret shows at once after a change, then blinks.
    private func restartBlink() {
        caretLayer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5]
        blink.calculationMode = .discrete
        blink.duration = Self.blinkPeriod
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + Self.blinkPeriod / 2
        blink.fillMode = .backwards
        caretLayer.add(blink, forKey: "blink")
    }

    /// The caret at `index` on the screen (an input method's candidate window goes beside it).
    func screenRect(forCaretAt index: Int) -> NSRect? {
        guard let editor, let caret = editor.caret(at: index), let window else { return nil }
        let top = viewport.view(caret.top)
        let bottom = viewport.view(caret.bottom)
        let rect = NSRect(x: min(top.x, bottom.x), y: min(top.y, bottom.y), width: max(1, abs(bottom.x - top.x)),
                          height: max(1, abs(bottom.y - top.y)))
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Tests

    /// The selection layer's path and whether the caret shows (tests).
    var drawnSelection: CGPath? { selectionLayer.path }
    var drawnCaret: CGPath? { caretLayer.isHidden ? nil : caretLine.path }
}

/// The text view of a typing session on the program monitor: invisible, it takes the keys, so every key editing text
/// does what it does in any Mac text field (arrows, Option-arrows, Command-arrows, Delete, Return for a new line,
/// Command-A, Command-C/X/V of text, input methods) and the editor's single-key shortcuts (Space, J/K/L, I/O, the
/// arrows, Delete) never see them (`KeyboardController.shouldHandleKeys`: a text view has the keys). Moves and deletions
/// that depend on the lines (up, down, the start and end of a line, Command-Delete and Command-Forward-Delete, Select
/// Line) follow the title's drawn lines, not this view's own (whose lines are paragraphs: its container is unbounded). It has
/// no undo of its own, so Command-Z undoes the typing run in the engine as one step. Escape, or giving up the keys,
/// ends the session.
final class TitleEditingTextView: NSTextView {
    weak var surface: TitleEditingSurfaceView?
    /// Where Copy, Cut and Paste put and take text: the clipboard (tests give it a pasteboard of their own).
    var pasteboard = NSPasteboard.general

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        delete(sender)
    }

    override func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    override var undoManager: UndoManager? { nil }

    override func cancelOperation(_ sender: Any?) {
        surface?.endEditing()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { surface?.textViewResigned() }
        return resigned
    }

    override func moveUp(_ sender: Any?) { surface?.moveVertically(up: true, extend: false) }
    override func moveDown(_ sender: Any?) { surface?.moveVertically(up: false, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { surface?.moveVertically(up: true, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { surface?.moveVertically(up: false, extend: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { surface?.moveToLineBoundary(end: false, extend: false) }
    override func moveToEndOfLine(_ sender: Any?) { surface?.moveToLineBoundary(end: true, extend: false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { surface?.moveToLineBoundary(end: false, extend: false) }
    override func moveToRightEndOfLine(_ sender: Any?) { surface?.moveToLineBoundary(end: true, extend: false) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        surface?.moveToLineBoundary(end: false, extend: true)
    }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { surface?.moveToLineBoundary(end: true, extend: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        surface?.moveToLineBoundary(end: false, extend: true)
    }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        surface?.moveToLineBoundary(end: true, extend: true)
    }
    override func deleteToBeginningOfLine(_ sender: Any?) { surface?.deleteToLineBoundary(end: false) }
    override func deleteToEndOfLine(_ sender: Any?) { surface?.deleteToLineBoundary(end: true) }
    override func selectLine(_ sender: Any?) { surface?.selectDrawnLine() }
    override func pageUp(_ sender: Any?) { surface?.moveToDocumentBoundary(end: false, extend: false) }
    override func pageDown(_ sender: Any?) { surface?.moveToDocumentBoundary(end: true, extend: false) }
    override func pageUpAndModifySelection(_ sender: Any?) { surface?.moveToDocumentBoundary(end: false, extend: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { surface?.moveToDocumentBoundary(end: true, extend: true) }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        surface?.screenRect(forCaretAt: range.location) ?? super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }
}
