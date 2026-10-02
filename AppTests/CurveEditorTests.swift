import AppKit
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The Colour tab's curves: the editor's rules (`CurveEditing`: the identity shown as its two ends, adding in
/// x order with at most 16 points and none on top of another, moving between the neighbours, removing down to
/// the identity, hit testing, drag-out), and the tools model's curve edits over the selection (one and
/// several clips, mixed, a drag as one undo step, resets).
@MainActor
final class CurveEditorTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var tools: GradeToolsModel { store.gradeTools }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("curves")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    func testTheEditorsRules() {
        let identity = CurveEditing.editable([])
        XCTAssertEqual(identity, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        // Adding: in x order, limited to [0, 1].
        let added = try? XCTUnwrap(CurveEditing.adding(CGPoint(x: 0.4, y: 1.3), to: []))
        XCTAssertEqual(added?.index, 1)
        XCTAssertEqual(added?.points, [CGPoint(x: 0, y: 0), CGPoint(x: 0.4, y: 1), CGPoint(x: 1, y: 1)])
        XCTAssertNil(CurveEditing.adding(CGPoint(x: 0.405, y: 0.2), to: added?.points ?? []), "on top of another point")
        var full: [CGPoint] = []
        for i in 0 ..< 16 { full.append(CGPoint(x: CGFloat(i) / 15, y: CGFloat(i) / 30)) }
        XCTAssertNil(CurveEditing.adding(CGPoint(x: 0.51, y: 0.5), to: full), "16 points at most")
        // Moving: between the neighbours (a gap kept), limited to [0, 1].
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]
        let right = CurveEditing.moving(1, to: CGPoint(x: 2, y: -1), in: points)[1]
        XCTAssertEqual(right.x, 0.99, accuracy: 1e-12)
        XCTAssertEqual(right.y, 0)
        XCTAssertEqual(CurveEditing.moving(1, to: CGPoint(x: -1, y: 0.7), in: points)[1], CGPoint(x: 0.01, y: 0.7))
        XCTAssertEqual(CurveEditing.moving(0, to: CGPoint(x: 0.2, y: 0.1), in: points)[0], CGPoint(x: 0.2, y: 0.1))
        XCTAssertEqual(CurveEditing.moving(7, to: .zero, in: points), points, "no such point: unchanged")
        // Removing: down to the identity.
        XCTAssertEqual(CurveEditing.removing(1, from: points), [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        XCTAssertEqual(CurveEditing.removing(0, from: [CGPoint(x: 0, y: 0.2), CGPoint(x: 1, y: 1)]), [])
        // Hit testing and the view's coordinates (y up in the curve, down in the view).
        XCTAssertEqual(CurveEditing.viewPoint(CGPoint(x: 0.5, y: 0.25), side: 200), CGPoint(x: 100, y: 150))
        XCTAssertEqual(CurveEditing.curvePoint(CGPoint(x: 100, y: 150), side: 200), CGPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(CurveEditing.hit(CGPoint(x: 104, y: 97), in: points, side: 200), 1)
        XCTAssertNil(CurveEditing.hit(CGPoint(x: 140, y: 100), in: points, side: 200))
        XCTAssertEqual(CurveEditing.hit(CGPoint(x: 2, y: 197), in: [], side: 200), 0, "the identity's ends")
        XCTAssertTrue(CurveEditing.isDraggedOut(CGPoint(x: 230, y: 100), side: 200))
        XCTAssertFalse(CurveEditing.isDraggedOut(CGPoint(x: 210, y: -10), side: 200))
    }

    func testCurveEditsOverTheSelection() async throws {
        let (movie, _) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        func points(_ id: VEClipID, _ curve: VEGradeCurve) -> [CGPoint] {
            store.clips[id]?.gradeCurvePoints(curve).map(\.pointValue) ?? []
        }
        store.selection = [first]
        let sCurve = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.85), CGPoint(x: 1, y: 1)]
        tools.setCurve(.luma, sCurve)
        XCTAssertEqual(points(first, .luma), sCurve)
        XCTAssertEqual(store.undoActionName, "Change Luma Curve")
        XCTAssertEqual(tools.curve(.luma).points, sCurve)
        XCTAssertFalse(tools.curve(.luma).mixed)

        store.selection = [first, second]
        XCTAssertTrue(tools.curve(.luma).mixed)
        XCTAssertFalse(tools.curve(.red).mixed)
        // A drag (add a point, move it) over both clips: one undo step, both get the curve.
        tools.curveChannel = .red
        tools.beginCurveDrag(.red)
        var working = CurveEditing.adding(CGPoint(x: 0.5, y: 0.5), to: [])!.points
        for y in [0.55, 0.6, 0.7] {
            working = CurveEditing.moving(1, to: CGPoint(x: 0.5, y: y), in: working)
            tools.setCurve(.red, working)
        }
        tools.endDrag()
        XCTAssertEqual(points(second, .red), working)
        XCTAssertEqual(points(first, .red), working)
        XCTAssertEqual(store.undoActionName, "Change Red Curve")
        store.undo()
        XCTAssertEqual(points(second, .red), [], "one undo step")
        store.redo()
        XCTAssertTrue(tools.anyCurveSet)
        // A curve back to the identity, then all of them.
        tools.resetCurve(.red)
        XCTAssertEqual(points(first, .red), [])
        XCTAssertEqual(points(first, .luma), sCurve, "one curve's reset keeps the others")
        tools.resetCurves()
        XCTAssertEqual(store.undoActionName, "Reset Curves")
        XCTAssertFalse(tools.anyCurveSet)
        XCTAssertFalse(store.clips[first]?.hasGrade ?? true)
    }
}
