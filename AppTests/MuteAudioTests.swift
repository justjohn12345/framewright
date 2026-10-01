import AppKit
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Review B2 (general review, 2026-10-01): the transport bar's speaker button kept its own `@State`,
/// read only when it appeared, while Playback > Mute Audio toggled the engine directly: after the menu
/// muted, the button still showed the speaker and its next click "muted" again (nothing happened), and
/// the menu item had no check mark. Both now read and change `ProjectStore.isAudioMuted`, which is the
/// engine's state.
@MainActor
final class MuteAudioTests: XCTestCase {
    func testTheStoreStateIsTheEnginesAndPublishes() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        XCTAssertFalse(store.isAudioMuted)
        var published = 0
        let observation = store.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        store.toggleAudioMuted()
        XCTAssertTrue(store.isAudioMuted)
        XCTAssertTrue(store.engine.isMuted)
        XCTAssertEqual(published, 1, "a change publishes, so the button and the menu redraw")
        store.isAudioMuted = true
        XCTAssertEqual(published, 1, "setting the same state publishes nothing")
        store.isAudioMuted = false
        XCTAssertFalse(store.engine.isMuted)
        XCTAssertEqual(published, 2)
    }

    /// The button in a window: muted from elsewhere (the menu's path), its next click unmutes. (With
    /// the button's own `@State`, still "unmuted", the click "muted" again and nothing happened.)
    func testTheTransportButtonFollowsAMuteFromTheMenu() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TransportBar(store: store))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        // The bar's buttons in order: start, back a frame, J, play, L, forward a frame, end, mute.
        let buttons = Self.buttons(in: host)
        XCTAssertEqual(buttons.count, 8, "the transport bar's buttons")
        let mute = try XCTUnwrap(buttons.last)

        mute.performClick(nil)
        XCTAssertTrue(store.engine.isMuted, "a click mutes")
        mute.performClick(nil)
        XCTAssertFalse(store.engine.isMuted, "the next click unmutes")

        // Playback > Mute Audio (⌥⌘M) mutes through the store; the button's next click unmutes.
        store.isAudioMuted = true
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        mute.performClick(nil)
        XCTAssertFalse(store.engine.isMuted, "the click after a menu mute unmutes")
        XCTAssertFalse(store.isAudioMuted)
    }

    /// The AppKit buttons SwiftUI made for the bar's Buttons, in layout order.
    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton {
                found.append(button)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}
