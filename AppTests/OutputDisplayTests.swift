import AppKit
import FramewrightEngine
import XCTest
@testable import Framewright

/// The program monitor on a second display (open finding 7), over an injected screen list: the
/// menu item's availability, the output window covering the other display with a preview view
/// the engine drives, Escape, and a display that goes away; and from the UX round review (findings
/// 2 and 3): only the transport keys work in the output window, it goes away while the app is in
/// the background and comes back, and it is not shown while the editor's display is unknown.
/// Whether the picture really reaches a physical second display can only be checked by hand.
@MainActor
final class OutputDisplayTests: XCTestCase {
    private final class FakeScreens: ScreenProviding {
        var screens: [DisplayScreen]
        var editorScreen: UInt32?

        init(_ screens: [DisplayScreen], editor: UInt32?) {
            self.screens = screens
            editorScreen = editor
        }

        func screenID(of window: NSWindow?) -> UInt32? {
            editorScreen
        }
    }

    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    private let main = DisplayScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), name: "Built-in")
    private let external = DisplayScreen(id: 7, frame: CGRect(x: 1440, y: 0, width: 1280, height: 720), name: "External")

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    func testTheOutputWindowCoversTheOtherDisplayAndClosesWhenItGoesAway() throws {
        let screens = FakeScreens([main], editor: 1)
        let output = OutputDisplayController(store: store, screens: screens, center: NotificationCenter())
        XCTAssertFalse(output.isAvailable, "one display: nothing to show it on")
        output.show()
        XCTAssertFalse(output.isShowing)
        XCTAssertNil(store.engine.outputView)

        screens.screens = [main, external]
        output.screensChanged()
        XCTAssertTrue(output.isAvailable, "a display was connected")
        XCTAssertEqual(output.targetScreen, external)
        output.show()
        XCTAssertTrue(output.isShowing)
        let window = try XCTUnwrap(output.window)
        XCTAssertEqual(window.frame, external.frame, "full screen on the other display")
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.canBecomeKey, "so Escape and the transport keys reach it")
        let view = try XCTUnwrap(window.contentView as? VEPreviewView)
        XCTAssertTrue(store.engine.outputView === view, "the engine drives the output view")
        XCTAssertTrue(view.isPaused, "stopped: the engine keeps its render loop paused")

        // Escape closes it.
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.keyDown(with: escape)
        XCTAssertFalse(output.isShowing)
        XCTAssertNil(output.window)
        XCTAssertNil(store.engine.outputView, "detached")

        // Shown again, then the display is unplugged: closed, detached, and the status line says why.
        output.toggle()
        XCTAssertTrue(output.isShowing)
        screens.screens = [main]
        output.screensChanged()
        XCTAssertFalse(output.isShowing)
        XCTAssertFalse(output.isAvailable)
        XCTAssertNil(store.engine.outputView)
        XCTAssertEqual(store.statusMessage, OutputDisplayController.screenGoneMessage)
    }

    func testTheOutputUsesADisplayTheEditorIsNotOn() throws {
        let screens = FakeScreens([main, external], editor: 7)
        let output = OutputDisplayController(store: store, screens: screens, center: NotificationCenter())
        XCTAssertEqual(output.targetScreen, main, "the editor window is on the external display")
        output.show()
        XCTAssertEqual(output.window?.frame, main.frame)
        // A display rearranged or resized: the window follows it.
        let moved = DisplayScreen(id: 1, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), name: "Built-in")
        screens.screens = [moved, external]
        output.screensChanged()
        XCTAssertTrue(output.isShowing)
        XCTAssertEqual(output.window?.frame, moved.frame)
        output.hide()
        XCTAssertFalse(output.isShowing)
        XCTAssertNil(store.engine.outputView)
    }

    func testTheTransportKeysWorkInTheOutputWindow() throws {
        let screens = FakeScreens([main, external], editor: 1)
        let output = OutputDisplayController(store: store, screens: screens, center: NotificationCenter())
        store.outputDisplay = output
        output.show()
        let window = try XCTUnwrap(output.window)
        let keyboard = KeyboardController(store: store)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: " ",
                                                   charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertTrue(keyboard.handle(space, window: window), "Space in the output window is the transport's")
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertFalse(keyboard.handle(space, window: other), "other windows keep their keys")
        store.engine.pause()
        output.hide()
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// Finding 2: the editing keys do nothing from the output window (Delete, Shift/Option-Delete,
    /// Forward Delete, Command-A, I/O, zoom, gain); the transport keys drive the program monitor.
    func testOnlyTheTransportKeysWorkInTheOutputWindow() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        _ = try fixture.placeMovie(movie, at: 2)
        store.showInSourceMonitor(movie.assetID) // I/O would mark the source monitor's asset
        store.focusArea = .timeline
        store.selection = [clip]
        let screens = FakeScreens([main, external], editor: 1)
        let output = OutputDisplayController(store: store, screens: screens, center: NotificationCenter())
        store.outputDisplay = output
        output.show()
        let window = try XCTUnwrap(output.window)
        let keyboard = KeyboardController(store: store)

        let changeCount = store.changeCount
        let clipCount = store.clips.count
        let pixelsPerSecond = store.pixelsPerSecond
        let source = store.source
        let editing: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("\u{7f}", 51, []), ("\u{7f}", 51, .shift), ("\u{7f}", 51, .option), ("\u{f728}", 117, []),
            ("a", 0, .command), ("i", 34, []), ("o", 31, []), ("=", 24, []), ("+", 24, .shift), ("-", 27, []),
            ("]", 30, []), ("[", 33, []), ("}", 30, .shift), ("{", 33, .shift),
        ]
        for (characters, keyCode, modifiers) in editing {
            let event = try key(characters, keyCode: keyCode, modifiers: modifiers, window: window)
            XCTAssertNotNil(KeyboardController.action(keyCode: keyCode, characters: characters, modifiers: modifiers),
                            "\(characters) is an editing key in the editor")
            XCTAssertFalse(keyboard.handle(event, window: window),
                           "\(characters) \(modifiers) is not the output window's")
        }
        XCTAssertEqual(store.changeCount, changeCount, "no edit from the output window")
        XCTAssertEqual(store.clips.count, clipCount)
        XCTAssertEqual(store.selection, [clip], "Command-A selected nothing")
        XCTAssertEqual(store.pixelsPerSecond, pixelsPerSecond, "no zoom")
        XCTAssertEqual(store.source, source, "no source marks")

        // The transport: Space plays, K stops, the arrows step, End and Home jump.
        XCTAssertTrue(keyboard.handle(try key(" ", keyCode: 49, window: window), window: window))
        XCTAssertTrue(store.engine.playbackState == .playing || store.engine.playbackState == .prerolling,
                      "Space plays")
        XCTAssertTrue(keyboard.handle(try key("k", keyCode: 40, window: window), window: window))
        XCTAssertEqual(store.engine.playbackState, .stopped, "K stops")
        XCTAssertTrue(keyboard.handle(try key("\u{f703}", keyCode: 119, window: window), window: window))
        let end = store.engine.currentTime
        XCTAssertGreaterThan(end.seconds, 3.5, "End goes to the last frame")
        XCTAssertTrue(keyboard.handle(try key("\u{f702}", keyCode: 123, window: window), window: window))
        XCTAssertLessThan(store.engine.currentTime.seconds, end.seconds, "← steps back")
        XCTAssertTrue(keyboard.handle(try key("\u{f729}", keyCode: 115, window: window), window: window))
        XCTAssertEqual(store.engine.currentTime.seconds, 0, "Home goes to the start")
        XCTAssertTrue(keyboard.handle(try key("\u{f703}", keyCode: 124, window: window), window: window))
        XCTAssertEqual(store.engine.currentTime.seconds, 1.0 / 30, accuracy: 1e-6, "→ steps forward")
        XCTAssertTrue(keyboard.handle(try key("l", keyCode: 37, window: window), window: window))
        XCTAssertTrue(store.engine.playbackState == .playing || store.engine.playbackState == .prerolling, "L plays")
        XCTAssertTrue(keyboard.handle(try key("j", keyCode: 38, window: window), window: window))
        XCTAssertLessThan(store.engine.playbackRate, 0, "J plays backwards")
        store.engine.pause()
        XCTAssertEqual(store.changeCount, changeCount, "the transport edits nothing")

        // The same editing key in the editor window does edit.
        let editor = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        store.editorWindow = editor
        XCTAssertTrue(keyboard.handle(try key("\u{7f}", keyCode: 51, window: editor), window: editor))
        XCTAssertNil(store.clips[clip], "Delete in the editor window deletes the selected clip")
        output.hide()
    }

    /// Finding 3: while the app is in the background the output window is gone (it would stay on
    /// top of other apps on its display); it comes back on activation, only if it was up, and not
    /// when its display went away meanwhile (the status line says so).
    func testTheOutputGoesAwayWhileTheAppIsInTheBackground() throws {
        let center = NotificationCenter()
        let screens = FakeScreens([main, external], editor: 1)
        let output = OutputDisplayController(store: store, screens: screens, center: center)
        func post(_ name: Notification.Name) {
            center.post(name: name, object: NSApp)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02)) // observers are on the main queue
        }

        // Not shown: the app's activation changes nothing.
        post(NSApplication.didResignActiveNotification)
        post(NSApplication.didBecomeActiveNotification)
        XCTAssertFalse(output.isShowing)
        XCTAssertNil(store.engine.outputView)

        output.show()
        XCTAssertTrue(output.isShowing)
        post(NSApplication.didResignActiveNotification)
        XCTAssertTrue(StoreFixture.spin(until: { !output.isShowing }, timeout: 2), "gone with the app")
        XCTAssertNil(output.window)
        XCTAssertNil(store.engine.outputView, "detached while in the background")
        XCTAssertTrue(output.resumesOnActivation)
        post(NSApplication.didBecomeActiveNotification)
        XCTAssertTrue(StoreFixture.spin(until: { output.isShowing }, timeout: 2), "back with the app")
        let window = try XCTUnwrap(output.window)
        XCTAssertEqual(window.frame, external.frame)
        XCTAssertTrue(store.engine.outputView === window.contentView, "attached again")
        XCTAssertFalse(output.resumesOnActivation)

        // Closed by the user: it stays closed after a round trip through the background.
        output.hide()
        post(NSApplication.didResignActiveNotification)
        post(NSApplication.didBecomeActiveNotification)
        XCTAssertFalse(output.isShowing)

        // Its display unplugged while the app was in the background: not shown, and the status says why.
        output.show()
        post(NSApplication.didResignActiveNotification)
        XCTAssertTrue(StoreFixture.spin(until: { !output.isShowing }, timeout: 2))
        screens.screens = [main]
        output.screensChanged()
        store.statusMessage = nil
        post(NSApplication.didBecomeActiveNotification)
        XCTAssertFalse(output.isShowing)
        XCTAssertNil(store.engine.outputView)
        XCTAssertEqual(store.statusMessage, OutputDisplayController.screenGoneMessage)
    }

    /// Finding 3: while the editor window's display is unknown (no editor window yet) the output is
    /// neither available nor shown: any display could be the editor's own. Setting the editor window
    /// re-reads the availability.
    func testTheOutputNeedsToKnowTheEditorsDisplay() throws {
        let screens = FakeScreens([main, external], editor: nil)
        let output = OutputDisplayController(store: store, screens: screens, center: NotificationCenter())
        store.outputDisplay = output
        XCTAssertNil(output.targetScreen, "no fallback to the first display")
        XCTAssertFalse(output.isAvailable)
        output.show()
        XCTAssertFalse(output.isShowing, "refused")
        XCTAssertNil(output.window)
        XCTAssertNil(store.engine.outputView)

        // The editor window appears on the built-in display: the other one is available.
        screens.editorScreen = 1
        XCTAssertFalse(output.isAvailable, "not re-read yet")
        let editor = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        store.editorWindow = editor
        XCTAssertTrue(output.isAvailable, "setting the editor window re-reads the displays")
        XCTAssertEqual(output.targetScreen, external)
        output.show()
        XCTAssertTrue(output.isShowing)
        output.hide()
    }
}
