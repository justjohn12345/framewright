import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Motion in the app since Motion keyframes became effect spans (effect lanes round 1): the
/// inspector's Video rows edit the static values and its keyframe controls, Add Motion Keyframe and
/// the timeline's keyframe markers are inert (the effect lanes UI replaces them); the Ken Burns
/// helper's rectangles, the Motion span it applies (a clip's span over exactly the helper's range
/// is edited in place, else a new one is added on the first free lane) and its lifetime; matching a
/// neighbour. The movie is 2 s (60 frames) at 320x180 on a 1920x1080 30 fps sequence; the
/// timeline's geometry at the default zoom is 50 pt/s with V1 at y 66...130.
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

    /// The clip's Motion spans, in time order.
    private func motionSpans(_ id: VEClipID) -> [VEEffectSpan] {
        store.engine.spans(forClip: id).filter { $0.kind == .motion }.sorted { $0.start < $1.start }
    }

    /// The timeline ranges of the clip's Motion spans.
    private func motionRanges(_ id: VEClipID) -> [[CMTime]] {
        motionSpans(id).map { [$0.start, $0.end] }
    }

    /// A Ken Burns move straight through the engine: a Motion span on lane 1 over `range` (default:
    /// the whole clip) with the framings applied.
    @discardableResult
    private func kenBurns(_ id: VEClipID, start: VEMotionFraming, end: VEMotionFraming,
                          interpolation: VEKeyframeInterpolation, range: CMTimeRange? = nil) throws -> VEEffectSpan {
        let info = try clip(id)
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: range ?? CMTimeRange(start: info.timelineStart, end: info.timelineEnd))
        let span = try XCTUnwrap(added.span, added.message)
        XCTAssertTrue(store.engine.applyKenBurns(span: span.spanID, start: start, end: end,
                                                 interpolation: interpolation).ok)
        store.refreshModel()
        return try XCTUnwrap(store.engine.spanInfo(span.spanID))
    }

    /// The Motion an edge of `span` shows (the framings a Ken Burns move set).
    private func edgeMotion(_ id: VEClipID, _ span: VEEffectSpan, atEnd: Bool) throws -> VEVideoParams {
        var motion = VEVideoParams()
        XCTAssertTrue(try clip(id).getMotion(&motion, atEdgeOfSpan: span.spanID, atEnd: atEnd,
                                             frameDuration: store.frameDuration))
        return motion
    }

    /// The movie on V1 at 0 s, selected alone.
    private func placedClip() async throws -> VEClipID {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        return id
    }

    // MARK: Inspector

    func testTheVideoRowsEditStaticValuesAndTheKeyframeControlsAreInert() async throws {
        let id = try await placedClip()
        XCTAssertFalse(inspector.hasKeyframeControls(.scale), "Motion keyframes became effect spans")
        XCTAssertNil(inspector.keyframeControlState(.scale))

        // A value is the static value, wherever the playhead is.
        store.playheadTime = frames(10)
        inspector.setValue(.scale, 150)
        XCTAssertEqual(try clip(id).videoParams.scale, 1.5, accuracy: 1e-12)
        XCTAssertTrue(try clip(id).spans.isEmpty)

        // The keyframe actions change nothing and say why.
        let changes = store.changeCount
        for action in [{ self.inspector.toggleKeyframe(.scale) }, { self.inspector.setInterpolation(.hold, for: .scale) },
                       { self.inspector.removeAnimation(.scale) }] {
            store.statusMessage = nil
            action()
            XCTAssertEqual(inspector.message, InspectorModel.keyframesMovedMessage)
            XCTAssertEqual(store.statusMessage, InspectorModel.keyframesMovedMessage)
        }
        XCTAssertEqual(store.changeCount, changes)
        XCTAssertFalse(inspector.isAnimated(.scale))
        XCTAssertNil(inspector.interpolation(.scale))
        XCTAssertNil(inspector.previousKeyframeTime(.scale))
        XCTAssertNil(inspector.nextKeyframeTime(.scale))
        inspector.goToKeyframe(.scale, forward: true)
        XCTAssertEqual(store.playheadTime, frames(10))

        // With a Motion span on the clip the rows still show and edit the static values; the
        // picture composes the span onto them (scale multiplies).
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: CMTimeRange(start: .zero, duration: frames(60)))
        let span = try XCTUnwrap(added.span, added.message)
        var end = VESpanValuesUnchanged()
        end.scale = 2 // a factor on the static scale
        XCTAssertTrue(store.engine.setSpanValues(span.spanID, start: VESpanValuesUnchanged(), end: end).ok)
        store.refreshModel()
        XCTAssertEqual(span.lane, 1)
        store.playheadTime = frames(30)
        XCTAssertEqual(try XCTUnwrap(inspector.value(.scale)), 150, accuracy: 1e-9, "the static value")
        XCTAssertEqual(try clip(id).motion(at: frames(30)).scale, 1.5 * 1.5, accuracy: 1e-9, "halfway, linear")
        inspector.commitText(.scale, "200 %")
        XCTAssertEqual(try clip(id).videoParams.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(try clip(id).motion(at: frames(30)).scale, 2 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(motionSpans(id).count, 1, "the span stays")
    }

    func testASliderDragIsOneUndoStepOnTheStaticValue() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(30)
        inspector.beginSliderDrag(.opacity)
        for value in stride(from: 95.0, through: 40.0, by: -5.0) {
            inspector.sliderChanged(.opacity, value)
        }
        XCTAssertTrue(store.isGestureActive, "the drag's group blocks other commands")
        inspector.endSliderDrag()
        XCTAssertEqual(try clip(id).videoParams.opacity, 0.4, accuracy: 1e-12)
        XCTAssertTrue(try clip(id).spans.isEmpty)
        store.undo()
        XCTAssertEqual(try clip(id).videoParams.opacity, 1, accuracy: 1e-12, "one undo step")
    }

    func testSeveralClipsChangeTheirStaticValuesAndAVideoResetKeepsTheirSpans() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 3)
        try kenBurns(a, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: VEMotionFraming(x: 0, y: 0, scale: 2),
                     interpolation: .easeInOut)
        store.selection = [a, b]
        XCTAssertNil(inspector.motionTarget)
        inspector.setValue(.scale, 50) // a static value: applies to both, animated by a span or not
        XCTAssertEqual(try clip(a).videoParams.scale, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try clip(b).videoParams.scale, 0.5, accuracy: 1e-12)
        inspector.setValue(.opacity, 50)
        XCTAssertEqual(try clip(a).videoParams.opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try clip(b).videoParams.opacity, 0.5, accuracy: 1e-12)
        inspector.reset(.video)
        XCTAssertEqual(try clip(a).videoParams.opacity, 1)
        XCTAssertEqual(try clip(a).videoParams.scale, 1)
        XCTAssertEqual(motionSpans(a).count, 1, "a reset of the static values keeps the spans")
        store.undo()
        XCTAssertEqual(try clip(a).videoParams.opacity, 0.5, accuracy: 1e-12)
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

    func testKenBurnsAppliesAMotionSpanOverTheRange() async throws {
        let id = try await placedClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.start = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        model.end = CGRect(x: 960, y: 540, width: 960, height: 540) // the bottom-right quarter
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertNil(store.kenBurns, "closed after applying")
        XCTAssertEqual(store.undoActionName, "Add Motion Span", "the new span and its values: one undo step")
        // A Motion span on the first effect lane over the whole clip, easing in and out from the
        // start framing to the end framing, reached at the span's end.
        let spans = motionSpans(id)
        XCTAssertEqual(spans.count, 1)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.lane, 1)
        XCTAssertEqual([span.start, span.end], [frames(0), frames(60)])
        XCTAssertEqual(span.interpolation, .easeInOut)
        XCTAssertEqual(span.startValues.x, 0, accuracy: 1e-12)
        XCTAssertEqual(span.startValues.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(span.endValues.x, -960, accuracy: 1e-9)
        XCTAssertEqual(span.endValues.y, -540, accuracy: 1e-9)
        XCTAssertEqual(span.endValues.scale, 2, accuracy: 1e-12)
        let info = try clip(id)
        XCTAssertEqual(info.motion(at: frames(0)).scale, 1, accuracy: 1e-12)
        let last = info.motion(at: frames(59))
        XCTAssertTrue(last.scale > 1.99 && last.scale < 2, "the last frame is a frame short of the end: \(last.scale)")
        let end = try edgeMotion(id, span, atEnd: true)
        XCTAssertEqual(end.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(end.x, -960, accuracy: 1e-9)
        // Opening the helper again starts from that move.
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
        XCTAssertTrue(try clip(id).spans.isEmpty)
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
        XCTAssertTrue(try clip(id).spans.isEmpty)
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

    /// A picture source the test answers by hand: each fetch waits until `land` or `fail`.
    private final class ScriptedPictures {
        struct Request {
            let millis: Int64
            let completion: (CGImage?, Error?) -> Void
        }

        private(set) var requests: [Request] = []
        private var answered = 0

        func fetch(_ asset: VEAssetID, _ time: CMTime, _ size: Int, _ completion: @escaping (CGImage?, Error?) -> Void) {
            requests.append(Request(millis: time.value * 1000 / Int64(time.timescale), completion: completion))
        }

        var pending: Request? { answered < requests.count ? requests[answered] : nil }

        /// Answers the oldest open request with a picture (1x1, tagged by its time in the colour).
        @discardableResult
        func land() -> CGImage? {
            guard let request = pending else { return nil }
            answered += 1
            let image = Self.picture()
            request.completion(image, nil)
            return image
        }

        func fail() {
            guard let request = pending else { return }
            answered += 1
            request.completion(nil, NSError(domain: "Test", code: 1))
        }

        static func picture() -> CGImage? {
            CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    func testKenBurnsPictureLoaderShowsEveryLandedPictureWhileScrubbingOneFetchAtATime() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 4, fetch: source.fetch)
        // A scrub: many times while nothing has landed start one fetch.
        for frame in stride(from: 0, through: 12, by: 3) {
            loader.want(seconds: Double(frame) / 30)
        }
        XCTAssertEqual(loader.fetchesStarted, 1)
        XCTAssertEqual(source.pending?.millis, 0)
        XCTAssertNil(loader.image, "nothing to show before the first picture")

        // Three landings while the playhead keeps moving: each landed picture shows at once (the
        // preview never freezes on the first one), and the latest wanted time is fetched next.
        var shown: [CGImage] = []
        for step in 1 ... 3 {
            let landed = try XCTUnwrap(source.land())
            XCTAssertTrue(loader.image === landed, "landing \(step) shows its picture")
            shown.append(landed)
            XCTAssertEqual(loader.fetchesStarted, step + 1, "the latest time follows")
            XCTAssertEqual(source.pending?.millis, Int64((Double(12 + 3 * (step - 1)) / 30 * 1000).rounded()))
            loader.want(seconds: Double(12 + 3 * step) / 30) // the scrub goes on
        }
        XCTAssertEqual(Set(shown.map(ObjectIdentifier.init)).count, 3)

        // The scrub stops at 0.7 s: 0.6 s lands, then the wanted 0.7 s, which stays.
        source.land()
        let final = try XCTUnwrap(source.land())
        XCTAssertTrue(loader.image === final)
        XCTAssertNil(loader.pendingSeconds)
        XCTAssertNil(source.pending)
        // A kept time (0.5 s, the third landing) shows at once without a fetch; one the capacity of
        // four pushed out (0 s, the first) is fetched again.
        let fetches = loader.fetchesStarted
        loader.want(seconds: 0.5)
        XCTAssertTrue(loader.image === shown[2])
        XCTAssertEqual(loader.fetchesStarted, fetches)
        loader.want(seconds: 0)
        XCTAssertEqual(loader.fetchesStarted, fetches + 1)
        XCTAssertEqual(source.pending?.millis, 0)
        XCTAssertTrue(loader.image === shown[2], "the last picture stays up meanwhile")
    }

    func testKenBurnsPictureLoaderMovesOnAfterAFailedFetchAndKeepsTheLastPicture() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 4, fetch: source.fetch)
        loader.want(seconds: 1)
        let first = try XCTUnwrap(source.land())
        loader.want(seconds: 2)
        loader.want(seconds: 3) // wanted while 2 is in flight
        source.fail()
        XCTAssertEqual(loader.fetchesFailed, 1)
        XCTAssertTrue(loader.image === first, "the last picture stays up")
        XCTAssertEqual(source.pending?.millis, 3000, "the failure re-drives the loader to the latest time")
        source.fail()
        XCTAssertNil(source.pending, "a time that just failed is not fetched again in a loop")
        XCTAssertEqual(loader.fetchesStarted, 3)
        // Wanting another time and coming back tries it again.
        loader.want(seconds: 4)
        let fourth = try XCTUnwrap(source.land())
        XCTAssertTrue(loader.image === fourth)
        loader.want(seconds: 3)
        XCTAssertEqual(source.pending?.millis, 3000)
    }

    func testKenBurnsPictureLoaderMemoryIsBounded() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 5, fetch: source.fetch)
        // A long scrub back and forth over 300 distinct frames.
        for pass in 0 ..< 2 {
            for frame in 0 ..< 150 {
                loader.want(seconds: Double(pass == 0 ? frame : 149 - frame) / 30)
                source.land()
                XCTAssertLessThanOrEqual(loader.cachedCount, 5)
            }
        }
        XCTAssertEqual(loader.cachedCount, 5)
        // Memory pressure keeps only the picture on screen.
        let onScreen = loader.image
        loader.handleMemoryPressure()
        XCTAssertEqual(loader.cachedCount, 1)
        XCTAssertTrue(loader.image === onScreen)
    }

    func testTheKenBurnsHelperLoadsItsPictureFromTheEngineWithoutTheSharedCache() async throws {
        let id = try await placedClip()
        store.beginKenBurns(clip: id)
        let loader = try XCTUnwrap(store.kenBurns?.picture)
        let thumbnails = store.thumbnails
        let requestsBefore = thumbnails.requestsStarted
        let versionBefore = thumbnails.version
        loader.want(seconds: 0.5)
        let landed = await StoreFixture.wait(until: { loader.image != nil }, timeout: 20)
        XCTAssertTrue(landed, "a real picture arrives from the engine")
        let width = try XCTUnwrap(store.asset(try XCTUnwrap(store.clips[id]).assetID)).width
        XCTAssertEqual(loader.image?.width, min(KenBurnsPictureLoader.maxDimension, Int(width)),
                       "the whole picture, at most the helper's size")
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertEqual(thumbnails.requestsStarted, requestsBefore, "the shared thumbnail cache is not used")
        XCTAssertEqual(thumbnails.version, versionBefore, "nothing bumps the timeline's and bin's redraw token")
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
        XCTAssertEqual(motionRanges(id), [[frames(0), frames(90)]])
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

    func testAKenBurnsMoveOverTheFirstSecondsHoldsItsEndFramingAndTheNextMoveStartsThere() async throws {
        let id = try await longClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromClipStart
        model.durationText = "5s"
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.rangeCaption, KenBurnsModel.holdCaption)
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080), "an unplaced clip: the push in")
        model.end = CGRect(x: 960, y: 540, width: 960, height: 540) // the bottom-right quarter
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Add Motion Span")
        XCTAssertEqual(motionRanges(id), [[frames(0), frames(150)]])
        let info = try clip(id)
        XCTAssertGreaterThan(info.motion(at: frames(149)).scale, 1.99, "near the end framing on its last frame")
        XCTAssertLessThan(info.motion(at: frames(149)).scale, 2)
        let firstSpan = try XCTUnwrap(motionSpans(id).first)
        var endFraming = VEVideoParams()
        XCTAssertTrue(info.getMotion(&endFraming, atEdgeOfSpan: firstSpan.spanID, atEnd: true, frameDuration: frames(1)))
        XCTAssertEqual(endFraming.scale, 2, accuracy: 1e-9)
        for frame: Int64 in [150, 220, 299] {
            let shown = info.motion(at: frames(frame))
            XCTAssertEqual(shown.scale, endFraming.scale, "frame \(frame): the end framing holds to the clip's end")
            XCTAssertEqual(shown.x, endFraming.x)
            XCTAssertEqual(shown.y, endFraming.y)
        }

        // The clip has a move now: the helper opens on it, the rectangles on its framings.
        store.playheadTime = frames(200)
        store.beginKenBurns(clip: id)
        let second = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(second.range, .existingMove)
        XCTAssertEqual(second.rangeTimecodes, "00:00:00:00 – 00:00:04:29")
        XCTAssertEqual(second.end.minX, 960, accuracy: 1e-6, "the move's end framing")
        XCTAssertEqual(second.end.width, 960, accuracy: 1e-6)
        XCTAssertEqual(second.start.width, 1920, accuracy: 1e-6, "and its start")
        second.range = .fromPlayhead
        // At the playhead (after the move) the picture holds the move's end framing: both rectangles
        // show it.
        for rect in [second.start, second.end] {
            XCTAssertEqual(rect.minX, 960, accuracy: 1e-6, "the held end framing")
            XCTAssertEqual(rect.minY, 540, accuracy: 1e-6)
            XCTAssertEqual(rect.width, 960, accuracy: 1e-6)
        }
        // A rectangle the user moved keeps its place when the range changes; the other follows.
        second.end = CGRect(x: 0, y: 0, width: 960, height: 540)
        second.move(.end, from: second.end, by: CGSize(width: 500, height: 300))
        let moved = second.end
        XCTAssertEqual(moved.minX, 500, accuracy: 1e-9)
        second.range = .fromClipStart
        XCTAssertEqual(second.end, moved)
        XCTAssertEqual(second.start.width, 1920, accuracy: 1e-6, "the framing on the clip's first frame")

        // A second move later in the clip is a second span on the same lane, starting from the held
        // framing (no jump where it starts); one undo step takes it back.
        second.range = .fromPlayhead
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(motionRanges(id), [[frames(0), frames(150)], [frames(200), frames(300)]])
        XCTAssertEqual(motionSpans(id).map(\.lane), [1, 1])
        let chained = try clip(id)
        XCTAssertEqual(chained.motion(at: frames(180)).scale, 2, accuracy: 1e-9, "between the moves the first one holds")
        XCTAssertEqual(chained.motion(at: frames(200)).scale, chained.motion(at: frames(199)).scale, accuracy: 1e-6)
        XCTAssertEqual(chained.motion(at: frames(200)).x, chained.motion(at: frames(199)).x, accuracy: 1e-6)
        store.undo()
        XCTAssertEqual(motionRanges(id), [[frames(0), frames(150)]])
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
        XCTAssertEqual(motionRanges(id), [[frames(60), frames(210)]])
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

        // Apply after moving the red rectangle to the top-left quarter: the same span keeps its
        // range and start values; only the end values change.
        let before = try XCTUnwrap(motionSpans(id).first)
        model.move(.end, from: model.end, by: CGSize(width: -960, height: -540))
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        let spans = motionSpans(id)
        XCTAssertEqual(spans.count, 1)
        let after = try XCTUnwrap(spans.first)
        XCTAssertEqual(after.spanID, before.spanID, "edited in place")
        XCTAssertEqual([after.start, after.end], [before.start, before.end])
        XCTAssertEqual(after.interpolation, .easeIn)
        XCTAssertEqual(after.startValues.x, before.startValues.x, accuracy: 1e-9, "start values kept")
        XCTAssertEqual(after.startValues.y, before.startValues.y, accuracy: 1e-9)
        XCTAssertEqual(after.startValues.scale, before.startValues.scale, accuracy: 1e-9)
        XCTAssertEqual(after.endValues.x, 960, accuracy: 1e-6, "was -960")
        XCTAssertEqual(after.endValues.y, 540, accuracy: 1e-6, "was -540")
        XCTAssertEqual(after.endValues.scale, 2, accuracy: 1e-9, "the same size")
        XCTAssertEqual(try clip(id).motion(at: frames(20)).scale, applied.motion(at: frames(20)).scale,
                       accuracy: 1e-12, "nothing changes before the move")
    }

    func testOfSeveralMovesTheFirstIsEditedAndTheOthersStay() async throws {
        let id = try await longClip()
        try kenBurns(id, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: VEMotionFraming(x: -960, y: -540, scale: 2),
                     interpolation: .linear, range: CMTimeRange(start: .zero, duration: frames(150)))
        // The later move on the same lane starts from the framing the first one holds, so its own
        // values are relative to it (1.5 / 2 in scale).
        let later = try kenBurns(id, start: VEMotionFraming(x: -960, y: -540, scale: 2),
                                 end: VEMotionFraming(x: 0, y: 0, scale: 1.5), interpolation: .easeOut,
                                 range: CMTimeRange(start: frames(200), duration: frames(100)))
        XCTAssertEqual(later.startValues.scale, 1, accuracy: 1e-12, "it continues the held framing")
        XCTAssertEqual(later.endValues.scale, 0.75, accuracy: 1e-12)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .move(KenBurnsModel.ExistingMove(first: 0, last: 149, hasKeyframesBetween: false,
                                                                         interpolation: .linear)))
        XCTAssertEqual(model.rangeCaption, "Editing the move from 00:00:00:00 to 00:00:04:29")
        XCTAssertEqual(model.interpolation, .linear, "the span's smoothing")
        XCTAssertEqual(model.end.width, 960, accuracy: 1e-6, "the move's end framing (200 %)")
        model.move(.end, from: model.end, by: CGSize(width: -960, height: 0))
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        XCTAssertEqual(motionRanges(id), [[frames(0), frames(150)], [frames(200), frames(300)]])
        XCTAssertEqual(try XCTUnwrap(motionSpans(id).first).endValues.x, 960, accuracy: 1e-6,
                       "the bottom-left quarter (the rectangle moved left by 960)")
        let kept = try XCTUnwrap(store.engine.spanInfo(later.spanID))
        XCTAssertEqual(kept.startValues.scale, later.startValues.scale, "the other move's values are untouched")
        XCTAssertEqual(kept.endValues.scale, later.endValues.scale)
        XCTAssertEqual(kept.endValues.x, later.endValues.x)
    }

    func testAClipWithoutAMoveOpensOnTheWholeClipPushIn() async throws {
        let id = try await placedClip()
        // An Opacity span is not a move.
        let opacity = store.engine.addSpan(kind: .opacity, lane: 1, clip: id,
                                           range: CMTimeRange(start: frames(10), duration: frames(30)))
        XCTAssertTrue(opacity.ok, opacity.message)
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

        // Nor is a Motion span of a single frame.
        let single = store.engine.addSpan(kind: .motion, lane: 2, clip: id,
                                          range: CMTimeRange(start: frames(30), duration: frames(1)))
        XCTAssertTrue(single.ok, single.message)
        store.beginKenBurns(clip: id)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.detection, .none, "a span of one frame")
        XCTAssertEqual(model.range, .wholeClip)
    }

    func testATrimClipsTheMoveAndTheHelperEditsWhatIsLeft() async throws {
        let id = try await placedClip()
        try kenBurns(id, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: VEMotionFraming(x: -960, y: -540, scale: 2),
                     interpolation: .easeInOut)
        XCTAssertTrue(store.engine.trimClipHead(id, to: frames(10), clamp: false).ok)
        XCTAssertTrue(store.engine.trimClipTail(id, to: frames(50), clamp: false).ok)
        let clipped = try XCTUnwrap(motionSpans(id).first)
        XCTAssertEqual([clipped.start, clipped.end], [frames(10), frames(50)], "cut at the new edges")
        store.selection = [id]
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        // The cut divided the eased segment: its parts are custom curves, which the helper does not
        // offer, so it proposes its default smoothing.
        XCTAssertEqual(model.detection, .move(KenBurnsModel.ExistingMove(first: 0, last: 39, hasKeyframesBetween: false,
                                                                         interpolation: nil)))
        XCTAssertEqual(model.interpolation, .easeInOut)
        XCTAssertEqual(model.range, .existingMove)
        XCTAssertEqual(model.rangeTimecodes, "00:00:00:10 – 00:00:01:19")
        // The rectangles show the framings at the cuts (the values the trim evaluated there).
        let startFraming = try edgeMotion(id, clipped, atEnd: false)
        XCTAssertEqual(model.startFraming.scale, startFraming.scale, accuracy: 1e-9)
        XCTAssertEqual(model.startFraming.x, startFraming.x, accuracy: 1e-6)
        let endFraming = try edgeMotion(id, clipped, atEnd: true)
        XCTAssertEqual(model.endFraming.scale, endFraming.scale, accuracy: 1e-9)
        XCTAssertTrue(store.applyKenBurns())
        XCTAssertEqual(store.undoActionName, "Ken Burns")
        let edited = try XCTUnwrap(motionSpans(id).first)
        XCTAssertEqual(edited.spanID, clipped.spanID, "the same span, edited in place")
        XCTAssertEqual(edited.endValues.scale, clipped.endValues.scale, accuracy: 1e-9, "an unchanged apply keeps it")
    }

    func testTheExistingMoveFollowsModelChangesWhileTheHelperIsOpen() async throws {
        let id = try await longClip()
        try applyPartialMove(id)
        // A smoothing the helper does not offer is not taken.
        let span = try XCTUnwrap(motionSpans(id).first)
        XCTAssertTrue(store.engine.setSpanInterpolation(span.spanID, interpolation: .hold).ok)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertNotNil(model.existingMove)
        XCTAssertNil(model.existingMove?.interpolation)
        XCTAssertEqual(model.interpolation, .easeInOut, "Hold is not offered: the default")
        // The span's end moves two frames earlier: the range follows.
        XCTAssertTrue(store.engine.setSpanRange(span.spanID, range: CMTimeRange(start: frames(60), end: frames(208))).ok)
        XCTAssertTrue(store.kenBurns === model)
        XCTAssertEqual(model.rangeTimecodes, "00:00:02:00 – 00:00:06:27")
        // Undone back to no move at all: the range falls back to the whole clip.
        while !motionSpans(id).isEmpty, store.canUndo { store.undo() }
        XCTAssertTrue(motionSpans(id).isEmpty)
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

    func testApplyWithATypedRangePutsTheSpanOnExactlyThoseFrames() async throws {
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
        XCTAssertEqual(motionRanges(id), [[frames(130), frames(216)]], "the last frame typed is the span's last")
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
        XCTAssertEqual(rect.height, row.rowHeight)
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

    func testMatchingSetsTheStaticValuesSoTheCutMatchesWhateverTheSpans() async throws {
        let (a, b, _) = try await neighbours()
        let placed = VEVideoParams(x: 100, y: -20, scale: 1.5, rotationDegrees: 10, opacity: 0.5)
        XCTAssertTrue(store.engine.setVideoParams(placed, forClip: a).ok)

        // A clip without spans: its static values become A's.
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

        // A clip with an Opacity span over its first 40 frames (0.8 down to 0.2): the static opacity
        // is set so the first frame shows A's 0.5 through the span.
        let added = store.engine.addSpan(kind: .opacity, lane: 1, clip: b,
                                         range: CMTimeRange(start: frames(60), duration: frames(40)))
        let span = try XCTUnwrap(added.span, added.message)
        var start = VESpanValuesUnchanged()
        start.opacity = 0.8
        var end = VESpanValuesUnchanged()
        end.opacity = 0.2
        XCTAssertTrue(store.engine.setSpanValues(span.spanID, start: start, end: end).ok)
        inspector.matchAdjacent(.start)
        XCTAssertEqual(inspector.message, "Matched the previous clip's end: set as this clip's static values.")
        XCTAssertEqual(try clip(b).videoParams.opacity, 0.5 / 0.8, accuracy: 1e-12)
        let first = try clip(b).motion(at: frames(60))
        XCTAssertEqual(first.opacity, 0.5, accuracy: 1e-12, "the cut matches")
        XCTAssertEqual(first.scale, 1.5)
        XCTAssertEqual(try clip(b).motion(at: frames(100)).opacity, 0.5 / 0.8 * 0.2, accuracy: 1e-12,
                       "after the span its end value holds")

        // The next clip's start onto A's last frame: B starts exactly as A is, so nothing changes.
        store.selection = [a]
        inspector.matchAdjacent(.end)
        XCTAssertEqual(inspector.message, "This clip already matches the next clip's start.")
        XCTAssertEqual(store.undoActionName, "Match Previous Clip", "no undo step")
        // With A turned back, it takes B's first frame again.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParamsIdentity(), forClip: a).ok)
        inspector.matchAdjacent(.end)
        XCTAssertEqual(store.undoActionName, "Match Next Clip")
        XCTAssertEqual(try clip(a).videoParams.opacity, 0.5, accuracy: 1e-12, "B's first frame")
        XCTAssertEqual(try clip(a).videoParams.x, 100)
        XCTAssertEqual(try clip(a).videoParams.rotationDegrees, 10)
    }

    func testMatchingFollowsAnAnimatedNeighbourAndIsRefusedDuringAGesture() async throws {
        let (a, b, _) = try await neighbours()
        try kenBurns(a, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: VEMotionFraming(x: -120, y: 60, scale: 1.8),
                     interpolation: .easeInOut)
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
        let aLast = try clip(a).motion(at: frames(59))
        XCTAssertEqual(first.x, aLast.x, accuracy: 1e-9, "A's last frame")
        XCTAssertEqual(first.y, aLast.y, accuracy: 1e-9)
        XCTAssertEqual(first.scale, aLast.scale, accuracy: 1e-12)
        XCTAssertGreaterThan(aLast.scale, 1.79, "near A's end framing, a frame short of the span's end")
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
        try kenBurns(a, start: VEMotionFraming(x: 0, y: 0, scale: 1), end: VEMotionFraming(x: -960, y: -540, scale: 2),
                     interpolation: .easeInOut)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: d).ok)
        // A's last frame, a frame short of the move's end, keeps the quarter's right and bottom edges.
        let aLast = try clip(a).motion(at: frames(59))
        XCTAssertTrue(aLast.scale > 1.99 && aLast.scale < 2)
        store.beginKenBurns(clip: b)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(model.continuesFromPrevious, "the previous clip is animated")
        XCTAssertTrue(model.leadsIntoNext, "the next clip is not at the identity")
        XCTAssertEqual(model.start.width, 1920 / aLast.scale, accuracy: 1e-6, "A's framing on its last frame")
        XCTAssertEqual(model.start.maxX, 1920, accuracy: 1e-6)
        XCTAssertEqual(model.start.maxY, 1080, accuracy: 1e-6)
        XCTAssertEqual(model.end.width, 1280, accuracy: 1e-6, "D's 150 %")
        XCTAssertEqual(model.end.midX, 960, accuracy: 1e-6)
        XCTAssertNil(model.neighbourNote)
        // Off: the default comes back; on again: the neighbour's framing, even after a drag.
        model.continuesFromPrevious = false
        XCTAssertEqual(model.start, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        model.move(.start, from: model.start, by: CGSize(width: 0, height: 0))
        model.continuesFromPrevious = true
        XCTAssertEqual(model.start.width, 1920 / aLast.scale, accuracy: 1e-6)
        // Applied, B starts where A's last frame is and its move ends where D starts.
        XCTAssertTrue(store.applyKenBurns())
        let info = try clip(b)
        XCTAssertEqual(info.motion(at: frames(60)).x, aLast.x, accuracy: 1e-6)
        XCTAssertEqual(info.motion(at: frames(60)).scale, aLast.scale, accuracy: 1e-9)
        let span = try XCTUnwrap(motionSpans(b).first)
        XCTAssertEqual(try edgeMotion(b, span, atEnd: true).scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(span.endValues.scale, 1.5, accuracy: 1e-9)

        // A neighbour that goes away turns its toggle off.
        store.beginKenBurns(clip: b)
        model = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(model.leadsIntoNext)
        XCTAssertTrue(store.engine.removeClips([NSNumber(value: d)]).ok)
        XCTAssertNil(model.next)
        XCTAssertFalse(model.leadsIntoNext)
    }
}
