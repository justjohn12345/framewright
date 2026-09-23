import AppKit
import SwiftUI
import XCTest
@testable import VidEdit

/// `NumericField`'s AppKit behaviour in a hosted window (review 2026-09-23, phase 6, test gap 2):
/// typed text commits on Return and when the field loses focus, Escape reverts, Up/Down and
/// Shift+Up/Down nudge by 1 and 10, and text typed before a nudge is committed first.
@MainActor
final class NumericFieldTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    /// What the field reported, in order ("commit 42", "nudge 10.0").
    private final class Recorder {
        var events: [String] = []
    }

    private struct Hosted {
        let window: NSWindow
        let field: NSTextField
        let coordinator: NumericField.Coordinator
    }

    private func host(text: String, recorder: Recorder) throws -> Hosted {
        let view = NumericField(text: text, placeholder: "", commit: { recorder.events.append("commit \($0)") },
                                nudge: { recorder.events.append("nudge \($0)") }, accessibilityIdentifier: "Value")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let hosting = NSHostingView(rootView: view.frame(width: 120, height: 22))
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let field = try XCTUnwrap(Self.textField(in: hosting), "the representable's NSTextField")
        let coordinator = try XCTUnwrap(field.delegate as? NumericField.Coordinator)
        return Hosted(window: window, field: field, coordinator: coordinator)
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    /// Focuses the field and types `text` over its contents, as the keyboard would.
    private func type(_ text: String, into hosted: Hosted) throws -> NSTextView {
        XCTAssertTrue(hosted.window.makeFirstResponder(hosted.field))
        let editor = try XCTUnwrap(hosted.field.currentEditor() as? NSTextView, "the field editor")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, text)
        return editor
    }

    private func command(_ selector: Selector, _ hosted: Hosted, _ editor: NSTextView) -> Bool {
        hosted.coordinator.control(hosted.field, textView: editor, doCommandBy: selector)
    }

    func testTypedTextCommitsOnReturnAndOnFocusLoss() throws {
        let recorder = Recorder()
        let hosted = try host(text: "5", recorder: recorder)
        XCTAssertEqual(hosted.field.stringValue, "5")

        var editor = try type("42", into: hosted)
        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:)), hosted, editor))
        XCTAssertEqual(recorder.events, ["commit 42"])
        XCTAssertEqual(editor.string, "5", "the field shows the model's value again")

        // Leaving the field (Tab or a click elsewhere) commits what was typed.
        editor = try type("17", into: hosted)
        XCTAssertTrue(hosted.window.makeFirstResponder(nil))
        XCTAssertEqual(recorder.events, ["commit 42", "commit 17"])
        XCTAssertEqual(hosted.field.stringValue, "5")

        // Focus in and out without typing: nothing is committed.
        XCTAssertTrue(hosted.window.makeFirstResponder(hosted.field))
        XCTAssertTrue(hosted.window.makeFirstResponder(nil))
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testEscapeRevertsWithoutCommitting() throws {
        let recorder = Recorder()
        let hosted = try host(text: "5", recorder: recorder)
        let editor = try type("99", into: hosted)
        XCTAssertTrue(command(#selector(NSResponder.cancelOperation(_:)), hosted, editor))
        XCTAssertEqual(editor.string, "5")
        XCTAssertTrue(hosted.window.makeFirstResponder(nil))
        XCTAssertEqual(recorder.events, [], "the reverted text is not committed on focus loss")
    }

    func testArrowsNudgeAndCommitPendingTextFirst() throws {
        let recorder = Recorder()
        let hosted = try host(text: "5", recorder: recorder)
        XCTAssertTrue(hosted.window.makeFirstResponder(hosted.field))
        var editor = try XCTUnwrap(hosted.field.currentEditor() as? NSTextView)
        XCTAssertTrue(command(#selector(NSResponder.moveUp(_:)), hosted, editor))
        XCTAssertTrue(command(#selector(NSResponder.moveDown(_:)), hosted, editor))
        XCTAssertTrue(command(#selector(NSResponder.moveUpAndModifySelection(_:)), hosted, editor))
        XCTAssertTrue(command(#selector(NSResponder.moveDownAndModifySelection(_:)), hosted, editor))
        XCTAssertEqual(recorder.events, ["nudge 1.0", "nudge -1.0", "nudge 10.0", "nudge -10.0"])

        // Typed, then nudged: the typed value is committed first, then nudged from.
        recorder.events = []
        editor = try type("7", into: hosted)
        XCTAssertTrue(command(#selector(NSResponder.moveUp(_:)), hosted, editor))
        XCTAssertEqual(recorder.events, ["commit 7", "nudge 1.0"])
        XCTAssertTrue(hosted.window.makeFirstResponder(nil))
        XCTAssertEqual(recorder.events, ["commit 7", "nudge 1.0"], "nothing left to commit on focus loss")

        // Other commands are left to AppKit.
        XCTAssertFalse(command(#selector(NSResponder.moveLeft(_:)), hosted, editor))
    }
}
