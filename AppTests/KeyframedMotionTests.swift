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

    // MARK: Ken Burns range

    /// A 10 s movie (300 frames) on V1 at 0 s, selected alone.
    private func longClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 300)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let movie = try XCTUnwrap(imported.first)
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        XCTAssertEqual(try clip(id).duration, frames(300))
        return id
    }

    func testKenBurnsRangeDefaultsTimecodesAndThePicture() async throws {
        let id = try await longClip()
        store.playheadTime = frames(200)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)

        // Whole clip (the default): the clip's length, not editable, no caption.
        XCTAssertEqual(model.range, .wholeClip)
        XCTAssertEqual(model.durationFrames, 300)
        XCTAssertEqual(model.durationText, "00:00:10:00")
        XCTAssertFalse(model.isDurationEditable)
        XCTAssertEqual(model.rangeTimecodes, "00:00:00:00 – 00:00:09:29")
        XCTAssertNil(model.rangeCaption)
        XCTAssertEqual(model.pictureSeconds, 200.0 / 30.0, accuracy: 1e-9, "the picture follows the playhead")

        // From clip start: 5 s, and the end framing holds for the rest of the clip.
        model.range = .fromClipStart
        XCTAssertEqual(model.durationFrames, 150)
        XCTAssertEqual(model.durationText, "00:00:05:00")
        XCTAssertTrue(model.isDurationEditable)
        XCTAssertEqual(model.rangeTimecodes, "00:00:00:00 – 00:00:04:29")
        XCTAssertEqual(model.rangeCaption, KenBurnsModel.holdCaption)

        // From playhead: 5 s clamped to the 100 frames left after frame 200; it reaches the end.
        model.range = .fromPlayhead
        XCTAssertEqual(model.durationFrames, 100)
        XCTAssertEqual(model.rangeTimecodes, "00:00:06:20 – 00:00:09:29")
        XCTAssertNil(model.rangeCaption)
        XCTAssertEqual(model.pictureSeconds, 200.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(model.rangeStart, frames(200))
        // The playhead moves: the range follows, and the 5 s default fits again.
        store.playheadTime = frames(60)
        model.setPlayhead(store.playheadTime) // what the overlay does on every playhead change
        XCTAssertEqual(model.durationFrames, 150)
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:06:29")
        XCTAssertEqual(model.pictureSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(model.rangeCaption, KenBurnsModel.holdCaption)
        // Off the clip, or on its last frame: nothing to apply, and the caption says why.
        model.setPlayhead(frames(299))
        XCTAssertNotNil(model.rangeProblem)
        model.setPlayhead(frames(400))
        XCTAssertEqual(model.rangeProblem, "Move the playhead over the clip to start the move there.")
        XCTAssertEqual(model.rangeCaption, model.rangeProblem)
        XCTAssertFalse(store.applyKenBurns())
        XCTAssertEqual(store.statusMessage, model.rangeProblem)
        XCTAssertFalse(try clip(id).hasKeyframes)
        // Changing the range resets the duration to its default.
        model.range = .fromClipStart
        XCTAssertNil(model.rangeProblem)
        XCTAssertEqual(model.durationFrames, 150)
    }

    func testKenBurnsPictureFollowsThePlayheadThroughSpeedAndClampsToTheClip() async throws {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 1) // timeline frames [30, 90)
        store.selection = [id]
        store.playheadTime = frames(45)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.pictureFrame, frames(45))
        XCTAssertEqual(model.pictureSeconds, 0.5, accuracy: 1e-9)
        // Every range shows the picture under the playhead.
        model.range = .fromClipStart
        XCTAssertEqual(model.pictureSeconds, 0.5, accuracy: 1e-9)
        // Before and after the clip: its first and last frames.
        model.setPlayhead(frames(10))
        XCTAssertEqual(model.pictureFrame, frames(30))
        XCTAssertEqual(model.pictureSeconds, 0, accuracy: 1e-9)
        model.setPlayhead(frames(200))
        XCTAssertEqual(model.pictureFrame, frames(89))
        XCTAssertEqual(model.pictureSeconds, 59.0 / 30.0, accuracy: 1e-9)
        // At half speed the clip is 120 frames long and timeline frame 70 (40 into the clip) shows
        // source second 40 / 30 / 2; the helper follows the changed clip.
        XCTAssertTrue(store.engine.setSpeedNumerator(1, denominator: 2, forClip: id).ok)
        XCTAssertTrue(store.kenBurns === model, "still open")
        XCTAssertEqual(model.clip.duration, frames(120))
        model.setPlayhead(frames(70))
        XCTAssertEqual(model.pictureSeconds, 40.0 / 30.0 / 2, accuracy: 1e-9)
        model.setPlayhead(frames(400))
        XCTAssertEqual(model.pictureFrame, frames(149))
        XCTAssertEqual(model.pictureSeconds, 119.0 / 30.0 / 2, accuracy: 1e-9)
        store.cancelKenBurns()

        // A still has one picture, wherever the playhead is.
        let heic = fixture.directory.appendingPathComponent("still.heic")
        try TestMediaFactory.writeHEIC(to: heic)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([heic]) { continuation.resume(returning: $0) }
        }
        let still = try fixture.placeMovie(try XCTUnwrap(imported.first), at: 10)
        store.selection = [still]
        store.playheadTime = frames(320)
        store.beginKenBurns(clip: still)
        let stillModel = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(stillModel.pictureSeconds, 0)
        stillModel.setPlayhead(frames(700))
        XCTAssertEqual(stillModel.pictureSeconds, 0)
    }

    func testKenBurnsPictureLoaderFetchesOneAtATimeAndEndsOnTheLatestTime() async throws {
        let id = try await placedClip()
        store.beginKenBurns(clip: id)
        let loader = try XCTUnwrap(store.kenBurns?.picture)
        let thumbnails = store.thumbnails
        // A scrub: many times in a row while nothing has landed yet starts one fetch.
        for frame in stride(from: 0, through: 45, by: 3) {
            loader.want(seconds: Double(frame) / 30)
        }
        XCTAssertEqual(loader.fetchesStarted, 1)
        XCTAssertEqual(loader.pendingSeconds, 0)
        XCTAssertNil(loader.image)
        // The first lands; the update fetches the latest wanted time (the ones between are skipped).
        let landed = await StoreFixture.wait(until: { !thumbnails.isFetching }, timeout: 20)
        XCTAssertTrue(landed)
        loader.update()
        XCTAssertNotNil(loader.image, "the first picture shows while the latest loads")
        XCTAssertEqual(loader.fetchesStarted, 2)
        XCTAssertEqual(loader.pendingSeconds, 1.5)
        let second = await StoreFixture.wait(until: { !thumbnails.isFetching }, timeout: 20)
        XCTAssertTrue(second)
        loader.update()
        let latest = try XCTUnwrap(thumbnails.cachedImage(asset: loader.assetID, seconds: 1.5,
                                                          maxDimension: KenBurnsPictureLoader.maxDimension))
        XCTAssertTrue(loader.image === latest)
        XCTAssertNil(loader.pendingSeconds)
        XCTAssertEqual(loader.fetchesStarted, 2)
        // A time already cached shows at once, without a fetch.
        loader.want(seconds: 0)
        XCTAssertTrue(loader.image === thumbnails.cachedImage(asset: loader.assetID, seconds: 0,
                                                             maxDimension: KenBurnsPictureLoader.maxDimension))
        XCTAssertEqual(loader.fetchesStarted, 2)
    }

    func testKenBurnsDurationFieldParsesAndClamps() async throws {
        let id = try await longClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromClipStart
        for (typed, expected) in [("2s", Int64(60)), ("45f", 45), ("1:10", 40), ("00:00:03:15", 105), ("2.5 sec", 75)] {
            model.durationText = typed
            XCTAssertTrue(model.commitDuration(), typed)
            XCTAssertEqual(model.durationFrames, expected, typed)
            XCTAssertNil(model.rangeNote, typed)
            XCTAssertEqual(model.durationText, store.durationString(frames: expected), "shown in the project's format")
        }
        model.durationText = "soon"
        XCTAssertFalse(model.commitDuration())
        XCTAssertEqual(model.rangeNote?.contains("not a duration"), true)
        XCTAssertEqual(model.durationFrames, 75, "unchanged")
        model.durationText = "1f"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.durationFrames, 2)
        XCTAssertEqual(model.rangeNote, "A move is at least two frames long.")
        model.durationText = "20s"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.durationFrames, 300)
        XCTAssertEqual(model.rangeNote, "Limited to the 00:00:10:00 left in the clip.")
        // Apply takes a duration still being typed (Return also presses Apply).
        model.durationText = "3s"
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(try clip(id).keyframes(for: .scale).map(\.frameTime), [frames(0), frames(89)])
        // Invalid text refuses Apply and keeps the helper open.
        store.beginKenBurns(clip: id)
        let again = try XCTUnwrap(store.kenBurns)
        again.range = .fromPlayhead
        again.durationText = "later"
        XCTAssertFalse(store.applyKenBurns())
        XCTAssertNotNil(store.kenBurns)
        XCTAssertEqual(store.statusMessage?.contains("not a duration"), true)

        // A bare number means the display's unit (frames here).
        var reason = ""
        let framesModel = try XCTUnwrap(KenBurnsModel(clip: try clip(id), asset: try XCTUnwrap(store.asset(try clip(id).assetID)),
                                                      sequence: store.sequence, playhead: .zero,
                                                      durationDisplay: .frames, reason: &reason))
        framesModel.range = .fromClipStart
        XCTAssertEqual(framesModel.durationText, "150f")
        framesModel.durationText = "90"
        XCTAssertTrue(framesModel.commitDuration())
        XCTAssertEqual(framesModel.durationFrames, 90)
    }

    func testAKenBurnsMoveOverTheFirstSecondsHoldsItsEndFramingAndStartsFromTheCurrentFraming() async throws {
        let id = try await longClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromClipStart
        model.durationText = "5s"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080), "an unplaced clip: the push in")
        model.end = CGRect(x: 960, y: 540, width: 960, height: 540) // the bottom-right quarter
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        let info = try clip(id)
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            XCTAssertEqual(info.keyframes(for: parameter).map(\.frameTime), [frames(0), frames(149)])
        }
        for frame: Int64 in [149, 150, 220, 299] {
            let shown = info.motion(at: frames(frame))
            XCTAssertEqual(shown.scale, 2, accuracy: 1e-12, "frame \(frame) holds the end framing")
            XCTAssertEqual(shown.x, -960, accuracy: 1e-9)
            XCTAssertEqual(shown.y, -540, accuracy: 1e-9)
        }

        // The clip is animated now: the helper opens on its move, the rectangles on its framing at
        // the move's ends.
        store.playheadTime = frames(200)
        store.beginKenBurns(clip: id)
        let second = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(second.range, .existingMove)
        XCTAssertEqual(second.rangeTimecodes, "00:00:00:00 – 00:00:04:29")
        XCTAssertEqual(second.end.minX, 960, accuracy: 1e-6, "the framing on the move's last frame")
        XCTAssertEqual(second.start.width, 1920, accuracy: 1e-6, "and on its first")
        second.range = .fromPlayhead
        XCTAssertEqual(second.start.minX, 960, accuracy: 1e-6, "the framing held at the playhead")
        XCTAssertEqual(second.start.width, 960, accuracy: 1e-6)
        XCTAssertEqual(second.end.width, 960, accuracy: 1e-6)
        // A rectangle the user moved keeps its place when the range changes; the other follows.
        second.move(.end, from: second.end, by: CGSize(width: -500, height: -300))
        let moved = second.end
        second.range = .fromClipStart
        XCTAssertEqual(second.end, moved)
        XCTAssertEqual(second.start.width, 1920, accuracy: 1e-6, "the framing on the clip's first frame")

        // A second move later in the clip keeps the first one; one undo step takes it back.
        second.range = .fromPlayhead
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(try clip(id).keyframes(for: .scale).map(\.frameTime),
                       [frames(0), frames(149), frames(200), frames(299)])
        XCTAssertEqual(try clip(id).motion(at: frames(180)).scale, 2, accuracy: 1e-12, "held between the moves")
        store.undo()
        XCTAssertEqual(try clip(id).keyframes(for: .scale).map(\.frameTime), [frames(0), frames(149)])
    }

    // MARK: Ken Burns: editing a move

    /// A move over timeline frames 60...209 of the long clip (2 s to 6:29), Ease In, from a 75 %
    /// framing to the bottom-right quarter; the helper is closed afterwards.
    private func applyPartialMove(_ id: VEClipID) throws {
        store.playheadTime = frames(60)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromPlayhead
        model.durationText = "150f"
        XCTAssertTrue(model.commitDuration())
        model.start = CGRect(x: 240, y: 135, width: 1440, height: 810)
        model.end = CGRect(x: 960, y: 540, width: 960, height: 540)
        model.interpolation = .easeIn
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(try clip(id).keyframes(for: .scale).map(\.frameTime), [frames(60), frames(209)])
    }

    func testReopeningKenBurnsEditsTheExistingMoveInPlace() async throws {
        let id = try await longClip()
        try applyPartialMove(id)
        let applied = try clip(id)

        // Reopened with the playhead elsewhere: the same range, rectangles and smoothing.
        store.playheadTime = frames(250)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .move(KenBurnsModel.ExistingMove(first: 60, last: 209,
                                                                         hasKeyframesBetween: false,
                                                                         interpolation: .easeIn)))
        XCTAssertEqual(model.range, .existingMove)
        XCTAssertEqual(model.rangeChoices, [.wholeClip, .fromPlayhead, .fromClipStart, .existingMove, .custom])
        XCTAssertEqual(model.rangeStart, frames(60))
        XCTAssertEqual(model.durationFrames, 150)
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:06:29")
        XCTAssertEqual(model.rangeCaption, "Editing the move from 00:00:02:00 to 00:00:06:29")
        XCTAssertEqual(model.interpolation, .easeIn, "the move's own smoothing")
        XCTAssertTrue(model.isDurationEditable, "a typed duration makes it Custom")
        for (rect, expected) in [(model.start, CGRect(x: 240, y: 135, width: 1440, height: 810)),
                                 (model.end, CGRect(x: 960, y: 540, width: 960, height: 540))] {
            XCTAssertEqual(rect.minX, expected.minX, accuracy: 1e-6)
            XCTAssertEqual(rect.minY, expected.minY, accuracy: 1e-6)
            XCTAssertEqual(rect.width, expected.width, accuracy: 1e-6)
        }

        // Apply after moving the red rectangle to the top-left quarter: the keyframes keep their
        // times and the start values; only the end values change.
        model.move(.end, from: model.end, by: CGSize(width: -960, height: -540))
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        let edited = try clip(id)
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            let before = applied.keyframes(for: parameter)
            let after = edited.keyframes(for: parameter)
            XCTAssertEqual(after.map(\.sourceTime), before.map(\.sourceTime), "\(parameter.rawValue): times kept")
            XCTAssertEqual(after.first?.value ?? .nan, before.first?.value ?? 0, accuracy: 1e-9, "start value kept")
            XCTAssertEqual(after.first?.interpolation, .easeIn)
        }
        XCTAssertEqual(edited.keyframes(for: .positionX).last?.value ?? 0, 960, accuracy: 1e-6, "was -960")
        XCTAssertEqual(edited.keyframes(for: .positionY).last?.value ?? 0, 540, accuracy: 1e-6, "was -540")
        XCTAssertEqual(edited.keyframes(for: .scale).last?.value ?? 0, 2, accuracy: 1e-9, "the same size")
        XCTAssertEqual(edited.motion(at: frames(20)).scale, applied.motion(at: frames(20)).scale, accuracy: 1e-12,
                       "the start framing still holds before the move")
    }

    func testSeveralMovesAreEditedAsOneSpanAndTheCaptionSaysSo() async throws {
        let id = try await longClip()
        XCTAssertTrue(store.engine.applyKenBurns(clip: id, start: VEMotionFraming(x: 0, y: 0, scale: 1),
                                                 end: VEMotionFraming(x: -960, y: -540, scale: 2),
                                                 interpolation: .linear, from: .zero, duration: frames(150)).ok)
        XCTAssertTrue(store.engine.applyKenBurns(clip: id, start: VEMotionFraming(x: -960, y: -540, scale: 2),
                                                 end: VEMotionFraming(x: 0, y: 0, scale: 1.5),
                                                 interpolation: .easeOut, from: frames(200), duration: frames(100)).ok)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .move(KenBurnsModel.ExistingMove(first: 0, last: 299, hasKeyframesBetween: true,
                                                                         interpolation: .linear)))
        XCTAssertEqual(model.rangeCaption,
                       "Editing the move from 00:00:00:00 to 00:00:09:29; keyframes in between are replaced")
        XCTAssertEqual(model.interpolation, .linear, "the first keyframe's smoothing")
        XCTAssertEqual(model.end.width, 1280, accuracy: 1e-6, "the framing on the last frame (150 %)")
        XCTAssertTrue(store.applyKenBurns())
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            XCTAssertEqual(try clip(id).keyframes(for: parameter).map(\.frameTime), [frames(0), frames(299)])
        }
    }

    func testAClipWithoutAMoveOpensOnTheWholeClipPushIn() async throws {
        let id = try await placedClip()
        // Rotation keyframes and keyframes all on one frame are not a move.
        store.playheadTime = frames(10)
        inspector.toggleKeyframe(.rotation)
        store.playheadTime = frames(40)
        inspector.setValue(.rotation, 0)
        XCTAssertEqual(try clip(id).keyframes(for: .rotation).count, 2)
        store.beginKenBurns(clip: id)
        var model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .none)
        XCTAssertEqual(model.range, .wholeClip)
        XCTAssertEqual(model.rangeChoices, [.wholeClip, .fromPlayhead, .fromClipStart, .custom],
                       "no Existing move to offer")
        XCTAssertEqual(model.interpolation, .easeInOut)
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.end.width, 1920 * KenBurnsModel.defaultEndFraction, accuracy: 1e-9, "the push in")
        XCTAssertNil(model.rangeCaption)
        store.cancelKenBurns()

        store.playheadTime = frames(30)
        inspector.toggleKeyframe(.scale)
        inspector.toggleKeyframe(.positionX)
        store.beginKenBurns(clip: id)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .none, "keyframes on a single frame")
        XCTAssertEqual(model.range, .wholeClip)
    }

    func testAMoveHiddenByATrimFallsBackToTheWholeClipAndSaysWhy() async throws {
        let id = try await placedClip()
        XCTAssertTrue(store.engine.applyKenBurns(clip: id, start: VEMotionFraming(x: 0, y: 0, scale: 1),
                                                 end: VEMotionFraming(x: -960, y: -540, scale: 2),
                                                 interpolation: .easeInOut).ok)
        XCTAssertTrue(store.engine.trimClipHead(id, to: frames(10), clamp: false).ok)
        XCTAssertTrue(store.engine.trimClipTail(id, to: frames(50), clamp: false).ok)
        XCTAssertTrue(try clip(id).keyframes(for: .scale).allSatisfy { !$0.isInsideClip }, "both hidden")
        store.selection = [id]
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .hiddenOnly)
        XCTAssertEqual(model.range, .wholeClip)
        XCTAssertEqual(model.rangeCaption, KenBurnsModel.hiddenMoveCaption)
        XCTAssertFalse(model.rangeChoices.contains(.existingMove))
        XCTAssertEqual(model.rangeTimecodes, "00:00:00:10 – 00:00:01:19")
        // The whole clip reaches both ends: Apply replaces the hidden keyframes.
        XCTAssertTrue(store.applyKenBurns())
        let keys = try clip(id).keyframes(for: .scale)
        XCTAssertEqual(keys.map(\.frameTime), [frames(10), frames(49)])
        XCTAssertTrue(keys.allSatisfy(\.isInsideClip))
    }

    func testTheExistingMoveFollowsModelChangesWhileTheHelperIsOpen() async throws {
        let id = try await longClip()
        try applyPartialMove(id)
        // A smoothing the helper does not offer is not taken.
        XCTAssertTrue(store.engine.setKeyframeInterpolation(.hold, parameter: .positionX, clip: id, at: frames(60)).ok)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertNotNil(model.existingMove)
        XCTAssertNil(model.existingMove?.interpolation)
        XCTAssertEqual(model.interpolation, .easeInOut, "Hold is not offered: the default")
        // The end keyframes move two frames earlier (all three parameters): the range follows.
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            XCTAssertTrue(store.engine.moveKeyframe(clip: id, parameter: parameter, from: frames(209),
                                                    to: frames(207)).ok)
        }
        XCTAssertTrue(store.kenBurns === model)
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:06:27")
        // Undone back to no move at all: the range falls back to the whole clip.
        while try clip(id).hasKeyframes, store.canUndo { store.undo() }
        XCTAssertFalse(try clip(id).hasKeyframes)
        XCTAssertEqual(model.detection, .none)
        XCTAssertEqual(model.range, .wholeClip)
        XCTAssertFalse(model.rangeChoices.contains(.existingMove))
    }

    // MARK: Ken Burns: Custom range

    /// The long movie (300 frames) on V1 at 2 s, i.e. timeline frames 60...359, selected alone.
    private func longClipAtTwoSeconds() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 300)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let id = try fixture.placeMovie(try XCTUnwrap(imported.first), at: 2)
        store.selection = [id]
        XCTAssertEqual(try clip(id).timelineStart, frames(60))
        return id
    }

    func testStartAndEndFieldsShowTimelineTimesAndParseLikeTheDurationField() async throws {
        let id = try await longClipAtTwoSeconds()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        // Whole clip: the fields show the timeline times of its first and last frames (the ruler's).
        XCTAssertEqual(model.startText, "00:00:02:00")
        XCTAssertEqual(model.endText, "00:00:11:29")
        XCTAssertFalse(model.hasUncommittedText)
        // Every duration form, as a timeline time: timecode, short timecode, frames, seconds.
        for (typed, frame) in [("00:00:05:00", Int64(150)), ("4:15", 135), ("200f", 200), ("3.5s", 105), ("90", 90)] {
            model.startText = typed
            XCTAssertTrue(model.hasUncommittedText, typed)
            XCTAssertTrue(model.commitStart(), typed)
            XCTAssertEqual(model.range, .custom, typed)
            XCTAssertEqual(model.rangeStart, frames(frame), typed)
            XCTAssertEqual(model.rangeLastFrame, frames(359), "\(typed): the end is kept")
            XCTAssertEqual(model.startText, store.durationString(frames: frame), "shown in the project's format")
            XCTAssertNil(model.rangeNote, typed)
            XCTAssertFalse(model.hasUncommittedText, typed)
        }
        model.endText = "00:00:08:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(model.rangeTimecodes, "00:00:03:00 – 00:00:08:00")
        XCTAssertEqual(model.durationFrames, 151)
        XCTAssertEqual(model.durationText, "00:00:05:01")
        XCTAssertEqual(model.rangeCaption, KenBurnsModel.holdCaption)
        // Not a time: refused with a reason, the range stays.
        model.endText = "later"
        XCTAssertFalse(model.commitEnd())
        XCTAssertEqual(model.rangeNote?.contains("is not a time"), true)
        XCTAssertEqual(model.rangeLastFrame, frames(240))
        // Unchanged text changes nothing (no mode switch from another range).
        model.range = .fromClipStart
        model.startText = model.startString
        XCTAssertTrue(model.commitStart())
        XCTAssertEqual(model.range, .fromClipStart)

        // The frames display: a bare number is frames, shown as "150f".
        var reason = ""
        let asset = try XCTUnwrap(store.asset(try clip(id).assetID))
        let framesModel = try XCTUnwrap(KenBurnsModel(clip: try clip(id), asset: asset, sequence: store.sequence,
                                                      playhead: .zero, durationDisplay: .frames, reason: &reason))
        XCTAssertEqual(framesModel.startText, "60f")
        framesModel.endText = "300"
        XCTAssertTrue(framesModel.commitEnd())
        XCTAssertEqual(framesModel.rangeLastFrame, frames(300))
        XCTAssertEqual(framesModel.endText, "300f")
    }

    func testTypedStartAndEndAreClampedToTheClipAndTwoFrames() async throws {
        let id = try await longClipAtTwoSeconds()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.startText = "00:00:00:10"
        XCTAssertTrue(model.commitStart())
        XCTAssertEqual(model.rangeStart, frames(60))
        XCTAssertEqual(model.rangeNote, "Limited to the clip's first frame, 00:00:02:00.")
        model.endText = "00:01:00:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(model.rangeLastFrame, frames(359))
        XCTAssertEqual(model.rangeNote, "Limited to the clip's last frame, 00:00:11:29.")
        model.endText = "00:00:06:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertNil(model.rangeNote, "taken as typed")
        // A start at or after the end stops a frame before it; an end at or before the start a
        // frame after it (a move is at least two frames).
        model.startText = "00:00:09:00"
        XCTAssertTrue(model.commitStart())
        XCTAssertEqual(model.rangeStart, frames(179))
        XCTAssertEqual(model.rangeLastFrame, frames(180))
        XCTAssertEqual(model.rangeNote,
                       "A move is at least two frames long: the start is 00:00:05:29, a frame before the end.")
        model.endText = "00:00:01:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(model.rangeLastFrame, frames(180))
        XCTAssertEqual(model.rangeNote,
                       "A move is at least two frames long: the end is 00:00:06:00, a frame after the start.")
        XCTAssertEqual(model.durationFrames, 2)
        XCTAssertNil(model.rangeProblem)
        // A typed duration in Custom moves the end, within what is left of the clip.
        model.durationText = "20s"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.rangeLastFrame, frames(359))
        XCTAssertEqual(model.rangeNote, "Limited to the 00:00:06:01 left in the clip.")
        // A trim while the helper is open keeps the span inside the clip.
        XCTAssertTrue(store.engine.trimClipTail(id, to: frames(200), clamp: false).ok)
        XCTAssertTrue(store.kenBurns === model)
        XCTAssertEqual(model.rangeTimecodes, "00:00:05:29 – 00:00:06:19")
    }

    func testTypingInAFieldSwitchesToCustomFromEveryRange() async throws {
        let id = try await longClipAtTwoSeconds()
        store.playheadTime = frames(100)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        // From playhead: the fields show its computed range and stay editable; an edit keeps the
        // other end.
        model.range = .fromPlayhead
        XCTAssertEqual(model.startText, "00:00:03:10")
        XCTAssertEqual(model.endText, "00:00:08:09")
        model.endText = "00:00:07:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(model.range, .custom)
        XCTAssertEqual(model.rangeTimecodes, "00:00:03:10 – 00:00:07:00")
        // The playhead no longer moves a Custom range.
        model.setPlayhead(frames(200))
        XCTAssertEqual(model.rangeTimecodes, "00:00:03:10 – 00:00:07:00")
        // Choosing Custom in the menu keeps the current range.
        model.range = .fromClipStart
        model.range = .custom
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:06:29")
        // Existing move: a typed duration keeps its start.
        XCTAssertTrue(store.applyKenBurns())
        store.beginKenBurns(clip: id)
        let again = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(again.range, .existingMove)
        again.durationText = "2s"
        XCTAssertTrue(again.commitDuration())
        XCTAssertEqual(again.range, .custom)
        XCTAssertEqual(again.rangeTimecodes, "00:00:02:00 – 00:00:03:29")
        // Whole clip: a typed start keeps the clip's last frame as the end.
        again.range = .wholeClip
        again.startText = "00:00:10:00"
        XCTAssertTrue(again.commitStart())
        XCTAssertEqual(again.rangeTimecodes, "00:00:10:00 – 00:00:11:29")
    }

    func testApplyWithATypedRangePutsTheKeyframesOnExactlyThoseFrames() async throws {
        let id = try await longClipAtTwoSeconds()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.startText = "00:00:04:10"
        XCTAssertTrue(model.commitStart())
        // Return with the End still being typed commits it and does not press Apply; Apply (the
        // button) takes a value still being typed.
        model.endText = "00:00:07:05"
        XCTAssertTrue(model.hasUncommittedText, "Return commits the field instead of pressing Apply")
        XCTAssertTrue(store.applyKenBurns())
        let info = try clip(id)
        for parameter: VEMotionParameter in [.positionX, .positionY, .scale] {
            XCTAssertEqual(info.keyframes(for: parameter).map(\.frameTime), [frames(130), frames(215)])
        }
        // A start being typed that is not a time refuses Apply and keeps the helper open.
        store.beginKenBurns(clip: id)
        let again = try XCTUnwrap(store.kenBurns)
        again.startText = "soon"
        XCTAssertFalse(store.applyKenBurns())
        XCTAssertNotNil(store.kenBurns)
        XCTAssertEqual(store.statusMessage?.contains("is not a time"), true)
    }

    // MARK: Ken Burns: the range in the timeline

    func testTheTimelineMarksTheRangeWhileTheHelperIsOpen() async throws {
        let id = try await longClipAtTwoSeconds()
        let band = store.kenBurnsBand
        XCTAssertNil(band.range, "no helper, no band")
        store.playheadTime = frames(100)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        // Whole clip: from the start of its first frame to the end of its last.
        XCTAssertEqual(band.range, KenBurnsBandRange(clipID: id, start: 2, end: 12))
        // From playhead: follows the playhead, and hides while the playhead is off the clip.
        model.range = .fromPlayhead
        XCTAssertEqual(band.range, KenBurnsBandRange(clipID: id, start: 100.0 / 30, end: 250.0 / 30))
        model.setPlayhead(frames(130))
        XCTAssertEqual(band.range?.start ?? 0, 130.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(band.range?.end ?? 0, 280.0 / 30, accuracy: 1e-12)
        model.setPlayhead(frames(20))
        XCTAssertNil(band.range, "nothing to apply: no band")
        // Custom: follows typing.
        model.startText = "00:00:04:00"
        XCTAssertTrue(model.commitStart())
        model.endText = "00:00:05:29"
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(band.range, KenBurnsBandRange(clipID: id, start: 4, end: 6))

        // Geometry: the clip's row, x through the timeline model at its zoom and scroll.
        store.pixelsPerSecond = 80
        store.scrollX = 40
        let timeline = store.timelineModel
        let range = try XCTUnwrap(band.range)
        let rect = try XCTUnwrap(KenBurnsBandView.rect(for: range, in: timeline))
        let row = try XCTUnwrap(timeline.layout(forTrack: try clip(id).trackID))
        XCTAssertEqual(rect.minX, timeline.x(forTime: 4), accuracy: 1e-9)
        XCTAssertEqual(rect.minX, 4 * 80 - 40, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX, timeline.x(forTime: 6), accuracy: 1e-9)
        XCTAssertEqual(rect.minY, row.y - timeline.scrollY)
        XCTAssertEqual(rect.height, row.height)
        XCTAssertNil(KenBurnsBandView.rect(for: KenBurnsBandRange(clipID: 9999, start: 0, end: 1), in: timeline))

        // Hidden when the helper closes: Cancel, Apply, and a selection that drops the clip.
        store.cancelKenBurns()
        XCTAssertNil(band.range)
        store.beginKenBurns(clip: id)
        XCTAssertNotNil(band.range)
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertNil(band.range)
        store.beginKenBurns(clip: id)
        XCTAssertEqual(band.range, KenBurnsBandRange(clipID: id, start: 2, end: 12),
                       "the existing move: the whole clip")
        store.selection = []
        XCTAssertNil(band.range)
    }

    // MARK: Neighbour matching

    /// V1: A [0, 60), B [60, 120) touching it, C [150, 210) after a gap. B is selected.
    private func neighbours() async throws -> (a: VEClipID, b: VEClipID, c: VEClipID) {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 2)
        let c = try fixture.placeMovie(movie, at: 5)
        store.selection = [b]
        return (a, b, c)
    }

    func testMatchIsEnabledNextToATouchingClip() async throws {
        let (a, b, c) = try await neighbours()
        XCTAssertEqual(store.adjacentClip(to: b, at: .start)?.clipID, a)
        XCTAssertNil(store.adjacentClip(to: b, at: .end), "a gap")
        XCTAssertTrue(inspector.canMatch(.start))
        XCTAssertFalse(inspector.canMatch(.end))
        store.selection = [a]
        XCTAssertFalse(inspector.canMatch(.start))
        XCTAssertTrue(inspector.canMatch(.end))
        store.selection = [c]
        XCTAssertFalse(inspector.canMatch(.start))
        XCTAssertFalse(inspector.canMatch(.end))
        store.selection = [a, b]
        XCTAssertFalse(inspector.canMatch(.start), "a single video clip only")
        XCTAssertFalse(inspector.canMatch(.end))
    }

    func testMatchingCopiesTheNeighboursFramingAsStaticValuesOrKeyframes() async throws {
        let (a, b, _) = try await neighbours()
        let placed = VEVideoParams(x: 100, y: -20, scale: 1.5, rotationDegrees: 10, opacity: 0.5)
        XCTAssertTrue(store.engine.setVideoParams(placed, forClip: a).ok)

        // An unanimated clip: static values.
        inspector.matchAdjacent(.start)
        XCTAssertEqual(store.undoActionName, "Match Previous Clip")
        XCTAssertEqual(inspector.message, "Matched the previous clip's end: set as this clip's static values.")
        let matched = try clip(b).videoParams
        XCTAssertEqual(matched.x, 100)
        XCTAssertEqual(matched.y, -20)
        XCTAssertEqual(matched.scale, 1.5)
        XCTAssertEqual(matched.rotationDegrees, 10)
        XCTAssertEqual(matched.opacity, 0.5)
        store.undo()
        XCTAssertEqual(try clip(b).videoParams.x, 0, "one undo step")

        // An animated clip: a keyframe on its first frame for what it animates.
        store.playheadTime = frames(60)
        inspector.toggleKeyframe(.opacity)
        store.playheadTime = frames(100)
        inspector.setValue(.opacity, 20)
        inspector.matchAdjacent(.start)
        XCTAssertEqual(inspector.message, "Matched the previous clip's end: Opacity got keyframes on this clip's "
            + "first frame; Position X, Position Y, Scale and Rotation became static values.")
        let opacity = try clip(b).keyframes(for: .opacity)
        XCTAssertEqual(opacity.map(\.frameTime), [frames(60), frames(100)])
        XCTAssertEqual(opacity[0].value, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try clip(b).motion(at: frames(60)).scale, 1.5)
        XCTAssertEqual(try clip(b).motion(at: frames(100)).opacity, 0.2, accuracy: 1e-12, "the rest stays")

        // The next clip's start onto A's last frame: B starts exactly as A is, so nothing changes.
        store.selection = [a]
        inspector.matchAdjacent(.end)
        XCTAssertEqual(inspector.message, "This clip already matches the next clip's start.")
        XCTAssertEqual(store.undoActionName, "Match Previous Clip", "no undo step")
        // With A turned back, it takes B's first frame again (A is static: static values).
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParamsIdentity(), forClip: a).ok)
        inspector.matchAdjacent(.end)
        XCTAssertEqual(store.undoActionName, "Match Next Clip")
        XCTAssertEqual(try clip(a).videoParams.opacity, 0.5, accuracy: 1e-12, "B's first frame")
        XCTAssertEqual(try clip(a).videoParams.x, 100)
        XCTAssertEqual(try clip(a).videoParams.rotationDegrees, 10)
    }

    func testMatchingFollowsAnAnimatedNeighbourAndIsRefusedDuringAGesture() async throws {
        let (a, b, _) = try await neighbours()
        let end = VEMotionFraming(x: -120, y: 60, scale: 1.8)
        XCTAssertTrue(store.engine.applyKenBurns(clip: a, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: end,
                                                 interpolation: .easeInOut).ok)
        // During a slider drag nothing happens, with a reason.
        store.selection = [b]
        inspector.beginSliderDrag(.rotation)
        XCTAssertTrue(store.isGestureActive)
        inspector.matchAdjacent(.start)
        XCTAssertEqual(inspector.message, "Finish the current drag first.")
        XCTAssertEqual(try clip(b).videoParams.scale, 1)
        inspector.endSliderDrag()
        inspector.matchAdjacent(.start)
        let first = try clip(b).motion(at: frames(60))
        XCTAssertEqual(first.x, -120, accuracy: 1e-9, "A's last frame")
        XCTAssertEqual(first.y, 60, accuracy: 1e-9)
        XCTAssertEqual(first.scale, 1.8, accuracy: 1e-12)
    }

    func testKenBurnsContinuesFromAnAnimatedPreviousClipAndLeadsIntoTheNext() async throws {
        let (a, b, _) = try await neighbours()
        let (movie, _) = try await fixture.importMedia()
        let d = try fixture.placeMovie(movie, at: 4) // touches B's end: [120, 180)
        store.selection = [b]

        // Unmoved neighbours: both off, the push in as before.
        store.beginKenBurns(clip: b)
        var model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.previous?.clipID, a)
        XCTAssertEqual(model.next?.clipID, d)
        XCTAssertFalse(model.continuesFromPrevious)
        XCTAssertFalse(model.leadsIntoNext)
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.end.width, 1920 * KenBurnsModel.defaultEndFraction, accuracy: 1e-9)
        store.cancelKenBurns()

        // A pushes into its bottom-right quarter; D starts at 150 %.
        XCTAssertTrue(store.engine.applyKenBurns(clip: a, start: VEMotionFraming(x: 0, y: 0, scale: 1),
                                                 end: VEMotionFraming(x: -960, y: -540, scale: 2),
                                                 interpolation: .easeInOut).ok)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: d).ok)
        store.beginKenBurns(clip: b)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(model.continuesFromPrevious, "the previous clip is animated")
        XCTAssertTrue(model.leadsIntoNext, "the next clip is not at the identity")
        XCTAssertEqual(model.start.minX, 960, accuracy: 1e-6, "A's end framing")
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6)
        XCTAssertEqual(model.end.width, 1280, accuracy: 1e-6, "D's 150 %")
        XCTAssertEqual(model.end.midX, 960, accuracy: 1e-6)
        XCTAssertNil(model.neighbourNote)
        // Off: the default comes back; on again: the neighbour's framing, even after a drag.
        model.continuesFromPrevious = false
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        model.move(.start, from: model.start, by: CGSize(width: 0, height: 0))
        model.continuesFromPrevious = true
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6)
        // Applied, B starts where A ends and ends where D starts.
        XCTAssertTrue(store.applyKenBurns())
        let info = try clip(b)
        XCTAssertEqual(info.motion(at: frames(60)).x, try clip(a).motion(at: frames(59)).x, accuracy: 1e-6)
        XCTAssertEqual(info.motion(at: frames(60)).scale, 2, accuracy: 1e-9)
        XCTAssertEqual(info.motion(at: frames(119)).scale, 1.5, accuracy: 1e-9)

        // A neighbour that goes away turns its toggle off.
        store.beginKenBurns(clip: b)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(model.leadsIntoNext)
        XCTAssertTrue(store.engine.removeClips([NSNumber(value: d)]).ok)
        XCTAssertNil(model.next)
        XCTAssertFalse(model.leadsIntoNext)
    }

    // MARK: Keyframe controls and Add Motion Keyframe

    /// The user's sequence (Part 3 bug): the controls are drawn only from `keyframeControlState`, so
    /// each step must change it, and the engine must agree.
    func testKeyframeControlStateFollowsEveryEdit() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(10)
        let initial = try XCTUnwrap(inspector.keyframeControlState(.positionX))
        XCTAssertEqual(initial, KeyframeControlState())

        inspector.toggleKeyframe(.positionX)
        let added = try XCTUnwrap(inspector.keyframeControlState(.positionX))
        XCTAssertTrue(added.hasKeyframeAtPlayhead)
        XCTAssertTrue(added.isAnimated)
        XCTAssertEqual(added.interpolation, .linear)
        XCTAssertNotEqual(added, initial, "the diamond's input changed")

        // Toggled off again: the engine and the controls both lose it.
        inspector.toggleKeyframe(.positionX)
        XCTAssertEqual(store.undoActionName, "Delete Keyframe")
        XCTAssertFalse(try clip(id).isAnimated(.positionX))
        XCTAssertNil(inspector.keyframeAtPlayhead(.positionX))
        XCTAssertEqual(inspector.keyframeControlState(.positionX), KeyframeControlState())

        // Another parameter's diamond.
        inspector.toggleKeyframe(.scale)
        XCTAssertTrue(try clip(id).isAnimated(.scale))
        XCTAssertEqual(inspector.keyframeControlState(.scale)?.hasKeyframeAtPlayhead, true)
        XCTAssertEqual(inspector.keyframeControlState(.positionX)?.hasKeyframeAtPlayhead, false)

        // The interpolation sticks and reads back.
        inspector.setInterpolation(.easeInOut, for: .scale)
        XCTAssertEqual(store.undoActionName, "Change Keyframe Interpolation")
        XCTAssertEqual(inspector.interpolation(.scale), .easeInOut)
        XCTAssertEqual(inspector.keyframeControlState(.scale)?.interpolation, .easeInOut)
        XCTAssertEqual(try clip(id).keyframes(for: .scale).first?.interpolation, .easeInOut)

        // Previous/next availability follows the playhead.
        store.playheadTime = frames(30)
        XCTAssertEqual(inspector.keyframeControlState(.scale),
                       KeyframeControlState(hasKeyframeAtPlayhead: false, interpolation: nil, isAnimated: true,
                                            hasPrevious: true, hasNext: false))
        store.selection = []
        XCTAssertNil(inspector.keyframeControlState(.scale), "no controls without a single video clip")
    }

    func testControlKIsAddMotionKeyframe() {
        XCTAssertEqual(KeyboardController.action(keyCode: 40, characters: "k", modifiers: .control), .toggleMotionKeyframes)
        XCTAssertEqual(KeyboardController.action(keyCode: 40, characters: "k", modifiers: []), .shuttleStop)
        XCTAssertNil(KeyboardController.action(keyCode: 40, characters: "k", modifiers: .command), "Split: the menu's")
        XCTAssertNil(KeyboardController.action(keyCode: 40, characters: "k", modifiers: [.control, .shift]))
        XCTAssertFalse(KeyboardController.Action.toggleMotionKeyframes.isTransportOrCancel, "editor window only")
    }

    func testAddMotionKeyframeAddsTheMissingOnesOrRemovesAllInOneUndoStep() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(10)
        inspector.setValue(.opacity, 60)
        let keys = KeyboardController(store: store)
        keys.perform(.toggleMotionKeyframes, on: store)
        XCTAssertEqual(store.statusMessage, "Keyframes added on 5 parameters")
        XCTAssertEqual(store.undoActionName, "Add Keyframes")
        let parameters: [VEMotionParameter] = [.positionX, .positionY, .scale, .rotation, .opacity]
        for parameter in parameters {
            XCTAssertNotNil(try clip(id).keyframe(for: parameter, at: frames(10)), "\(parameter.rawValue)")
        }
        XCTAssertEqual(try clip(id).keyframe(for: .opacity, at: frames(10))?.value ?? 0, 0.6, accuracy: 1e-12)
        XCTAssertTrue(store.hasAllMotionKeyframesAtPlayhead(try clip(id)))

        keys.perform(.toggleMotionKeyframes, on: store)
        XCTAssertEqual(store.statusMessage, "Keyframes removed")
        XCTAssertFalse(try clip(id).hasKeyframes)
        XCTAssertEqual(try clip(id).videoParams.opacity, 0.6, accuracy: 1e-12, "the picture stays")
        store.undo()
        XCTAssertEqual(try clip(id).allKeyframes.count, 5, "one undo step")
        store.undo()
        XCTAssertFalse(try clip(id).hasKeyframes, "one undo step")

        // Some there already: only the missing ones.
        inspector.toggleKeyframe(.scale)
        store.toggleMotionKeyframes()
        XCTAssertEqual(store.statusMessage, "Keyframes added on 4 parameters")

        // Refusals say why.
        store.playheadTime = frames(90)
        store.toggleMotionKeyframes()
        XCTAssertEqual(store.statusMessage, "Move the playhead over the clip to work with its keyframes.")
        store.playheadTime = frames(20)
        inspector.beginSliderDrag(.rotation)
        store.toggleMotionKeyframes()
        XCTAssertEqual(store.statusMessage, "Finish the current drag first.")
        inspector.endSliderDrag()
        store.selection = []
        store.toggleMotionKeyframes()
        XCTAssertEqual(store.statusMessage, "Select a single video clip to add Motion keyframes.")
    }

    func testTheTimelinesContextMenuOffersAddMotionKeyframeOnAVideoClip() async throws {
        let id = try await placedClip()
        store.selection = []
        store.playheadTime = frames(15)
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let row = try XCTUnwrap(model.layout(forTrack: try clip(id).trackID))
        let point = CGPoint(x: model.x(forTime: 1), y: row.y + 20)
        var items = gestures.contextMenuItems(at: point)
        let add = try XCTUnwrap(items.first { $0.title == "Add Motion Keyframe  ⌃K" })
        XCTAssertTrue(add.isEnabled)
        add.action()
        XCTAssertEqual(try clip(id).allKeyframes.count, 5)
        items = gestures.contextMenuItems(at: point)
        let remove = try XCTUnwrap(items.first { $0.title == "Remove Motion Keyframes  ⌃K" })
        remove.action()
        XCTAssertFalse(try clip(id).hasKeyframes)
        // With the playhead off the clip the item is there but disabled.
        store.playheadTime = frames(100)
        items = gestures.contextMenuItems(at: point)
        XCTAssertEqual(items.first { $0.title == "Add Motion Keyframe  ⌃K" }?.isEnabled, false)
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

        // A drag that starts on a marker moves its keyframes (not the clip): 10 pt at 50 pt/s is 6
        // frames, so the keyframes shown by timeline frame 10 go to frame 16, source frame 32 at 2x.
        gestures.changed(location: center, startLocation: center, modifiers: [])
        gestures.changed(location: CGPoint(x: center.x + 10, y: center.y), startLocation: center, modifiers: [])
        gestures.ended()
        XCTAssertEqual(try clip(id).timelineStart, .zero, "the clip stays")
        XCTAssertEqual(store.undoActionName, "Move Keyframes")
        XCTAssertEqual(try clip(id).keyframes(for: .scale).map(\.sourceTime), [frames(0), frames(32)])
        XCTAssertEqual(try clip(id).keyframes(for: .opacity).map(\.sourceTime), [frames(32)])
        XCTAssertEqual(try XCTUnwrap(store.timelineModel.clip(id: id)).keyframes.last ?? 0, 16.0 / 30.0, accuracy: 1e-9)
    }

    /// V1: the movie at 0 s (60 frames) with scale keyed on frames 0 and 20, opacity on 20 (one
    /// marker for both) and rotation on 40; the gesture controller and the marker on frame 20.
    private func markedClip() async throws -> (id: VEClipID, gestures: TimelineGestureController, marker: CGPoint) {
        let id = try await placedClip()
        for frame: Int64 in [0, 20] {
            store.playheadTime = frames(frame)
            inspector.toggleKeyframe(.scale)
        }
        store.playheadTime = frames(20)
        inspector.toggleKeyframe(.opacity)
        store.playheadTime = frames(40)
        inspector.toggleKeyframe(.rotation)
        let model = store.timelineModel
        let timelineClip = try XCTUnwrap(model.clip(id: id))
        XCTAssertEqual(timelineClip.keyframes.count, 3)
        let marker = try XCTUnwrap(model.keyframeMarkerCenter(forClip: timelineClip, time: 20.0 / 30.0))
        XCTAssertEqual(model.hitTest(marker), .keyframe(id, 20.0 / 30.0))
        return (id, TimelineGestureController(store: store), marker)
    }

    /// Frame starts of `parameter`'s keyframes.
    private func keyedFrames(_ id: VEClipID, _ parameter: VEMotionParameter) throws -> [CMTime] {
        try clip(id).keyframes(for: parameter).map(\.frameTime)
    }

    func testDraggingAMarkerMovesItsKeyframesTogetherAsOneUndoStep() async throws {
        let (id, gestures, marker) = try await markedClip()
        let frame = 50.0 / 30.0 // points per frame at 50 pt/s
        gestures.changed(location: marker, startLocation: marker, modifiers: [])
        gestures.changed(location: CGPoint(x: marker.x + 4 * frame, y: marker.y + 30), startLocation: marker,
                         modifiers: [])
        XCTAssertTrue(store.isGestureActive, "other commands wait for the drag")
        XCTAssertEqual(store.statusMessage, "Keyframes at 00:00:00:24")
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(24)], "horizontal only")
        gestures.changed(location: CGPoint(x: marker.x + 10 * frame, y: marker.y), startLocation: marker, modifiers: [])
        XCTAssertEqual(store.statusMessage, "Keyframes at 00:00:01:00")
        gestures.ended()
        XCTAssertFalse(store.isGestureActive)
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(30)])
        XCTAssertEqual(try keyedFrames(id, .opacity), [frames(30)])
        XCTAssertEqual(try keyedFrames(id, .rotation), [frames(40)], "another marker's keyframe stays")
        XCTAssertEqual(try clip(id).keyframes(for: .scale).last?.value ?? 0, 1, accuracy: 1e-12, "values kept")
        XCTAssertEqual(store.undoActionName, "Move Keyframes")
        XCTAssertEqual(try clip(id).timelineStart, .zero)
        store.undo()
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(20)], "one undo step")
        XCTAssertEqual(try keyedFrames(id, .opacity), [frames(20)])

        // A single parameter's marker ("Move Keyframe"); the cursor over a marker is the sideways one.
        let model = store.timelineModel
        let rotation = try XCTUnwrap(model.keyframeMarkerCenter(forClip: try XCTUnwrap(model.clip(id: id)),
                                                                time: 40.0 / 30.0))
        var cursors: [TimelineGestureController.PointerCursor] = []
        gestures.applyCursor = { cursors.append($0) }
        gestures.hover(at: rotation)
        XCTAssertEqual(cursors, [.resizeLeftRight])
        gestures.hover(at: nil)
        gestures.changed(location: rotation, startLocation: rotation, modifiers: [])
        gestures.changed(location: CGPoint(x: rotation.x - 5 * frame, y: rotation.y), startLocation: rotation,
                         modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.undoActionName, "Move Keyframe")
        XCTAssertEqual(store.statusMessage, "Keyframe at 00:00:01:05")
        XCTAssertEqual(try keyedFrames(id, .rotation), [frames(35)])
    }

    func testAMarkerDragStopsAtItsNeighboursAndTheClipsEndsAndEscapeRevertsIt() async throws {
        let (id, gestures, marker) = try await markedClip()
        // Left: scale's keyframe on frame 0 stops the group a frame after it.
        gestures.changed(location: marker, startLocation: marker, modifiers: [])
        gestures.changed(location: CGPoint(x: marker.x - 300, y: marker.y), startLocation: marker, modifiers: [])
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(1)])
        XCTAssertEqual(store.statusMessage, "Keyframes at 00:00:00:01 (as far as they go: keyframes stay in order, "
            + "a frame apart, on the clip's frames)")
        // Right: nothing follows on scale or opacity, so the clip's last frame (rotation's keyframe on
        // frame 40 belongs to another parameter).
        gestures.changed(location: CGPoint(x: marker.x + 300, y: marker.y), startLocation: marker, modifiers: [])
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(59)])
        XCTAssertEqual(try keyedFrames(id, .opacity), [frames(59)])
        // Escape puts them back; the rest of the gesture is ignored.
        gestures.cancel()
        XCTAssertEqual(gestures.drag, .cancelled)
        XCTAssertFalse(store.isGestureActive)
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(20)])
        XCTAssertEqual(try keyedFrames(id, .opacity), [frames(20)])
        gestures.changed(location: CGPoint(x: marker.x + 40, y: marker.y), startLocation: marker, modifiers: [])
        gestures.ended()
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(20)])
        XCTAssertEqual(gestures.drag, .idle)

        // The marker on frame 0: the clip's first frame stops it on the left.
        let model = store.timelineModel
        let first = try XCTUnwrap(model.keyframeMarkerCenter(forClip: try XCTUnwrap(model.clip(id: id)), time: 0))
        let changes = store.changeCount
        gestures.changed(location: first, startLocation: first, modifiers: [])
        gestures.changed(location: CGPoint(x: first.x - 40, y: first.y), startLocation: first, modifiers: [])
        gestures.ended()
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(20)], "already on the first frame")
        XCTAssertEqual(store.changeCount, changes, "no edit, no undo step")
        XCTAssertEqual(store.undoActionName, "Add Keyframe")

        // A click without movement still moves the playhead and selects the clip.
        store.playheadTime = frames(50)
        store.selection = []
        gestures.changed(location: marker, startLocation: marker, modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.playheadTime, frames(20))
        XCTAssertEqual(store.selection, [id])

        // A locked track: the drag is refused with the reason, the keyframes stay.
        let track = try clip(id).trackID
        XCTAssertTrue(store.engine.setTrack(track, locked: true).ok)
        gestures.changed(location: marker, startLocation: marker, modifiers: [])
        gestures.changed(location: CGPoint(x: marker.x + 20, y: marker.y), startLocation: marker, modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.statusMessage?.hasSuffix("is locked."), true)
        XCTAssertEqual(try keyedFrames(id, .scale), [frames(0), frames(20)])
    }

    func testTheKenBurnsRangeFollowsItsKeyframesDraggedInTheTimeline() async throws {
        let id = try await longClip()
        try applyPartialMove(id) // frames 60...209
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.range, .existingMove)
        let end = model.end
        let timeline = store.timelineModel
        let marker = try XCTUnwrap(timeline.keyframeMarkerCenter(forClip: try XCTUnwrap(timeline.clip(id: id)),
                                                                 time: 209.0 / 30.0))
        let gestures = TimelineGestureController(store: store)
        gestures.changed(location: marker, startLocation: marker, modifiers: [])
        gestures.changed(location: CGPoint(x: marker.x + 50, y: marker.y), startLocation: marker, modifiers: [])
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:07:29", "follows while dragging")
        XCTAssertEqual(store.kenBurnsBand.range?.end ?? 0, 8, accuracy: 1e-9, "and so does the band")
        gestures.ended()
        XCTAssertTrue(store.kenBurns === model, "the helper stays open")
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:07:29")
        XCTAssertEqual(model.end.minX, end.minX, accuracy: 1e-6, "the end framing moved with its keyframes")
        XCTAssertEqual(model.end.width, end.width, accuracy: 1e-6)
    }

    func testClipsWithoutKeyframesHaveNoMarkers() async throws {
        let id = try await placedClip()
        XCTAssertEqual(store.timelineModel.clip(id: id)?.keyframes, [])
        let center = CGPoint(x: 20, y: 66 + 64 - 4)
        XCTAssertEqual(store.timelineModel.hitTest(center), .clipBody(id))
    }
}
