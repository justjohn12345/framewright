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

    func testTheHueCurvesRules() {
        XCTAssertEqual(CurveChannel.allCases.count, 7)
        XCTAssertTrue(CurveChannel.hueHue.isHue)
        XCTAssertEqual(CurveChannel.hueLuma.hueCurve, .luma)
        XCTAssertNil(CurveChannel.red.hueCurve)
        // No points: none shown (a flat line at no change); one point is a curve; x stays below 1.
        XCTAssertEqual(CurveEditing.editable([], periodic: true), [])
        let one = CurveEditing.adding(CGPoint(x: 1.4, y: 0.8), to: [], periodic: true)
        XCTAssertEqual(one?.points, [CGPoint(x: CurveEditing.hueLimit, y: 0.8)])
        let two = CurveEditing.adding(CGPoint(x: 0.2, y: 0.3), to: one?.points ?? [], periodic: true)
        XCTAssertEqual(two?.index, 0)
        let moved = CurveEditing.moving(1, to: CGPoint(x: 2, y: 0.5), in: two?.points ?? [], periodic: true)
        XCTAssertEqual(moved[1].x, CurveEditing.hueLimit, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.removing(0, from: [CGPoint(x: 0.4, y: 0.9)], periodic: true), [],
                       "the last point removed: the identity")
        XCTAssertEqual(CurveEditing.removing(0, from: two?.points ?? [], periodic: true).count, 1)
    }

    func testHueCurveEditsOverTheSelection() async throws {
        let (movie, _) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        store.selection = [first]
        tools.curveChannel = .hueSaturation
        tools.beginCurveDrag(.hueSaturation)
        var working = CurveEditing.adding(CGPoint(x: 0.3, y: 0.5), to: [], periodic: true)!.points
        working = CurveEditing.moving(0, to: CGPoint(x: 0.3, y: 0.1), in: working, periodic: true)
        tools.setCurve(.hueSaturation, working)
        tools.endDrag()
        XCTAssertEqual(store.clips[first]?.gradeHueCurvePoints(.saturation).map(\.pointValue), working)
        XCTAssertEqual(store.undoActionName, "Change Hue vs Saturation Curve")
        XCTAssertEqual(tools.curve(.hueSaturation).points, working)
        XCTAssertTrue(tools.anyCurveSet)
        tools.resetCurves()
        XCTAssertFalse(store.clips[first]?.hasGrade ?? true)
    }

    /// The user's report: a point dragged in the editor disappeared on release (the curve drawn back to the
    /// identity) and the next press started from the identity again, overwriting the curve. The engine kept the
    /// curve; the editor did not redraw, because the Curves section observed only the tools model, which did
    /// not announce the selection's clips changing. The drag is made as the editor makes it (press on empty
    /// space adds a point, moving it, release), then: the clip has the curve, the section's inputs have it, the
    /// hosted Colour tab draws what a newly opened one draws, and a second press on the point grabs it.
    func testTheEditorKeepsTheCurveAfterTheDrag() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]
        let panel = HostedView(ColourPanel(store: store), size: NSSize(width: 320, height: 1400))
        defer { panel.close() }
        await panel.settle()
        let identity = await panel.pixels()
        var announced = 0
        let watch = tools.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }

        // The first press, on empty space: a point added there and dragged up.
        let side: CGFloat = 200
        let shown = CurveEditing.editable(tools.curve(.luma).points)
        let press = CurveEditing.viewPoint(CGPoint(x: 0.5, y: 0.5), side: side)
        XCTAssertNil(CurveEditing.hit(press, in: shown, side: side))
        let added = try XCTUnwrap(CurveEditing.adding(CurveEditing.curvePoint(press, side: side), to: shown))
        tools.beginCurveDrag(.luma)
        tools.setCurve(.luma, added.points)
        let lifted = CurveEditing.moving(added.index, to: CGPoint(x: 0.5, y: 0.8), in: added.points)
        tools.setCurve(.luma, lifted)
        tools.endDrag()
        XCTAssertEqual(store.clips[clip]?.gradeCurvePoints(.luma).map(\.pointValue), lifted, "the engine has the curve")
        XCTAssertGreaterThan(announced, 0, "the tools model announced the change to the views observing it")
        let state = tools.curve(.luma)
        XCTAssertEqual(state.points, lifted, "what the section gives the editor")
        XCTAssertFalse(state.mixed)

        let fresh = HostedView(ColourPanel(store: store), size: NSSize(width: 320, height: 1400))
        defer { fresh.close() }
        await fresh.settle()
        let reopened = await fresh.pixels()
        XCTAssertNotEqual(reopened, identity, "the curve changes the drawing")
        let live = await panel.pixels()
        XCTAssertTrue(live == reopened, "the editor shows the curve after the release, not the identity")

        // The second press, on the point: it grabs it (no point added, the curve not reset) and moves it.
        let shownAgain = CurveEditing.editable(tools.curve(.luma).points)
        XCTAssertEqual(shownAgain, lifted)
        let grabbed = try XCTUnwrap(CurveEditing.hit(CurveEditing.viewPoint(lifted[1], side: side), in: shownAgain,
                                                     side: side))
        XCTAssertEqual(grabbed, 1)
        tools.beginCurveDrag(.luma)
        let lowered = CurveEditing.moving(grabbed, to: CGPoint(x: 0.6, y: 0.3), in: shownAgain)
        tools.setCurve(.luma, lowered)
        tools.endDrag()
        XCTAssertEqual(tools.curve(.luma).points, [CGPoint(x: 0, y: 0), CGPoint(x: 0.6, y: 0.3), CGPoint(x: 1, y: 1)])
        store.undo()
        XCTAssertEqual(tools.curve(.luma).points, lifted, "each drag is one undo step")
        // Another selection is announced too (the editor shows the newly selected clip's curve).
        announced = 0
        store.selection = []
        XCTAssertGreaterThan(announced, 0)
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
