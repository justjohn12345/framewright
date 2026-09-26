import AppKit
import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Ken Burns editor's two modes (the Ken Burns and Transform round): Ken Burns shows the clip
/// alone at identity (the engine's program preview solo) with rectangles that are the part of the
/// picture filling the frame, Transform the composed program with placement boxes; both express the
/// same span values (the geometries and their round trip, a turned clip), switching writes nothing,
/// the rectangles stay inside the frame box (what the monitor shows at 100 %, the bars of a source of
/// another aspect included) and are at least a tenth of the frame wide, and the mode is
/// remembered per span. The entry points record their intent (the Effects tab's Ken Burns and Move,
/// the Clip and context menus) and Control-K and selection use the automatic mode. The movie is 10 s
/// (300 frames) at 320x180, filling the 1920x1080 frame.
@MainActor
final class KenBurnsModesTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "ken-burns-modes-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private let sequence = CGSize(width: 1920, height: 1080)

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    /// The 10 s movie at `seconds` on V1 (or `track`).
    private func longClip(at seconds: Double = 0, track: VETrackID? = nil) async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try TestMediaFactory.writeMovie(to: url, frames: 300)
        }
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        return try fixture.placeMovie(try XCTUnwrap(imported.first), at: seconds, track: track)
    }

    private func span(_ id: VESpanID) throws -> VEEffectSpan {
        try XCTUnwrap(store.engine.spanInfo(id))
    }

    /// The Motion an edge of `span` shows (absolute).
    private func edge(_ span: VESpanID, of clip: VEClipID, atEnd: Bool) throws -> VEVideoParams {
        var motion = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&motion, atEdgeOfSpan: span, atEnd: atEnd,
                                                                 frameDuration: store.frameDuration))
        return motion
    }

    private func assertBox(_ box: KenBurnsBox, center: CGPoint, size: CGSize, rotation: Double = 0,
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.center.x, center.x, accuracy: 1e-6, "centre x " + message, file: file, line: line)
        XCTAssertEqual(box.center.y, center.y, accuracy: 1e-6, "centre y " + message, file: file, line: line)
        XCTAssertEqual(box.size.width, size.width, accuracy: 1e-6, "width " + message, file: file, line: line)
        XCTAssertEqual(box.size.height, size.height, accuracy: 1e-6, "height " + message, file: file, line: line)
        XCTAssertEqual(box.rotationDegrees, rotation, accuracy: 1e-9, "rotation " + message, file: file, line: line)
    }

    private func assertSame(_ a: VESpanValues, _ b: VESpanValues, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-12, "x " + message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-12, "y " + message, file: file, line: line)
        XCTAssertEqual(a.scale, b.scale, accuracy: 1e-12, "scale " + message, file: file, line: line)
        XCTAssertEqual(a.rotationDegrees, b.rotationDegrees, accuracy: 1e-12, "rotation " + message, file: file, line: line)
    }

    /// Where the compositor draws the picture point `p` (sequence pixels of the fitted, unplaced
    /// picture) for a clip placed by `m`: the frame's centre + (x, y) + s R(θ) (p - the centre).
    private func placed(_ p: CGPoint, by m: VEVideoParams) -> CGPoint {
        let theta = m.rotationDegrees * .pi / 180
        let dx = p.x - sequence.width / 2
        let dy = p.y - sequence.height / 2
        return CGPoint(x: sequence.width / 2 + m.x + m.scale * (cos(theta) * dx - sin(theta) * dy),
                       y: sequence.height / 2 + m.y + m.scale * (sin(theta) * dx + cos(theta) * dy))
    }

    // MARK: The two geometries

    /// The same values give consistent shapes in both modes: the Ken Burns rectangle's corners are
    /// the picture points the compositor puts on the frame's corners, the Transform box's corners are
    /// where it puts the picture's corners; each converts back to the values (to 1e-9), and one
    /// converts into the other through the values. With no rotation the rectangle is the original
    /// editor's (centre = frame centre - (x, y) / s, before commit 666143e); with one its centre is the
    /// original's too (which turned it by R(-θ)), and it is drawn turned by -θ.
    func testTheTwoGeometriesDescribeTheSamePlacement() {
        let wide = CGSize(width: 320, height: 180)
        let portrait = CGSize(width: 1080, height: 1920)
        let cases: [(VEVideoParams, CGSize)] = [
            (VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: 0, y: 0, scale: 1.25, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: -150, y: 84.5, scale: 1.6, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: -100, y: 50, scale: 2.5, rotationDegrees: 30, opacity: 1), wide),
            (VEVideoParams(x: 12.5, y: -400, scale: 2, rotationDegrees: -90, opacity: 1), portrait),
            (VEVideoParams(x: 333, y: 17, scale: 0.75, rotationDegrees: 187.5, opacity: 1), wide),
        ]
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: sequence.width, y: 0),
                       CGPoint(x: sequence.width, y: sequence.height), CGPoint(x: 0, y: sequence.height)]
        for (m, picture) in cases {
            let label = "\(m.x), \(m.y), \(m.scale), \(m.rotationDegrees)"
            let rect = KenBurnsModel.rect(for: m, sequence: sequence)
            let box = KenBurnsModel.box(for: m, picture: picture, sequence: sequence)
            XCTAssertEqual(rect.size.width, sequence.width / m.scale, accuracy: 1e-9, label)
            XCTAssertEqual(rect.size.height, sequence.height / m.scale, accuracy: 1e-9, label)
            XCTAssertEqual(rect.rotationDegrees, -m.rotationDegrees, accuracy: 1e-12, label)
            // What fills the frame: the rectangle's corners land on the frame's corners.
            for (corner, frameCorner) in zip(rect.corners, corners) {
                let shown = placed(corner, by: m)
                XCTAssertEqual(shown.x, frameCorner.x, accuracy: 1e-9, label)
                XCTAssertEqual(shown.y, frameCorner.y, accuracy: 1e-9, label)
            }
            // Where the clip sits: the fitted picture's corners land on the box's corners.
            let fitted = KenBurnsModel.fittedSize(picture: picture, sequence: sequence)
            let pictureCorners = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)]
                .map { CGPoint(x: sequence.width / 2 + $0.x * fitted.width / 2, y: sequence.height / 2 + $0.y * fitted.height / 2) }
            for (corner, boxCorner) in zip(pictureCorners, box.corners) {
                let shown = placed(corner, by: m)
                XCTAssertEqual(shown.x, boxCorner.x, accuracy: 1e-9, label)
                XCTAssertEqual(shown.y, boxCorner.y, accuracy: 1e-9, label)
            }
            // Each converts back to the values.
            let fromRect = try? XCTUnwrap(KenBurnsModel.motion(forRect: rect, sequence: sequence))
            let fromBox = KenBurnsModel.motion(for: box, picture: picture, sequence: sequence)
            for back in [fromRect, fromBox] {
                XCTAssertEqual(back?.framing.x ?? .nan, m.x, accuracy: 1e-9, label)
                XCTAssertEqual(back?.framing.y ?? .nan, m.y, accuracy: 1e-9, label)
                XCTAssertEqual(back?.framing.scale ?? .nan, m.scale, accuracy: 1e-12, label)
                XCTAssertEqual(back?.rotationDegrees ?? .nan, m.rotationDegrees, accuracy: 1e-12, label)
            }
            // One mode's shape into the other's through the values (what switching does).
            if let fromRect {
                let again = KenBurnsModel.box(for: VEVideoParams(x: fromRect.framing.x, y: fromRect.framing.y,
                                                                 scale: fromRect.framing.scale,
                                                                 rotationDegrees: fromRect.rotationDegrees, opacity: 1),
                                              picture: picture, sequence: sequence)
                assertBox(again, center: box.center, size: box.size, rotation: box.rotationDegrees, label)
            }
            let back = KenBurnsModel.rect(for: VEVideoParams(x: fromBox.framing.x, y: fromBox.framing.y,
                                                             scale: fromBox.framing.scale,
                                                             rotationDegrees: fromBox.rotationDegrees, opacity: 1),
                                          sequence: sequence)
            assertBox(back, center: rect.center, size: rect.size, rotation: rect.rotationDegrees, label)
            // The original editor's rect(for:) (history before 666143e): v = -(x, y) / s, centre =
            // frame centre + R(-θ) v, size = frame / s.
            let theta = m.rotationDegrees * .pi / 180
            let vx = -m.x / m.scale
            let vy = -m.y / m.scale
            XCTAssertEqual(rect.center.x, sequence.width / 2 + cos(theta) * vx + sin(theta) * vy, accuracy: 1e-9, label)
            XCTAssertEqual(rect.center.y, sequence.height / 2 - sin(theta) * vx + cos(theta) * vy, accuracy: 1e-9, label)
            if m.rotationDegrees == 0 {
                XCTAssertEqual(rect.center.x, sequence.width / 2 - m.x / m.scale, accuracy: 1e-9, label)
                XCTAssertEqual(rect.center.y, sequence.height / 2 - m.y / m.scale, accuracy: 1e-9, label)
            }
        }
        // Scale 0: nothing of the clip fills the frame, an empty rectangle with no values.
        let empty = KenBurnsModel.rect(for: VEVideoParams(x: 10, y: 0, scale: 0, rotationDegrees: 0, opacity: 1),
                                       sequence: sequence)
        XCTAssertEqual(empty.size, .zero)
        XCTAssertNil(KenBurnsModel.motion(forRect: empty, sequence: sequence))
    }

    /// The automatic mode: Ken Burns when the clip's placement at the span's start spans the frame on
    /// at least one axis (left edge to right edge, or top to bottom, somewhere on the frame, to within a
    /// pixel): a full-frame clip, one zoomed in on, a letterboxed or pillarboxed picture at identity;
    /// Transform when it spans neither (a picture in picture, scaled down, moved off the frame).
    func testTheAutomaticModeFollowsWhetherTheClipCoversTheFrame() {
        let wide = CGSize(width: 320, height: 180)
        let letterboxed = CGSize(width: 2048, height: 872)
        let portrait = CGSize(width: 1080, height: 1920)
        func mode(_ x: Double, _ y: Double, _ scale: Double, _ rotation: Double = 0,
                  picture: CGSize = CGSize(width: 320, height: 180)) -> KenBurnsMode {
            KenBurnsModel.automaticMode(start: VEVideoParams(x: x, y: y, scale: scale, rotationDegrees: rotation, opacity: 1),
                                        picture: picture, sequence: sequence)
        }
        XCTAssertEqual(mode(0, 0, 1), .kenBurns, "a full-frame clip")
        XCTAssertEqual(mode(100, -60, 1.25), .kenBurns, "zoomed in and offset, still over the whole frame")
        XCTAssertEqual(mode(200, 0, 1), .kenBurns, "moved sideways: still top to bottom (a bar on the left)")
        XCTAssertEqual(mode(2500, 0, 1), .transform, "moved off the frame: spans neither")
        XCTAssertEqual(mode(690, 324, 0.3), .transform, "a picture in picture")
        XCTAssertEqual(mode(0, 0, 0.9), .transform, "scaled down")
        XCTAssertEqual(mode(0, 0, 1.5, 30), .kenBurns, "turned, larger than the frame: spans it across")
        XCTAssertEqual(mode(0, 0, 2, 30), .kenBurns, "turned and zoomed enough to cover it")
        XCTAssertEqual(mode(0, 0, 1, picture: CGSize(width: 240, height: 320)), .kenBurns, "a pillarboxed portrait")
        XCTAssertEqual(mode(0, 0, 1, picture: portrait), .kenBurns, "a pillarboxed 9:16 portrait")
        XCTAssertEqual(mode(0, 0, 1, picture: letterboxed), .kenBurns, "a letterboxed 2.35:1 picture")
        XCTAssertEqual(mode(0, 300, 1, picture: letterboxed), .kenBurns, "moved down: still across the frame")
        XCTAssertEqual(mode(0, 1000, 1, picture: letterboxed), .transform, "moved below the frame: spans neither")
        XCTAssertEqual(mode(0, 0, 1, 10, picture: letterboxed), .kenBurns, "tilted: a line still runs across it")
        XCTAssertEqual(mode(0, 0, 1, 30, picture: letterboxed), .transform, "turned: no line runs across it")
        // Within a pixel of the frame's edges.
        XCTAssertEqual(mode(0.9, 0, 1, picture: letterboxed), .kenBurns, "0.9 px short on the left")
        XCTAssertEqual(mode(1.5, 0, 1, picture: letterboxed), .transform, "1.5 px short on the left")
        XCTAssertEqual(mode(0, 0, 0.9995), .kenBurns, "0.48 px short on each side")
        XCTAssertEqual(mode(0, 0, 0.998), .transform, "1.92 px short on each side")
        XCTAssertEqual(mode(0, 0, 0), .transform, "invisible")
        XCTAssertEqual(mode(0, 0, 1, picture: wide), .kenBurns)
    }

    // MARK: Ken Burns mode

    /// Ken Burns mode on a full-frame clip: the monitor shows the clip alone (the engine's solo
    /// preview, identity); the start rectangle is the whole picture, the push in's end 1 / 1.25 of
    /// the frame; a pan moves the clip the other way by the zoom; the rectangle stays inside the frame
    /// box (here the picture: it fills the frame) and at least a tenth of the frame wide; a zoom out
    /// against the frame's edge moves it in; one undo step per drag. Switching to Transform and back
    /// writes nothing and gives the same rectangles; the solo preview follows the mode and ends when the
    /// editor closes; the other clips are outlined in Transform mode only.
    func testKenBurnsModeFramesThePictureAloneAndSwitchesWithoutWriting() async throws {
        let clip = try await longClip()
        // A picture in picture over it on V2.
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        let pip = try await longClip(at: 0, track: v2)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1),
                                                  forClip: pip).ok)
        store.selection = [clip]
        store.playheadTime = frames(30)
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID
        XCTAssertEqual(model.mode, .kenBurns)
        XCTAssertEqual(store.kenBurnsMode, .kenBurns)
        XCTAssertEqual(store.kenBurnsModes[id], .kenBurns, "the intent is remembered")
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip, "the monitor shows the clip alone")
        XCTAssertTrue(store.engine.programPreviewSoloIdentityMotion)
        XCTAssertEqual(model.modeCaption, "The rectangle is what fills the frame.")
        XCTAssertEqual(model.outlines, [], "the other tracks are not shown")
        XCTAssertEqual(model.frameBox, CGRect(origin: .zero, size: sequence))
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: sequence, "the whole picture")
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 1536, height: 864), "1 / 1.25")
        XCTAssertEqual(try span(id).endValues.scale, 1.25, accuracy: 1e-12)

        // A pan of the end rectangle 100 px right shows the picture 100 px further right, which moves
        // the clip 125 px left at 1.25x; one undo step.
        let pushIn = model.end
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 60, height: 0))
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: -40))
        model.endDrag()
        XCTAssertEqual(model.end.center.x, 1060, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.x, -125, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.y, 50, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.scale, 1.25, accuracy: 1e-12, "a pan keeps the zoom")
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        store.undo()
        XCTAssertEqual(model.end, pushIn, "one undo step")
        // Panned far: it stops at the frame's edge (here the picture's: it fills the frame).
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 5000, height: 5000))
        model.endDrag()
        XCTAssertEqual(model.end.corner(.bottomRight).x, 1920, accuracy: 1e-9)
        XCTAssertEqual(model.end.corner(.bottomRight).y, 1080, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.x, -1.25 * 192, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.y, -1.25 * 108, accuracy: 1e-9)
        // A corner pulled in stops at a tenth of the frame (a 1000 % zoom), about its centre.
        let panned = model.end
        model.applyDrag(.corner(.end, .topLeft), origin: panned, translation: CGSize(width: 3000, height: 3000))
        model.endDrag()
        assertBox(model.end, center: panned.center, size: CGSize(width: 192, height: 108), "the smallest")
        XCTAssertEqual(try span(id).endValues.scale, 10, accuracy: 1e-9)
        // Pulled out far: the whole frame at most, moved in to stay inside it.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: 9000, height: 9000))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: sequence, "the whole picture again")
        XCTAssertEqual(try span(id).endValues.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)
        store.undo()
        store.undo()
        store.undo()
        XCTAssertEqual(model.end, pushIn)

        // Switching to Transform writes nothing: the same values as boxes over the program, with the
        // other clip outlined, and the program in the monitor again.
        let values = try span(id)
        let changes = store.changeCount
        let rectangles = (model.start, model.end)
        model.setMode(.transform)
        XCTAssertEqual(store.changeCount, changes, "nothing written")
        assertSame(try span(id).startValues, values.startValues)
        assertSame(try span(id).endValues, values.endValues)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
        XCTAssertEqual(store.kenBurnsMode, .transform)
        XCTAssertEqual(store.kenBurnsModes[id], .transform, "the switch is remembered")
        XCTAssertEqual(model.modeCaption, "The box is where the clip sits.")
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 2400, height: 1350), "the push in's box")
        XCTAssertEqual(model.outlines.map(\.clipID), [pip])
        XCTAssertEqual(model.endFraming.scale, 1.25, accuracy: 1e-12)
        // And back: the same rectangles.
        model.setMode(.kenBurns)
        XCTAssertEqual(store.changeCount, changes)
        assertBox(model.start, center: rectangles.0.center, size: rectangles.0.size)
        assertBox(model.end, center: rectangles.1.center, size: rectangles.1.size)
        XCTAssertEqual(model.outlines, [])
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)

        // Closing the editor gives the monitor the program back; reopening keeps the mode.
        store.closeKenBurns()
        XCTAssertNil(store.kenBurnsMode)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
        store.showKenBurns(span: id)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)
        // Selecting the clip closes it too.
        store.selection = [clip]
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
        // Removing the clip while it is open (Ken Burns mode): the editor and the solo end.
        store.select(span: id)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)
        XCTAssertTrue(store.engine.removeClips([NSNumber(value: clip)]).ok)
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
        // Undo brings the span back; selected again, it opens in its remembered mode.
        store.undo()
        store.select(span: id)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)
        // New: the memory and the solo go with the project.
        store.newProject()
        XCTAssertEqual(store.kenBurnsModes, [:])
        XCTAssertNil(store.kenBurnsMode)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
    }

    /// A turned clip in Ken Burns mode: its rectangles are turned against the clip's rotation (the
    /// frame's corners land on theirs), a pan stops where a turned corner meets the frame's edge, and
    /// the rotation is kept.
    func testATurnedClipsRectanglesTurnAgainstItsRotationAndStayInsideTheFrame() async throws {
        let clip = try await longClip()
        let turned = VEVideoParams(x: 0, y: 0, scale: 2, rotationDegrees: 30, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(turned, forClip: clip).ok)
        store.selection = [clip]
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead()
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID
        XCTAssertEqual(model.mode, .kenBurns, "zoomed enough to cover the frame turned")
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: CGSize(width: 960, height: 540), rotation: -30)
        // The push in: 2.5x on screen.
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 768, height: 432), rotation: -30)
        XCTAssertTrue(model.fitsInFrame(model.end))
        // Panned far right: the rectangle's rightmost (turned) corner reaches the frame's right edge.
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 5000, height: 0))
        model.endDrag()
        XCTAssertEqual(model.end.corners.map(\.x).max() ?? 0, 1920, accuracy: 1e-9)
        XCTAssertTrue(model.fitsInFrame(model.end))
        XCTAssertEqual(model.end.rotationDegrees, -30, accuracy: 1e-12)
        let shown = try edge(id, of: clip, atEnd: true)
        XCTAssertEqual(shown.rotationDegrees, 30, accuracy: 1e-9, "the rotation is kept")
        XCTAssertEqual(shown.scale, 2.5, accuracy: 1e-9)
        // What the edge shows is the rectangle: back through the values, the same one.
        assertBox(KenBurnsModel.rect(for: shown, sequence: sequence), center: model.end.center, size: model.end.size,
                  rotation: -30)
        // The widest turned rectangle inside the frame is the zoom out's limit.
        let widest = model.maximumRectWidth(rotationDegrees: -30)
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: 9000, height: 5000))
        model.endDrag()
        XCTAssertEqual(model.end.size.width, widest, accuracy: 1e-6)
        XCTAssertTrue(model.fitsInFrame(model.end))
        let cosine = cos(Double.pi / 6)
        XCTAssertEqual(widest, 1920 * min(1920 / (cosine * 1920 + 0.5 * 1080), 1080 / (0.5 * 1920 + cosine * 1080)),
                       accuracy: 1e-6)
    }

    /// On a pillarboxed portrait still (810 px of picture across the frame's 1920) the rectangles are
    /// held to the frame box, not the picture: the push in's End pans over the bars; a rectangle placed
    /// past the frame's edge (typed values) is not pulled in by a drag's first step and moves back in
    /// freely; once inside it stays inside, and a zoom out stops at the whole frame.
    func testARectangleOutsideTheFrameDoesNotJump() async throws {
        let url = fixture.directory.appendingPathComponent("portrait.heic")
        try TestMediaFactory.writeHEIC(to: url, width: 240, height: 320)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let still = try fixture.placeMovie(try XCTUnwrap(imported.first), at: 0)
        store.selection = [still]
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.mode, .kenBurns, "asked for (and the automatic mode: it spans the frame top to bottom)")
        XCTAssertEqual(model.frameBox, CGRect(origin: .zero, size: sequence))
        XCTAssertEqual(KenBurnsModel.fittedSize(picture: model.pictureSize, sequence: sequence),
                       CGSize(width: 810, height: 1080))
        // The push in's End (1536 px, wider than the picture) is inside the frame: it pans across the
        // bars, as far as the frame's edge.
        let end = model.end
        XCTAssertTrue(model.fitsInFrame(end))
        model.applyDrag(.body(.end), origin: end, translation: CGSize(width: 150, height: 30))
        model.endDrag()
        XCTAssertEqual(model.end.center.x, 1110, accuracy: 1e-9, "room across (1536 of the frame's 1920)")
        XCTAssertEqual(model.end.center.y, 570, accuracy: 1e-9, "room down (864 of the frame's 1080)")
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 500, height: 0))
        model.endDrag()
        XCTAssertEqual(model.end.corner(.topRight).x, 1920, accuracy: 1e-9, "stops at the frame's edge")
        // The start placed past the frame's left edge: 3x, 2000 px right (its centre 666.7 px left of
        // the frame's, its left edge 26.7 px off the frame).
        var typed = VESpanValuesUnchanged()
        typed.x = 2000
        typed.scale = 3
        XCTAssertTrue(store.engine.setSpanValues(model.spanID, start: typed, end: VESpanValuesUnchanged()).ok)
        let outside = model.start
        assertBox(outside, center: CGPoint(x: 960 - 2000.0 / 3, y: 540), size: CGSize(width: 640, height: 360))
        XCTAssertFalse(model.fitsInFrame(outside))
        model.applyDrag(.body(.start), origin: outside, translation: CGSize(width: -10, height: 0))
        XCTAssertEqual(model.start.center.x, outside.center.x, accuracy: 1e-9, "no further out")
        model.applyDrag(.body(.start), origin: outside, translation: CGSize(width: 40, height: 0))
        XCTAssertEqual(model.start.center.x, outside.center.x + 40, accuracy: 1e-9, "no jump: 40 px in")
        model.endDrag()
        // Moved into the frame it stops at its right edge, over the bar there.
        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: 3000, height: 0))
        model.endDrag()
        XCTAssertEqual(model.start.corner(.topRight).x, 1920, accuracy: 1e-9)
        XCTAssertTrue(model.fitsInFrame(model.start))
        // Zoomed out: at most the whole frame (100 %), moved in to stay inside it.
        model.applyDrag(.corner(.start, .bottomRight), origin: model.start, translation: CGSize(width: 2000, height: 1200))
        model.endDrag()
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: sequence)
        XCTAssertTrue(model.fitsInFrame(model.start))
        XCTAssertEqual(model.startFraming.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(model.startFraming.x, 0, accuracy: 1e-9)
    }

    // MARK: Sources of another aspect

    /// A 2048x872 movie (Sintel's frame, 2.35:1: letterboxed in the 1920x1080 frame, 817.5 px of
    /// picture down its 1080), 1 s long (30 frames: the writer fills every pixel), at 0 s on V1.
    private func letterboxedClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("letterboxed.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 30, width: 2048, height: 872)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let movie = try XCTUnwrap(imported.first)
        XCTAssertEqual(movie.width, 2048)
        XCTAssertEqual(movie.height, 872)
        return try fixture.placeMovie(movie, at: 0)
    }

    /// A 1080x1920 portrait still (pillarboxed in the 1920x1080 frame: 607.5 px of picture across its
    /// 1920) at `seconds` on V1.
    private func portraitStill(at seconds: Double = 0) async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("tall.heic")
        try TestMediaFactory.writeHEIC(to: url, width: 1080, height: 1920)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let photo = try XCTUnwrap(imported.first)
        XCTAssertTrue(photo.isStill)
        return try fixture.placeMovie(photo, at: seconds)
    }

    /// Ken Burns mode on `clip`, whose fitted picture is `picture` (inside the frame, with bars): the
    /// rectangles are held to the frame box (what the monitor shows at 100 %, bars included), not to
    /// the picture's pixels, so a corner drag grows the push in's End back to the whole frame (100 %,
    /// no offset) and a body drag pans a smaller rectangle to the frame's corners, over the bars.
    private func checkRectanglesReachTheWholeFrame(of clip: VEClipID, picture: CGRect,
                                                   file: StaticString = #filePath, line: UInt = #line) throws {
        store.selection = [clip]
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        let model = try XCTUnwrap(store.kenBurns, file: file, line: line)
        let id = model.spanID
        XCTAssertEqual(model.mode, .kenBurns, file: file, line: line)
        let fitted = KenBurnsModel.fittedSize(picture: model.pictureSize, sequence: sequence)
        XCTAssertEqual(fitted.width, picture.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(fitted.height, picture.height, accuracy: 1e-9, file: file, line: line)
        // The Start (identity) is the whole frame, bars included; the push in's End is 1 / 1.25 of it.
        let middle = CGPoint(x: 960, y: 540)
        assertBox(model.start, center: middle, size: sequence, "identity", file: file, line: line)
        assertBox(model.end, center: middle, size: CGSize(width: 1536, height: 864), "the push in", file: file, line: line)

        // A corner pulled out far: the whole frame at most (100 %, no offset), one undo step.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: 9000, height: 9000))
        model.endDrag()
        assertBox(model.end, center: middle, size: sequence, "the whole frame", file: file, line: line)
        let whole = try edge(id, of: clip, atEnd: true)
        XCTAssertEqual(whole.scale, 1, accuracy: 1e-9, "100 %", file: file, line: line)
        XCTAssertEqual(whole.x, 0, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(whole.y, 0, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(try span(id).endValues.scale, 1, accuracy: 1e-9, file: file, line: line)

        // Pulled in to half the frame (200 %) about its centre, then panned far up and left: it stops
        // at the frame's top-left corner, showing the bars there as 100 % does.
        model.applyDrag(.corner(.end, .topLeft), origin: model.end, translation: CGSize(width: 480, height: 270))
        model.endDrag()
        assertBox(model.end, center: middle, size: CGSize(width: 960, height: 540), "200 %", file: file, line: line)
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: -5000, height: -5000))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 480, y: 270), size: CGSize(width: 960, height: 540), "top left",
                  file: file, line: line)
        XCTAssertFalse(picture.contains(model.end.corner(.topLeft)), "the corner is on a bar", file: file, line: line)
        var shown = try edge(id, of: clip, atEnd: true)
        XCTAssertEqual(shown.scale, 2, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(shown.x, 960, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(shown.y, 540, accuracy: 1e-9, file: file, line: line)
        // And to the bottom-right corner.
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 9000, height: 9000))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 1440, y: 810), size: CGSize(width: 960, height: 540), "bottom right",
                  file: file, line: line)
        XCTAssertFalse(picture.contains(model.end.corner(.bottomRight)), "the corner is on a bar", file: file, line: line)
        shown = try edge(id, of: clip, atEnd: true)
        XCTAssertEqual(shown.x, -960, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(shown.y, -540, accuracy: 1e-9, file: file, line: line)

        // The Start, the whole frame already, neither moves nor grows.
        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: 300, height: -200))
        model.endDrag()
        model.applyDrag(.corner(.start, .topRight), origin: model.start, translation: CGSize(width: 400, height: -400))
        model.endDrag()
        assertBox(model.start, center: middle, size: sequence, "still identity", file: file, line: line)
        let first = try edge(id, of: clip, atEnd: false)
        XCTAssertEqual(first.scale, 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(first.x, 0, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(first.y, 0, accuracy: 1e-9, file: file, line: line)
    }

    /// Sintel's 2048x872 in a 1920x1080 sequence (the user's report: the End stopped at the picture's
    /// height, about 132 %, and would not grow to the whole frame).
    func testALetterboxedSourcesRectanglesReachTheWholeFrame() async throws {
        let clip = try await letterboxedClip()
        try checkRectanglesReachTheWholeFrame(of: clip, picture: CGRect(x: 0, y: 131.25, width: 1920, height: 817.5))
    }

    /// A 1080x1920 portrait still in a 1920x1080 sequence.
    func testAPillarboxedStillsRectanglesReachTheWholeFrame() async throws {
        let still = try await portraitStill()
        try checkRectanglesReachTheWholeFrame(of: still, picture: CGRect(x: 656.25, y: 0, width: 607.5, height: 1080))
    }

    /// A second span chained after a push in, on a letterboxed source, zooms back out to 100 %: its
    /// End pulled out to the whole frame stores 1 / 1.25 over the held 1.25x.
    func testASecondSpanAfterAPushInZoomsBackOutToTheWholeFrame() async throws {
        let clip = try await letterboxedClip()
        let pushIn = store.engine.addSpan(kind: .motion, lane: 1, clip: clip, range: CMTimeRange(start: .zero, end: frames(15)))
        let first = try XCTUnwrap(pushIn.span, pushIn.message).spanID
        var zoomed = VESpanValuesUnchanged()
        zoomed.scale = 1.25
        XCTAssertTrue(store.engine.setSpanValues(first, start: VESpanValuesUnchanged(), end: zoomed).ok)
        let chained = store.engine.addSpan(kind: .motion, lane: 1, clip: clip,
                                           range: CMTimeRange(start: frames(15), end: frames(30)))
        let second = try XCTUnwrap(chained.span, chained.message).spanID
        store.refreshModel()
        store.select(span: second)
        let model = try XCTUnwrap(store.kenBurns)
        model.setMode(.kenBurns)
        let held = CGSize(width: 1536, height: 864)
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: held, "the push in's held end")
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: held)
        model.applyDrag(.corner(.end, .topRight), origin: model.end, translation: CGSize(width: 2000, height: -2000))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: sequence, "the whole frame")
        XCTAssertEqual(try span(second).endValues.scale, 0.8, accuracy: 1e-9, "1 / 1.25 over the held push in")
        let shown = try edge(second, of: clip, atEnd: true)
        XCTAssertEqual(shown.scale, 1, accuracy: 1e-9, "100 %")
        XCTAssertEqual(shown.x, 0, accuracy: 1e-9)
        XCTAssertEqual(shown.y, 0, accuracy: 1e-9)
    }

    // MARK: The mode per span, and the entry points

    /// Control-K on a clip of another aspect at identity, a letterboxed 2048x872 movie and a
    /// pillarboxed 1080x1920 still, opens in Ken Burns mode (the automatic mode: its placement spans the
    /// frame on one axis; the bars are what 100 % shows): the clip alone, the Start the whole frame. A
    /// picture in picture and a full-frame clip: `testControlKAndSelectionUseTheAutomaticMode...`.
    func testControlKOpensALetterboxedOrPillarboxedClipInKenBurnsMode() async throws {
        let movie = try await letterboxedClip()
        let still = try await portraitStill(at: 2)
        let keyboard = KeyboardController(store: store)
        for (clip, time, label) in [(movie, frames(10), "letterboxed"), (still, frames(70), "pillarboxed")] {
            store.selection = [clip]
            store.playheadTime = time
            keyboard.perform(.addMotionSpan, on: store)
            let model = try XCTUnwrap(store.kenBurns, label)
            XCTAssertEqual(model.mode, .kenBurns, label)
            XCTAssertNil(store.kenBurnsModes[model.spanID], "the automatic mode is not a choice to remember")
            XCTAssertEqual(store.engine.programPreviewSoloClipID, clip, label)
            assertBox(model.start, center: CGPoint(x: 960, y: 540), size: sequence, label)
            XCTAssertEqual(try span(model.spanID).endValues.scale, 1.25, accuracy: 1e-12, "the push in")
            // Selected again with no remembered mode: the automatic one again.
            store.selection = [clip]
            store.select(span: model.spanID)
            XCTAssertEqual(store.kenBurns?.mode, .kenBurns, label)
        }
    }

    /// Control-K opens in the automatic mode (Ken Burns on a clip covering the frame, Transform on a
    /// picture in picture, both with the push in); a span selected with no remembered mode opens in
    /// the automatic one, with one in its own; the mode is per span.
    func testControlKAndSelectionUseTheAutomaticModeUnlessOneIsRemembered() async throws {
        let clip = try await longClip()
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        let pip = try await longClip(at: 0, track: v2)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1),
                                                  forClip: pip).ok)
        let keyboard = KeyboardController(store: store)
        store.playheadTime = frames(15)
        store.selection = [pip]
        keyboard.perform(.addMotionSpan, on: store)
        let pipModel = try XCTUnwrap(store.kenBurns)
        let pipSpan = pipModel.spanID
        XCTAssertEqual(pipModel.mode, .transform, "a picture in picture: Transform")
        XCTAssertNil(store.kenBurnsModes[pipSpan], "the automatic mode is not a choice to remember")
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0, "the program")
        XCTAssertEqual(try span(pipSpan).endValues.scale, 1.25, accuracy: 1e-12, "the push in")
        store.selection = [clip]
        keyboard.perform(.addMotionSpan, on: store)
        let fullModel = try XCTUnwrap(store.kenBurns)
        let fullSpan = fullModel.spanID
        XCTAssertEqual(fullModel.mode, .kenBurns, "a full-frame clip: Ken Burns")
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)
        XCTAssertEqual(try span(fullSpan).endValues.scale, 1.25, accuracy: 1e-12, "the push in")

        // Selected again with no remembered mode: the automatic one, each.
        store.select(span: pipSpan)
        XCTAssertEqual(store.kenBurns?.mode, .transform)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0)
        // Switched: remembered for that span only.
        store.kenBurns?.setMode(.kenBurns)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, pip, "the picture in picture alone, unplaced")
        store.select(span: fullSpan)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        store.kenBurns?.setMode(.transform)
        store.select(span: pipSpan)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns, "remembered")
        store.select(span: fullSpan)
        XCTAssertEqual(store.kenBurns?.mode, .transform, "remembered")
        XCTAssertEqual(store.kenBurnsModes, [pipSpan: .kenBurns, fullSpan: .transform])
        // The rules of Control-K hold for the menus' two items: they act on the selected clip (or
        // span's clip) only.
        store.selectedSpanID = nil
        store.selection = []
        XCTAssertFalse(store.canAddMotionSpanAtPlayhead)
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        XCTAssertEqual(store.statusMessage, "Select a clip first.")
    }

    /// The entry points with an intent: the Effects tab's Ken Burns (the push in, Ken Burns mode) and
    /// Move (the end where the start is, Transform mode), dropped on a lane or added with "+" at the
    /// playhead; Clip > Add Ken Burns… and Add Motion Span. A Ken Burns asked for on a frame where a
    /// Motion span already starts selects it in Ken Burns mode.
    func testTheEntryPointsRecordTheirIntent() async throws {
        let clip = try await longClip()
        XCTAssertEqual(EffectKind.kenBurns.spanKind, .motion)
        XCTAssertEqual(EffectKind.move.spanKind, .motion)
        XCTAssertEqual(EffectKind.kenBurns.motionMode, .kenBurns)
        XCTAssertEqual(EffectKind.move.motionMode, .transform)
        XCTAssertNil(EffectKind.fade.motionMode)
        XCTAssertEqual(EffectKind.kenBurns.trackKind, .video)
        XCTAssertEqual(EffectKind.move.trackKind, .video)

        // Dropped on lane 1 at 1 s: a 5 s Motion span from there.
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let layout = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[clip]).trackID))
        let lane1 = try XCTUnwrap(layout.laneY(1)) - model.scrollY + TimelineViewModel.laneHeight / 2
        let target = try XCTUnwrap(gestures.effectDragUpdated(kind: .kenBurns, at: CGPoint(x: model.x(forTime: 1), y: lane1)))
        XCTAssertEqual(target.start, 1, accuracy: 1e-9)
        XCTAssertEqual(target.end, 6, accuracy: 1e-9)
        XCTAssertTrue(target.allowed)
        XCTAssertTrue(gestures.dropEffect(kind: .kenBurns, at: CGPoint(x: model.x(forTime: 1), y: lane1)))
        let kenBurns = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual(kenBurns.kind, .motion)
        XCTAssertEqual([kenBurns.start, kenBurns.end], [frames(30), frames(180)])
        XCTAssertEqual(kenBurns.endValues.scale, 1.25, accuracy: 1e-12, "the push in")
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        XCTAssertEqual(store.undoActionName, "Add Motion Span")
        // A Move dropped near the clip's end (lane 2): to the clip's end, ending where it starts.
        store.refreshModel()
        let fresh = store.timelineModel
        let lane2 = try XCTUnwrap(try XCTUnwrap(fresh.layout(forTrack: try XCTUnwrap(store.clips[clip]).trackID)).laneY(2))
            - fresh.scrollY + TimelineViewModel.laneHeight / 2
        XCTAssertTrue(gestures.dropEffect(kind: .move, at: CGPoint(x: fresh.x(forTime: 8), y: lane2)))
        let move = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual([move.start, move.end], [frames(240), frames(300)])
        XCTAssertEqual(store.kenBurns?.mode, .transform)
        let start = try edge(move.spanID, of: clip, atEnd: false)
        let end = try edge(move.spanID, of: clip, atEnd: true)
        XCTAssertEqual([end.x, end.y, end.scale, end.rotationDegrees], [start.x, start.y, start.scale, start.rotationDegrees],
                       "nothing moves until a box is dragged")
        XCTAssertEqual(store.kenBurns?.start, store.kenBurns?.end)
        XCTAssertEqual(try span(move.spanID).interpolation, .easeInOut)

        // "+" and the Clip menu: at the playhead on the selected clip, with the intent.
        store.selection = [clip]
        store.playheadTime = frames(200)
        XCTAssertTrue(store.canAddMotionSpanAtPlayhead)
        store.addMotionSpanAtPlayhead(mode: .transform) // Add Motion Span, Move's "+"
        let added = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual(added.start, frames(200))
        XCTAssertEqual(added.endValues.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(store.kenBurns?.mode, .transform)
        store.selection = [clip]
        store.playheadTime = frames(10)
        store.addMotionSpanAtPlayhead(mode: .kenBurns) // Add Ken Burns…, Ken Burns' "+"
        let pushIn = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual(pushIn.start, frames(10))
        XCTAssertEqual(pushIn.endValues.scale, 1.25, accuracy: 1e-12)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        // Asked again on a frame where a Motion span starts: that span, in the asked mode.
        store.selection = [clip]
        store.playheadTime = frames(200)
        let changes = store.changeCount
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        XCTAssertEqual(store.changeCount, changes)
        XCTAssertEqual(store.selectedSpanID, added.spanID)
        XCTAssertEqual(store.kenBurns?.mode, .kenBurns)
        XCTAssertEqual(store.kenBurnsModes[added.spanID], .kenBurns)
    }
}
