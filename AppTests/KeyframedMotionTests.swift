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
            XCTAssertNil(model.durationNote, typed)
            XCTAssertEqual(model.durationText, store.durationString(frames: expected), "shown in the project's format")
        }
        model.durationText = "soon"
        XCTAssertFalse(model.commitDuration())
        XCTAssertEqual(model.durationNote?.contains("not a duration"), true)
        XCTAssertEqual(model.durationFrames, 75, "unchanged")
        model.durationText = "1f"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.durationFrames, 2)
        XCTAssertEqual(model.durationNote, "A move is at least two frames long.")
        model.durationText = "20s"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.durationFrames, 300)
        XCTAssertEqual(model.durationNote, "Limited to the 00:00:10:00 left in the clip.")
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

        // The clip is animated now: the rectangles start from its framing at the range's ends.
        store.playheadTime = frames(200)
        store.beginKenBurns(clip: id)
        let second = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(second.end.minX, 960, accuracy: 1e-6, "whole clip: the framing on the last frame")
        XCTAssertEqual(second.start.width, 1920, accuracy: 1e-6, "and on the first")
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
