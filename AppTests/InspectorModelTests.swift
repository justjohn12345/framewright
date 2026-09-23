import CoreMedia
import VidEditEngine
import XCTest
@testable import VidEdit

/// The inspector's editing logic: nudge bursts as one undo step, typed values with units
/// (parsed and clamped), sliders, resets, multi-selection batches and refusal messages.
@MainActor
final class InspectorModelTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "inspector-\(UUID())"))
    }

    override func tearDown() async throws {
        InspectorModel.burstIdleSeconds = 1.0
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }

    private func video(_ id: VEClipID) -> VEVideoParams {
        store.clips[id]?.videoParams ?? VEVideoParamsIdentity()
    }

    private func audio(_ id: VEClipID) -> VEAudioParams {
        store.clips[id]?.audioParams ?? VEAudioParamsDefault()
    }

    /// Places the tone on A1 at `seconds`; selects and returns it.
    private func placeTone(_ tone: VEAssetInfo, at seconds: Double) throws -> VEClipID {
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: store.frameTime(seconds), videoTrack: 0, audioTrack: a1,
                                  overwrite: true), store.statusMessage ?? "")
        return try XCTUnwrap(store.selection.first)
    }

    func testTenNudgesAreOneUndoStep() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]
        for _ in 0 ..< 10 {
            inspector.nudge(.opacity, steps: -1)
        }
        XCTAssertEqual(video(clip).opacity, 0.9, accuracy: 1e-9)
        XCTAssertTrue(store.engine.isCoalescing, "the burst is still open")
        XCTAssertFalse(store.isGestureActive, "a nudge burst does not block other commands")
        inspector.endNudgeBurst()
        XCTAssertFalse(store.engine.isCoalescing)
        XCTAssertEqual(store.undoActionName, "Change Video Settings")
        store.undo()
        XCTAssertEqual(video(clip).opacity, 1, accuracy: 1e-9, "ten nudges were one undo step")
        XCTAssertEqual(store.undoActionName, "Overwrite")

        // Shift steps are 10; a burst closes by itself after the idle time.
        InspectorModel.burstIdleSeconds = 0.05
        inspector.nudge(.rotation, steps: InspectorModel.bigStep)
        inspector.nudge(.rotation, steps: InspectorModel.bigStep)
        XCTAssertEqual(video(clip).rotationDegrees, 20, accuracy: 1e-9)
        let closed = await StoreFixture.wait(until: { !self.store.engine.isCoalescing }, timeout: 5)
        XCTAssertTrue(closed)
        XCTAssertNil(store.nudgeGroup)
        store.undo()
        XCTAssertEqual(video(clip).rotationDegrees, 0, accuracy: 1e-9)

        // Another command during a burst commits the burst as its own step first.
        InspectorModel.burstIdleSeconds = 10
        inspector.nudge(.positionX, steps: 1)
        inspector.nudge(.positionX, steps: 1)
        store.splitAtPlayhead() // playhead at 0: nothing to split, but no gesture blocks it
        XCTAssertFalse(store.isGestureActive)
        store.selection = [clip]
        store.playheadTime = CMTime(value: 30, timescale: 30)
        store.splitAtPlayhead()
        XCTAssertEqual(store.undoActionName, "Split Clip")
        store.undo()
        XCTAssertEqual(store.undoActionName, "Change Video Settings", "the burst was committed as one step")
        XCTAssertEqual(video(clip).x, 2, accuracy: 1e-9)
    }

    func testTypedValuesWithUnitsParseAndClamp() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]
        inspector.commitText(.opacity, "50 %")
        XCTAssertEqual(video(clip).opacity, 0.5, accuracy: 1e-9)
        XCTAssertNil(inspector.message)
        inspector.commitText(.opacity, "150")
        XCTAssertEqual(video(clip).opacity, 1, accuracy: 1e-9, "clamped to 100 %")
        XCTAssertTrue(inspector.message?.contains("limited") == true, inspector.message ?? "")
        inspector.commitText(.rotation, "45°")
        XCTAssertEqual(video(clip).rotationDegrees, 45, accuracy: 1e-9)
        inspector.commitText(.positionX, "-12.5px")
        XCTAssertEqual(video(clip).x, -12.5, accuracy: 1e-9)
        inspector.commitText(.scale, "250%")
        XCTAssertEqual(video(clip).scale, 2.5, accuracy: 1e-9)
        XCTAssertEqual(inspector.text(.scale), "250 %")
        let before = store.changeCount
        inspector.commitText(.scale, "big")
        XCTAssertEqual(store.changeCount, before, "invalid text changes nothing")
        XCTAssertTrue(inspector.message?.contains("not a valid") == true, inspector.message ?? "")
        inspector.commitText(.opacity, "40 dB")
        XCTAssertEqual(store.changeCount, before, "a wrong unit is refused")

        // Speed: a percentage or an exact ratio.
        inspector.commitText(.speed, "50%")
        XCTAssertEqual(store.clips[clip]?.speedNumerator, 1)
        XCTAssertEqual(store.clips[clip]?.speedDenominator, 2)
        inspector.commitText(.speed, "1/3")
        XCTAssertEqual(store.clips[clip]?.speedDenominator, 3)
        XCTAssertEqual(inspector.text(.speed), "1/3")

        // Audio: gain in dB, fades as frames, seconds or timecode (30 fps sequence).
        let toneClip = try placeTone(tone, at: 10)
        inspector.commitText(.gain, "-6 dB")
        XCTAssertEqual(audio(toneClip).gainDb, -6, accuracy: 1e-9)
        inspector.commitText(.fadeIn, "15f")
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 15)
        inspector.commitText(.fadeIn, "0.5s")
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 15)
        inspector.commitText(.fadeIn, "00:00:01:00")
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 30)
        inspector.commitText(.fadeIn, "20") // bare number: frames with the timecode display
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 20)
        XCTAssertEqual(inspector.text(.fadeIn), "00:00:00:20")
        inspector.commitText(.fadeOut, "80f") // the 3 s clip has 90 frames: 90 - 20 = 70 left
        XCTAssertEqual(store.frames(audio(toneClip).fadeOutDuration), 70, "fade in + fade out <= duration")
        XCTAssertTrue(inspector.message?.contains("limited") == true, inspector.message ?? "")
        store.defaults.set(DurationDisplay.seconds.rawValue, forKey: EditingPreferences.durationDisplayKey)
        XCTAssertEqual(inspector.text(.fadeOut), "2.33 s")
        inspector.commitText(.fadeOut, "1") // bare number: seconds with the seconds display
        XCTAssertEqual(store.frames(audio(toneClip).fadeOutDuration), 30)
    }

    func testMultiSelectionEditsEveryClipOfTheMatchingKindInOneStep() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 5)
        let toneClip = try placeTone(tone, at: 0)
        store.selection = [first, second, toneClip]
        XCTAssertEqual(inspector.videoTargets.count, 2)
        XCTAssertEqual(inspector.audioTargets.count, 1)
        XCTAssertNil(inspector.speedTarget, "speed is per clip; several use the sheet")
        inspector.setValue(.positionY, 30)
        XCTAssertEqual(video(first).y, 30, accuracy: 1e-9)
        XCTAssertEqual(video(second).y, 30, accuracy: 1e-9)
        XCTAssertEqual(video(toneClip).y, 0, accuracy: 1e-9, "video parameters only go to video clips")
        store.undo()
        XCTAssertEqual(video(first).y, 0, accuracy: 1e-9)
        XCTAssertEqual(video(second).y, 0, accuracy: 1e-9, "one undo step for both")

        // Mixed values show a placeholder; a nudge moves each clip from its own value.
        store.selection = [first]
        inspector.setValue(.positionX, 10)
        store.selection = [first, second]
        XCTAssertTrue(inspector.isMixed(.positionX))
        XCTAssertEqual(inspector.text(.positionX), "")
        inspector.nudge(.positionX, steps: 5)
        inspector.endNudgeBurst()
        XCTAssertEqual(video(first).x, 15, accuracy: 1e-9)
        XCTAssertEqual(video(second).x, 5, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(video(first).x, 10, accuracy: 1e-9)
        XCTAssertEqual(video(second).x, 0, accuracy: 1e-9)
    }

    func testSliderDragIsOneStepAndResets() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let toneClip = try placeTone(tone, at: 0)
        store.selection = [clip, toneClip]
        inspector.beginSliderDrag(.scale)
        XCTAssertTrue(store.isGestureActive, "a slider drag blocks other commands")
        for value in stride(from: 100.0, through: 180, by: 20) {
            inspector.sliderChanged(.scale, value)
        }
        inspector.endSliderDrag()
        XCTAssertFalse(store.engine.isCoalescing)
        XCTAssertEqual(video(clip).scale, 1.8, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(video(clip).scale, 1, accuracy: 1e-9, "the drag was one undo step")

        inspector.setValue(.opacity, 30)
        inspector.setValue(.rotation, 90)
        inspector.setValue(.gain, -12)
        inspector.setValue(.fadeIn, 10)
        inspector.reset(.opacity)
        XCTAssertEqual(video(clip).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(video(clip).rotationDegrees, 90, accuracy: 1e-9, "a parameter reset leaves the others")
        inspector.reset(.video)
        XCTAssertEqual(video(clip).rotationDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(audio(toneClip).gainDb, -12, accuracy: 1e-9, "the video reset leaves the audio")
        inspector.reset(.audio)
        XCTAssertEqual(audio(toneClip).gainDb, 0, accuracy: 1e-9)
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 0)
        store.undo()
        XCTAssertEqual(audio(toneClip).gainDb, -12, accuracy: 1e-9, "a section reset is one step")
        XCTAssertEqual(store.frames(audio(toneClip).fadeInDuration), 10)
    }

    func testRefusedEditsShowAMessage() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        XCTAssertTrue(store.engine.setTrack(v1, locked: true).ok)
        inspector.commitText(.opacity, "20")
        XCTAssertTrue(inspector.message?.contains("locked") == true, inspector.message ?? "nil")
        XCTAssertEqual(video(clip).opacity, 1, accuracy: 1e-9)
        inspector.nudge(.opacity, steps: -1)
        XCTAssertTrue(inspector.message?.contains("locked") == true, "a refused nudge is reported too")
        inspector.endNudgeBurst()
        XCTAssertTrue(store.engine.setTrack(v1, locked: false).ok)

        // Busy: another edit ends the slider's group mid-drag; the drag stops and says so.
        inspector.beginSliderDrag(.opacity)
        inspector.sliderChanged(.opacity, 70)
        XCTAssertTrue(store.engine.renameTrack(v1, to: "Picture").ok) // an edit outside the drag
        inspector.sliderChanged(.opacity, 40)
        XCTAssertTrue(inspector.message?.contains("interrupted") == true, inspector.message ?? "nil")
        XCTAssertEqual(video(clip).opacity, 0.7, accuracy: 1e-9, "the late step was not applied")
        inspector.sliderChanged(.opacity, 10)
        XCTAssertEqual(video(clip).opacity, 0.7, accuracy: 1e-9, "the rest of the drag is ignored")
        inspector.endSliderDrag()
        XCTAssertEqual(store.undoActionName, "Change Track")
        store.undo()
        XCTAssertEqual(store.undoActionName, "Change Video Settings", "the drag's first part is its own step")

        // A timeline drag in progress refuses inspector edits with a message.
        store.cancelActiveGesture = {}
        inspector.nudge(.opacity, steps: 1)
        XCTAssertEqual(inspector.message, "Finish the timeline drag first.")
        store.cancelActiveGesture = nil
    }

    func testDurationAndSpeedParsing() {
        let fd = CMTime(value: 1, timescale: 30)
        XCTAssertEqual(DurationFormat.parseFrames("12f", frameDuration: fd, display: .timecode), 12)
        XCTAssertEqual(DurationFormat.parseFrames("12 frames", frameDuration: fd, display: .seconds), 12)
        XCTAssertEqual(DurationFormat.parseFrames("0,5 s", frameDuration: fd, display: .frames), 15)
        XCTAssertEqual(DurationFormat.parseFrames("1:05", frameDuration: fd, display: .frames), 35)
        XCTAssertEqual(DurationFormat.parseFrames("01:00:00:00", frameDuration: fd, display: .frames), 108_000)
        XCTAssertEqual(DurationFormat.parseFrames("2", frameDuration: fd, display: .seconds), 60)
        XCTAssertNil(DurationFormat.parseFrames("-3f", frameDuration: fd, display: .frames))
        XCTAssertNil(DurationFormat.parseFrames("3 apples", frameDuration: fd, display: .frames))
        XCTAssertEqual(DurationFormat.string(frames: 35, frameDuration: fd, display: .timecode), "00:00:01:05")
        XCTAssertEqual(DurationFormat.string(frames: 35, frameDuration: fd, display: .frames), "35f")
        XCTAssertEqual(DurationFormat.shortString(frames: 35, frameDuration: fd, display: .timecode), "1:05")
        XCTAssertEqual(SpeedRatio.parse("50"), SpeedRatio(numerator: 1, denominator: 2))
        XCTAssertEqual(SpeedRatio.parse("33.3%"), SpeedRatio(numerator: 333, denominator: 1000))
        XCTAssertEqual(SpeedRatio.parse("2x"), SpeedRatio(numerator: 2, denominator: 1))
        XCTAssertEqual(SpeedRatio.parse("1/3"), SpeedRatio(numerator: 1, denominator: 3))
        XCTAssertEqual(SpeedRatio.approximating(1.0 / 3.0), SpeedRatio(numerator: 1, denominator: 3))
        XCTAssertEqual(SpeedRatio.approximating(0.999), SpeedRatio(numerator: 999, denominator: 1000))
        XCTAssertNil(SpeedRatio.parse("0"))
        XCTAssertNil(SpeedRatio.parse("fast"))
        XCTAssertEqual(KeyboardController.action(keyCode: 30, characters: "]", modifiers: []), .gainUp(big: false))
        XCTAssertEqual(KeyboardController.action(keyCode: 33, characters: "{", modifiers: .shift), .gainDown(big: true))
    }
}
