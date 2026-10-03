import AppKit
import CoreGraphics
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The program monitor's stage while the Ken Burns editor is open, and its zoom: at Fit the monitor zooms out just
/// enough to show both boxes (or rectangles) with their handles when they reach past the Transform margin (or the
/// frame box in Ken Burns mode), re-fitted when the editor opens and when a drag ends, never during one, and back
/// to Fit when the editor closes or the boxes are inside again; the zoom control's fixed levels and Command-plus /
/// Command-minus / Shift-Z while the monitor has the focus (the timeline's zoom otherwise).
/// The movie is 10 s at 320x180, filling the 1920x1080 frame.
@MainActor
final class ProgramMonitorZoomTests: XCTestCase {
    private var fixture: StoreFixture!
    private let sequence = CGSize(width: 1920, height: 1080)
    private let monitor = CGSize(width: 1000, height: 700)
    /// A Retina display: two pixels per point.
    private let pointsPerPixel: CGFloat = 0.5

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("program-zoom")
        try fixture.configureSequence()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private var standard: KenBurnsViewport {
        KenBurnsViewport(sequence: sequence, monitor: monitor, margin: KenBurnsViewport.marginFraction)
    }

    /// The stage the program monitor's layout shows now (`ProgramMonitorLayout`).
    private func stage() -> KenBurnsViewport {
        KenBurnsViewport.stage(zoom: store.programZoom.zoom, mode: store.kenBurnsMode, extent: store.kenBurnsExtent,
                               sequence: sequence, monitor: monitor, pointsPerPixel: pointsPerPixel)
    }

    /// Every corner of `boxes` (with its handle) is on the monitor with `extentPadding` to spare.
    private func assertShown(_ boxes: [KenBurnsBox], on viewport: KenBurnsViewport, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let area = CGRect(origin: .zero, size: monitor).insetBy(dx: KenBurnsViewport.extentPadding - 1e-6,
                                                                 dy: KenBurnsViewport.extentPadding - 1e-6)
        for corner in boxes.flatMap(\.corners) {
            let point = viewport.view(corner)
            XCTAssertTrue(area.contains(point), "\(message): corner \(corner) at \(point) is off the monitor",
                          file: file, line: line)
        }
    }

    /// The 10 s movie at 0 on V1.
    private func longClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try TestMediaFactory.writeMovie(to: url, frames: 300)
        }
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        return try fixture.placeMovie(try XCTUnwrap(imported.first), at: 0)
    }

    /// The editor on a new Motion span (the push in) of `clip`, in `mode`.
    private func openEditor(on clip: VEClipID, mode: KenBurnsMode) throws -> KenBurnsModel {
        store.playheadTime = .zero
        store.selection = [clip]
        store.addMotionSpanAtPlayhead(mode: mode)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.mode, mode)
        return model
    }

    private func assertBox(_ box: KenBurnsBox, _ expected: KenBurnsBox, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.center.x, expected.center.x, accuracy: 1e-6, "centre x " + message, file: file, line: line)
        XCTAssertEqual(box.center.y, expected.center.y, accuracy: 1e-6, "centre y " + message, file: file, line: line)
        XCTAssertEqual(box.size.width, expected.size.width, accuracy: 1e-6, "width " + message, file: file, line: line)
        XCTAssertEqual(box.size.height, expected.size.height, accuracy: 1e-6, "height " + message, file: file, line: line)
    }

    // MARK: The automatic fit

    /// The fit rectangle covers both boxes with the padding: boxes inside the frame (or inside the Transform margin)
    /// leave the stage at Fit; boxes partly outside it, entirely outside the frame, much larger than the frame, and a
    /// picture in picture's Ken Burns rectangles zoom it out just enough, the frame no larger than the margin's.
    func testTheFitStageShowsBothBoxesAndTheirHandles() {
        let frame = CGRect(origin: .zero, size: sequence)
        let full = KenBurnsBox(center: CGPoint(x: 960, y: 540), size: sequence, rotationDegrees: 0)
        let half = KenBurnsBox(center: CGPoint(x: 960, y: 540), size: CGSize(width: 960, height: 540), rotationDegrees: 0)
        func stage(_ boxes: [KenBurnsBox], _ mode: KenBurnsMode) -> KenBurnsViewport {
            KenBurnsViewport.stage(zoom: .fit, mode: mode, extent: KenBurnsModel.extent(of: boxes, frame: frame),
                                   sequence: sequence, monitor: monitor, pointsPerPixel: pointsPerPixel)
        }
        // Inside the frame: Fit (Transform's margin, Ken Burns' whole monitor).
        XCTAssertEqual(stage([full, half], .transform), standard)
        XCTAssertEqual(stage([full, half], .kenBurns), KenBurnsViewport(sequence: sequence, monitor: monitor, margin: 0))
        // Partly outside the frame but inside the margin: still Fit.
        let nudged = KenBurnsBox(center: CGPoint(x: 1920, y: 540), size: CGSize(width: 480, height: 270), rotationDegrees: 0)
        XCTAssertNotNil(KenBurnsModel.extent(of: [nudged], frame: frame))
        XCTAssertEqual(stage([full, nudged], .transform), standard, "a box within the margin keeps the margin")
        // Past the margin: half off the frame, entirely off it, three frames wide, turned.
        let cases: [(String, [KenBurnsBox])] = [
            ("half off the frame", [full, KenBurnsBox(center: CGPoint(x: 2304, y: 540), size: sequence, rotationDegrees: 0)]),
            ("entirely off the frame", [full, KenBurnsBox(center: CGPoint(x: 4000, y: -1500), size: CGSize(width: 960, height: 540),
                                                          rotationDegrees: 0)]),
            ("three frames wide", [full, full.scaled(by: 3)]),
            ("turned and scaled up", [half, KenBurnsBox(center: CGPoint(x: 700, y: 900), size: CGSize(width: 3840, height: 2160),
                                                        rotationDegrees: 30)]),
        ]
        for (name, boxes) in cases {
            let fitted = stage(boxes, .transform)
            assertShown(boxes, on: fitted, name)
            assertShown([KenBurnsBox(center: CGPoint(x: 960, y: 540), size: sequence, rotationDegrees: 0)], on: fitted,
                        name + ": the frame")
            XCTAssertLessThan(fitted.scale, standard.scale, name + ": zoomed out")
            // Just enough: one side of what it shows touches the padding.
            let shown = KenBurnsModel.extent(of: boxes, frame: frame)!
            let width = shown.width * fitted.scale
            let height = shown.height * fitted.scale
            let inner = CGSize(width: monitor.width - 2 * KenBurnsViewport.extentPadding,
                               height: monitor.height - 2 * KenBurnsViewport.extentPadding)
            XCTAssertTrue(abs(width - inner.width) < 1e-6 || abs(height - inner.height) < 1e-6, name + ": just enough")
        }
        // Ken Burns mode: a picture in picture's rectangles (30 %: 3.3 frames wide).
        let rect = KenBurnsModel.rect(for: VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1),
                                      sequence: sequence)
        let kenBurns = stage([rect, rect.scaled(by: 0.8)], .kenBurns)
        assertShown([rect], on: kenBurns, "Ken Burns rectangles")
    }

    /// A box dragged past the stage: nothing rescales during the drag (the box goes past the monitor's edge); when
    /// it ends the stage zooms out to show both boxes; dragged back inside, the stage returns to Fit; an undo that
    /// puts it out again re-fits; closing the editor returns the monitor to the plain fit, while a zoom level chosen
    /// by hand is kept (as in Final Cut).
    func testADragPastTheStageRefitsWhenItEndsAndClosingReturnsToFit() async throws {
        let clip = try await longClip()
        let model = try openEditor(on: clip, mode: .transform)
        XCTAssertEqual(stage(), standard, "the push in's boxes fit the margin")
        let origin = model.start
        model.applyDrag(.body(.start), origin: origin, translation: CGSize(width: 1500, height: 0))
        XCTAssertTrue(model.isDragging)
        XCTAssertEqual(stage(), standard, "no rescale during the drag")
        let dragged = model.start
        XCTAssertGreaterThan(dragged.center.x, sequence.width, "the box is off the frame")
        let extentBefore = KenBurnsModel.extent(of: [dragged], frame: CGRect(origin: .zero, size: sequence))!
        XCTAssertFalse(standard.shows(extentBefore, padding: KenBurnsViewport.extentPadding), "and past the stage")
        model.endDrag()
        let fitted = stage()
        XCTAssertLessThan(fitted.scale, standard.scale, "re-fitted when the drag ended")
        assertShown([model.start, model.end], on: fitted, "after the drag")

        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: -(model.start.center.x - 960), height: 0))
        model.endDrag()
        XCTAssertEqual(stage(), standard, "back inside: Fit")
        store.undo()
        XCTAssertLessThan(stage().scale, standard.scale, "undone: past the margin again")
        assertShown([model.start, model.end], on: stage(), "after the undo")

        store.closeKenBurns()
        XCTAssertNil(store.kenBurnsExtent)
        XCTAssertEqual(stage(), KenBurnsViewport(sequence: sequence, monitor: monitor, margin: 0),
                       "closed: the frame fitted again")
        store.programZoom.zoom = .percent(50)
        store.showKenBurns(span: model.spanID)
        store.closeKenBurns()
        XCTAssertEqual(store.programZoom.zoom, .percent(50), "a level chosen by hand stays")
    }

    /// The editor opening on a span whose box is already past the margin (typed values) is fitted at once.
    func testTheEditorOpensFittedToBoxesPastTheMargin() async throws {
        let clip = try await longClip()
        let model = try openEditor(on: clip, mode: .transform)
        let spanID = model.spanID
        var far = VESpanValuesUnchanged()
        far.x = 2600
        far.scale = 2
        XCTAssertTrue(store.engine.setSpanValues(spanID, start: VESpanValuesUnchanged(), end: far).ok)
        store.closeKenBurns()
        store.showKenBurns(span: spanID)
        let reopened = try XCTUnwrap(store.kenBurns)
        XCTAssertLessThan(stage().scale, standard.scale)
        assertShown([reopened.start, reopened.end], on: stage(), "on opening")
    }

    // MARK: Manual zoom

    /// Zoom In and Zoom Out step through the fixed levels from what is shown (Fit's own percentage at Fit), and stop
    /// at the ends; a level shows the frame at that many percent of its pixels, centred.
    func testTheZoomLevelsStepFromWhatFitShows() {
        let zoom = ProgramMonitorZoom()
        zoom.noteFitPercent(37.5)
        XCTAssertEqual(zoom.zoom.title, "Fit")
        zoom.zoomIn()
        XCTAssertEqual(zoom.zoom, .percent(50))
        XCTAssertEqual(zoom.zoom.title, "50 %")
        for expected in [75, 100, 200, 200] {
            zoom.zoomIn()
            XCTAssertEqual(zoom.zoom, .percent(expected))
        }
        for expected in [100, 75, 50, 25, 25] {
            zoom.zoomOut()
            XCTAssertEqual(zoom.zoom, .percent(expected))
        }
        zoom.fit()
        zoom.zoomOut()
        XCTAssertEqual(zoom.zoom, .percent(25), "from Fit at 37.5 %: the next level below")
        zoom.fit()
        zoom.noteFitPercent(50)
        zoom.zoomIn()
        XCTAssertEqual(zoom.zoom, .percent(75), "Fit at exactly a level: the next one")
        zoom.fit()
        zoom.noteFitPercent(250)
        zoom.zoomIn()
        XCTAssertEqual(zoom.zoom, .fit, "nothing larger than Fit")
        zoom.zoomOut()
        XCTAssertEqual(zoom.zoom, .percent(200))

        for level in ProgramZoom.levels {
            let viewport = KenBurnsViewport.stage(zoom: .percent(level), mode: nil, extent: nil, sequence: sequence,
                                                  monitor: monitor, pointsPerPixel: pointsPerPixel)
            XCTAssertEqual(viewport.frame.width, sequence.width * CGFloat(level) / 100 * pointsPerPixel, accuracy: 1e-9)
            XCTAssertEqual(viewport.frame.midX, monitor.width / 2, accuracy: 1e-9)
            XCTAssertEqual(viewport.frame.midY, monitor.height / 2, accuracy: 1e-9)
            XCTAssertEqual(viewport.percent(pointsPerPixel: pointsPerPixel), Double(level), accuracy: 1e-9)
        }
        // A level applies with the editor open too (boxes may then be cut off; Fit shows them).
        let open = KenBurnsViewport.stage(zoom: .percent(25), mode: .transform, extent: CGRect(x: -2000, y: 0, width: 6000, height: 1080),
                                          sequence: sequence, monitor: monitor, pointsPerPixel: pointsPerPixel)
        XCTAssertEqual(open.scale, 0.125, accuracy: 1e-12)
    }

    /// Command-plus / Command-minus (and = / -) zoom the program monitor while it has the focus (a click on it), the
    /// timeline otherwise; Shift-Z fits the focused one; a click in the timeline or a scrub of its ruler takes the
    /// focus back. Command-Shift-Z stays Redo.
    func testTheZoomKeysZoomTheFocusedArea() async throws {
        XCTAssertEqual(KeyboardController.action(keyCode: 6, characters: "Z", modifiers: .shift), .zoomToFit)
        XCTAssertEqual(KeyboardController.action(keyCode: 6, characters: "z", modifiers: .shift), .zoomToFit)
        XCTAssertNil(KeyboardController.action(keyCode: 6, characters: "z", modifiers: [.command, .shift]))
        XCTAssertNil(KeyboardController.action(keyCode: 6, characters: "z", modifiers: []))
        _ = try await longClip()
        let keys = KeyboardController(store: store)
        store.programZoom.noteFitPercent(40)
        let timelineZoom = store.pixelsPerSecond

        store.focusProgramMonitor()
        XCTAssertEqual(store.focusArea, .timeline, "the transport keys still drive the program")
        store.zoomIn()
        XCTAssertEqual(store.programZoom.zoom, .percent(50))
        keys.perform(.zoomIn, on: store)
        XCTAssertEqual(store.programZoom.zoom, .percent(75))
        store.zoomOut()
        XCTAssertEqual(store.programZoom.zoom, .percent(50))
        XCTAssertEqual(store.pixelsPerSecond, timelineZoom, "the timeline keeps its zoom")
        keys.perform(.zoomToFit, on: store)
        XCTAssertEqual(store.programZoom.zoom, .fit)

        store.focusArea = .timeline // a click in the timeline
        store.zoomIn()
        XCTAssertGreaterThan(store.pixelsPerSecond, timelineZoom, "the timeline zooms")
        XCTAssertEqual(store.programZoom.zoom, .fit)

        store.focusProgramMonitor()
        store.scrub(toSeconds: 1)
        store.endScrub()
        let scrubbed = store.pixelsPerSecond
        store.zoomOut()
        XCTAssertLessThan(store.pixelsPerSecond, scrubbed, "after a ruler scrub the timeline has the zoom keys")
        XCTAssertEqual(store.programZoom.zoom, .fit)

        store.focusProgramMonitor()
        store.focusArea = .mediaBin
        store.zoomIn()
        XCTAssertEqual(store.programZoom.zoom, .fit, "the bin took the focus")
    }

    // MARK: Pictures (offscreen, for the report)

    /// Renders the program monitor's layout with the real program picture (the program view's own snapshot drawn
    /// into the layout's offscreen drawing; never a screen capture) at its state: a box dragged off the frame before
    /// and after the automatic fit, and the whole editor window at 50 % with the zoom control and the Reset buttons.
    /// The PNGs are written to the test host's temporary directory, under FramewrightProgramZoom.
    func testRendersTheStagePictures() async throws {
        let clip = try await longClip()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramewrightProgramZoom")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = self.store
        let monitorView = HostedView(ProgramMonitorLayout(store: store) {
            ProgramMonitorView(attachID: ObjectIdentifier(store)) { view in store.attachProgramView(view) }
        }, size: NSSize(width: 1000, height: 700))
        defer {
            store.engine.attachProgramView(nil)
            monitorView.close()
        }
        let model = try openEditor(on: clip, mode: .transform)
        await monitorView.settle()
        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: 1500, height: -200))
        try await writePicture(of: monitorView, to: directory.appendingPathComponent("1-box-dragged-off-before-fit.png"))
        model.endDrag()
        try await writePicture(of: monitorView, to: directory.appendingPathComponent("2-box-dragged-off-after-fit.png"))
        XCTAssertLessThan(stage().scale, standard.scale)

        let documents = DocumentController(store: store, defaults: try makeTestDefaults("program-zoom-window"))
        store.programZoom.zoom = .percent(50)
        let window = HostedView(ContentView(store: store, documents: documents), size: NSSize(width: 1400, height: 900))
        defer { window.close() }
        try await writePicture(of: window, to: directory.appendingPathComponent("3-window-zoom-50-and-reset-buttons.png"))
        store.programZoom.fit()
        try await writePicture(of: window, to: directory.appendingPathComponent("4-window-fit-and-reset-buttons.png"))
        print("Program zoom pictures: \(directory.path)")
    }

    /// Draws `hosted` offscreen with the program view's snapshot in its place, and writes it as a PNG.
    private func writePicture(of hosted: HostedView, to url: URL) async throws {
        await hosted.settle()
        let previews = previewViews(in: hosted.host)
        for preview in previews {
            try? await preview.renderOnce()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await hosted.settle()
        let rep = try XCTUnwrap(hosted.bitmap())
        let image = NSImage(size: hosted.host.bounds.size)
        image.addRepresentation(rep)
        let composed = NSImage(size: hosted.host.bounds.size)
        composed.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: hosted.host.bounds.size))
        for preview in previews {
            // The picture the view shows (its own snapshot, not the screen) where the view is, in drawing
            // coordinates (origin at the bottom left).
            guard let snapshot = preview.snapshot() else { continue }
            let rect = preview.convert(preview.bounds, to: hosted.host)
            let placed = hosted.host.isFlipped
                ? CGRect(x: rect.minX, y: hosted.host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                : rect
            NSGraphicsContext.current?.cgContext.draw(snapshot, in: placed)
        }
        composed.unlockFocus()
        let tiff = try XCTUnwrap(composed.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("Wrote \(url.path)")
    }

    private func previewViews(in view: NSView) -> [VEPreviewView] {
        var found: [VEPreviewView] = []
        if let preview = view as? VEPreviewView { found.append(preview) }
        for subview in view.subviews { found.append(contentsOf: previewViews(in: subview)) }
        return found
    }
}
