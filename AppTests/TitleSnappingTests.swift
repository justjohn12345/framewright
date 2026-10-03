import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Snapping a dragged title box (titles slice 2): the model (each axis on its own, the nearest feature and line within
/// the threshold, a turned box by its bounds), a box moved and widened on the program monitor snapping to the frame's
/// centre lines and the safe-area edges under Motion, Command not snapping, the lines it snapped to shown while the
/// drag lasts, and one undo step per drag.
@MainActor
final class TitleSnappingTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("titleSnapping")
        try fixture.configureSequence() // 1920x1080
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }
    private var lines: [SafeAreas.Line] { SafeAreas(frame: CGSize(width: 1920, height: 1080), standard: .smpte).lines }

    func testTheModelSnapsEachAxisToTheNearestLine() {
        // A box whose centre is 5 px right of the frame's centre line, its top 3 px under title-safe's top (54).
        let box = CGRect(x: 865, y: 57, width: 200, height: 100)
        let snap = TitleSnapping.snap(bounds: box, to: lines, threshold: 8)
        XCTAssertEqual(snap.offset.width, -5, accuracy: 1e-9)
        XCTAssertEqual(snap.offset.height, -3, accuracy: 1e-9)
        XCTAssertEqual(snap.lines, [SafeAreas.Line(kind: .centre, vertical: true, position: 960),
                                    SafeAreas.Line(kind: .titleSafe, vertical: false, position: 54)])
        // Beyond the threshold: nothing.
        XCTAssertEqual(TitleSnapping.snap(bounds: box, to: lines, threshold: 2).offset, CGSize(width: 0, height: 0))
        XCTAssertTrue(TitleSnapping.snap(bounds: box, to: lines, threshold: 2).lines.isEmpty)
        // The nearest of several: a right edge 1 px left of title-safe's right (1824) beats its centre 6 px off centre.
        let right = CGRect(x: 1623, y: 500, width: 200, height: 10)
        let snapped = TitleSnapping.snap(bounds: right, to: lines, threshold: 8)
        XCTAssertEqual(snapped.offset.width, 1, accuracy: 1e-9)
        XCTAssertEqual(snapped.lines.first?.kind, .titleSafe)
        // An edge alone (a width dragged).
        let edge = TitleSnapping.snapEdge(x: 1850, to: lines, threshold: 8)
        XCTAssertEqual(edge?.x ?? 0, 1852.8, accuracy: 1e-9)
        XCTAssertEqual(edge?.line.kind, .actionSafe)
        XCTAssertNil(TitleSnapping.snapEdge(x: 1700, to: lines, threshold: 8))
        // A turned box snaps its bounds.
        let turned = KenBurnsBox(center: CGPoint(x: 963, y: 400), size: CGSize(width: 100, height: 100), rotationDegrees: 45)
        let bounds = TitleBoxModel.bounds(of: turned)
        XCTAssertEqual(bounds.width, 100 * 2.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(TitleSnapping.snap(bounds: bounds, to: lines, threshold: 8).offset.width, -3, accuracy: 1e-9)
    }

    /// A title (centred at 0.5, 0.5) selected with the playhead on it.
    private func title() throws -> (VEClipID, TitleBoxModel) {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.title))
        let id = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(10)
        let box = try XCTUnwrap(store.titleBox)
        box.setPlayhead(frames(10))
        return (id, box)
    }

    func testAMovedBoxSnapsToTheCentreAndTheSafeAreasUnlessCommandIsHeld() async throws {
        let (id, model) = try title()
        // Moved 5 px right and 4 down: the centre lines pull it back, both shown.
        model.applyDrag(.body, translation: CGSize(width: 5, height: 4), snapping: true)
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(store.clips[id]?.title?.y ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(model.snapLines.map(\.kind), [.centre, .centre])
        // Further, with Command: it goes where the pointer says, and no line shows.
        model.applyDrag(.body, translation: CGSize(width: 5, height: 4), snapping: false)
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.5 + 5.0 / 1920, accuracy: 1e-12)
        XCTAssertTrue(model.snapLines.isEmpty)
        // To the left of the frame: its left edge onto title-safe's left (96 px).
        let block = store.engine.titleBlock(ofClip: id)
        let toTitleSafe = 96 - block.minX // the block's left edge at the drag's start
        model.applyDrag(.body, translation: CGSize(width: toTitleSafe + 4, height: 200), snapping: true)
        XCTAssertEqual(store.engine.titleBlock(ofClip: id).minX, 96, accuracy: 1e-6)
        XCTAssertEqual(model.snapLines.map(\.kind), [.titleSafe])
        model.endDrag()
        XCTAssertTrue(model.snapLines.isEmpty, "the lines go when the drag ends")
        XCTAssertEqual(store.undoActionName, "Move Title")
        store.undo()
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.5, accuracy: 1e-12, "one undo step")
    }

    func testABoxUnderMotionSnapsWhereItIsOnTheFrame() async throws {
        let (id, model) = try title()
        // Zoomed 1.5x and moved 30 px right: the block's centre is on the frame at 990.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 30, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: id).ok)
        model.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        XCTAssertEqual(model.box.center.x, 990, accuracy: 1e-6)
        // A drag of 27 px left on the frame: 3 px from the centre line, so it snaps onto it.
        model.applyDrag(.body, translation: CGSize(width: -27, height: 0), snapping: true)
        model.endDrag()
        XCTAssertEqual(model.box.center.x, 960, accuracy: 1e-6)
        // On the canvas that is 30 px / 1.5 = 20 px left of the centre.
        XCTAssertEqual(store.clips[id]?.title?.x ?? 0, 0.5 - 20.0 / 1920, accuracy: 1e-12)
    }

    func testADraggedEdgeSnapsUnlessTheBoxIsTurned() async throws {
        let (id, model) = try title()
        // The right edge of the 0.8-wide box is at 1728; dragged 122 px right it is 2.8 px from action-safe (1852.8).
        model.applyDrag(.edge(right: true), translation: CGSize(width: 122, height: 0), snapping: true)
        model.endDrag()
        XCTAssertEqual(store.engine.titleBlock(ofClip: id).maxX, 1852.8, accuracy: 1e-6)
        XCTAssertEqual(store.undoActionName, "Resize Title")
        // Turned: the edge is not vertical on the frame, and does not snap.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 10, opacity: 1),
                                                  forClip: id).ok)
        model.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        let width = try XCTUnwrap(store.clips[id]?.title?.width)
        model.applyDrag(.edge(right: true), translation: CGSize(width: 10, height: 0), snapping: true)
        model.endDrag()
        let expected = width + 2 * Double(TitleBoxModel.canvasTranslation(CGSize(width: 10, height: 0),
                                                                          motion: store.clips[id]!.motion(at: frames(10)))!
                                              .width) / 1920
        XCTAssertEqual(store.clips[id]?.title?.width ?? 0, expected, accuracy: 1e-12)
        XCTAssertTrue(model.snapLines.isEmpty)
    }
}
