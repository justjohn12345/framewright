import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The title box on the program monitor (`TitleBoxModel`; titles design section 9, slice 1): when it is shown, its
/// geometry through the clip's Motion and rotation, what a press grabs, moving and widening with synthetic drags
/// (as the Ken Burns tests make them), under a zoom and a turn, one undo step per drag, Escape cancelling, and the
/// other titles outlined; a step of a drag drawn on the paused program monitor at once, without a new picture.
@MainActor
final class TitleBoxTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        try fixture.configureSequence() // 1920x1080
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// A lower third at 0 (centre 0.26, 0.8 of the frame; 0.4 of its width wide), selected, the playhead on it.
    private func lowerThird() throws -> (VEClipID, TitleBoxModel) {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let id = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(10)
        let box = try XCTUnwrap(store.titleBox)
        box.setPlayhead(frames(10))
        return (id, box)
    }

    private func assertBox(_ box: KenBurnsBox, center: CGPoint, size: CGSize, rotation: Double,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.center.x, center.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(box.center.y, center.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(box.size.width, size.width, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(box.size.height, size.height, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(box.rotationDegrees, rotation, accuracy: 1e-9, file: file, line: line)
    }

    func testTheBoxShowsForOneSelectedTitleWithThePlayheadInIt() async throws {
        let (id, box) = try lowerThird()
        XCTAssertTrue(box.isVisible)
        store.playheadTime = frames(200) // after the 5 s clip
        box.setPlayhead(frames(200))
        XCTAssertFalse(box.isVisible)
        store.playheadTime = frames(30)
        XCTAssertTrue(store.addGenerated(.title))
        let other = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(store.titleBox?.clipID, other)
        store.selection = [id, other]
        XCTAssertNil(store.titleBox, "two titles: no box")
        store.selection = [id]
        XCTAssertEqual(store.titleBox?.clipID, id)
        // A selected Motion span opens the Ken Burns editor instead.
        store.addMotionSpanAtPlayhead(mode: .transform)
        XCTAssertNotNil(store.selectedSpanID)
        XCTAssertNil(store.titleBox)
        XCTAssertEqual(store.kenBurns?.mode, .transform, "a title's Motion opens in Transform mode")
        XCTAssertEqual(store.kenBurns?.pictureSize, CGSize(width: 1920, height: 1080), "the canvas is the frame")
    }

    func testTheBoxIsTheTextBlockThroughTheClipsMotion() async throws {
        let (id, model) = try lowerThird()
        let block = store.engine.titleBlockSize(ofClip: id)
        XCTAssertEqual(block.width, 0.4 * 1920, accuracy: 1e-9)
        XCTAssertGreaterThan(block.height, 0)
        assertBox(model.box, center: CGPoint(x: 0.26 * 1920, y: 0.8 * 1080), size: block, rotation: 0)
        // Zoomed 2x about the frame's centre and moved: the block zooms and moves with the canvas.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 100, y: -50, scale: 2, rotationDegrees: 0, opacity: 1),
                                                  forClip: id).ok)
        assertBox(model.box, center: CGPoint(x: 960 + 100 + (0.26 * 1920 - 960) * 2, y: 540 - 50 + (0.8 * 1080 - 540) * 2),
                  size: CGSize(width: block.width * 2, height: block.height * 2), rotation: 0)
        // Turned 90° clockwise: a point right of the centre goes below it.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 90, opacity: 1),
                                                  forClip: id).ok)
        let dx = 0.26 * 1920 - 960
        let dy = 0.8 * 1080 - 540
        assertBox(model.box, center: CGPoint(x: 960 - dy, y: 540 + dx), size: block, rotation: 90)
    }

    func testWhatAPressGrabs() {
        let box = KenBurnsBox(center: CGPoint(x: 200, y: 100), size: CGSize(width: 100, height: 40), rotationDegrees: 0)
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 200, y: 100), box: box), .body)
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 200, y: 81), box: box), .body, "the top edge moves")
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 252, y: 100), box: box), .edge(right: true))
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 147, y: 95), box: box), .edge(right: false))
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 146, y: 76), box: box), .edge(right: false), "a corner")
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 255, y: 124), box: box), .edge(right: true))
        XCTAssertNil(TitleBoxModel.target(at: CGPoint(x: 200, y: 140), box: box))
        XCTAssertNil(TitleBoxModel.target(at: CGPoint(x: 300, y: 100), box: box))
        // Turned 90°: the right edge is at the bottom.
        let turned = KenBurnsBox(center: box.center, size: box.size, rotationDegrees: 90)
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 200, y: 151), box: turned), .edge(right: true))
        XCTAssertEqual(TitleBoxModel.target(at: CGPoint(x: 252, y: 100), box: turned), nil)
    }

    func testDraggingMovesAndWidensAsOneUndoStepEach() async throws {
        let (id, model) = try lowerThird()
        let undoName = store.undoActionName
        // Body: 192 x 108 sequence pixels is a tenth of the frame each way.
        for step in 1 ... 4 {
            model.applyDrag(.body, translation: CGSize(width: 48 * step, height: 27 * step))
        }
        XCTAssertTrue(store.isGestureActive)
        model.endDrag()
        XCTAssertFalse(store.isGestureActive)
        let moved = try XCTUnwrap(store.clips[id]?.title)
        XCTAssertEqual(moved.x, 0.36, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 0.9, accuracy: 1e-9)
        XCTAssertEqual(moved.width, 0.4, accuracy: 1e-12, "a move keeps the width")
        XCTAssertEqual(store.undoActionName, "Move Title")
        // The right edge out by 96 pixels: 192 wider about the centre.
        model.applyDrag(.edge(right: true), translation: CGSize(width: 96, height: 30))
        model.endDrag()
        XCTAssertEqual(store.clips[id]?.title?.width ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.36, accuracy: 1e-9, "about the centre")
        XCTAssertEqual(store.undoActionName, "Resize Title")
        // The left edge out (to the left) widens too.
        model.applyDrag(.edge(right: false), translation: CGSize(width: -96, height: 0))
        model.endDrag()
        XCTAssertEqual(store.clips[id]?.title?.width ?? 0, 0.6, accuracy: 1e-9)
        store.undo()
        store.undo()
        XCTAssertEqual(store.clips[id]?.title?.width ?? 0, 0.4, accuracy: 1e-9, "one undo per drag")
        store.undo()
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.26, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, undoName)
        // Escape mid-drag: back where it was, no undo step; the rest of the gesture writes nothing.
        model.applyDrag(.body, translation: CGSize(width: 300, height: 0))
        XCTAssertNotEqual(store.clips[id]?.title?.x ?? 0, 0.26, accuracy: 1e-9)
        store.cancelActiveGesture?()
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.26, accuracy: 1e-9)
        model.applyDrag(.body, translation: CGSize(width: 400, height: 0))
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.26, accuracy: 1e-9)
        model.endDrag()
        XCTAssertEqual(store.undoActionName, undoName)
        // The width stays in its range.
        model.applyDrag(.edge(right: false), translation: CGSize(width: 5000, height: 0))
        model.endDrag()
        XCTAssertEqual(store.clips[id]?.title?.width ?? 0, 0.02, accuracy: 1e-12)
    }

    func testADragFollowsThePointerUnderAZoomAndATurn() async throws {
        let (id, model) = try lowerThird()
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 2, rotationDegrees: 90, opacity: 1),
                                                  forClip: id).ok)
        let before = model.box.center
        // Down the frame by 200 pixels: along the turned canvas's x axis, 100 canvas pixels at 2x.
        model.applyDrag(.body, translation: CGSize(width: 0, height: 200))
        model.endDrag()
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.26 + 100.0 / 1920, accuracy: 1e-9)
        XCTAssertEqual(store.clips[id]?.title?.y ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(model.box.center.x, before.x, accuracy: 1e-6, "the box followed the pointer")
        XCTAssertEqual(model.box.center.y, before.y + 200, accuracy: 1e-6)
        // A locked track refuses the drag with a reason.
        let track = try XCTUnwrap(store.clips[id]).trackID
        XCTAssertTrue(store.engine.setTrack(track, locked: true).ok)
        store.refreshModel()
        model.applyDrag(.body, translation: CGSize(width: 10, height: 0))
        XCTAssertFalse(model.isDragging)
        XCTAssertEqual(model.note, "“\(store.track(track)?.name ?? "")” is locked.")
    }

    /// The Ken Burns editor's outlines of the other clips at the playhead show a title's text block, not its
    /// frame-sized canvas, and no colour matte (review fix round, finding 13).
    func testKenBurnsOutlinesATitlesBlockAndNoMatte() async throws {
        let media = try await fixture.importMedia()
        let movie = try fixture.placeMovie(media.movie, at: 0)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let title = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let matte = try XCTUnwrap(store.selection.first)
        let outlines = KenBurnsModel.outlines(at: frames(10), excluding: movie, store: store,
                                              sequence: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(outlines.map(\.clipID), [title], "the title, not the matte")
        let block = try XCTUnwrap(TitleBoxModel.block(of: try XCTUnwrap(store.clips[title]), at: frames(10), store: store))
        XCTAssertEqual(outlines.first?.box, block)
        XCTAssertLessThan(outlines.first?.box.size.width ?? 2000, 1920 * 0.5, "the lower third's block, not the frame")
        XCTAssertNotNil(store.clips[matte])
    }

    func testTheOtherTitlesAreOutlined() async throws {
        let (id, model) = try lowerThird()
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.title))
        let other = try XCTUnwrap(store.selection.first)
        store.selection = [id]
        let box = try XCTUnwrap(store.titleBox)
        XCTAssertTrue(box === model || box.clipID == id)
        box.setPlayhead(frames(5))
        XCTAssertEqual(box.outlines.map(\.clipID), [other])
        assertBox(try XCTUnwrap(box.outlines.first).box, center: CGPoint(x: 960, y: 540),
                  size: CGSize(width: 0.8 * 1920, height: store.engine.titleBlockSize(ofClip: other).height),
                  rotation: 0)
        // The overlay draws over the monitor.
        let hosted = HostedView(TitleBoxOverlay(model: box, playhead: store.playhead,
                                                viewport: KenBurnsViewport(sequence: CGSize(width: 1920, height: 1080),
                                                                           monitor: CGSize(width: 640, height: 360),
                                                                           margin: 0)),
                                size: NSSize(width: 640, height: 360))
        defer { hosted.close() }
        let pixels = await hosted.pixels()
        XCTAssertFalse(pixels.isEmpty)
    }

    // MARK: Drawing a drag (2026-10-03)

    /// A paused program view (no window: it draws on its render thread all the same) over the movie at 0 with the
    /// lower third over it, selected, the playhead on frame 10; returns once the frame is drawn with every layer.
    private func programViewWithLowerThird() async throws -> (VEPreviewView, TitleBoxModel) {
        let view = VEPreviewView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        store.attachProgramView(view)
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        let (_, model) = try lowerThird()
        let drawn = await StoreFixture.wait(until: { view.renderCount > 0 && view.missingLayerCount == 0 }, timeout: 20)
        XCTAssertTrue(drawn, "the movie and the lower third were drawn")
        // Settled: the stopped lookahead and the audio warm-up have run.
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        return (view, model)
    }

    /// Waits on the main thread without letting it turn (no main-queue block, no SwiftUI update runs) until the
    /// view drew more than `count` frames, or `timeout` passes.
    private func waitWithoutTurning(_ view: VEPreviewView, drawnMoreThan count: UInt,
                                    timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while view.renderCount <= count, Date() < deadline {
            usleep(200)
        }
        return view.renderCount > count
    }

    /// A step of a move drag is drawn by the paused program monitor at once, on its render thread: before the main
    /// thread's next turn (which, in the app, is SwiftUI updating the window for the edit), from the title's cached
    /// picture (no new render, nothing asked of the decode pool), once (the controller's later request for the same
    /// edit draws nothing).
    func testAMoveStepIsDrawnAtOnceFromTheCachedPicture() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let (view, model) = try await programViewWithLowerThird()
        defer { store.engine.attachProgramView(nil) }
        for step in 1 ... 5 {
            let renders = view.renderCount
            let before = store.engine.playbackStats
            model.applyDrag(.body, translation: CGSize(width: 20 * step, height: 10 * step))
            guard waitWithoutTurning(view, drawnMoreThan: renders) else {
                XCTFail("step \(step) was not drawn until the main thread turned")
                return
            }
            let after = store.engine.playbackStats
            XCTAssertEqual(view.renderCount, renders + 1, "step \(step) drawn once")
            XCTAssertEqual(after.presentedFrames, before.presentedFrames + 1, "a new frame for step \(step)")
            XCTAssertEqual(after.cacheMisses, before.cacheMisses,
                           "step \(step): the title's picture was not rendered again")
            XCTAssertEqual(view.missingLayerCount, 0)
        }
        let drawn = view.renderCount
        let presented = store.engine.playbackStats.presentedFrames
        model.endDrag()
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        XCTAssertEqual(view.renderCount, drawn, "the controller's requests for the same edits drew nothing more")
        XCTAssertEqual(store.engine.playbackStats.presentedFrames, presented)
        XCTAssertEqual(store.clips[store.titleBox?.clipID ?? 0]?.title?.x ?? 0, 0.26 + 100.0 / 1920, accuracy: 1e-9)
    }

    /// A step of a wrap-width drag needs a new picture: the monitor keeps showing the previous one (never the frame
    /// without the title) while the pool renders it off the main thread, then draws the new one.
    func testAWidthStepKeepsThePreviousPictureUntilTheNewOneLands() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let (view, model) = try await programViewWithLowerThird()
        defer { store.engine.attachProgramView(nil) }
        let renders = view.renderCount
        let before = store.engine.playbackStats
        model.applyDrag(.edge(right: true), translation: CGSize(width: 96, height: 0))
        XCTAssertFalse(waitWithoutTurning(view, drawnMoreThan: renders, timeout: 0.3) && view.missingLayerCount > 0,
                       "never the frame without the title")
        let landed = await StoreFixture.wait(until: {
            self.store.engine.playbackStats.presentedFrames > before.presentedFrames
        }, timeout: 10)
        XCTAssertTrue(landed, "the new picture was drawn")
        XCTAssertEqual(view.missingLayerCount, 0)
        XCTAssertGreaterThan(store.engine.playbackStats.cacheMisses, before.cacheMisses, "a new picture was needed")
        model.endDrag()
        XCTAssertEqual(store.clips[store.titleBox?.clipID ?? 0]?.title?.width ?? 0, 0.5, accuracy: 1e-9)
    }
}
