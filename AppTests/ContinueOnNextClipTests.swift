import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Continue on Next Clip (hands-on round, 2026-09-27): the Ken Burns bar's button and the Clip menu
/// item carry the selected Motion span's move on to the clip touching the end of its clip, as a new
/// span from that clip's first frame that starts where the move is at the cut and goes on at the same
/// rate; one undo step; the new span is selected and the editor moves to it in the same mode; the
/// refusals say why. The movie is 2 s (60 frames) at 320x180, filling the 1920x1080 frame.
@MainActor
final class ContinueOnNextClipTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("continue-next")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    /// The movie at each of `seconds` on V1.
    private func clips(at seconds: [Double]) async throws -> [VEClipID] {
        let (movie, _) = try await fixture.importMedia()
        return try seconds.map { try fixture.placeMovie(movie, at: $0) }
    }

    /// A Motion span over the whole of `clip` (60 frames from `startFrame`) zooming 1 -> 1.5 and panning
    /// x 0 -> 300, linear; selected.
    private func move(on clip: VEClipID, from startFrame: Int64) throws -> VESpanID {
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: clip,
                                         range: CMTimeRange(start: frames(startFrame), end: frames(startFrame + 60)))
        let id = try XCTUnwrap(added.span, added.message).spanID
        var from = VESpanValuesUnchanged()
        from.scale = 1
        from.x = 0
        var to = VESpanValuesUnchanged()
        to.scale = 1.5
        to.x = 300
        XCTAssertTrue(store.engine.setSpanValues(id, start: from, end: to).ok)
        store.select(span: id)
        return id
    }

    private func edge(_ id: VESpanID, atEnd: Bool) throws -> VEVideoParams {
        let span = try XCTUnwrap(store.engine.spanInfo(id))
        let clip = try XCTUnwrap(store.clips[span.clipID])
        var motion = VEVideoParams()
        XCTAssertTrue(clip.getMotion(&motion, atEdgeOfSpan: id, atEnd: atEnd, frameDuration: store.frameDuration))
        return motion
    }

    func testTheMoveGoesOnFromTheCutAtItsRateInOneUndoStep() async throws {
        let ids = try await clips(at: [0, 2])
        let source = try move(on: ids[0], from: 0)
        let editor = try XCTUnwrap(store.kenBurns)
        editor.setMode(.transform)
        XCTAssertNil(editor.continueOnNextClipProblem)
        XCTAssertTrue(store.canContinueMotionOnNextClip, "the Clip menu item is enabled")

        editor.continueOnNextClip()
        let continued = try XCTUnwrap(store.selectedSpanID)
        XCTAssertNotEqual(continued, source)
        let span = try XCTUnwrap(store.engine.spanInfo(continued))
        XCTAssertEqual(span.clipID, ids[1])
        XCTAssertEqual(span.kind, .motion)
        XCTAssertEqual(span.start, frames(60), "from the next clip's first frame")
        XCTAssertEqual(span.end, frames(120), "as long as the move")
        XCTAssertEqual(span.interpolation, try XCTUnwrap(store.engine.spanInfo(source)).interpolation)
        XCTAssertEqual(store.undoActionName, "Continue on Next Clip")
        XCTAssertEqual(store.statusMessage, "The move continues on “clip.mov”.")
        // The editor moved to the new span, in the same mode.
        let moved = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(moved.spanID, continued)
        XCTAssertEqual(moved.mode, .transform)
        // Start: where the move is at the cut (its end placement) is the next clip's first frame.
        let sourceEnd = try edge(source, atEnd: true)
        let first = try XCTUnwrap(store.clips[ids[1]]).motion(at: frames(60))
        XCTAssertEqual(first.scale, sourceEnd.scale, accuracy: 1e-12)
        XCTAssertEqual(first.x, sourceEnd.x, accuracy: 1e-9)
        XCTAssertEqual(first.scale, 1.5, accuracy: 1e-12)
        // End: the same rate for as long again: 1.5 x 1.5 and 300 + 300.
        let end = try edge(continued, atEnd: true)
        XCTAssertEqual(end.scale, 2.25, accuracy: 1e-12)
        XCTAssertEqual(end.x, 600, accuracy: 1e-9)

        store.undo()
        XCTAssertNil(store.engine.spanInfo(continued), "one undo step removes it")
        XCTAssertTrue(try XCTUnwrap(store.clips[ids[1]]).spans.isEmpty)
        XCTAssertNotNil(store.engine.spanInfo(source))
    }

    func testTheMenuItemAndTheButtonSayWhyTheyCannotContinue() async throws {
        let ids = try await clips(at: [0, 2])
        // The last clip has no clip after it.
        let last = try move(on: ids[1], from: 60)
        XCTAssertFalse(store.canContinueMotionOnNextClip)
        XCTAssertEqual(store.kenBurns?.continueOnNextClipProblem,
                       "No clip touches the end of “clip.mov”, so there is nothing to continue the move on.")
        XCTAssertFalse(store.continueMotionOnNextClip())
        XCTAssertEqual(store.statusMessage,
                       "No clip touches the end of “clip.mov”, so there is nothing to continue the move on.")
        XCTAssertEqual(store.selectedSpanID, last)

        // Every lane of the next clip taken on its first frame.
        XCTAssertTrue(store.engine.removeSpan(last).ok)
        for lane in 1 ... 3 {
            XCTAssertTrue(store.engine.addSpan(kind: .motion, lane: lane, clip: ids[1],
                                               range: CMTimeRange(start: frames(60), end: frames(62))).ok)
        }
        _ = try move(on: ids[0], from: 0)
        XCTAssertFalse(store.canContinueMotionOnNextClip)
        store.kenBurns?.continueOnNextClip()
        let lanes = "Every effect lane of “clip.mov” has a span on its first frame, so the move has no room there: "
            + "remove one or move it to a free lane."
        XCTAssertEqual(store.kenBurns?.note, lanes)
        XCTAssertEqual(store.statusMessage, lanes)

        // Nothing selected, or a clip rather than a span.
        store.selection = [ids[0]]
        XCTAssertFalse(store.canContinueMotionOnNextClip)
        XCTAssertFalse(store.continueMotionOnNextClip())
        XCTAssertEqual(store.statusMessage, "Select a Motion span to continue its move on the next clip.")
    }

    func testAStillTakesTheContinuedMove() async throws {
        let ids = try await clips(at: [0])
        let url = fixture.directory.appendingPathComponent("still.heic")
        try TestMediaFactory.writeHEIC(to: url)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let still = try fixture.placeMovie(try XCTUnwrap(imported.first), at: 2)
        XCTAssertTrue(try XCTUnwrap(store.clips[still]).isStill)
        _ = try move(on: ids[0], from: 0)
        XCTAssertTrue(store.canContinueMotionOnNextClip)
        XCTAssertTrue(store.continueMotionOnNextClip())
        let span = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual(span.clipID, still)
        XCTAssertEqual(try XCTUnwrap(store.clips[still]).motion(at: frames(60)).scale, 1.5, accuracy: 1e-12)
    }

    /// The user's A | reversed A | A (hands-on round, item B): the move continues through the reversed
    /// clip and on to the third.
    func testTheMoveContinuesThroughAReversedClip() async throws {
        let ids = try await clips(at: [0, 2, 4])
        store.selection = [ids[1]]
        XCTAssertTrue(store.setReversed(true))
        _ = try move(on: ids[0], from: 0)
        XCTAssertTrue(store.continueMotionOnNextClip())
        let onReversed = try XCTUnwrap(store.selectedSpanID)
        XCTAssertEqual(store.engine.spanInfo(onReversed)?.clipID, ids[1])
        XCTAssertTrue(store.continueMotionOnNextClip())
        let onLast = try XCTUnwrap(store.selectedSpanID)
        XCTAssertEqual(store.engine.spanInfo(onLast)?.clipID, ids[2])
        XCTAssertEqual(try XCTUnwrap(store.clips[ids[1]]).motion(at: frames(60)).scale, 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(store.clips[ids[2]]).motion(at: frames(120)).scale, 2.25, accuracy: 1e-12)
        XCTAssertEqual(try edge(onLast, atEnd: true).scale, 3.375, accuracy: 1e-12)
        XCTAssertEqual(try edge(onLast, atEnd: true).x, 900, accuracy: 1e-9)
    }
}
