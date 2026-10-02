import AppKit
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The scope panel (View > Show Scopes): the layout remembers the scope, the histogram's style, the
/// placement and the width (the clipping overlay is for the moment, not remembered); the arrangement keeps
/// the program monitor large and the scope at the picture's aspect, beside or below the monitor; the window
/// shows the engine's scope view at that size, in the chosen mode, without replacing the program monitor's
/// view; the clipping overlay reaches the engine.
@MainActor
final class ScopePanelTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("scopes")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    func testTheLayoutRemembersTheScopeSettings() throws {
        let defaults = try makeTestDefaults("scope-layout")
        let layout = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(layout.scopeMode, .waveform)
        XCTAssertEqual(layout.histogramStyle, .rgbAndLuma)
        XCTAssertEqual(layout.scopePlacement, .automatic)
        XCTAssertEqual(layout.scopeWidth, WindowLayoutModel.defaultScopeWidth)
        XCTAssertFalse(layout.showsClippingOverlay)
        layout.scopeMode = .histogram
        layout.histogramStyle = .parade
        layout.scopePlacement = .below
        layout.setScopeWidth(720)
        layout.showsClippingOverlay = true
        let reopened = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(reopened.scopeMode, .histogram, "remembered across launches")
        XCTAssertEqual(reopened.histogramStyle, .parade)
        XCTAssertEqual(reopened.scopePlacement, .below)
        XCTAssertEqual(reopened.scopeWidth, 720)
        XCTAssertFalse(reopened.showsClippingOverlay, "the overlay is a check for the moment: off at every launch")
        // Widths are clamped; a non-finite one is ignored.
        layout.setScopeWidth(10)
        XCTAssertEqual(layout.scopeWidth, WindowLayoutModel.scopeWidths.lowerBound)
        layout.setScopeWidth(.infinity)
        XCTAssertEqual(layout.scopeWidth, WindowLayoutModel.scopeWidths.lowerBound)
        layout.setScopeWidth(99_999)
        XCTAssertEqual(layout.scopeWidth, WindowLayoutModel.scopeWidths.upperBound)
        // A stored value from elsewhere that is out of range or unknown.
        defaults.set("vectorscope-of-the-future", forKey: WindowLayoutModel.scopeModeKey)
        defaults.set(5.0, forKey: WindowLayoutModel.scopeWidthKey)
        let odd = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(odd.scopeMode, .waveform)
        XCTAssertEqual(odd.scopeWidth, WindowLayoutModel.scopeWidths.lowerBound)
        // Reset Window Layout restores every default.
        layout.resetToDefaults()
        XCTAssertEqual(layout.scopeMode, .waveform)
        XCTAssertEqual(layout.histogramStyle, .rgbAndLuma)
        XCTAssertEqual(layout.scopePlacement, .automatic)
        XCTAssertEqual(layout.scopeWidth, WindowLayoutModel.defaultScopeWidth)
        XCTAssertFalse(layout.showsClippingOverlay)
        let afterReset = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(afterReset.scopeMode, .waveform)
        XCTAssertEqual(afterReset.scopeWidth, WindowLayoutModel.defaultScopeWidth)
    }

    func testTheArrangementKeepsTheMonitorLargeAndTheScopeAtThePicturesAspect() {
        let aspect: CGFloat = 16.0 / 9.0
        let thickness = WindowLayoutModel.dividerThickness
        // A wide area (the monitor limited by its height): automatic puts the scope beside the monitor,
        // where the picture keeps its size.
        let wide = CGSize(width: 1600, height: 560)
        let pictureAlone = ScopeLayout.pictureSize(in: wide, aspect: aspect)
        let besideWide = ScopeLayout.arrange(area: wide, aspect: aspect, placement: .automatic, scopeWidth: 480)
        XCTAssertTrue(besideWide.beside)
        XCTAssertEqual(besideWide.scopeSize.width, 480)
        XCTAssertEqual(besideWide.scopeSize.width / besideWide.scopeSize.height, aspect, accuracy: 1e-9,
                       "the scope has the picture's aspect: its columns are the picture's columns")
        XCTAssertEqual(besideWide.panel.width, 480 + ScopeLayout.scaleWidth)
        XCTAssertEqual(besideWide.panel.height, 270 + ScopeLayout.headerHeight)
        XCTAssertEqual(besideWide.monitor.width + thickness + besideWide.panel.width, wide.width, accuracy: 1e-9)
        XCTAssertEqual(besideWide.panel.midY, wide.height / 2, accuracy: 1e-9, "centred beside the monitor")
        XCTAssertEqual(ScopeLayout.pictureSize(in: besideWide.monitor.size, aspect: aspect), pictureAlone,
                       "beside a height-limited monitor the picture keeps its size")
        // A tall area (the monitor limited by its width): automatic puts it below.
        let tall = CGSize(width: 900, height: 900)
        let belowTall = ScopeLayout.arrange(area: tall, aspect: aspect, placement: .automatic, scopeWidth: 480)
        XCTAssertFalse(belowTall.beside)
        XCTAssertEqual(belowTall.monitor.height + thickness + belowTall.panel.height, tall.height, accuracy: 1e-9)
        XCTAssertEqual(belowTall.panel.midX, tall.width / 2, accuracy: 1e-9, "centred below the monitor")
        XCTAssertEqual(ScopeLayout.pictureSize(in: belowTall.monitor.size, aspect: aspect),
                       ScopeLayout.pictureSize(in: tall, aspect: aspect), "below a width-limited monitor the picture keeps its size")
        // Automatic chooses whichever leaves the larger picture, every time.
        for area in [CGSize(width: 1100, height: 500), CGSize(width: 800, height: 700), CGSize(width: 1300, height: 650),
                     CGSize(width: 600, height: 400)] {
            let auto = ScopeLayout.arrange(area: area, aspect: aspect, placement: .automatic, scopeWidth: 480)
            let beside = ScopeLayout.arrange(area: area, aspect: aspect, placement: .beside, scopeWidth: 480)
            let below = ScopeLayout.arrange(area: area, aspect: aspect, placement: .below, scopeWidth: 480)
            let autoPicture = ScopeLayout.pictureSize(in: auto.monitor.size, aspect: aspect).width
            XCTAssertGreaterThanOrEqual(autoPicture + 0.5, ScopeLayout.pictureSize(in: beside.monitor.size, aspect: aspect).width,
                                        "\(area)")
            XCTAssertGreaterThanOrEqual(autoPicture + 0.5, ScopeLayout.pictureSize(in: below.monitor.size, aspect: aspect).width,
                                        "\(area)")
            for arrangement in [auto, beside, below] {
                XCTAssertGreaterThanOrEqual(arrangement.monitor.width, ScopeLayout.minimumMonitor.width - 1e-9, "\(area)")
                XCTAssertGreaterThanOrEqual(arrangement.monitor.height, ScopeLayout.minimumMonitor.height - 1e-9, "\(area)")
                XCTAssertLessThanOrEqual(arrangement.panel.maxX, area.width + 1e-9, "\(area)")
                XCTAssertLessThanOrEqual(arrangement.panel.maxY, area.height + 1e-9, "\(area)")
                XCTAssertEqual(arrangement.scopeSize.width / arrangement.scopeSize.height, aspect, accuracy: 1e-9)
            }
        }
        // The user's width, limited by the area: beside, by the height and the monitor's minimum width.
        let limited = ScopeLayout.arrange(area: CGSize(width: 1000, height: 300), aspect: aspect, placement: .beside,
                                          scopeWidth: 2000)
        XCTAssertEqual(limited.scopeSize.width, (300 - ScopeLayout.headerHeight) * aspect, accuracy: 1e-9)
        let narrow = ScopeLayout.arrange(area: CGSize(width: 700, height: 900), aspect: aspect, placement: .beside,
                                         scopeWidth: 2000)
        XCTAssertEqual(narrow.monitor.width, ScopeLayout.minimumMonitor.width, accuracy: 1e-9)
        // A 4:3 picture: a 4:3 scope.
        let square = ScopeLayout.arrange(area: wide, aspect: 4.0 / 3.0, placement: .beside, scopeWidth: 400)
        XCTAssertEqual(square.scopeSize.height, 300, accuracy: 1e-9)
        // A degenerate aspect falls back to 16:9; a tiny area gives no negative sizes.
        let fallback = ScopeLayout.arrange(area: wide, aspect: .nan, placement: .beside, scopeWidth: 480)
        XCTAssertEqual(fallback.scopeSize.height, 270, accuracy: 1e-9)
        let tiny = ScopeLayout.arrange(area: CGSize(width: 50, height: 40), aspect: aspect, placement: .automatic,
                                       scopeWidth: 480)
        XCTAssertGreaterThanOrEqual(tiny.scopeSize.width, 0)
        XCTAssertGreaterThanOrEqual(tiny.monitor.width, 0)
        XCTAssertGreaterThanOrEqual(tiny.monitor.height, 0)
    }

    func testDraggingTheDividerAndTheClippingText() {
        XCTAssertEqual(ScopeLayout.draggedWidth(from: 480, translation: -100, beside: true, aspect: 16.0 / 9.0), 580,
                       "beside: dragging left widens")
        XCTAssertEqual(ScopeLayout.draggedWidth(from: 480, translation: -90, beside: false, aspect: 16.0 / 9.0), 640,
                       accuracy: 1e-9, "below: dragging up makes it taller, the width following the aspect")
        XCTAssertEqual(ScopeLayout.draggedWidth(from: 480, translation: .nan, beside: true, aspect: 16.0 / 9.0), 480)
        XCTAssertEqual(ScopeLayout.clippingText(0), "0 %")
        XCTAssertEqual(ScopeLayout.clippingText(.nan), "0 %")
        XCTAssertEqual(ScopeLayout.clippingText(0.0001), "<0.1 %")
        XCTAssertEqual(ScopeLayout.clippingText(0.023), "2.3 %")
        XCTAssertEqual(ScopeLayout.clippingText(1), "100.0 %")
        let model = ScopeClippingModel()
        model.update(highlights: 0.2, shadows: 0.01)
        XCTAssertEqual(model.highlights, 0.2)
        XCTAssertEqual(model.shadows, 0.01)
    }

    func testTheClippingOverlayReachesTheEngine() {
        XCTAssertFalse(store.engine.showsClippingOverlay)
        store.layout.showsClippingOverlay = true
        XCTAssertTrue(store.engine.showsClippingOverlay)
        store.layout.resetToDefaults()
        XCTAssertFalse(store.engine.showsClippingOverlay, "Reset Window Layout turns it off")
    }

    // MARK: - In the window

    private func scopeViews(in view: NSView) -> [VEWaveformView] {
        var found: [VEWaveformView] = []
        if let scope = view as? VEWaveformView { found.append(scope) }
        for subview in view.subviews { found.append(contentsOf: scopeViews(in: subview)) }
        return found
    }

    private func previewViews(in view: NSView) -> [VEPreviewView] {
        var found: [VEPreviewView] = []
        if let preview = view as? VEPreviewView { found.append(preview) }
        for subview in view.subviews { found.append(contentsOf: previewViews(in: subview)) }
        return found
    }

    private func settle(_ host: NSView) async {
        for _ in 0 ..< 6 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    func testTheWindowShowsTheScopesWideAtThePicturesAspect() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let documents = DocumentController(store: store, defaults: try makeTestDefaults("scope-window"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        window.orderFront(nil)
        defer {
            store.engine.attachWaveformView(nil)
            window.orderOut(nil)
            window.close()
        }
        await settle(host)
        XCTAssertTrue(scopeViews(in: host).isEmpty, "hidden by default")
        let program = try XCTUnwrap(store.engine.programView)
        let pictureBefore = program.convert(program.bounds, to: nil)

        store.setWaveformVisible(true)
        await settle(host)
        let scope = try XCTUnwrap(scopeViews(in: host).first)
        XCTAssertTrue(store.engine.waveformView === scope)
        XCTAssertTrue(store.engine.programView === program, "the program monitor keeps its view")
        XCTAssertEqual(previewViews(in: host).count, 1)
        // Wide and short at the sequence's 16:9, at the layout's width (the area allows it here).
        let frame = scope.convert(scope.bounds, to: nil)
        XCTAssertEqual(frame.width, WindowLayoutModel.defaultScopeWidth, accuracy: 1, "\(frame)")
        XCTAssertEqual(frame.width / frame.height, 16.0 / 9.0, accuracy: 0.02, "\(frame)")
        // Beside the monitor in this wide window (below would leave the picture smaller).
        let picture = program.convert(program.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(frame.minX, picture.maxX, "beside: right of the picture")
        XCTAssertLessThanOrEqual(picture.width, pictureBefore.width + 1)

        // The mode and the style reach the view; its clipping handler is the panel's.
        XCTAssertEqual(scope.mode, .waveform)
        XCTAssertNotNil(scope.clippingHandler)
        store.layout.scopeMode = .histogram
        store.layout.histogramStyle = .parade
        await settle(host)
        XCTAssertEqual(scope.mode, .histogram)
        XCTAssertEqual(scope.histogramStyle, .parade)
        XCTAssertTrue(scopeViews(in: host).first === scope, "the same view in every mode")

        // Below the monitor: under the picture, centred, still the picture's aspect.
        store.layout.scopePlacement = .below
        await settle(host)
        let below = try XCTUnwrap(scopeViews(in: host).first)
        let belowFrame = below.convert(below.bounds, to: nil)
        let pictureAbove = program.convert(program.bounds, to: nil)
        // Window coordinates have y up: below the picture means a lower maxY.
        XCTAssertLessThanOrEqual(belowFrame.maxY, pictureAbove.minY + 1, "below: under the picture")
        XCTAssertEqual(belowFrame.width / belowFrame.height, 16.0 / 9.0, accuracy: 0.02)
        XCTAssertTrue(store.engine.programView === program, "moving the scopes keeps the program monitor's view")

        // A drawn frame reaches the view (the program monitor draws it).
        let drawn = await StoreFixture.wait(until: {
            program.renderOnce()
            return below.drawCount > 0
        }, timeout: 10)
        XCTAssertTrue(drawn)

        // Hidden: the panel goes, and the engine lets go of its view; the monitor stays.
        store.setWaveformVisible(false)
        await settle(host)
        XCTAssertTrue(scopeViews(in: host).isEmpty)
        XCTAssertNil(store.engine.waveformView)
        XCTAssertTrue(store.engine.programView === program)
    }
}
