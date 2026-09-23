import AppKit
import FramewrightEngine
import XCTest
@testable import Framewright

/// The program monitor on a second display (open finding 7), over an injected screen list: the
/// menu item's availability, the output window covering the other display with a preview view
/// the engine drives, Escape, and a display that goes away. Whether the picture really reaches a
/// physical second display can only be checked by hand.
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
}
