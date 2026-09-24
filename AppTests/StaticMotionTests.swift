import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// A clip's static Motion values in the inspector's Video section (what its effect spans compose
/// onto; they do not follow the playhead): a slider drag is one undo step, several clips change
/// together and a Video reset keeps their spans, a nudge on a split piece moves the static value
/// under its span; and matching a touching neighbour's framing onto the static values (the Video
/// section's Match menu). The movie is 2 s (60 frames) at 320x180 on a 1920x1080 30 fps sequence.
@MainActor
final class StaticMotionTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "static-motion-\(UUID())"))
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

    /// The movie on V1 at 0 s, selected alone.
    private func placedClip() async throws -> VEClipID {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        return id
    }

    // MARK: Static values

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

    func testANudgeOnASplitPieceMovesTheStaticValueUnderItsSpan() async throws {
        let id = try await placedClip()
        // A Motion span moving the clip left by 150 over its 60 frames, then a split at frame 30: the
        // left piece keeps the span's first half, which ends on its out point.
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: CMTimeRange(start: .zero, duration: frames(60)))
        let span = try XCTUnwrap(added.span, added.message)
        var start = VESpanValuesUnchanged()
        start.x = 0
        var end = VESpanValuesUnchanged()
        end.x = -150
        XCTAssertTrue(store.engine.setSpanValues(span.spanID, start: start, end: end).ok)
        XCTAssertTrue(store.engine.splitClip(id, at: frames(30)).ok)
        store.selection = [id]
        store.playheadTime = frames(29) // the left piece's last frame
        let pieceSpan = try XCTUnwrap(store.engine.spans(forClip: id).first { $0.kind == .motion })
        XCTAssertEqual(pieceSpan.end, frames(30), "the span ends on the piece's out point")
        XCTAssertEqual(pieceSpan.endValues.x, -75, accuracy: 1e-9, "cut exactly at the split")
        let shownBefore = try clip(id).motion(at: frames(29)).x
        // The row edits the static value (what the span composes onto), whatever the playhead shows.
        XCTAssertEqual(try XCTUnwrap(inspector.value(.positionX)), 0, accuracy: 1e-12)
        inspector.nudge(.positionX, steps: 1)
        inspector.endNudgeBurst()
        XCTAssertEqual(try XCTUnwrap(inspector.value(.positionX)), 1, accuracy: 1e-9)
        XCTAssertEqual(try clip(id).videoParams.x, 1, accuracy: 1e-9)
        XCTAssertEqual(try clip(id).motion(at: frames(29)).x, shownBefore + 1, accuracy: 1e-9,
                       "the frame shows the span plus the nudged static value")
    }

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
}
