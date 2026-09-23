import AppKit
import XCTest
@testable import Framewright

/// Pointer handling outside the timeline (UX round review, findings 6 and 8): the pane dividers'
/// cursor (set with change detection, never pushed, reset when a drag ends outside the divider)
/// and the right-click catcher's event monitor (filtered on the button and Control before any
/// coordinate work, installed exactly while the view is in a window).
@MainActor
final class PointerHandlingTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    // MARK: Divider cursor (finding 6)

    func testTheDividerSetsItsCursorOnlyWhenTheShapeChanges() {
        let cursor = DividerCursor(orientation: .vertical)
        var applied: [DividerCursor.Shape] = []
        cursor.apply = { applied.append($0) }
        XCTAssertEqual(cursor.resize, .resizeLeftRight)
        XCTAssertEqual(DividerCursor(orientation: .horizontal).resize, .resizeUpDown)

        cursor.hover(inside: true)
        cursor.hover(inside: true) // hover fires on every pointer event
        XCTAssertEqual(applied, [.resizeLeftRight], "set once")
        cursor.hover(inside: false)
        XCTAssertEqual(applied, [.resizeLeftRight, .arrow], "the arrow when the pointer leaves")
        XCTAssertNil(cursor.current, "given back: the next hover sets it again")
        cursor.hover(inside: false)
        XCTAssertEqual(applied.count, 2, "leaving again changes nothing (another view may own the cursor)")
        cursor.hover(inside: true)
        XCTAssertEqual(applied.last, .resizeLeftRight)
        XCTAssertEqual(cursor.changes, 3)
    }

    func testADragEndingOutsideTheDividerRestoresTheArrow() {
        let cursor = DividerCursor(orientation: .horizontal)
        var applied: [DividerCursor.Shape] = []
        cursor.apply = { applied.append($0) }
        cursor.frame = CGRect(x: 0, y: 400, width: 1000, height: 5)

        // The pointer leaves the divider during the drag (a pane at its size limit stops following
        // it): the resize cursor stays for the drag.
        cursor.hover(inside: true)
        cursor.dragChanged()
        cursor.dragChanged()
        XCTAssertTrue(cursor.isDragging)
        cursor.hover(inside: false)
        XCTAssertEqual(applied, [.resizeUpDown], "kept while dragging")
        // It ends outside: the arrow, without waiting for the next hover cycle.
        cursor.dragEnded(at: CGPoint(x: 500, y: 300))
        XCTAssertFalse(cursor.isDragging)
        XCTAssertEqual(applied, [.resizeUpDown, .arrow])
        XCTAssertNil(cursor.current)

        // A drag ending on the divider keeps the resize cursor (no change).
        cursor.hover(inside: true)
        cursor.dragChanged()
        cursor.dragEnded(at: CGPoint(x: 500, y: 402))
        XCTAssertEqual(applied, [.resizeUpDown, .arrow, .resizeUpDown])
        XCTAssertEqual(cursor.current, .resizeUpDown)

        // The divider goes away (the source monitor hidden) while the pointer is over it.
        cursor.disappeared()
        XCTAssertEqual(applied.last, .arrow)
        XCTAssertNil(cursor.current)
    }

    // MARK: Context menu catcher (finding 8)

    func testTheContextMenuMonitorIsInstalledExactlyWhileTheViewIsInAWindow() throws {
        let view = ContextMenuCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse(view.isMonitoring, "no window: no monitor")
        let window = makeWindow()
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(view)
        XCTAssertTrue(view.isMonitoring, "installed once in a window")
        let other = makeWindow()
        try XCTUnwrap(other.contentView).addSubview(view) // moved to another window
        XCTAssertTrue(view.isMonitoring, "still installed (one monitor)")
        view.removeFromSuperview()
        XCTAssertFalse(view.isMonitoring, "removed with the window")
        content.addSubview(view)
        XCTAssertTrue(view.isMonitoring, "installed again")
        view.removeMonitor() // dismantleNSView
        XCTAssertFalse(view.isMonitoring)
        view.removeFromSuperview()
    }

    func testOnlyContextClicksInsideTheViewAskForAMenu() throws {
        let window = makeWindow()
        let view = ContextMenuCatcher.CatcherView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
        try XCTUnwrap(window.contentView).addSubview(view)
        var asked: [CGPoint] = []
        var items: [ContextMenuItem] = [ContextMenuItem(title: "Delete", action: {})]
        var shown: [NSMenu] = []
        view.itemsAt = { point in
            asked.append(point)
            return items
        }
        view.popUp = { menu, _, _ in shown.append(menu) }
        func press(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, modifiers: NSEvent.ModifierFlags = [],
                   in target: NSWindow? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
                                             timestamp: 0, windowNumber: (target ?? window).windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }

        XCTAssertTrue(ContextMenuCatcher.CatcherView.isContextClick(type: .rightMouseDown, modifierFlags: []))
        XCTAssertTrue(ContextMenuCatcher.CatcherView.isContextClick(type: .leftMouseDown, modifierFlags: .control))
        XCTAssertFalse(ContextMenuCatcher.CatcherView.isContextClick(type: .leftMouseDown, modifierFlags: [.command]))

        // A plain left click inside the view passes on without asking for items.
        let plain = try press(.leftMouseDown, x: 100, y: 100)
        XCTAssertTrue(view.handle(plain, window: window) === plain)
        XCTAssertTrue(asked.isEmpty, "no hit testing for an ordinary click")
        // A right click and a Control-click inside: the menu, and the press is consumed.
        XCTAssertNil(view.handle(try press(.rightMouseDown, x: 100, y: 100), window: window))
        XCTAssertNil(view.handle(try press(.leftMouseDown, x: 60, y: 140, modifiers: .control), window: window))
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown.first?.items.first?.title, "Delete")
        // The point is in the view's flipped coordinates (origin top-left).
        XCTAssertEqual(asked[0], CGPoint(x: 50, y: 50))
        XCTAssertEqual(asked[1], CGPoint(x: 10, y: 10))
        // Outside the view, from another window, or with no items: passed on, no menu.
        let outside = try press(.rightMouseDown, x: 10, y: 10)
        XCTAssertTrue(view.handle(outside, window: window) === outside)
        let other = makeWindow()
        let elsewhere = try press(.rightMouseDown, x: 100, y: 100, in: other)
        XCTAssertTrue(view.handle(elsewhere, window: other) === elsewhere)
        XCTAssertEqual(asked.count, 2)
        items = []
        let empty = try press(.rightMouseDown, x: 100, y: 100)
        XCTAssertTrue(view.handle(empty, window: window) === empty)
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(shown.count, 2, "no items, no menu")
        view.removeFromSuperview()
    }
}
