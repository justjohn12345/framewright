import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The inspector's fields over several clips whose values differ, in a hosted window with the real
/// `InspectorView`: every such row (Motion, Opacity, Colour, Gain) shows an empty field with the grey
/// "Mixed" placeholder, never a value as editable text, also while the field keeps the keyboard focus
/// (Return keeps it) and the values come to differ under it (a new selection, Undo); a typed value sets
/// that parameter on every selected clip in one undo step; an empty or invalid commit changes nothing
/// and leaves the placeholder.
@MainActor
final class MixedValueFieldTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }
    private var window: NSWindow?
    private var host: NSHostingView<InspectorView>?

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("mixedfields")
    }

    override func tearDown() async throws {
        window?.makeFirstResponder(nil)
        window?.orderOut(nil)
        window?.close()
        window = nil
        host = nil
        InspectorModel.burstIdleSeconds = 1.0
        fixture?.cleanUp()
    }

    // MARK: Fixture

    /// Two movie clips on V1 (0 s and 1 s) and two tone clips on A1 (0 s and 1.5 s), none linked.
    private func clips() async throws -> (video: [VEClipID], audio: [VEClipID]) {
        let (movie, tone) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        var sounds: [VEClipID] = []
        for seconds in [0.0, 1.5] {
            XCTAssertTrue(store.place(asset: tone.assetID, at: store.frameTime(seconds), videoTrack: 0, audioTrack: a1,
                                      sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
            sounds.append(try XCTUnwrap(store.selection.first))
        }
        return ([first, second], sounds)
    }

    /// The real inspector in a window.
    private func showInspector() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 1400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InspectorView(store: store))
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        self.host = host
    }

    /// Lets SwiftUI apply the latest model change to the views (suspending frees the main run loop).
    private func settle() async {
        for _ in 0 ..< 2 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            host?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    private func field(_ parameter: InspectorParameter, file: StaticString = #filePath,
                       line: UInt = #line) throws -> NSTextField {
        let host = try XCTUnwrap(host, file: file, line: line)
        return try XCTUnwrap(Self.textField("Parameter.\(parameter.rawValue)", in: host),
                             "the \(parameter.label) field", file: file, line: line)
    }

    private static func textField(_ identifier: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityIdentifier() == identifier { return field }
        for subview in view.subviews {
            if let found = textField(identifier, in: subview) { return found }
        }
        return nil
    }

    /// Types `text` over the field's contents, as the keyboard would (focusing it first).
    private func type(_ text: String, into parameter: InspectorParameter) throws {
        let field = try field(parameter)
        if field.currentEditor() == nil {
            XCTAssertTrue(try XCTUnwrap(window).makeFirstResponder(field))
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field editor")
        editor.selectAll(nil)
        if text.isEmpty {
            editor.deleteBackward(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        XCTAssertEqual(editor.string, text)
    }

    /// Return in the focused field (it keeps the focus, as in the app).
    private func pressReturn(in parameter: InspectorParameter) throws {
        let field = try field(parameter)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field is being edited")
        let coordinator = try XCTUnwrap(field.delegate as? NumericField.Coordinator)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    /// The field shows no value as text and the grey "Mixed" placeholder, in the field and (while
    /// focused) in its editor.
    private func assertShowsMixedPlaceholder(_ parameter: InspectorParameter, _ context: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let field = try field(parameter, file: file, line: line)
        XCTAssertTrue(inspector.isMixed(parameter), "\(parameter.label) differs: \(context)", file: file, line: line)
        XCTAssertEqual(field.stringValue, "", "\(parameter.label) has no value as text: \(context)", file: file, line: line)
        XCTAssertEqual(field.placeholderString, "Mixed", "\(parameter.label) placeholder: \(context)", file: file, line: line)
        if let editor = field.currentEditor() as? NSTextView {
            XCTAssertEqual(editor.string, "", "\(parameter.label)'s editor holds no text: \(context)", file: file, line: line)
        }
    }

    private func value(_ parameter: InspectorParameter, _ clip: VEClipID) throws -> Double {
        inspector.value(parameter, of: try XCTUnwrap(store.clips[clip]))
    }

    // MARK: Tests

    /// Each multi-clip row with differing values shows the empty field with the "Mixed" placeholder:
    /// when the selection is made, and when it changes while the row's field keeps the focus after a
    /// value was typed on one clip (it used to keep that value as editable text).
    func testDifferingValuesShowThePlaceholderInEveryMultiClipRow() async throws {
        let (video, audio) = try await clips()
        showInspector()
        let rows: [(parameter: InspectorParameter, clips: [VEClipID], typed: String, shown: String)] = [
            (.positionX, video, "40", "40 px"),
            (.opacity, video, "50", "50 %"),
            (.exposure, video, "1.5", "1.5 stops"),
            (.saturation, video, "0.5", "0.5 ×"),
            (.gain, audio, "-6", "-6 dB"),
        ]
        for row in rows {
            // One clip: type a value and press Return; the field keeps the focus, showing the value.
            store.selection = [row.clips[0]]
            await settle()
            try type(row.typed, into: row.parameter)
            try pressReturn(in: row.parameter)
            await settle()
            XCTAssertEqual(try field(row.parameter).stringValue, row.shown, "\(row.parameter.label) on one clip")
            XCTAssertNotNil(try field(row.parameter).currentEditor(), "Return keeps the focus")

            // Both clips selected while the field has the focus: their values differ.
            store.selection = Set(row.clips)
            await settle()
            XCTAssertNotNil(try field(row.parameter).currentEditor(), "still focused")
            try assertShowsMixedPlaceholder(row.parameter, "selection changed under the focus")

            // Unfocused, the same.
            XCTAssertTrue(try XCTUnwrap(window).makeFirstResponder(nil))
            await settle()
            try assertShowsMixedPlaceholder(row.parameter, "after the focus left")
        }
        // The rows whose values agree show them.
        store.selection = Set(video)
        await settle()
        XCTAssertEqual(try field(.scale).stringValue, "100 %")
        XCTAssertEqual(try field(.scale).placeholderString, "")
        XCTAssertEqual(try field(.contrast).stringValue, "1 ×")
    }

    /// A value typed into a mixed field sets that parameter on every selected clip in one undo step;
    /// one Undo brings back the clips' own values and the focused field's placeholder.
    func testTypingIntoTheMixedFieldSetsEveryClipInOneUndoStep() async throws {
        let (video, audio) = try await clips()
        store.selection = [video[0]]
        inspector.setValue(.exposure, 1.5)
        inspector.setValue(.positionX, 25)
        store.selection = [audio[0]]
        inspector.setValue(.gain, -3)
        showInspector()

        let rows: [(parameter: InspectorParameter, clips: [VEClipID], typed: String, shown: String,
                    value: Double, original: [Double])] = [
            (.exposure, video, "0.5 stops", "0.5 stops", 0.5, [1.5, 0]),
            (.positionX, video, "-12", "-12 px", -12, [25, 0]),
            (.gain, audio, "2 dB", "2 dB", 2, [-3, 0]),
        ]
        for row in rows {
            store.selection = Set(row.clips)
            await settle()
            try assertShowsMixedPlaceholder(row.parameter, "before typing")
            let before = store.changeCount
            try type(row.typed, into: row.parameter)
            try pressReturn(in: row.parameter)
            await settle()
            for clip in row.clips {
                XCTAssertEqual(try value(row.parameter, clip), row.value, accuracy: 1e-9, "\(row.parameter.label) on every clip")
            }
            XCTAssertEqual(store.changeCount, before + 1, "one undo step")
            XCTAssertEqual(try field(row.parameter).stringValue, row.shown)
            XCTAssertNotNil(try field(row.parameter).currentEditor(), "Return keeps the focus")

            // One Undo (the Edit menu: the field editor has nothing of its own to undo).
            store.undo()
            await settle()
            for (clip, original) in zip(row.clips, row.original) {
                XCTAssertEqual(try value(row.parameter, clip), original, accuracy: 1e-9, "one Undo restores each clip")
            }
            try assertShowsMixedPlaceholder(row.parameter, "after Undo, still focused")
            XCTAssertTrue(try XCTUnwrap(window).makeFirstResponder(nil))
        }
    }

    /// An empty commit (Return with nothing typed, or with the typed text deleted, or leaving the field)
    /// and an invalid one change nothing and leave the placeholder, also when the values came to differ
    /// under the focused field.
    func testAnEmptyOrInvalidCommitChangesNothingAndKeepsThePlaceholder() async throws {
        let (video, _) = try await clips()
        showInspector()
        store.selection = [video[0]]
        await settle()
        try type("2", into: .exposure)
        try pressReturn(in: .exposure)
        await settle()
        store.selection = Set(video)
        await settle()
        let before = store.changeCount
        let originals = try video.map { try value(.exposure, $0) }
        XCTAssertEqual(originals, [2, 0])
        // The focused field is empty with its placeholder: Return now commits an empty field.
        XCTAssertNotNil(try field(.exposure).currentEditor(), "Return kept the focus")
        try assertShowsMixedPlaceholder(.exposure, "focused, before the empty Return")

        // Return with nothing typed.
        try pressReturn(in: .exposure)
        await settle()
        try assertShowsMixedPlaceholder(.exposure, "after an empty Return")

        // Text typed, then deleted, then Return.
        try type("3", into: .exposure)
        try type("", into: .exposure)
        try pressReturn(in: .exposure)
        await settle()
        try assertShowsMixedPlaceholder(.exposure, "after deleting the typed text")

        // Invalid text: refused with a message, the placeholder back.
        try type("bright", into: .exposure)
        try pressReturn(in: .exposure)
        await settle()
        XCTAssertNotNil(inspector.message)
        try assertShowsMixedPlaceholder(.exposure, "after invalid text")

        // Leaving the field with nothing typed.
        XCTAssertTrue(try XCTUnwrap(window).makeFirstResponder(nil))
        await settle()
        try assertShowsMixedPlaceholder(.exposure, "after leaving the field")

        XCTAssertEqual(store.changeCount, before, "nothing changed")
        XCTAssertEqual(try video.map { try value(.exposure, $0) }, originals)
    }
}
