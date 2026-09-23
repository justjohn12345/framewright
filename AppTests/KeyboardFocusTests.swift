import AppKit
import CoreMedia
import VidEditEngine
import XCTest
@testable import VidEdit

/// Keyboard focus rules (review 2026-09-23, finding 6): only the editor window's keys are taken,
/// a click in the editor takes focus back from a text field, auto-repeat of the transport keys
/// is ignored, Escape passes on when there is nothing to cancel, and dragging the playhead gives
/// the timeline the focus.
@MainActor
final class KeyboardFocusTests: XCTestCase {
    private var fixture: StoreFixture!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                         isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: isARepeat,
                                       keyCode: keyCode))
    }

    func testOnlyTheEditorWindowsKeysAreTaken() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let editor = makeWindow()
        let settings = makeWindow()
        store.editorWindow = editor
        let keyboard = KeyboardController(store: store)
        let delete = try keyDown("\u{7f}", keyCode: 51)
        XCTAssertFalse(keyboard.handle(delete, window: settings), "a key in another window is not the editor's")
        XCTAssertNotNil(store.clips[clip])
        XCTAssertFalse(keyboard.handle(delete, window: nil))
        XCTAssertTrue(keyboard.handle(delete, window: editor))
        XCTAssertNil(store.clips[clip], "Delete in the editor window deletes the selected clip")
    }

    func testAClickInTheTimelineTakesFocusBackFromATextField() throws {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        store.editorWindow = window
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder),
                       "the field is being edited")
        let gestures = TimelineGestureController(store: store)
        gestures.changed(location: CGPoint(x: 300, y: 40), startLocation: CGPoint(x: 300, y: 40), modifiers: [])
        gestures.ended()
        XCTAssertTrue(KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder),
                      "the timeline click ended the field's editing: \(String(describing: window.firstResponder))")

        // The same for a click in a monitor or the bin (they call the same store method).
        XCTAssertTrue(window.makeFirstResponder(field))
        store.reclaimKeyboardFocus()
        XCTAssertTrue(KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder))
    }

    func testAutoRepeatOfTheTransportKeysIsIgnored() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let editor = makeWindow()
        store.editorWindow = editor
        store.focusArea = .timeline
        let keyboard = KeyboardController(store: store)
        // A held L: the first press plays at 1x, the repeats change nothing.
        XCTAssertTrue(keyboard.handle(try keyDown("l", keyCode: 37), window: editor))
        XCTAssertEqual(store.engine.playbackRate, 1)
        for _ in 0 ..< 5 {
            XCTAssertTrue(keyboard.handle(try keyDown("l", keyCode: 37, isARepeat: true), window: editor),
                          "a repeat is swallowed")
        }
        XCTAssertEqual(store.engine.playbackRate, 1, "holding L does not race to 8x")
        XCTAssertTrue(keyboard.handle(try keyDown("l", keyCode: 37), window: editor))
        XCTAssertEqual(store.engine.playbackRate, 2, "a second press doubles")
        // A held Space: one toggle.
        XCTAssertTrue(keyboard.handle(try keyDown(" ", keyCode: 49), window: editor))
        XCTAssertEqual(store.engine.playbackState, .stopped)
        XCTAssertTrue(keyboard.handle(try keyDown(" ", keyCode: 49, isARepeat: true), window: editor))
        XCTAssertEqual(store.engine.playbackState, .stopped, "a Space repeat does not toggle again")
        // Arrow repeats still step (holding → moves frame by frame).
        let before = store.engine.currentTime
        XCTAssertTrue(keyboard.handle(try keyDown("", keyCode: 124, isARepeat: true), window: editor))
        XCTAssertEqual(store.engine.currentTime, CMTimeAdd(before, store.frameDuration))
    }

    func testEscapePassesOnWhenThereIsNothingToCancel() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let editor = makeWindow()
        store.editorWindow = editor
        let keyboard = KeyboardController(store: store)
        let escape = try keyDown("\u{1b}", keyCode: 53)
        XCTAssertFalse(keyboard.handle(escape, window: editor), "nothing to cancel: Escape is not consumed")
        // During a drag it cancels the drag.
        let gestures = TimelineGestureController(store: store)
        gestures.changed(location: CGPoint(x: 50, y: 90), startLocation: CGPoint(x: 50, y: 90), modifiers: [])
        gestures.changed(location: CGPoint(x: 100, y: 90), startLocation: CGPoint(x: 50, y: 90), modifiers: [])
        XCTAssertEqual(store.clips[clip]?.timelineStart.secondsOrZero ?? -1, 1, accuracy: 1e-9)
        XCTAssertTrue(keyboard.handle(escape, window: editor))
        XCTAssertEqual(store.clips[clip]?.timelineStart.secondsOrZero ?? -1, 0, accuracy: 1e-9)
        gestures.ended()
        XCTAssertFalse(keyboard.handle(escape, window: editor))
    }

    func testDraggingThePlayheadFocusesTheTimeline() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        store.showInSourceMonitor(movie.assetID)
        XCTAssertEqual(store.focusArea, .sourceMonitor)
        store.scrub(toSeconds: 0.5) // the ruler
        XCTAssertEqual(store.focusArea, .timeline)
        store.endScrub()
        XCTAssertEqual(store.playheadTime, CMTime(value: 15, timescale: 30))
    }
}
