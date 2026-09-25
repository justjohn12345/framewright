import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The frame is visible in the in-window monitors (Ken Burns and Transform round, item 3): the
/// program and source monitors size their picture view to the frame, fitted into their area with the
/// frame's aspect, and shade the rest of the area (`MonitorFrame.outsideColor`, a grey a step lighter
/// than the frame's black), so a letterboxed or pillarboxed frame shows where it ends. The output
/// window's stays black (`OutputDisplayTests.testTheOutputWindowStaysBlackOutsideTheFrame`).
@MainActor
final class MonitorFrameTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "monitor-frame-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private func assertRect(_ rect: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-9, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "x " + message, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "y " + message, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "width " + message, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "height " + message, file: file, line: line)
    }

    func testTheFrameIsFittedIntoAnyMonitorShape() {
        let hd = CGSize(width: 1920, height: 1080)
        // Letterboxed: a 10:7 monitor.
        assertRect(MonitorFrame.fitted(hd, in: CGSize(width: 1000, height: 700)), CGRect(x: 0, y: 68.75, width: 1000, height: 562.5))
        // A tall monitor.
        assertRect(MonitorFrame.fitted(hd, in: CGSize(width: 600, height: 900)), CGRect(x: 0, y: 281.25, width: 600, height: 337.5))
        // Pillarboxed: a wide monitor.
        let wide = MonitorFrame.fitted(hd, in: CGSize(width: 1600, height: 600))
        assertRect(wide, CGRect(x: (1600 - 3200.0 / 3) / 2, y: 0, width: 3200.0 / 3, height: 600))
        // A portrait picture (the source monitor's still) in a 16:9 area.
        assertRect(MonitorFrame.fitted(CGSize(width: 240, height: 320), in: CGSize(width: 800, height: 450)),
                   CGRect(x: 231.25, y: 0, width: 337.5, height: 450))
        // Exactly 16:9: the whole area.
        assertRect(MonitorFrame.fitted(hd, in: CGSize(width: 960, height: 540)), CGRect(x: 0, y: 0, width: 960, height: 540))
        // Nothing to frame: the whole area.
        assertRect(MonitorFrame.fitted(.zero, in: CGSize(width: 300, height: 200)), CGRect(x: 0, y: 0, width: 300, height: 200))
        // The Ken Burns editor's closed / Ken Burns-mode layout is the same fit.
        XCTAssertEqual(MonitorFrame.fitted(hd, in: CGSize(width: 1000, height: 700)),
                       KenBurnsViewport(sequence: hd, monitor: CGSize(width: 1000, height: 700), margin: 0).frame)
    }

    /// The sRGB colour of the host's pixel at `point` (from the host's top-left corner, as the
    /// bitmap's rows go).
    private func pixel(_ host: NSView, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    /// `view`'s frame in `host`, measured from the host's top-left corner.
    private func frame(of view: NSView, in host: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width,
                                              height: rect.height)
    }

    private func previewViews(in view: NSView) -> [VEPreviewView] {
        var found: [VEPreviewView] = []
        if let preview = view as? VEPreviewView { found.append(preview) }
        for subview in view.subviews { found.append(contentsOf: previewViews(in: subview)) }
        return found
    }

    private func settle(_ host: NSView) async {
        for _ in 0 ..< 5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    /// The program monitor in a 1000x700 area: the picture view is the 16:9 frame (1000x562.5, 68.75
    /// from the top) and the bands above and below are the outside shade, not black. The Ken Burns
    /// editor in Ken Burns mode keeps that fit (no margin); in Transform mode the frame sits inside
    /// the margin.
    func testTheProgramMonitorShadesTheBandsAroundTheFrame() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let store = self.store
        let host = NSHostingView(rootView: ProgramMonitorLayout(store: store) {
            ProgramMonitorView(attachID: ObjectIdentifier(store)) { view in store.attachProgramView(view) }
        })
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = host
        window.orderFront(nil)
        defer {
            store.engine.attachProgramView(nil)
            window.orderOut(nil)
            window.close()
        }
        await settle(host)
        let picture = try XCTUnwrap(previewViews(in: host).first)
        let shown = frame(of: picture, in: host)
        let expected = MonitorFrame.fitted(CGSize(width: 1920, height: 1080), in: CGSize(width: 1000, height: 700))
        XCTAssertEqual(shown.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(shown.height, expected.height, accuracy: 0.5)
        XCTAssertEqual(shown.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(shown.midX, 500, accuracy: 0.5)
        // The band above the frame (top-left origin: y 0 ..< 68.75) is the outside shade: a grey
        // clearly lighter than black.
        let band = try pixel(host, at: CGPoint(x: 500, y: 20))
        XCTAssertEqual(band.r, band.g, accuracy: 2)
        XCTAssertEqual(band.g, band.b, accuracy: 2)
        XCTAssertGreaterThan(band.r, 25, "not the frame's black (\(band))")
        XCTAssertLessThan(band.r, 70, "a dark grey (\(band))")
        let below = try pixel(host, at: CGPoint(x: 500, y: 690))
        XCTAssertEqual(below.r, band.r, accuracy: 2, "the same shade below")

        // The Ken Burns editor in Ken Burns mode: the same fit; in Transform mode, inside the margin.
        store.playheadTime = .zero
        store.selection = [clip]
        store.addMotionSpanAtPlayhead(mode: .kenBurns)
        await settle(host)
        let kenBurns = frame(of: picture, in: host)
        XCTAssertEqual(kenBurns.width, expected.width, accuracy: 0.5, "no margin in Ken Burns mode")
        store.kenBurns?.setMode(.transform)
        await settle(host)
        let transform = frame(of: picture, in: host)
        let margin = KenBurnsViewport(sequence: CGSize(width: 1920, height: 1080), monitor: CGSize(width: 1000, height: 700))
        XCTAssertEqual(transform.width, margin.frame.width, accuracy: 0.5, "inside the margin in Transform mode")
        XCTAssertEqual(transform.height, margin.frame.height, accuracy: 0.5)
        XCTAssertTrue(previewViews(in: host).first === picture, "the same picture view throughout")
        let marginPixel = try pixel(host, at: CGPoint(x: 20, y: 350))
        XCTAssertEqual(marginPixel.r, band.r, accuracy: 2, "the margin is the same shade")
        store.closeKenBurns()
        await settle(host)
        XCTAssertEqual(frame(of: picture, in: host).width, expected.width, accuracy: 0.5)
    }

    /// The source monitor frames its asset: a portrait still is pillarboxed (its picture view 3:4)
    /// with the shade beside it; a 16:9 movie in the same monitor is letterboxed or fills it.
    func testTheSourceMonitorFramesItsAssetsPicture() async throws {
        let url = fixture.directory.appendingPathComponent("portrait.heic")
        try TestMediaFactory.writeHEIC(to: url, width: 240, height: 320)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let still = try XCTUnwrap(imported.first)
        let (movie, _) = try await fixture.importMedia()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SourceMonitorView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.contentView = host
        window.orderFront(nil)
        defer {
            store.engine.attachSourceView(nil)
            window.orderOut(nil)
            window.close()
        }
        store.showInSourceMonitor(still.assetID)
        await settle(host)
        let picture = try XCTUnwrap(previewViews(in: host).first)
        let portrait = frame(of: picture, in: host)
        XCTAssertEqual(portrait.width / portrait.height, 0.75, accuracy: 0.01, "the still's aspect (\(portrait))")
        XCTAssertLessThan(portrait.width, 500, "pillarboxed")
        let beside = try pixel(host, at: CGPoint(x: portrait.minX - 20, y: portrait.midY))
        XCTAssertGreaterThan(beside.r, 25, "the shade beside the picture (\(beside))")
        XCTAssertEqual(beside.r, beside.b, accuracy: 2)

        store.showInSourceMonitor(movie.assetID)
        await settle(host)
        let landscape = frame(of: picture, in: host)
        XCTAssertEqual(landscape.width / landscape.height, 16.0 / 9, accuracy: 0.01, "the movie's aspect (\(landscape))")
        XCTAssertTrue(previewViews(in: host).first === picture, "the same picture view")
    }
}
