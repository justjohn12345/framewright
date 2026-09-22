import XCTest
@testable import VidEdit

final class TimelineViewModelTests: XCTestCase {
    /// V2 above V1, then A1: two clips on V1, one on V2, one on A1.
    private func makeModel(pixelsPerSecond: Double = 100, scrollX: CGFloat = 0) -> TimelineViewModel {
        var model = TimelineViewModel()
        model.pixelsPerSecond = pixelsPerSecond
        model.scrollX = scrollX
        model.frameSeconds = 1.0 / 30.0
        model.playhead = 7
        model.tracks = [
            .init(id: 10, kind: .video, index: 0, name: "V1"),
            .init(id: 11, kind: .video, index: 1, name: "V2"),
            .init(id: 20, kind: .audio, index: 0, name: "A1"),
        ]
        model.clips = [
            .init(id: 1, trackID: 10, start: 0, end: 4, linkedClipID: 4),
            .init(id: 2, trackID: 10, start: 4, end: 6),
            .init(id: 3, trackID: 11, start: 10, end: 12),
            .init(id: 4, trackID: 20, start: 0, end: 4, linkedClipID: 1),
        ]
        model.transitions = [.init(id: 50, trackID: 10, start: 3.5, end: 4.5)]
        return model
    }

    func testRowsRunFromTopVideoTrackToAudio() {
        let layouts = makeModel().trackLayouts
        XCTAssertEqual(layouts.map(\.track.name), ["V2", "V1", "A1"])
        XCTAssertEqual(layouts[0].y, 0)
        XCTAssertEqual(layouts[1].y, TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing)
        XCTAssertEqual(layouts[2].height, TimelineViewModel.audioTrackHeight)
    }

    func testClipRectsAtSeveralZoomLevels() throws {
        for pps in [10.0, 100.0, 733.0] {
            let model = makeModel(pixelsPerSecond: pps, scrollX: 50)
            let v1Y = TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing
            let rect = try XCTUnwrap(model.rect(forClip: try XCTUnwrap(model.clip(id: 2))))
            XCTAssertEqual(rect.minX, CGFloat(4 * pps) - 50, accuracy: 1e-9)
            XCTAssertEqual(rect.width, CGFloat(2 * pps), accuracy: 1e-9)
            XCTAssertEqual(rect.minY, v1Y)
            XCTAssertEqual(rect.height, TimelineViewModel.videoTrackHeight)
            // x <-> time round trip.
            XCTAssertEqual(model.time(forX: model.x(forTime: 3.25)), 3.25, accuracy: 1e-9)
        }
        var scrolled = makeModel()
        scrolled.scrollY = 20
        XCTAssertEqual(try XCTUnwrap(scrolled.rect(forClip: try XCTUnwrap(scrolled.clip(id: 3)))).minY, -20)
    }

    func testSnappingPicksNearestCandidateWithinThreshold() {
        let model = makeModel(pixelsPerSecond: 100) // threshold 8 pt = 0.08 s
        XCTAssertEqual(model.snap(6.05)?.time, 6)
        XCTAssertEqual(model.snap(6.05)?.target, .clipEnd(2))
        XCTAssertEqual(model.snap(7.03)?.target, .playhead)
        XCTAssertEqual(model.snap(0.05)?.target, .sequenceStart)
        XCTAssertNil(model.snap(8.5), "nothing within 8 pt")
        XCTAssertNil(model.snap(6.1), "10 pt away is outside the threshold")
        // Between 9.95 (none) and candidates 10 (clip 3 start): nearest wins.
        XCTAssertEqual(model.snap(9.95)?.target, .clipStart(3))
        // The dragged clip's own edges are excluded.
        XCTAssertNil(model.snap(10.02, excluding: [3]))
        // At a coarser zoom the same distance snaps.
        XCTAssertEqual(makeModel(pixelsPerSecond: 10).snap(6.3)?.time, 6)
    }

    func testSnapMoveUsesTheCloserEdge() {
        let model = makeModel(pixelsPerSecond: 100)
        // Moving clip 3 ([10, 12)) left by 3.97 s: its end (8.03) is 0.97 from 7 (playhead) — too
        // far; its start (6.03) is 0.03 from 6 (end of clip 2): snaps the start.
        let moved = model.snapMove(start: 10, end: 12, delta: -3.97, excluding: [3])
        XCTAssertEqual(moved.delta, -4, accuracy: 1e-9)
        XCTAssertEqual(moved.snap?.target, .clipEnd(2))
        // End snapping onto the playhead.
        let toPlayhead = model.snapMove(start: 10, end: 12, delta: -4.96, excluding: [3])
        XCTAssertEqual(toPlayhead.delta, -5, accuracy: 1e-9)
        XCTAssertEqual(toPlayhead.snap?.target, .playhead)
        let free = model.snapMove(start: 10, end: 12, delta: 2.5, excluding: [3])
        XCTAssertEqual(free.delta, 2.5)
        XCTAssertNil(free.snap)
    }

    func testHitTestingEdgeZonesBodiesAndTransitions() {
        let model = makeModel(pixelsPerSecond: 100)
        let v1Mid = TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing + 40
        XCTAssertEqual(model.hitTest(CGPoint(x: 200, y: v1Mid)), .clipBody(1))
        XCTAssertEqual(model.hitTest(CGPoint(x: 3, y: v1Mid)), .clipHead(1))
        XCTAssertEqual(model.hitTest(CGPoint(x: 8, y: v1Mid)), .clipHead(1), "the zone is 8 pt wide")
        XCTAssertEqual(model.hitTest(CGPoint(x: 9, y: v1Mid)), .clipBody(1))
        // At the cut between clips 1 and 2 (x = 400) the closer edge wins.
        XCTAssertEqual(model.hitTest(CGPoint(x: 398, y: v1Mid)), .clipTail(1))
        XCTAssertEqual(model.hitTest(CGPoint(x: 403, y: v1Mid)), .clipHead(2))
        XCTAssertEqual(model.hitTest(CGPoint(x: 595, y: v1Mid)), .clipTail(2))
        XCTAssertEqual(model.hitTest(CGPoint(x: 700, y: v1Mid)), .track(10))
        // The transition strip at the top of the row.
        let v1Top = TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing
        XCTAssertEqual(model.hitTest(CGPoint(x: 380, y: v1Top + 5)), .transition(50))
        XCTAssertEqual(model.hitTest(CGPoint(x: 1050, y: 30)), .clipBody(3))
        XCTAssertEqual(model.hitTest(CGPoint(x: 100, y: 5000)), .none)
        // Narrow clips shrink the edge zones to a third of their width.
        let zoomedOut = makeModel(pixelsPerSecond: 3)
        XCTAssertEqual(zoomedOut.hitTest(CGPoint(x: 15, y: v1Mid)), .clipBody(2), "clip 2 is 6 pt wide: zones are 2 pt")
    }

    func testMarqueeSelectsIntersectingClipsAndLinksExpand() {
        let model = makeModel(pixelsPerSecond: 100)
        let v1Y = TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing
        // Across V1 from 3.5 s to 5 s.
        let ids = model.clipIDs(intersecting: CGRect(x: 350, y: v1Y + 10, width: 150, height: 10))
        XCTAssertEqual(ids, [1, 2])
        // Drawn backwards (negative size) behaves the same.
        XCTAssertEqual(model.clipIDs(intersecting: CGRect(x: 500, y: v1Y + 20, width: -150, height: -10)), [1, 2])
        XCTAssertEqual(model.expandingLinks(ids), [1, 2, 4])
        XCTAssertTrue(model.clipIDs(intersecting: CGRect(x: 700, y: v1Y, width: 100, height: 10)).isEmpty)
    }

    func testZoomKeepsTheAnchorTimeInPlaceAndRulerIntervalsScale() {
        var model = makeModel(pixelsPerSecond: 100, scrollX: 200)
        let anchorX: CGFloat = 300
        let before = model.time(forX: anchorX)
        model.zoom(by: 2, anchorX: anchorX)
        XCTAssertEqual(model.pixelsPerSecond, 200)
        XCTAssertEqual(model.time(forX: anchorX), before, accuracy: 1e-9)
        model.zoom(by: 1e9, anchorX: 0)
        XCTAssertEqual(model.pixelsPerSecond, TimelineViewModel.maxPixelsPerSecond)

        XCTAssertEqual(makeModel(pixelsPerSecond: 100).rulerInterval(), 1)
        XCTAssertEqual(makeModel(pixelsPerSecond: 10).rulerInterval(), 10)
        XCTAssertEqual(makeModel(pixelsPerSecond: 1000).rulerInterval(), 5.0 / 30.0, accuracy: 1e-9, "frames when zoomed in")
        let ticks = makeModel(pixelsPerSecond: 100).rulerTicks(width: 500)
        XCTAssertEqual(ticks.first, 0)
        XCTAssertEqual(ticks[1], 1)
    }

    func testFrameSnapping() {
        let model = makeModel()
        XCTAssertEqual(model.snapToFrame(1.01), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.snapToFrame(1.02), 31.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(model.snapToFrame(-3), 0)
    }
}
