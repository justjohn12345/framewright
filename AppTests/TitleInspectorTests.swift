import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The inspector's title and colour matte sections (titles design sections 9 and 10; slice 1): what shows for which
/// selection (no Colour rows for titles), "Mixed" and multi-selection edits that keep what differs, units in
/// sequence pixels, one undo step per edit, a slider drag or a colour burst, the typing run as one undo step that
/// does not block other commands and ends with the selection, the text disabled with several titles, and the text
/// area's focus request and lack of its own undo.
@MainActor
final class TitleInspectorTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var model: TitleInspectorModel { store.titleInspector }

    override func setUp() async throws {
        fixture = try StoreFixture()
        InspectorModel.burstIdleSeconds = 60 // bursts end by the tests' own calls
    }

    override func tearDown() async throws {
        InspectorModel.burstIdleSeconds = 1.0
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// The movie on V1 at 0 (a 1920x1080 sequence) and two titles above it, at 0 and 1 s; returns (movie, a, b).
    private func titles() async throws -> (movie: VEClipID, a: VEClipID, b: VEClipID) {
        try fixture.configureSequence()
        let media = try await fixture.importMedia()
        let movie = try fixture.placeMovie(media.movie, at: 0)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.title))
        let a = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(30)
        store.targetVideoTrackID = store.videoTracks[1].trackID
        XCTAssertTrue(store.addGenerated(.title))
        let b = try XCTUnwrap(store.selection.first)
        return (movie, a, b)
    }

    func testWhatShowsForWhichSelection() async throws {
        let (movie, a, _) = try await titles()
        store.selection = [a]
        XCTAssertTrue(model.showsTitleSections)
        XCTAssertFalse(model.showsMatteSection)
        XCTAssertFalse(store.inspector.isAvailable(.exposure), "titles are not graded: no Colour rows")
        XCTAssertTrue(store.inspector.isAvailable(.positionX), "the shared Video rows")
        XCTAssertNil(store.inspector.speedTarget, "a title is a still: no speed")
        store.selection = [a, movie]
        XCTAssertFalse(model.showsTitleSections, "a title with another picture: only the shared rows")
        XCTAssertTrue(store.inspector.isAvailable(.exposure), "the footage's Colour rows")
        XCTAssertEqual(store.inspector.gradeTargets.map(\.clipID), [movie])
        store.playheadTime = frames(120)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let matte = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(model.showsMatteSection)
        XCTAssertFalse(model.showsTitleSections)
        XCTAssertFalse(store.inspector.isAvailable(.exposure))
        store.selection = [a, matte]
        XCTAssertFalse(model.showsMatteSection)
        XCTAssertFalse(model.showsTitleSections)
    }

    func testSeveralTitlesShowMixedAndKeepWhatDiffers() async throws {
        let (_, a, b) = try await titles()
        store.selection = [a]
        model.textChanged("First")
        model.endTyping()
        model.setNumber(.size, 108) // px of a 1080-line frame: 0.1
        XCTAssertEqual(store.clips[a]?.title?.size ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertEqual(store.undoActionName, "Change Size")
        store.selection = [a, b]
        XCTAssertTrue(model.isMixed(.size))
        XCTAssertEqual(model.text(.size), "", "the field shows Mixed")
        XCTAssertFalse(model.isMixed(.fillColour))
        XCTAssertFalse(model.canEditText, "several titles: the text is disabled")
        XCTAssertEqual(model.text, "")
        let changes = store.changeCount
        model.textChanged("Both")
        XCTAssertEqual(store.changeCount, changes, "no text set on several titles")
        // One control sets one parameter on both, keeping their texts.
        model.commit(.size, "54 px")
        XCTAssertEqual(store.clips[a]?.title?.size ?? 0, 0.05, accuracy: 1e-12)
        XCTAssertEqual(store.clips[b]?.title?.size ?? 0, 0.05, accuracy: 1e-12)
        XCTAssertEqual(store.clips[a]?.title?.text, "First")
        XCTAssertEqual(store.clips[b]?.title?.text, "Title")
        XCTAssertFalse(model.isMixed(.size))
        XCTAssertEqual(model.text(.size), "54 px")
        // Typed values are clamped to the range, and nonsense is refused with a message.
        model.commit(.shadowOpacity, "250 %")
        XCTAssertEqual(store.clips[b]?.title?.shadowOpacity, 1)
        model.commit(.shadowAngle, "north")
        XCTAssertEqual(model.message, "“north” is not a valid shadow angle in °.")
        model.setAlignment(.right)
        XCTAssertEqual(model.alignment, .right)
        model.setToggle(.box, true)
        XCTAssertEqual(model.toggle(.box), true)
        XCTAssertEqual(store.clips[b]?.title?.box, true)
        model.setFont(VETitleFont.named("Helvetica-Bold", family: "Helvetica", style: "Bold"))
        XCTAssertEqual(model.font?.postScriptName, "Helvetica-Bold")
        XCTAssertEqual(store.undoActionName, "Change Font")
    }

    func testUnitsAreSequencePixelsPercentAndDegrees() async throws {
        let (_, a, _) = try await titles()
        store.selection = [a]
        XCTAssertEqual(model.text(.size), "64.8 px")
        XCTAssertEqual(model.text(.shadowOpacity), "50 %")
        XCTAssertEqual(model.text(.shadowAngle), "135°")
        XCTAssertEqual(model.text(.lineSpacing), "1 ×")
        XCTAssertEqual(model.text(.tracking), "0")
        XCTAssertEqual(model.text(.positionX), "960 px")
        XCTAssertEqual(model.text(.boxWidth), "1536 px")
        XCTAssertEqual(model.range(.size), 5.4 ... 1080)
        XCTAssertEqual(TitleInspectorModel.parse(.size, "70px"), 70)
        XCTAssertEqual(TitleInspectorModel.parse(.size, " 70.5 "), 70.5)
        XCTAssertNil(TitleInspectorModel.parse(.size, "big"))
    }

    func testTheTypingRunIsOneUndoStepAndBlocksNothing() async throws {
        let (movie, a, _) = try await titles()
        store.selection = [a]
        for text in ["H", "He", "Hel", "Hell", "Hello"] {
            model.textChanged(text)
            XCTAssertEqual(store.clips[a]?.title?.text, text)
        }
        XCTAssertNotNil(store.titleTypingGroup)
        XCTAssertFalse(store.isGestureActive, "typing does not hold up the menus")
        XCTAssertEqual(store.clips[a]?.name, "Hello")
        // Undo during the run takes the whole run back.
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.text, "Title")
        XCTAssertEqual(store.undoActionName, "Add Title")
        store.redo()
        XCTAssertEqual(store.clips[a]?.title?.text, "Hello")
        // Another edit ends the run; the next keystroke starts a new one.
        model.textChanged("Hello,")
        XCTAssertTrue(store.engine.setTrack(store.videoTracks[0].trackID, locked: true).ok)
        model.textChanged("Hello, world")
        XCTAssertEqual(store.clips[a]?.title?.text, "Hello, world")
        model.endTyping()
        XCTAssertNil(store.titleTypingGroup)
        XCTAssertEqual(store.undoActionName, "Edit Title Text")
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.text, "Hello,", "the run after the other edit is its own step")
        // A selection change ends the run.
        model.textChanged("Bye")
        store.selection = [movie]
        XCTAssertNil(store.titleTypingGroup)
        XCTAssertNil(store.engine.coalescingKey)
        XCTAssertEqual(store.undoActionName, "Edit Title Text")
    }

    func testDragsAndColourBurstsAreOneUndoStepEach() async throws {
        let (_, a, b) = try await titles()
        store.selection = [a, b]
        model.beginSliderDrag(.outlineWidth)
        XCTAssertTrue(store.isGestureActive, "a slider drag is a gesture")
        for px in [2.0, 4.0, 6.0] {
            model.sliderChanged(.outlineWidth, px)
        }
        model.endSliderDrag()
        XCTAssertEqual(store.clips[b]?.title?.outlineWidth ?? 0, 6.0 / 1080, accuracy: 1e-12)
        XCTAssertEqual(store.undoActionName, "Change Outline Width")
        store.undo()
        XCTAssertEqual(store.clips[b]?.title?.outlineWidth ?? 0, 0.003, accuracy: 1e-12, "one undo for the drag")
        // The colour panel sends a colour per pointer movement: one undo step.
        let undoName = store.undoActionName
        model.setColour(.fillColour, VEColour(red: 1, green: 0, blue: 0))
        model.setColour(.fillColour, VEColour(red: 0.9, green: 0.1, blue: 0))
        model.setColour(.fillColour, VEColour(red: 0.8, green: 0.2, blue: 0))
        XCTAssertFalse(store.isGestureActive, "a colour burst does not hold up the menus")
        model.endBurst()
        XCTAssertEqual(store.clips[a]?.title?.fillColour.green ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(store.undoActionName, "Change Fill Colour")
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.fillColour.green, 1, "back to white in one step")
        XCTAssertEqual(store.undoActionName, undoName)
        // Nudges: a burst is one step.
        model.nudge(.tracking, steps: 1)
        model.nudge(.tracking, steps: 10)
        model.endBurst()
        XCTAssertEqual(store.clips[a]?.title?.tracking, 11)
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.tracking, 0)
        // A section's reset is one step.
        model.setToggle(.shadow, false)
        model.setNumber(.shadowAngle, 45)
        model.reset([.shadow, .shadowColour, .shadowOpacity, .shadowAngle, .shadowDistance, .shadowBlur])
        XCTAssertEqual(store.clips[a]?.title?.shadow, true)
        XCTAssertEqual(store.clips[b]?.title?.shadowAngle, 135)
        store.undo()
        XCTAssertEqual(store.clips[b]?.title?.shadowAngle, 45, "one undo for the reset")
        XCTAssertEqual(store.clips[b]?.title?.shadow, false)
    }

    func testANudgeMovesEachTitleFromItsOwnValue() async throws {
        let (_, a, b) = try await titles()
        store.selection = [a]
        model.setNumber(.tracking, 10)
        store.selection = [b]
        model.setNumber(.tracking, 50)
        store.selection = [a, b]
        XCTAssertTrue(model.isMixed(.tracking))
        model.nudge(.tracking, steps: 1)
        model.nudge(.tracking, steps: 10)
        model.endBurst()
        XCTAssertEqual(store.clips[a]?.title?.tracking, 21)
        XCTAssertEqual(store.clips[b]?.title?.tracking, 61, "still different")
        XCTAssertEqual(store.undoActionName, "Change Tracking")
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.tracking, 10, "one undo for the burst")
        XCTAssertEqual(store.clips[b]?.title?.tracking, 50)
        // At the range's end each stops there.
        model.nudge(.tracking, steps: 1000)
        model.endBurst()
        XCTAssertEqual(store.clips[a]?.title?.tracking, 1000)
        XCTAssertEqual(store.clips[b]?.title?.tracking, 1000)
    }

    /// Slice 2: point text and the vertical anchor, "Mixed" where the titles differ, one undo step each, keeping the
    /// text where it is; the Text section's Reset turns them back before centring the text.
    func testPointTextAndTheAnchorKeepTheTextInPlace() async throws {
        let (_, a, b) = try await titles()
        store.selection = [a, b]
        XCTAssertEqual(model.pointText, false)
        XCTAssertEqual(model.anchor, .centre)
        store.selection = [a]
        model.setAlignment(.left)
        let before = store.engine.titleBlock(ofClip: a)
        model.setPointText(true)
        XCTAssertEqual(store.undoActionName, "Change Point Text")
        XCTAssertEqual(model.pointText, true)
        let point = store.engine.titleBlock(ofClip: a)
        XCTAssertEqual(point.minX, before.minX, accuracy: 1e-6, "its left edge stays")
        XCTAssertLessThan(point.width, before.width)
        model.setAnchor(.bottom)
        XCTAssertEqual(store.undoActionName, "Change Vertical Anchor")
        XCTAssertEqual(store.engine.titleBlock(ofClip: a).maxY, point.maxY, accuracy: 1e-6)
        store.selection = [a, b]
        XCTAssertNil(model.pointText, "they differ: Mixed")
        XCTAssertNil(model.anchor)
        XCTAssertTrue(model.isMixed(.pointText))
        // Reset: area text anchored at its centre, centred on the frame, one step.
        store.selection = [a]
        model.reset([.alignment, .pointText, .anchor, .lineSpacing, .tracking, .positionX, .positionY, .boxWidth])
        let reset = try XCTUnwrap(store.clips[a]?.title)
        XCTAssertFalse(reset.pointText)
        XCTAssertEqual(reset.anchor, .centre)
        XCTAssertEqual(reset.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(reset.y, 0.5, accuracy: 1e-12)
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.anchor, .bottom, "the reset was one step")
    }

    func testAMatteColourIsSetAsOneStep() async throws {
        _ = try await titles()
        store.playheadTime = frames(150)
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let first = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(400)
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let second = try XCTUnwrap(store.selection.first)
        store.selection = [first]
        model.setMatteColour(VEColour(red: 0.1, green: 0.2, blue: 0.3))
        model.setMatteColour(VEColour(red: 0.2, green: 0.3, blue: 0.4))
        model.endBurst()
        XCTAssertEqual(store.clips[first]?.matteColour.blue ?? 0, 0.4, accuracy: 1e-12)
        XCTAssertEqual(store.undoActionName, "Change Matte Colour")
        store.selection = [first, second]
        XCTAssertTrue(model.isMatteColourMixed)
        store.undo()
        XCTAssertFalse(model.isMatteColourMixed)
    }

    func testTheTextAreaTakesTheFocusAndHasNoUndoOfItsOwn() async throws {
        let (_, a, _) = try await titles()
        XCTAssertNil(TitleTextView().undoManager, "⌘Z goes to the engine")
        store.selection = []
        let hosted = HostedView(InspectorView(store: store), size: NSSize(width: 320, height: 1400))
        defer { hosted.close() }
        await hosted.settle()
        store.selection = [a]
        store.requestInspectorFocus(.titleText)
        await hosted.settle()
        let textView = try XCTUnwrap(hosted.window.firstResponder as? TitleTextView, "the caret is in the text")
        XCTAssertEqual(textView.string, "Title")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5), "all of it selected")
        XCTAssertFalse(KeyboardController.shouldHandleKeys(firstResponder: textView))
        // Typing replaces the placeholder: each change is a step of the run.
        textView.insertText("New", replacementRange: textView.selectedRange())
        XCTAssertEqual(store.clips[a]?.title?.text, "New")
        textView.insertText(" title", replacementRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(store.clips[a]?.title?.text, "New title")
        hosted.window.makeFirstResponder(nil)
        XCTAssertNil(store.titleTypingGroup, "leaving the text ends the run")
        store.undo()
        XCTAssertEqual(store.clips[a]?.title?.text, "Title")
        await hosted.settle()
        func textViews(_ view: NSView) -> [TitleTextView] {
            ((view as? TitleTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
        }
        _ = await hosted.pixels() // draws the window: SwiftUI applies its updates
        let shown = textViews(hosted.host)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first === textView, "the same text view")
        XCTAssertEqual(shown.first?.string, "Title", "the text area follows the model")
    }
}
