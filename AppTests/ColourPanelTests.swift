import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Colour section of the inspector and the grade commands: the rows come from the engine's grade
/// table; one clip shows its grade; several show each value where they agree and "Mixed" where they
/// differ, and moving a control sets that one parameter on all of them (their linked sound left out);
/// typed values with units, nudges in the grade's steps, a slider drag as one undo step, per-row and
/// section resets; Copy Grade, Paste Grade and Reset Grade from the store, the menus' enabled states
/// and the clip's context menu; every change one undo step.
@MainActor
final class ColourPanelTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("colour")
    }

    override func tearDown() async throws {
        InspectorModel.burstIdleSeconds = 1.0
        fixture?.cleanUp()
    }

    private func grade(_ id: VEClipID) -> VEGradeParams {
        store.clips[id]?.grade ?? VEGradeParamsNeutral()
    }

    /// Two movie clips on V1 at 0 s and 1 s, the first linked to the tone on A1; returns (first, second,
    /// tone clip).
    private func clips() async throws -> (VEClipID, VEClipID, VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let sound = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(first, withClip: sound).ok)
        return (first, second, sound)
    }

    func testTheRowsComeFromTheEngineTable() {
        let rows = InspectorParameter.parameters(in: .colour)
        XCTAssertEqual(rows, [.exposure, .contrast, .temperature, .tint, .saturation])
        for row in rows {
            let info = try? XCTUnwrap(row.gradeInfo)
            XCTAssertEqual(row.label, info?.displayName)
            XCTAssertEqual(row.unit, info?.unit)
            XCTAssertEqual(row.defaultValue, info?.neutralValue)
        }
        XCTAssertEqual(InspectorParameter.exposure.label, "Exposure")
        XCTAssertEqual(InspectorParameter.exposure.unit, "stops")
        XCTAssertEqual(InspectorParameter.saturation.defaultValue, 1)
        XCTAssertEqual(InspectorSection.colour.title, "Colour")
        // The other rows are as before.
        XCTAssertNil(InspectorParameter.opacity.gradeInfo)
        XCTAssertEqual(InspectorParameter.opacity.nudgeStep, 1)
        XCTAssertEqual(InspectorParameter.exposure.nudgeStep, 0.1)
    }

    func testOneClipShowsItsGradeAndSeveralShowMixed() async throws {
        let (first, second, sound) = try await clips()
        store.selection = [first]
        XCTAssertTrue(inspector.isAvailable(.exposure))
        XCTAssertEqual(inspector.text(.exposure), "0 stops")
        XCTAssertEqual(inspector.text(.contrast), "1 ×")
        XCTAssertEqual(inspector.text(.temperature), "0")
        XCTAssertEqual(inspector.range(.temperature), -100 ... 100)
        XCTAssertEqual(inspector.sliderRange(.exposure), -5 ... 5)

        inspector.setValue(.exposure, 1.5)
        XCTAssertEqual(grade(first).exposure, 1.5)
        XCTAssertEqual(store.undoActionName, "Change Exposure")
        XCTAssertEqual(inspector.text(.exposure), "1.5 stops")

        // Two clips (and the linked sound) selected: exposure differs, saturation agrees.
        store.selection = [first, second, sound]
        XCTAssertEqual(inspector.videoTargets.map(\.clipID), [first, second])
        XCTAssertTrue(inspector.isMixed(.exposure))
        XCTAssertEqual(inspector.text(.exposure), "", "the field shows its Mixed placeholder")
        XCTAssertFalse(inspector.isMixed(.saturation))
        XCTAssertEqual(inspector.text(.saturation), "1 ×")
        // The engine's selection query agrees.
        let selection = store.engine.grade(ofClips: [NSNumber(value: first), NSNumber(value: second)])
        XCTAssertTrue(selection.isMixed(.exposure))
        XCTAssertFalse(selection.isMixed(.saturation))

        // A sound clip alone has no Colour rows.
        store.selection = [sound]
        XCTAssertFalse(inspector.isAvailable(.exposure))
    }

    func testMovingOneControlSetsItOnEveryClipInOneUndoStep() async throws {
        let (first, second, sound) = try await clips()
        store.selection = [first]
        inspector.setValue(.exposure, 1)
        store.selection = [second]
        inspector.setValue(.exposure, -1)

        store.selection = [first, second, sound]
        inspector.commitText(.saturation, "0.5×")
        XCTAssertEqual(grade(first).saturation, 0.5)
        XCTAssertEqual(grade(second).saturation, 0.5)
        XCTAssertEqual(grade(first).exposure, 1, "the other parameters stay")
        XCTAssertEqual(grade(second).exposure, -1)
        XCTAssertFalse(store.clips[sound]?.hasGrade ?? true, "sound has no grade")
        XCTAssertFalse(inspector.isMixed(.saturation))
        XCTAssertEqual(store.undoActionName, "Change Saturation")
        store.undo()
        XCTAssertEqual(grade(first).saturation, 1, "one undo step for both clips")
        XCTAssertEqual(grade(second).saturation, 1)
        store.redo()

        // Moving a mixed control sets the same value on all of them.
        inspector.setValue(.exposure, 0.25)
        XCTAssertEqual(grade(first).exposure, 0.25)
        XCTAssertEqual(grade(second).exposure, 0.25)
        XCTAssertFalse(inspector.isMixed(.exposure))

        // Typed: units accepted, the range enforced with a note, nonsense refused.
        inspector.commitText(.exposure, "2 stops")
        XCTAssertEqual(grade(first).exposure, 2)
        inspector.commitText(.temperature, "250")
        XCTAssertEqual(grade(second).temperature, 100)
        XCTAssertEqual(inspector.message, "Temperature is limited to -100 to 100.")
        inspector.commitText(.contrast, "a lot")
        XCTAssertEqual(grade(first).contrast, 1)
        XCTAssertNotNil(inspector.message)
    }

    func testNudgesMoveInTheGradesStepsAndADragIsOneUndoStep() async throws {
        let (first, second, _) = try await clips()
        store.selection = [first, second]
        for _ in 0 ..< 3 {
            inspector.nudge(.exposure, steps: 1)
        }
        inspector.nudge(.contrast, steps: InspectorModel.bigStep)
        inspector.endNudgeBurst()
        XCTAssertEqual(grade(first).exposure, 0.3, accuracy: 1e-9)
        XCTAssertEqual(grade(second).exposure, 0.3, accuracy: 1e-9)
        XCTAssertEqual(grade(first).contrast, 1.1, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(grade(first).contrast, 1, accuracy: 1e-9, "the contrast burst was its own step")
        store.undo()
        XCTAssertEqual(grade(first).exposure, 0, accuracy: 1e-9, "three nudges were one step")

        let before = store.changeCount
        inspector.beginSliderDrag(.tint)
        for value in [10.0, 25, 40, 33] {
            inspector.sliderChanged(.tint, value)
        }
        inspector.endSliderDrag()
        XCTAssertEqual(grade(first).tint, 33)
        XCTAssertEqual(grade(second).tint, 33)
        XCTAssertEqual(store.undoActionName, "Change Tint")
        XCTAssertGreaterThan(store.changeCount, before)
        store.undo()
        XCTAssertEqual(grade(first).tint, 0, "the drag was one undo step")
        XCTAssertEqual(grade(second).tint, 0)
    }

    func testResetsAndCopyPasteGrade() async throws {
        let (first, second, sound) = try await clips()
        store.selection = [first]
        var look = VEGradeParamsNeutral()
        look.exposure = 0.5
        look.contrast = 1.3
        look.temperature = -20
        look.tint = 10
        look.saturation = 1.4
        XCTAssertTrue(store.engine.setGrade(look, forClips: [NSNumber(value: first)]).ok)

        // Nothing copied yet: Paste is disabled; Copy and Reset are enabled for a graded video clip.
        XCTAssertFalse(store.hasCopiedGrade)
        XCTAssertTrue(store.canCopyGrade)
        XCTAssertFalse(store.canPasteGrade)
        XCTAssertTrue(store.canResetGrade)
        store.copyGrade()
        XCTAssertTrue(store.hasCopiedGrade)
        XCTAssertEqual(store.statusMessage, "Copied the grade of “clip.mov”.")

        // Paste onto the second clip with the linked sound selected too: one undo step.
        store.selection = [second, sound]
        XCTAssertTrue(store.canPasteGrade)
        XCTAssertFalse(store.canResetGrade, "the second clip has no grade yet")
        XCTAssertTrue(store.pasteGrade())
        XCTAssertEqual(store.undoActionName, "Paste Grade")
        XCTAssertEqual(grade(second).exposure, 0.5)
        XCTAssertEqual(grade(second).contrast, 1.3)
        XCTAssertEqual(grade(second).temperature, -20)
        XCTAssertEqual(grade(second).tint, 10)
        XCTAssertEqual(grade(second).saturation, 1.4)
        store.undo()
        XCTAssertFalse(store.clips[second]?.hasGrade ?? true)
        store.redo()

        // A row's reset: its neutral value on every selected clip.
        store.selection = [first, second]
        inspector.reset(.contrast)
        XCTAssertEqual(grade(first).contrast, 1)
        XCTAssertEqual(grade(second).contrast, 1)
        XCTAssertEqual(grade(first).exposure, 0.5, "the others stay")

        // The section's Reset and Clip > Reset Grade remove the grade, one undo step each.
        inspector.reset(.colour)
        XCTAssertFalse(store.clips[first]?.hasGrade ?? true)
        XCTAssertFalse(store.clips[second]?.hasGrade ?? true)
        XCTAssertEqual(store.undoActionName, "Reset Grade")
        store.undo()
        XCTAssertTrue(store.clips[first]?.hasGrade ?? false)
        XCTAssertTrue(store.resetGrade())
        XCTAssertFalse(store.clips[second]?.hasGrade ?? true)
        XCTAssertFalse(store.canResetGrade)

        // Nothing to act on: a sound clip alone.
        store.selection = [sound]
        XCTAssertFalse(store.canCopyGrade)
        XCTAssertFalse(store.canPasteGrade)
        XCTAssertFalse(store.pasteGrade())
        XCTAssertEqual(store.statusMessage, "Select the video clips to paste the grade onto.")
    }

    func testTheClipContextMenuOffersTheGradeCommands() async throws {
        let (first, second, sound) = try await clips()
        store.selection = [first]
        XCTAssertTrue(store.engine.setGradeValue(-1, for: .exposure, clips: [NSNumber(value: first)]).ok)
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let videoRow = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[first]).trackID))
        var items = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 0.5), y: videoRow.y + 20))
        let copy = try XCTUnwrap(items.first { $0.title == "Copy Grade" })
        XCTAssertTrue(copy.isEnabled)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.title == "Paste Grade" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.title == "Reset Grade" }).isEnabled)
        copy.action()
        XCTAssertTrue(store.hasCopiedGrade)

        // On the second clip: Paste gives it the first clip's grade.
        items = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 1.5), y: videoRow.y + 20))
        XCTAssertEqual(store.selection, [second])
        let paste = try XCTUnwrap(items.first { $0.title == "Paste Grade" })
        XCTAssertTrue(paste.isEnabled)
        paste.action()
        XCTAssertEqual(grade(second).exposure, -1)

        // A sound clip's menu has none of them.
        let soundRow = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[sound]).trackID))
        items = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 0.5), y: soundRow.y + 20))
        XCTAssertNil(items.first { $0.title == "Copy Grade" })
    }
}
