import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Keyframed Motion in the app: the inspector's keyframe toggle, values at the playhead,
/// previous/next navigation, interpolation, removing an animation, slider drags and the refusal
/// for several animated clips; the Ken Burns helper's rectangles, their keyframes and its
/// lifetime; the timeline's keyframe markers (positions through a speed change, hit testing, a
/// click moving the playhead). The movie is 2 s (60 frames) at 320x180 on a 1920x1080 30 fps
/// sequence; the timeline's geometry at the default zoom is 50 pt/s with V1 at y 66...130.
@MainActor
final class KeyframedMotionTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "keyframes-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    private func clip(_ id: VEClipID) throws -> VEClipInfo {
        try XCTUnwrap(store.clips[id])
    }

    /// The movie on V1 at 0 s, selected alone.
    private func placedClip() async throws -> VEClipID {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        return id
    }

    // MARK: Inspector

    func testTheKeyframeToggleAndValuesAtThePlayhead() async throws {
        let id = try await placedClip()
        XCTAssertTrue(inspector.hasKeyframeControls(.scale))
        XCTAssertFalse(inspector.hasKeyframeControls(.gain))

        // Without keyframes a value is the static value, wherever the playhead is.
        store.playheadTime = frames(10)
        inspector.setValue(.scale, 150)
        XCTAssertFalse(try clip(id).hasKeyframes)
        XCTAssertEqual(try clip(id).videoParams.scale, 1.5, accuracy: 1e-12)

        // The toggle adds a keyframe with the current value (the picture does not change).
        inspector.toggleKeyframe(.scale)
        XCTAssertEqual(store.undoActionName, "Add Keyframe")
        XCTAssertTrue(inspector.isAnimated(.scale))
        let first = try XCTUnwrap(inspector.keyframeAtPlayhead(.scale))
        XCTAssertEqual(first.value, 1.5, accuracy: 1e-12)
        XCTAssertEqual(first.frameTime, frames(10))

        // Elsewhere, a typed value adds a keyframe there (Premiere's stopwatch behaviour) and the
        // shown value follows the playhead.
        store.playheadTime = frames(40)
        XCTAssertNil(inspector.keyframeAtPlayhead(.scale))
        inspector.commitText(.scale, "250 %")
        XCTAssertEqual(store.undoActionName, "Add Keyframe")
        XCTAssertEqual(try clip(id).keyframes(for: .scale).count, 2)
        XCTAssertEqual(try XCTUnwrap(inspector.value(.scale)), 250, accuracy: 1e-9)
        store.playheadTime = frames(25)
        XCTAssertEqual(try XCTUnwrap(inspector.value(.scale)), 200, accuracy: 1e-9, "halfway, linear")
        store.playheadTime = frames(0)
        XCTAssertEqual(try XCTUnwrap(inspector.value(.scale)), 150, accuracy: 1e-9, "before the first keyframe")

        // On a keyframe, a value edits that keyframe.
        store.playheadTime = frames(40)
        inspector.setValue(.scale, 300)
        XCTAssertEqual(store.undoActionName, "Change Keyframe")
        XCTAssertEqual(try clip(id).keyframes(for: .scale).count, 2)
        XCTAssertEqual(try clip(id).keyframes(for: .scale)[1].value, 3, accuracy: 1e-12)

        // The toggle on a keyframe removes it; undo brings it back.
        inspector.toggleKeyframe(.scale)
        XCTAssertEqual(store.undoActionName, "Delete Keyframe")
        XCTAssertEqual(try clip(id).keyframes(for: .scale).count, 1)
        store.undo()
        XCTAssertEqual(try clip(id).keyframes(for: .scale).count, 2)
    }

    func testPreviousAndNextKeyframeMoveThePlayhead() async throws {
        let id = try await placedClip()
        for frame: Int64 in [5, 20, 45] {
            store.playheadTime = frames(frame)
            inspector.toggleKeyframe(.rotation)
        }
        XCTAssertEqual(try clip(id).keyframes(for: .rotation).count, 3)
        store.playheadTime = frames(30)
        XCTAssertEqual(inspector.previousKeyframeTime(.rotation), frames(20))
        XCTAssertEqual(inspector.nextKeyframeTime(.rotation), frames(45))
        inspector.goToKeyframe(.rotation, forward: true)
        XCTAssertEqual(store.playheadTime, frames(45))
        XCTAssertNil(inspector.nextKeyframeTime(.rotation), "none after the last")
        inspector.goToKeyframe(.rotation, forward: false)
        XCTAssertEqual(store.playheadTime, frames(20))
        inspector.goToKeyframe(.rotation, forward: false)
        XCTAssertEqual(store.playheadTime, frames(5))
        XCTAssertNil(inspector.previousKeyframeTime(.rotation))
        // Other parameters have their own keyframes.
        XCTAssertNil(inspector.nextKeyframeTime(.opacity))
    }

    func testInterpolationAndRemovingTheAnimation() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(0)
        inspector.toggleKeyframe(.positionX)
        store.playheadTime = frames(30)
        inspector.setValue(.positionX, 300)
        store.playheadTime = frames(0)
        XCTAssertEqual(inspector.interpolation(.positionX), .linear)
        inspector.setInterpolation(.hold, for: .positionX)
        XCTAssertEqual(inspector.interpolation(.positionX), .hold)
        store.playheadTime = frames(29)
        XCTAssertEqual(try XCTUnwrap(inspector.value(.positionX)), 0, accuracy: 1e-12, "held until the next keyframe")
        inspector.setInterpolation(.easeInOut, for: .positionX)
        XCTAssertNotNil(inspector.message, "no keyframe under the playhead: refused with a reason")
        XCTAssertEqual(try clip(id).keyframes(for: .positionX)[0].interpolation, .hold)

        // Removing the animation keeps the value at the playhead.
        store.playheadTime = frames(30)
        inspector.removeAnimation(.positionX)
        XCTAssertEqual(store.undoActionName, "Remove Animation")
        XCTAssertFalse(try clip(id).hasKeyframes)
        XCTAssertEqual(try clip(id).videoParams.x, 300, accuracy: 1e-12)
    }

    func testASliderDragOnAnAnimatedValueIsOneKeyframeAndOneUndoStep() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(0)
        inspector.toggleKeyframe(.opacity)
        store.playheadTime = frames(30)
        inspector.beginSliderDrag(.opacity)
        for value in stride(from: 95.0, through: 40.0, by: -5.0) {
            inspector.sliderChanged(.opacity, value)
        }
        XCTAssertTrue(store.isGestureActive, "the drag's group blocks other commands")
        inspector.endSliderDrag()
        let keys = try clip(id).keyframes(for: .opacity)
        XCTAssertEqual(keys.count, 2, "the drag added one keyframe")
        XCTAssertEqual(keys[1].value, 0.4, accuracy: 1e-12)
        store.undo()
        XCTAssertEqual(try clip(id).keyframes(for: .opacity).count, 1, "one undo step")
    }

    func testSeveralClipsCannotChangeAnAnimatedParameterAndAVideoResetClearsKeyframes() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 3)
        store.selection = [a]
        store.playheadTime = frames(10)
        inspector.toggleKeyframe(.scale)
        store.selection = [a, b]
        XCTAssertNil(inspector.motionTarget)
        XCTAssertFalse(inspector.hasKeyframeControls(.scale))
        inspector.setValue(.scale, 50)
        XCTAssertEqual(inspector.message?.contains("select that clip alone"), true)
        XCTAssertEqual(try clip(b).videoParams.scale, 1, "refused as a whole")
        inspector.setValue(.opacity, 50) // animated on neither: applies to both
        XCTAssertEqual(try clip(a).videoParams.opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try clip(b).videoParams.opacity, 0.5, accuracy: 1e-12)
        XCTAssertTrue(try clip(a).hasKeyframes, "a static change keeps the keyframes")
        inspector.reset(.video)
        XCTAssertFalse(try clip(a).hasKeyframes)
        XCTAssertEqual(try clip(a).videoParams.opacity, 1)
        store.undo()
        XCTAssertTrue(try clip(a).hasKeyframes)
    }

    // MARK: Ken Burns

    func testKenBurnsGeometry() {
        let sequence = CGSize(width: 1920, height: 1080)
        // A rectangle's framing and back, with and without the clip's rotation.
        for rotation in [0.0, 30.0, -90.0] {
            let rect = CGRect(x: 300, y: 200, width: 960, height: 540)
            let framing = KenBurnsModel.framing(for: rect, sequence: sequence, rotationDegrees: rotation)
            XCTAssertEqual(framing.scale, 2, accuracy: 1e-12)
            let back = KenBurnsModel.rect(for: framing, sequence: sequence, rotationDegrees: rotation)
            XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9)
            XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9)
            XCTAssertEqual(back.width, rect.width, accuracy: 1e-9)
        }
        // Unrotated: the rectangle's centre (180 px right of and 70 px below the frame's centre, at
        // 2x) moves to the frame's centre.
        let framing = KenBurnsModel.framing(for: CGRect(x: 660, y: 340, width: 960, height: 540), sequence: sequence,
                                            rotationDegrees: 0)
        XCTAssertEqual(framing.x, -360, accuracy: 1e-9)
        XCTAssertEqual(framing.y, -140, accuracy: 1e-9)
        // The whole frame is the identity.
        let whole = KenBurnsModel.framing(for: CGRect(origin: .zero, size: sequence), sequence: sequence,
                                          rotationDegrees: 0)
        XCTAssertEqual(whole.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(whole.x, 0, accuracy: 1e-12)
        // A portrait picture is pillarboxed; the largest frame-shaped rectangle fits its width.
        let portrait = KenBurnsModel.fittedPicture(width: 1080, height: 1920, in: sequence)
        XCTAssertEqual(portrait.width, 607.5, accuracy: 1e-9)
        let largest = KenBurnsModel.largestRect(in: portrait, aspect: 16.0 / 9.0)
        XCTAssertEqual(largest.width, portrait.width, accuracy: 1e-9)
        XCTAssertEqual(largest.midY, 540, accuracy: 1e-9)
    }

    func testKenBurnsRectanglesStayInsideThePictureAndKeepTheAspect() async throws {
        let id = try await placedClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.pictureBounds, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080), "starts on the whole picture")
        XCTAssertEqual(model.end.width, 1920 * KenBurnsModel.defaultEndFraction, accuracy: 1e-9, "a push in")
        XCTAssertEqual(model.end.midX, 960, accuracy: 1e-9)
        XCTAssertEqual(model.interpolation, .easeInOut, "FCP's default smoothing")

        // Moving past the picture's edge stops at it.
        let end = model.end
        model.move(.end, from: end, by: CGSize(width: 5000, height: -5000))
        XCTAssertEqual(model.end.maxX, 1920, accuracy: 1e-9)
        XCTAssertEqual(model.end.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(model.end.size, end.size)

        // Resizing from a corner keeps the frame's aspect and the opposite corner.
        let before = model.end
        model.resize(.end, from: before, corner: .bottomLeft, to: CGPoint(x: before.maxX - 400, y: 0))
        XCTAssertEqual(model.end.maxX, before.maxX, accuracy: 1e-9)
        XCTAssertEqual(model.end.minY, before.minY, accuracy: 1e-9)
        XCTAssertEqual(model.end.width / model.end.height, 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(model.end.width, 400, accuracy: 1e-9)
        // Not smaller than a tenth of the frame.
        model.resize(.end, from: model.end, corner: .bottomLeft, to: CGPoint(x: model.end.maxX - 1, y: 0))
        XCTAssertEqual(model.end.width, 192, accuracy: 1e-9)
        // Swap exchanges the framings.
        let (s, e) = (model.start, model.end)
        model.swap()
        XCTAssertEqual(model.start, e)
        XCTAssertEqual(model.end, s)
    }

    func testKenBurnsAppliesPositionAndScaleKeyframesOnTheFirstAndLastFrames() async throws {
        let id = try await placedClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.start = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        model.end = CGRect(x: 960, y: 540, width: 960, height: 540) // the bottom-right quarter
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertNil(store.kenBurns, "closed after applying")
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        let info = try clip(id)
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            let keys = info.keyframes(for: parameter)
            XCTAssertEqual(keys.map(\.frameTime), [frames(0), frames(59)])
            XCTAssertEqual(keys.first?.interpolation, .easeInOut)
        }
        XCTAssertEqual(info.motion(at: frames(0)).scale, 1, accuracy: 1e-12)
        let last = info.motion(at: frames(59))
        XCTAssertEqual(last.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(last.x, -960, accuracy: 1e-9)
        XCTAssertEqual(last.y, -540, accuracy: 1e-9)
        // Opening the helper again starts from those keyframes.
        store.beginKenBurns(clip: id)
        let again = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(again.end.minX, 960, accuracy: 1e-6)
        XCTAssertEqual(again.end.width, 960, accuracy: 1e-6)
        XCTAssertEqual(again.start.width, 1920, accuracy: 1e-6)
        // Cancel changes nothing; selecting another clip closes the helper.
        store.cancelKenBurns()
        XCTAssertNil(store.kenBurns)
        store.beginKenBurns(clip: id)
        XCTAssertNotNil(store.kenBurns)
        store.selection = []
        XCTAssertNil(store.kenBurns)
        store.undo()
        XCTAssertFalse(try clip(id).hasKeyframes)
    }

    func testKenBurnsIsRefusedForAOneFrameClip() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0, sourceIn: .zero,
                                  sourceOut: frames(1), overwrite: true))
        let id = try XCTUnwrap(store.selection.first)
        store.beginKenBurns(clip: id)
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.statusMessage?.contains("two frames"), true)
    }

    // MARK: Timeline markers

    func testTimelineMarkersFollowSpeedAndAClickMovesThePlayhead() async throws {
        let id = try await placedClip()
        for frame: Int64 in [0, 20] {
            store.playheadTime = frames(frame)
            inspector.toggleKeyframe(.scale)
        }
        store.playheadTime = frames(20)
        inspector.toggleKeyframe(.opacity) // the same frame: one marker
        var model = store.timelineModel
        var timelineClip = try XCTUnwrap(model.clip(id: id))
        XCTAssertEqual(timelineClip.keyframes.count, 2)
        XCTAssertEqual(timelineClip.keyframes[0], 0, accuracy: 1e-9)
        XCTAssertEqual(timelineClip.keyframes[1], 20.0 / 30.0, accuracy: 1e-9)

        // At 2x the keyframe on source frame 20 plays at timeline frame 10.
        XCTAssertTrue(store.engine.setSpeedNumerator(2, denominator: 1, forClip: id).ok)
        model = store.timelineModel
        timelineClip = try XCTUnwrap(model.clip(id: id))
        XCTAssertEqual(timelineClip.keyframes[1], 10.0 / 30.0, accuracy: 1e-9)

        // The marker is hit in the clip's bottom zone; a click moves the playhead to its frame.
        let center = try XCTUnwrap(model.keyframeMarkerCenter(forClip: timelineClip, time: timelineClip.keyframes[1]))
        XCTAssertEqual(model.hitTest(center), .keyframe(id, timelineClip.keyframes[1]))
        XCTAssertEqual(model.hitTest(CGPoint(x: center.x, y: center.y - 30)), .clipBody(id), "above the marker zone")
        store.playheadTime = frames(40)
        store.selection = []
        let gestures = TimelineGestureController(store: store)
        gestures.changed(location: center, startLocation: center, modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.playheadTime, frames(10))
        XCTAssertEqual(store.selection, [id], "the click selects the clip too")
        XCTAssertEqual(gestures.drag, .idle)

        // A drag that starts on a marker moves the clip, like its body.
        gestures.changed(location: center, startLocation: center, modifiers: [])
        gestures.changed(location: CGPoint(x: center.x + 50, y: center.y), startLocation: center, modifiers: [])
        gestures.ended()
        XCTAssertEqual(try clip(id).timelineStart.secondsOrZero, 1, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Move Clip")
    }

    func testClipsWithoutKeyframesHaveNoMarkers() async throws {
        let id = try await placedClip()
        XCTAssertEqual(store.timelineModel.clip(id: id)?.keyframes, [])
        let center = CGPoint(x: 20, y: 66 + 64 - 4)
        XCTAssertEqual(store.timelineModel.hitTest(center), .clipBody(id))
    }
}
