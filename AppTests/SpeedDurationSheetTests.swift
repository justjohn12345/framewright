import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Review B1 (general review, 2026-10-01): the Speed/Duration sheet lost what the user typed. Its model
/// was built inside ContentView's sheet closure and held as `@ObservedObject`, so any store change
/// (the refusal's own status line included) redrew the window, built a new model and replaced it: the
/// typed speed went back to the clip's and the refusal's reason disappeared. The store now keeps the
/// sheet's model (`ProjectStore.speedSheetModel`), as it does the Export and Sequence Settings sheets'.
@MainActor
final class SpeedDurationSheetTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// Two clips back to back on V1, the first selected.
    private func placeTwoClips() async throws -> (first: VEClipID, second: VEClipID) {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 2)
        store.selection = [a]
        return (a, b)
    }

    /// The model level: the sheet's model is the store's, created once when the sheet opens; a refused
    /// Apply followed by store changes keeps its text and its message, and the sheet stays open.
    func testARefusalFollowedByAStorePublishKeepsTheTypedSpeedAndTheReason() async throws {
        let (a, _) = try await placeTwoClips()
        store.showSpeedSheet()
        let sheet = try XCTUnwrap(store.speedSheetModel, "the sheet opens with the store's model")
        XCTAssertEqual(store.speedSheetClipIDs, [a])
        sheet.text = "50"
        sheet.ripple = .none
        XCTAssertFalse(sheet.apply(), "slowing the first clip into the second without ripple is refused")
        let reason = try XCTUnwrap(sheet.message)
        // The refusal's status line is a store publish; so is any other change while the sheet is open.
        store.statusMessage = "Something else changed."
        store.objectWillChange.send()
        XCTAssertTrue(store.speedSheetModel === sheet, "the same model after the store published")
        XCTAssertEqual(sheet.text, "50")
        XCTAssertEqual(sheet.ripple, SpeedRipple.none)
        XCTAssertEqual(sheet.message, reason)
        // The sheet is still open; a good Apply closes it.
        sheet.ripple = .syncedTracks
        XCTAssertTrue(sheet.apply(), sheet.message ?? "")
        XCTAssertNil(store.speedSheetModel)
        XCTAssertEqual(store.frames(store.clips[a]?.duration ?? .zero), 120)
        // Opening the sheet again makes a fresh model with the clip's new speed.
        store.showSpeedSheet()
        let again = try XCTUnwrap(store.speedSheetModel)
        XCTAssertFalse(again === sheet)
        XCTAssertEqual(again.text, "50")
        XCTAssertNil(again.message)
        again.cancel()
        XCTAssertNil(store.speedSheetModel)
    }

    /// The window level, as the user meets it: the sheet presented by ContentView, a speed typed into its
    /// field and refused, then a store change that redraws the window. The field must still show what
    /// was typed (a new model would show the clip's speed again) and the reason must still be there.
    func testTheSheetInTheWindowKeepsTheTypedTextAcrossARedraw() async throws {
        _ = try await placeTwoClips()
        let defaults = try makeTestDefaults("speed-sheet")
        let documents = DocumentController(store: store, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        store.showSpeedSheet()
        await StoreFixture.wait(until: { window.attachedSheet != nil }, timeout: 5)
        let sheetWindow = try XCTUnwrap(window.attachedSheet, "ContentView presents the sheet")
        var field: NSTextField?
        await StoreFixture.wait(until: {
            field = Self.editableField(in: sheetWindow.contentView)
            return field?.stringValue == "100"
        }, timeout: 5)
        let speedField = try XCTUnwrap(field, "the sheet's speed field")
        XCTAssertEqual(speedField.stringValue, "100", "the clip's own speed")

        // Type a speed that is not one and press Return (the field's submit applies): refused.
        XCTAssertTrue(sheetWindow.makeFirstResponder(speedField))
        let editor = try XCTUnwrap(speedField.currentEditor() as? NSTextView, "the field editor")
        editor.selectAll(nil)
        editor.insertText("fast", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        // The refusal (the model's message; the sheet's Label is not an AppKit view to read back).
        let refused = await StoreFixture.wait(until: { self.store.speedSheetModel?.message != nil }, timeout: 5)
        XCTAssertTrue(refused, "Return applied and was refused")
        let reason = store.speedSheetModel?.message

        // A store change redraws the window.
        store.statusMessage = "Something else changed."
        await StoreFixture.wait(until: { false }, timeout: 0.5)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.attachedSheet === sheetWindow, "the sheet is still open")
        let after = try XCTUnwrap(Self.editableField(in: sheetWindow.contentView))
        XCTAssertEqual(after.stringValue, "fast", "the typed text survives the redraw")
        XCTAssertEqual(store.speedSheetModel?.message, reason, "the reason survives the redraw")
    }

    /// The first editable text field under `view` (the sheet has one: the speed).
    private static func editableField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }
}
