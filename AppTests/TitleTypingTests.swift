import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Typing a title's text on the program monitor (titles slice 2; `PictureTitleEditor`, `TitleEditingSurfaceView`):
/// Return starts it with the text selected; typing is one undo step per run and the inspector follows; while it lasts
/// the editor's single-key shortcuts (Space, J/K/L, I/O, Delete, the arrows) type or edit text instead; Escape, a
/// click outside the box, another selection or the playhead leaving the clip end it; the caret and selection are
/// drawn where the engine lays the text out, through the clip's Motion; clicks put the caret, select words and
/// extend; up and down follow the title's drawn lines. Made through the program monitor's layout hosted in a window
/// (its drawing, never the screen), with key events sent through the window as AppKit delivers them.
@MainActor
final class TitleTypingTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var hosted: HostedView?

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("titleTyping")
        try fixture.configureSequence() // 1920x1080
        TitleInspectorModel.typingIdleSeconds = 60 // runs end by the tests' own actions
    }

    override func tearDown() async throws {
        TitleInspectorModel.typingIdleSeconds = 2.0
        hosted?.close()
        hosted = nil
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// The monitor's size in the window: half the frame (960 x 540 points for 1920 x 1080).
    private let monitor = NSSize(width: 960, height: 540)

    /// A title at 0 ("Title", centred), selected, the playhead on it, and the program monitor's layout in a window
    /// (the store's editor window).
    private func titleOnMonitor(_ preset: GeneratorPreset = .title) async throws -> (VEClipID, TitleBoxModel) {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(preset))
        let id = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(10)
        let box = try XCTUnwrap(store.titleBox)
        box.setPlayhead(frames(10))
        let hosted = HostedView(ProgramMonitorLayout(store: store) { Color.black }, size: monitor)
        self.hosted = hosted
        store.editorWindow = hosted.window
        store.focusArea = .timeline
        await hosted.settle()
        return (id, box)
    }

    private var window: NSWindow { hosted!.window }

    /// The editing surface in the window, once SwiftUI has made it.
    private func surface() async throws -> TitleEditingSurfaceView {
        await hosted?.settle()
        func find(_ view: NSView) -> TitleEditingSurfaceView? {
            (view as? TitleEditingSurfaceView) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(window.contentView!), "the typing surface is on the monitor")
    }

    private var viewport: KenBurnsViewport {
        KenBurnsViewport(sequence: CGSize(width: 1920, height: 1080), monitor: monitor, margin: 0)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// Sends a key as AppKit does: the editor's key monitor first (`KeyboardController`), then the window.
    @discardableResult
    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                       keyboard: KeyboardController) -> Bool {
        let event = keyEvent(characters, keyCode: keyCode, modifiers: modifiers)
        if keyboard.handle(event, window: window) { return true }
        window.sendEvent(event)
        return false
    }

    private func type(_ text: String, keyboard: KeyboardController) {
        for character in text {
            XCTAssertFalse(press(String(character), keyCode: 0, keyboard: keyboard), "“\(character)” goes to the text")
        }
    }

    private func mouse(_ type: NSEvent.EventType, at framePoint: CGPoint, clicks: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let view = viewport.view(framePoint)
        let location = NSPoint(x: view.x, y: monitor.height - view.y) // the window's, from its bottom
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                  pressure: 1)!
    }

    // MARK: Starting and ending

    func testReturnStartsTypingWithTheTextSelectedAndEscapeEndsIt() async throws {
        let (id, box) = try await titleOnMonitor()
        let keyboard = KeyboardController(store: store)
        XCTAssertTrue(store.canEditTitleOnPicture)
        XCTAssertTrue(press("\r", keyCode: 36, keyboard: keyboard), "Return is the keyboard controller's")
        XCTAssertTrue(store.isEditingTitleOnPicture)
        let surface = try await surface()
        XCTAssertTrue(window.firstResponder === surface.textView, "the text view has the keys")
        XCTAssertEqual(surface.textView.string, "Title")
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 5), "all of it selected")
        XCTAssertFalse(KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder))
        // Typing replaces it; Return makes a new line.
        type("Hi", keyboard: keyboard)
        XCTAssertFalse(press("\r", keyCode: 36, keyboard: keyboard), "Return types a line break while typing")
        type("there", keyboard: keyboard)
        XCTAssertEqual(store.clips[id]?.title?.text, "Hi\nthere")
        XCTAssertNotNil(store.titleTypingGroup, "one typing run")
        // Escape ends it: the run is committed, the keys go back to the editor.
        press("\u{1b}", keyCode: 53, keyboard: keyboard)
        XCTAssertFalse(store.isEditingTitleOnPicture)
        XCTAssertNil(box.editor)
        XCTAssertNil(store.titleTypingGroup)
        XCTAssertTrue(KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder))
        XCTAssertEqual(store.undoActionName, "Edit Title Text")
        store.undo()
        XCTAssertEqual(store.clips[id]?.title?.text, "Title", "the run was one undo step")
        // Return without a title's box: not taken.
        store.selection = []
        XCTAssertFalse(press("\r", keyCode: 36, keyboard: keyboard))
        XCTAssertFalse(store.isEditingTitleOnPicture)
    }

    func testSingleKeyShortcutsTypeWhileTypingOnThePicture() async throws {
        let (id, box) = try await titleOnMonitor()
        let keyboard = KeyboardController(store: store)
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        let markIn = store.source.inPoint
        // Space, J, K, L, I and O are text, not play, shuttle or marks: the keyboard controller does not take them.
        for (character, code) in [(" ", UInt16(49)), ("j", 38), ("k", 40), ("l", 37), ("i", 34), ("o", 31)] {
            XCTAssertFalse(press(character, keyCode: code, keyboard: keyboard), "“\(character)” goes to the text")
        }
        XCTAssertEqual(store.clips[id]?.title?.text, " jklio")
        XCTAssertFalse(store.playhead.isRunning, "Space did not play")
        XCTAssertEqual(store.source.inPoint, markIn, "I did not mark")
        // The arrows move the caret; Delete deletes text, not the clip.
        XCTAssertFalse(press("\u{F702}", keyCode: 123, modifiers: [.numericPad, .function], keyboard: keyboard))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(store.playheadTime, frames(10), "the left arrow did not step a frame")
        XCTAssertFalse(press("\u{7f}", keyCode: 51, keyboard: keyboard))
        XCTAssertEqual(store.clips[id]?.title?.text, " jklo")
        XCTAssertNotNil(store.clips[id], "the clip is still there")
        // Command-A selects the text (the text view's select all, not every clip).
        XCTAssertFalse(press("a", keyCode: 0, modifiers: .command, keyboard: keyboard))
        surface.textView.selectAll(nil)
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(store.selection, [id], "the clip selection is unchanged")
    }

    func testCopyCutAndPasteOfText() async throws {
        let (id, box) = try await titleOnMonitor()
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        let pasteboard = NSPasteboard.general
        surface.textView.setSelectedRange(NSRange(location: 0, length: 3))
        surface.textView.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Tit")
        surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
        surface.textView.paste(nil)
        XCTAssertEqual(store.clips[id]?.title?.text, "TitleTit")
        surface.textView.setSelectedRange(NSRange(location: 0, length: 5))
        surface.textView.cut(nil)
        XCTAssertEqual(store.clips[id]?.title?.text, "Tit")
        XCTAssertEqual(pasteboard.string(forType: .string), "Title")
    }

    func testTypingEndsWithTheSelectionThePlayheadAndAClickOutside() async throws {
        let (_, box) = try await titleOnMonitor()
        XCTAssertTrue(box.beginEditing(.selectAll))
        _ = try await surface()
        // The playhead leaving the clip.
        store.playheadTime = frames(200)
        box.setPlayhead(frames(200))
        XCTAssertFalse(store.isEditingTitleOnPicture)
        XCTAssertFalse(box.beginEditing(.selectAll), "the box does not show there")
        XCTAssertEqual(store.statusMessage, "Move the playhead into the title to type on the picture.")
        store.playheadTime = frames(10)
        box.setPlayhead(frames(10))
        // Another selection.
        XCTAssertTrue(box.beginEditing(.selectAll))
        store.selection = []
        XCTAssertFalse(store.isEditingTitleOnPicture)
        XCTAssertNil(box.editor)
        // A click outside the box on the picture.
        store.selection = [box.clipID]
        let again = try XCTUnwrap(store.titleBox)
        again.setPlayhead(frames(10))
        XCTAssertTrue(again.beginEditing(.selectAll))
        let surface = try await surface()
        surface.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(store.isEditingTitleOnPicture)
        XCTAssertFalse(window.firstResponder is TitleEditingTextView)
        // A locked track: refused, and says why.
        let track = try XCTUnwrap(store.track(again.clip.trackID))
        XCTAssertTrue(store.engine.setTrack(track.trackID, locked: true).ok)
        again.update(clip: try XCTUnwrap(store.engine.clipInfo(again.clipID)))
        XCTAssertFalse(again.beginEditing(.selectAll))
        XCTAssertEqual(store.statusMessage, "“\(track.name)” is locked.")
    }

    // MARK: The caret, the selection and clicks

    /// The caret drawn on the monitor: the engine's caret on the frame, placed by the monitor's viewport.
    private func assertCaret(_ surface: TitleEditingSurfaceView, at index: Int, editor: PictureTitleEditor,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let drawn = try XCTUnwrap(surface.drawnCaret, "a caret is drawn", file: file, line: line).boundingBoxOfPath
        let caret = try XCTUnwrap(editor.caret(at: index), file: file, line: line)
        let top = viewport.view(caret.top)
        let bottom = viewport.view(caret.bottom)
        XCTAssertEqual(drawn.minX, min(top.x, bottom.x), accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(drawn.maxX, max(top.x, bottom.x), accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(drawn.minY, min(top.y, bottom.y), accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(drawn.maxY, max(top.y, bottom.y), accuracy: 1e-6, file: file, line: line)
    }

    func testTheCaretAndSelectionAreDrawnWhereTheTextIsUnderMotion() async throws {
        let (id, box) = try await titleOnMonitor()
        XCTAssertTrue(store.engine.setTitleText("Hello world", clips: [NSNumber(value: id)]).ok)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 60, y: -40, scale: 1.5, rotationDegrees: 20,
                                                                opacity: 1), forClip: id).ok)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        let editor = try XCTUnwrap(box.editor)
        XCTAssertNil(surface.drawnCaret, "a selection, no caret")
        let quads = editor.selectionQuads(NSRange(location: 0, length: 11))
        XCTAssertEqual(quads.count, 1)
        let drawn = try XCTUnwrap(surface.drawnSelection).boundingBoxOfPath
        let corners = quads.flatMap { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }.map(viewport.view)
        XCTAssertEqual(drawn.minX, corners.map(\.x).min()!, accuracy: 1e-6)
        XCTAssertEqual(drawn.maxY, corners.map(\.y).max()!, accuracy: 1e-6)
        // The selection is turned with the title: its top-left corner is higher than its bottom-left... and left of
        // its top-right, by the rotation.
        let quad = quads[0]
        let angle = atan2(quad.topRight.y - quad.topLeft.y, quad.topRight.x - quad.topLeft.x) * 180 / .pi
        XCTAssertEqual(angle, 20, accuracy: 1e-6)
        // A caret: between "Hello" and " world".
        surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
        try assertCaret(surface, at: 5, editor: editor)
        let caret = try XCTUnwrap(editor.caret(at: 5))
        let height = hypot(caret.bottom.x - caret.top.x, caret.bottom.y - caret.top.y)
        XCTAssertGreaterThan(height, 0.06 * 1080 * 1.5 * 0.9, "the caret is a line of the zoomed text tall")
        // Typing moves it: drawn again at once, where the new text puts it.
        let draws = surface.drawCount
        surface.textView.insertText(",", replacementRange: surface.textView.selectedRange())
        XCTAssertEqual(store.clips[id]?.title?.text, "Hello, world")
        XCTAssertGreaterThan(surface.drawCount, draws)
        try assertCaret(surface, at: 6, editor: editor)
    }

    func testClicksPutTheCaretSelectWordsAndExtend() async throws {
        let (id, box) = try await titleOnMonitor()
        XCTAssertTrue(store.engine.setTitleText("Hello wide world", clips: [NSNumber(value: id)]).ok)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        let editor = try XCTUnwrap(box.editor)
        // Points on the frame: the middle of "wide" (characters 6-9), and just after the "w" of "world".
        let wide = try XCTUnwrap(editor.selectionQuads(NSRange(location: 6, length: 4)).first)
        let middle = CGPoint(x: (wide.topLeft.x + wide.bottomRight.x) / 2, y: (wide.topLeft.y + wide.bottomRight.y) / 2)
        let afterW = try XCTUnwrap(editor.selectionQuads(NSRange(location: 11, length: 1)).first)
        let w = CGPoint(x: afterW.topRight.x - 1, y: (afterW.topLeft.y + afterW.bottomLeft.y) / 2)
        surface.mouseDown(with: mouse(.leftMouseDown, at: w))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 12, length: 0), "a click: the caret")
        try assertCaret(surface, at: 12, editor: editor)
        surface.mouseDown(with: mouse(.leftMouseDown, at: middle, clicks: 2))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 6, length: 4), "a double-click: the word")
        surface.mouseDown(with: mouse(.leftMouseDown, at: w, modifiers: .shift))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 6, length: 6), "Shift-click extends")
        // A drag from the start of "Hello" to the middle of "wide".
        let hello = try XCTUnwrap(editor.selectionQuads(NSRange(location: 0, length: 1)).first)
        let start = CGPoint(x: hello.topLeft.x + 1, y: (hello.topLeft.y + hello.bottomLeft.y) / 2)
        surface.mouseDown(with: mouse(.leftMouseDown, at: start))
        surface.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: wide.topLeft.x + 1,
                                                                        y: (wide.topLeft.y + wide.bottomLeft.y) / 2)))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 6))
        surface.mouseDown(with: mouse(.leftMouseDown, at: middle, clicks: 3))
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 16), "a triple-click: the line")
        XCTAssertTrue(store.isEditingTitleOnPicture, "clicks on the text keep typing")
    }

    func testUpAndDownFollowTheTitlesDrawnLines() async throws {
        let (id, box) = try await titleOnMonitor()
        // A narrow box: the paragraph wraps in the title's lines, which the text view's own layout does not know.
        XCTAssertTrue(store.engine.setTitleText("one two three four five six", clips: [NSNumber(value: id)]).ok)
        XCTAssertTrue(store.engine.setTitleNumber(0.15, for: .boxWidth, clips: [NSNumber(value: id)]).ok)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        let editor = try XCTUnwrap(box.editor)
        let layout = try XCTUnwrap(editor.layout)
        XCTAssertGreaterThanOrEqual(layout.lineCount, 3)
        surface.textView.setSelectedRange(NSRange(location: 1, length: 0))
        surface.textView.moveDown(nil)
        let down = surface.textView.selectedRange().location
        XCTAssertEqual(layout.line(ofIndex: down), 1, "down: the next drawn line")
        XCTAssertEqual(down, editor.verticalMove(from: 1, up: false, goalX: editor.canvasX(at: 1)))
        surface.textView.moveDown(nil)
        surface.textView.moveUp(nil)
        XCTAssertEqual(surface.textView.selectedRange().location, down, "the caret keeps its x across moves")
        surface.textView.moveToEndOfLine(nil)
        let end = surface.textView.selectedRange().location
        XCTAssertEqual(layout.line(ofIndex: end), 1, "the end of the drawn line, not of the paragraph")
        XCTAssertLessThan(end, layout.length)
        surface.textView.moveToBeginningOfLineAndModifySelection(nil)
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: layout.range(ofLine: 1).location,
                                                                 length: end - layout.range(ofLine: 1).location))
        surface.textView.moveUp(nil)
        surface.textView.moveUp(nil)
        XCTAssertEqual(surface.textView.selectedRange().location, 0, "above the first line: the start")
        surface.textView.moveDownAndModifySelection(nil)
        XCTAssertEqual(surface.textView.selectedRange().location, 0)
        XCTAssertGreaterThan(surface.textView.selectedRange().length, 0, "Shift-down extends")
    }

    /// A double-click on the box, made by pointer events through a window as a hand makes them (they reach SwiftUI's
    /// gestures only in a visible window), starts typing with the caret where it was.
    func testADoubleClickOnTheBoxStartsTypingWithTheCaretThere() async throws {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.title))
        let id = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.setTitleText("Hello world", clips: [NSNumber(value: id)]).ok)
        store.playheadTime = frames(10)
        let box = try XCTUnwrap(store.titleBox)
        box.setPlayhead(frames(10))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: monitor), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ClickThroughHostingView(rootView: ProgramMonitorLayout(store: store) { Color.black })
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        guard window.occlusionState.contains(.visible) else {
            throw XCTSkip("the test window is not visible (the screen is locked or the window is covered)")
        }
        // The point just before "w" of "world" (index 6), on the frame and in the window.
        let layout = try XCTUnwrap(store.engine.titleTextLayout(ofClip: id, at: frames(10)))
        let quad = layout.frameQuad(ofCanvasRect: try XCTUnwrap(layout.canvasSelectionRects(for: NSRange(location: 6,
                                                                                                         length: 1)).first)
                                        .rectValue)
        let point = CGPoint(x: quad.topLeft.x + 2, y: (quad.topLeft.y + quad.bottomLeft.y) / 2)
        let view = viewport.view(point)
        let location = NSPoint(x: view.x, y: monitor.height - view.y)
        for click in 1 ... 2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil,
                                                             eventNumber: click, clickCount: click, pressure: 1))
                window.sendEvent(event)
                await StoreFixture.wait(until: { false }, timeout: 0.02)
            }
        }
        await StoreFixture.wait(until: { box.editor != nil }, timeout: 2)
        guard box.editor != nil else {
            throw XCTSkip("synthetic mouse events do not reach SwiftUI gestures in this test host")
        }
        XCTAssertTrue(store.isEditingTitleOnPicture)
        await StoreFixture.wait(until: { window.firstResponder is TitleEditingTextView }, timeout: 2)
        let textView = try XCTUnwrap(window.firstResponder as? TitleEditingTextView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0), "the caret where it was clicked")
    }

    /// Command-Delete and Command-Forward-Delete delete to the start and the end of the drawn line (review fix: the text
    /// view's own lines were one glyph wide, so they deleted one character).
    func testCommandDeleteDeletesToTheDrawnLinesEdge() async throws {
        let (id, box) = try await titleOnMonitor()
        let keyboard = KeyboardController(store: store)
        XCTAssertTrue(store.engine.setTitleText("Hello world", clips: [NSNumber(value: id)]).ok)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertTrue(box.beginEditing(.selectAll))
        let single = try await surface()
        single.textView.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertFalse(press("\u{7f}", keyCode: 51, modifiers: .command, keyboard: keyboard), "Command-Delete is text's")
        XCTAssertEqual(store.clips[id]?.title?.text, "", "Command-Delete at the end: the whole line")
        box.endEditing()
        // A paragraph the box wraps into drawn lines: only the drawn line's part goes.
        XCTAssertTrue(store.engine.setTitleText("one two three four five six", clips: [NSNumber(value: id)]).ok)
        XCTAssertTrue(store.engine.setTitleNumber(0.15, for: .boxWidth, clips: [NSNumber(value: id)]).ok)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertTrue(box.beginEditing(.selectAll))
        let wrapped = try await surface()
        let layout = try XCTUnwrap(box.editor?.layout)
        XCTAssertGreaterThanOrEqual(layout.lineCount, 3)
        let last = layout.range(ofLine: layout.lineCount - 1)
        let second = layout.range(ofLine: 1)
        wrapped.textView.setSelectedRange(NSRange(location: layout.length, length: 0))
        XCTAssertFalse(press("\u{7f}", keyCode: 51, modifiers: .command, keyboard: keyboard))
        let text = "one two three four five six" as NSString
        XCTAssertEqual(store.clips[id]?.title?.text, text.substring(to: last.location), "the last drawn line's text went")
        // Command-Forward-Delete from the start of the first drawn line to its end (before the wrap), in the text as it
        // is laid out now.
        let now = try XCTUnwrap(box.editor?.layout)
        XCTAssertGreaterThanOrEqual(now.lineCount, 2)
        XCTAssertEqual(second.location, now.range(ofLine: 1).location)
        wrapped.textView.setSelectedRange(NSRange(location: 0, length: 0))
        wrapped.textView.doCommand(by: #selector(NSResponder.deleteToEndOfLine(_:)))
        let lineEnd = now.index(onLine: 0, nearCanvasX: .greatestFiniteMagnitude)
        XCTAssertLessThan(lineEnd, now.range(ofLine: 1).location, "before the space the line wrapped at")
        let expected = (text.substring(to: last.location) as NSString).substring(from: lineEnd)
        XCTAssertEqual(store.clips[id]?.title?.text, expected)
        // The text view's own lines are paragraphs (an unbounded container), not single glyphs.
        XCTAssertGreaterThan(wrapped.textView.textContainer?.containerSize.width ?? 0, 1.0e6)
        XCTAssertFalse(wrapped.textView.textContainer?.widthTracksTextView ?? true)
    }

    func testUndoWhileTypingTakesTheRunBackAndTheTextFollows() async throws {
        let (id, box) = try await titleOnMonitor()
        let keyboard = KeyboardController(store: store)
        XCTAssertTrue(box.beginEditing(.selectAll))
        let surface = try await surface()
        type("New", keyboard: keyboard)
        XCTAssertEqual(store.clips[id]?.title?.text, "New")
        XCTAssertNil(surface.textView.undoManager, "no undo of its own: Command-Z reaches the engine")
        store.undo() // what Edit > Undo does
        XCTAssertEqual(store.clips[id]?.title?.text, "Title")
        XCTAssertEqual(surface.textView.string, "Title", "the text on the picture follows")
        surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(store.isEditingTitleOnPicture, "typing goes on")
        type("!", keyboard: keyboard)
        XCTAssertEqual(store.clips[id]?.title?.text, "Title!")
        // The inspector's text area shows what is typed on the picture (it reads the model).
        XCTAssertEqual(store.titleInspector.text, store.clips[id]?.title?.text)
    }
}

/// A hosting view that takes the first click in a window that is not key (the test host is not the active app while
/// someone else uses the Mac).
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
