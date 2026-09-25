import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The pane dividers take their press, drags, double-click and pointer shape in AppKit
/// (`DividerHandleView`), so a divider can be grabbed and dragged while either monitor plays: the
/// user could not grab the one between the source and program monitors while the source played
/// (the monitors re-render at the display rate in the same hosting view). The drag tests go through
/// `NSWindow.sendEvent`, the path real mouse events take to an AppKit view.
@MainActor
final class PaneDividerTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var eventNumber = 0

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    /// Sends a mouse event at `location` (window coordinates) through the window.
    private func send(_ type: NSEvent.EventType, _ location: NSPoint, to window: NSWindow, clickCount: Int = 1) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: eventNumber, clickCount: clickCount, pressure: 1) else {
            XCTFail("no \(type) event")
            return
        }
        window.sendEvent(event)
    }

    // MARK: The handle

    func testTheHandleDragsAlongItsAxisAfterAPointAndDoubleClicks() throws {
        let window = makeWindow(size: NSSize(width: 400, height: 300))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let vertical = DividerHandleView(orientation: .vertical)
        vertical.frame = NSRect(x: 100, y: 0, width: 5, height: 300)
        let horizontal = DividerHandleView(orientation: .horizontal)
        horizontal.frame = NSRect(x: 200, y: 150, width: 200, height: 5)
        container.addSubview(vertical)
        container.addSubview(horizontal)
        window.orderFront(nil) // the window routes mouse events only while it is on screen
        var events: [String] = []
        var shapes: [DividerCursor.Shape] = []
        for handle in [vertical, horizontal] {
            handle.onBegin = { events.append("begin") }
            handle.onDrag = { events.append("drag \($0)") }
            handle.onDoubleClick = { events.append("double") }
            handle.onDragging = { events.append($0 ? "dragging" : "released") }
            handle.cursor.apply = { shapes.append($0) }
        }
        XCTAssertTrue(vertical.acceptsFirstMouse(for: nil), "grabbable in an inactive window")

        // Less than a point of movement is a click, not a drag.
        send(.leftMouseDown, NSPoint(x: 102, y: 150), to: window)
        send(.leftMouseDragged, NSPoint(x: 102.5, y: 150), to: window)
        XCTAssertEqual(events, [])
        XCTAssertFalse(vertical.isDragging)
        // Then the translation along the axis since the press (the other axis ignored).
        send(.leftMouseDragged, NSPoint(x: 110, y: 150), to: window)
        send(.leftMouseDragged, NSPoint(x: 130, y: 170), to: window)
        XCTAssertTrue(vertical.isDragging)
        send(.leftMouseUp, NSPoint(x: 130, y: 170), to: window)
        XCTAssertEqual(events, ["dragging", "begin", "drag 8.0", "drag 28.0", "released"])
        XCTAssertFalse(vertical.isDragging)
        XCTAssertEqual(shapes, [.resizeLeftRight, .arrow], "resize while dragging, the arrow off the divider")

        // A horizontal divider: a drag down (window y decreasing) is positive.
        events = []
        shapes = []
        send(.leftMouseDown, NSPoint(x: 300, y: 152), to: window)
        send(.leftMouseDragged, NSPoint(x: 300, y: 140), to: window)
        send(.leftMouseDragged, NSPoint(x: 310, y: 172), to: window)
        send(.leftMouseUp, NSPoint(x: 310, y: 152), to: window)
        XCTAssertEqual(events, ["dragging", "begin", "drag 12.0", "drag -20.0", "released"])
        XCTAssertEqual(shapes, [.resizeUpDown], "released over the divider: the resize cursor stays")

        // A double-click fits and does not drag.
        events = []
        send(.leftMouseDown, NSPoint(x: 102, y: 100), to: window)
        send(.leftMouseUp, NSPoint(x: 102, y: 100), to: window)
        send(.leftMouseDown, NSPoint(x: 102, y: 100), to: window, clickCount: 2)
        send(.leftMouseDragged, NSPoint(x: 140, y: 100), to: window)
        send(.leftMouseUp, NSPoint(x: 140, y: 100), to: window, clickCount: 2)
        XCTAssertEqual(events, ["double"])

        // AppKit's cursor update sets the resize cursor every time (another view may have reset it),
        // hover only when the shape changes.
        shapes = []
        let update = try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate, location: NSPoint(x: 102, y: 100),
                                                          modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, trackingNumber: 0, userData: nil))
        vertical.cursorUpdate(with: update)
        vertical.cursorUpdate(with: update)
        XCTAssertEqual(shapes, [.resizeLeftRight, .resizeLeftRight])
        // Taken out of the window mid-drag (the source monitor hidden): the drag ends without
        // reporting to its owner (going away too), and the cursor is given back.
        events = []
        send(.leftMouseDown, NSPoint(x: 102, y: 100), to: window)
        send(.leftMouseDragged, NSPoint(x: 120, y: 100), to: window)
        vertical.removeFromSuperview()
        XCTAssertFalse(vertical.isDragging)
        XCTAssertEqual(events, ["dragging", "begin", "drag 18.0"])
        XCTAssertEqual(shapes.last, .arrow)
        send(.leftMouseUp, NSPoint(x: 120, y: 100), to: window)
        XCTAssertEqual(events, ["dragging", "begin", "drag 18.0"], "its release goes nowhere")
    }

    // MARK: In the editor window, while the monitors play

    /// The divider between the source and program monitors, dragged through real window events
    /// while the source monitor plays and then while the program plays: every step moves it by the
    /// pointer's movement (the source monitor's share of the monitor area follows) while the playing
    /// monitor re-renders between the steps, the release ends the drag, and the handle is the same
    /// view throughout (no re-render replaced it).
    func testTheSourceDividerDragsWhileEitherMonitorPlays() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        store.showInSourceMonitor(movie.assetID)
        store.selection = []
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "divider-\(UUID())"))
        let documents = DocumentController(store: store, defaults: defaults)
        let size = NSSize(width: 1400, height: 900)
        let window = makeWindow(size: size)
        let host = NSHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        await StoreFixture.wait(until: { false }, timeout: 0.3)

        func handles() -> [DividerHandleView] {
            var found: [DividerHandleView] = []
            func walk(_ view: NSView) {
                if let handle = view as? DividerHandleView { found.append(handle) }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found.filter { $0.orientation == .vertical }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        let vertical = handles()
        XCTAssertEqual(vertical.count, 3, "bin | source | program | inspector")
        let handle = try XCTUnwrap(vertical.count == 3 ? vertical[1] : nil)
        let sides = ContentView.sideWidths(windowWidth: size.width, binWidth: store.layout.mediaBinWidth,
                                           inspectorWidth: store.layout.inspectorWidth)
        let areaWidth = size.width - sides.bin - sides.inspector - 2 * WindowLayoutModel.dividerThickness

        for playsSource in [true, false] {
            if playsSource {
                store.focusArea = .sourceMonitor
                store.engine.sourceMonitorTogglePlay()
            } else {
                store.focusArea = .timeline
                store.engine.play()
            }
            let playhead = playsSource ? store.sourcePlayhead : store.playhead
            let running = await StoreFixture.wait(until: { playhead.isRunning }, timeout: 10)
            XCTAssertTrue(running, "the \(playsSource ? "source" : "program") plays")
            let startFraction = store.layout.sourceMonitorFraction
            let frame = handle.convert(handle.bounds, to: nil)
            let press = NSPoint(x: frame.midX, y: frame.midY)
            let updatesBefore = playhead.timeUpdates
            send(.leftMouseDown, press, to: window)
            for step in 1 ... 8 {
                // The playing monitor re-renders between the steps.
                await StoreFixture.wait(until: { false }, timeout: 0.05)
                send(.leftMouseDragged, NSPoint(x: press.x + CGFloat(step) * 5, y: press.y), to: window)
                XCTAssertEqual(store.layout.sourceMonitorFraction, startFraction + Double(CGFloat(step) * 5 / areaWidth),
                               accuracy: 1e-9, "step \(step) moves the divider")
            }
            await StoreFixture.wait(until: { false }, timeout: 0.05)
            send(.leftMouseUp, NSPoint(x: press.x + 40, y: press.y), to: window)
            XCTAssertFalse(handle.isDragging, "the release ends the drag")
            XCTAssertGreaterThanOrEqual(playhead.timeUpdates - updatesBefore, 5, "the monitor played during the drag")
            XCTAssertTrue(playhead.isRunning)
            host.layoutSubtreeIfNeeded()
            await StoreFixture.wait(until: { false }, timeout: 0.05)
            let moved = handle.convert(handle.bounds, to: nil)
            XCTAssertEqual(moved.midX - frame.midX, 40, accuracy: 0.5, "the divider followed the pointer")
            XCTAssertTrue(handles().contains { $0 === handle }, "the same handle view")
            if playsSource {
                store.engine.sourceMonitorTogglePlay()
            } else {
                store.engine.pause()
            }
            _ = await StoreFixture.wait(until: { !playhead.isRunning }, timeout: 5)
        }
    }
}
