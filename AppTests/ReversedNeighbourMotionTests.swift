import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// A Motion span continuing its neighbour across a cut between a forward and a reversed clip
/// (hands-on round, 2026-09-27): the user built A | reversed A | A from one clip, added a Motion span
/// on each with Control-K and could not make the reversed clip's span continue from the previous
/// clip. The movie is 2 s (60 frames) at 320x180, filling the 1920x1080 frame.
@MainActor
final class ReversedNeighbourMotionTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("reversed-neighbour")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    /// A [0, 60), reversed A [60, 120), A [120, 180) on V1, each with a Control-K Motion span from its
    /// first frame (the push in, to the clip's end). Returns the clips and their spans.
    private func forwardReversedForward() async throws -> (clips: [VEClipID], spans: [VESpanID]) {
        let (movie, _) = try await fixture.importMedia()
        let clips = [try fixture.placeMovie(movie, at: 0), try fixture.placeMovie(movie, at: 2),
                     try fixture.placeMovie(movie, at: 4)]
        store.selection = [clips[1]]
        XCTAssertTrue(store.setReversed(true), store.statusMessage ?? "")
        XCTAssertTrue(store.clips[clips[1]]?.reversed == true)
        var spans: [VESpanID] = []
        for (index, clip) in clips.enumerated() {
            store.selection = [clip]
            store.playheadTime = frames(Int64(index) * 60)
            store.addMotionSpanAtPlayhead()
            let span = try XCTUnwrap(store.selectedSpanID, store.statusMessage ?? "no span")
            XCTAssertEqual(store.engine.spanInfo(span)?.clipID, clip)
            XCTAssertEqual(store.engine.spanInfo(span)?.start, frames(Int64(index) * 60), "on the clip's first frame")
            spans.append(span)
        }
        return (clips, spans)
    }

    private func assertSameMotion(_ a: VEVideoParams, _ b: VEVideoParams, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(a.scale, b.scale, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.rotationDegrees, b.rotationDegrees, accuracy: 1e-9, message, file: file, line: line)
    }

    private func motion(_ clip: VEClipID, atFrame frame: Int64) throws -> VEVideoParams {
        try XCTUnwrap(store.clips[clip]).motion(at: frames(frame))
    }

    /// The same with linked sound on every clip (the pairs selected by a click, reversed together) and
    /// the reversed pair slowed to 50 %: Control-K on the reversed clip's first frame, then Continue.
    func testALinkedSlowedReversedPairContinuesTheClipBeforeIt() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        var pictures: [VEClipID] = []
        for index in 0 ..< 2 {
            let at = frames(Int64(index) * 60)
            XCTAssertTrue(store.place(asset: movie.assetID, at: at, videoTrack: v1, audioTrack: 0, overwrite: true))
            let picture = try XCTUnwrap(store.selection.first)
            XCTAssertTrue(store.place(asset: tone.assetID, at: at, videoTrack: 0, audioTrack: a1,
                                      sourceIn: .zero, sourceOut: frames(60), overwrite: true))
            let sound = try XCTUnwrap(store.selection.first)
            XCTAssertTrue(store.engine.linkClip(picture, withClip: sound).ok)
            pictures.append(picture)
        }
        store.select(clip: pictures[1], extend: false)
        XCTAssertEqual(store.selection.count, 2)
        XCTAssertTrue(store.setReversed(true), store.statusMessage ?? "")
        XCTAssertTrue(store.engine.setSpeedNumerator(1, denominator: 2, forClips: [NSNumber(value: pictures[1])],
                                                     ripple: true, scope: .allTracks).ok)
        XCTAssertTrue(store.clips[pictures[1]]?.reversed == true)

        store.select(clip: pictures[0], extend: false)
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead()
        store.select(clip: pictures[1], extend: false)
        store.playheadTime = frames(60)
        store.addMotionSpanAtPlayhead()
        let span = try XCTUnwrap(store.selectedSpanID, store.statusMessage ?? "no span")
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.span.start, frames(60))
        XCTAssertTrue(model.canContinueFromPrevious)
        model.setContinuesFromPrevious(true)
        XCTAssertTrue(model.continuesFromPrevious, store.statusMessage ?? "")
        XCTAssertEqual(store.undoActionName, "Match Previous Clip")
        assertSameMotion(try motion(pictures[1], atFrame: 60), try motion(pictures[0], atFrame: 59),
                         "the reversed clip's first frame shows the forward clip's last framing")
        XCTAssertEqual(store.engine.spanInfo(span)?.clipID, pictures[1])
    }

    func testTheReversedClipsSpanContinuesTheClipBeforeItAndLeadsIntoTheOneAfter() async throws {
        let (clips, spans) = try await forwardReversedForward()
        // The forward clip moves: its last frame is 1.25 x (nearly) about the centre.
        XCTAssertGreaterThan(try motion(clips[0], atFrame: 59).scale, 1.2)

        store.select(span: spans[1])
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.previous?.clipID, clips[0])
        XCTAssertEqual(model.next?.clipID, clips[2])
        XCTAssertTrue(model.canContinueFromPrevious, "the span starts on the reversed clip's first frame")
        XCTAssertTrue(store.canMatchSpan(try XCTUnwrap(store.engine.spanInfo(spans[1])), .start))
        XCTAssertFalse(model.continuesFromPrevious)
        let matched = store.matchSpanEdge(spans[1], .start)
        XCTAssertTrue(matched.ok, matched.message)
        XCTAssertTrue(model.continuesFromPrevious)
        assertSameMotion(try motion(clips[1], atFrame: 60), try motion(clips[0], atFrame: 59),
                         "the reversed clip's first frame shows the forward clip's last framing")

        // Lead into next: the end placement (reached at the span's end, the cut) is the next clip's
        // first framing (the last frame is a frame short of it while the span still moves there).
        model.setLeadsIntoNext(true)
        XCTAssertTrue(model.leadsIntoNext, store.statusMessage ?? "")
        let nextFirst = try motion(clips[2], atFrame: 120)
        XCTAssertEqual(model.endFraming.scale, nextFirst.scale, accuracy: 1e-9)
        XCTAssertEqual(model.endFraming.x, nextFirst.x, accuracy: 1e-6)
        XCTAssertEqual(model.endFraming.y, nextFirst.y, accuracy: 1e-6)

        // The forward clip after it continues the reversed one.
        store.select(span: spans[2])
        let after = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(after.canContinueFromPrevious)
        after.setContinuesFromPrevious(true)
        XCTAssertTrue(after.continuesFromPrevious, store.statusMessage ?? "")
        assertSameMotion(try motion(clips[2], atFrame: 120), try motion(clips[1], atFrame: 119),
                         "the forward clip's first frame shows the reversed clip's last framing")
    }
}
