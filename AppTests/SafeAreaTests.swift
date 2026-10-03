import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The program monitor's safe-area guides (titles slice 2): the rectangles of both standards (SMPTE ST 2046-1's 93 %
/// action and 90 % title, the default; the classic 90 % and 80 %), centred on any frame; the View menu's toggle and
/// the preference in the Editing preferences; and the guides drawn over the picture where the rectangles are.
@MainActor
final class SafeAreaTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("safeAreas")
        try fixture.configureSequence() // 1920x1080
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func assertRect(_ rect: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }

    func testTheRectanglesOfEachStandard() {
        let hd = SafeAreas(frame: CGSize(width: 1920, height: 1080), standard: .smpte)
        assertRect(hd.action, CGRect(x: 67.2, y: 37.8, width: 1785.6, height: 1004.4))
        assertRect(hd.title, CGRect(x: 96, y: 54, width: 1728, height: 972))
        XCTAssertEqual(hd.centre, CGPoint(x: 960, y: 540))
        let classic = SafeAreas(frame: CGSize(width: 1920, height: 1080), standard: .classic)
        assertRect(classic.action, CGRect(x: 96, y: 54, width: 1728, height: 972))
        assertRect(classic.title, CGRect(x: 192, y: 108, width: 1536, height: 864))
        // A vertical frame: each side its fraction, centred.
        let vertical = SafeAreas(frame: CGSize(width: 1080, height: 1920), standard: .smpte)
        assertRect(vertical.title, CGRect(x: 54, y: 96, width: 972, height: 1728))
        // The lines a box snaps to: the centre lines and every edge of both rectangles.
        XCTAssertEqual(hd.lines.count, 10)
        func positions(vertical: Bool) -> [CGFloat] { hd.lines.filter { $0.vertical == vertical }.map(\.position).sorted() }
        for (actual, expected) in zip(positions(vertical: true), [67.2, 96, 960, 1824, 1852.8] as [CGFloat]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        for (actual, expected) in zip(positions(vertical: false), [37.8, 54, 540, 1026, 1042.2] as [CGFloat]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(SafeAreaStandard.smpte.actionFraction, 0.93)
        XCTAssertEqual(SafeAreaStandard.smpte.titleFraction, 0.90)
    }

    func testTheToggleAndThePreference() {
        XCTAssertFalse(store.showsSafeAreas, "off by default")
        XCTAssertEqual(store.editingPreferences.safeAreaStandard, .smpte, "SMPTE by default")
        store.showsSafeAreas = true
        XCTAssertTrue(store.editingPreferences.showsSafeAreas)
        XCTAssertTrue(store.defaults.bool(forKey: EditingPreferences.showsSafeAreasKey))
        store.defaults.set(SafeAreaStandard.classic.rawValue, forKey: EditingPreferences.safeAreaStandardKey)
        XCTAssertEqual(store.safeAreas.standard, .classic)
        assertRect(store.safeAreas.title, CGRect(x: 192, y: 108, width: 1536, height: 864))
        store.defaults.set("unknown", forKey: EditingPreferences.safeAreaStandardKey)
        XCTAssertEqual(store.safeAreas.standard, .smpte, "an unknown value reads as the default")
    }

    /// A caption is added just inside the title-safe rectangle of the safe areas chosen (review fix: it ignored the
    /// classic choice).
    func testACaptionGoesInsideTheChosenTitleSafeArea() throws {
        for standard in SafeAreaStandard.allCases {
            store.defaults.set(standard.rawValue, forKey: EditingPreferences.safeAreaStandardKey)
            store.playheadTime = .zero
            XCTAssertTrue(store.addGenerated(.caption))
            let id = try XCTUnwrap(store.selection.first)
            let block = store.engine.titleBlock(ofClip: id)
            let titleSafe = store.safeAreas.title
            XCTAssertEqual(block.minX, titleSafe.minX + 0.005 * 1920, accuracy: 1e-6, standard.rawValue)
            XCTAssertEqual(block.minY, titleSafe.minY + 0.005 * 1080, accuracy: 1e-6, standard.rawValue)
            store.undo()
        }
    }

    /// The program monitor's layout over a black picture, 960 x 540 points for a 1920 x 1080 frame (half size): the
    /// guides are drawn on the rectangles' edges and nowhere else, only while shown.
    func testTheGuidesAreDrawnWhereTheRectanglesAre() async throws {
        let size = NSSize(width: 960, height: 540)
        let hosted = HostedView(ProgramMonitorLayout(store: store) { Color.black }, size: size)
        defer { hosted.close() }
        await hosted.settle()
        func level(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
            // Points to the bitmap's pixels (a Retina bitmap has two per point).
            let scale = CGFloat(rep.pixelsWide) / size.width
            guard let colour = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return -1 }
            return colour.whiteComponentEstimate
        }
        _ = await hosted.pixels()
        let off = try XCTUnwrap(hosted.bitmap())
        XCTAssertLessThan(level(off, 48.25, 270), 0.1, "no guides while hidden")
        store.showsSafeAreas = true
        _ = await hosted.pixels()
        let on = try XCTUnwrap(hosted.bitmap())
        TestSnapshots.write(on, name: "safe-areas-smpte")
        // Title-safe's left edge at 96 px = 48 points; action-safe's at 67.2 px = 33.6 points; the centre cross.
        XCTAssertGreaterThan(level(on, 48.25, 200), 0.5, "the title-safe edge")
        XCTAssertGreaterThan(level(on, 33.85, 200), 0.5, "the action-safe edge")
        XCTAssertGreaterThan(level(on, 480.25, 270), 0.5, "the centre cross")
        XCTAssertLessThan(level(on, 60, 200), 0.1, "nothing between the edges")
        XCTAssertLessThan(level(on, 300, 200), 0.1, "nothing inside title-safe")
        store.defaults.set(SafeAreaStandard.classic.rawValue, forKey: EditingPreferences.safeAreaStandardKey)
        _ = await hosted.pixels()
        let classic = try XCTUnwrap(hosted.bitmap())
        TestSnapshots.write(classic, name: "safe-areas-classic")
        XCTAssertGreaterThan(level(classic, 96.25, 200), 0.5, "classic title-safe at 80 %")
        XCTAssertLessThan(level(classic, 33.85, 200), 0.1)
    }
}

private extension NSColor {
    /// The colour's brightness (the mean of its components).
    var whiteComponentEstimate: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
}
