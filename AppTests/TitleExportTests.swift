import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The export sheet's missing-font confirmation (titles design section 11; slice 1): Export asks before exporting
/// titles whose font this Mac does not have (they would be drawn in the system font), names each font with how many
/// titles use it, and exports only on "Export Anyway"; without missing fonts it exports at once.
@MainActor
final class TitleExportTests: XCTestCase {
    private var fixture: StoreFixture!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        fixture = try StoreFixture()
        defaults = try makeTestDefaults("title-export")
        fixture.store.defaults = defaults
    }

    override func tearDown() async throws {
        fixture.store.engine.activeExport?.cancelAndWait(withTimeout: 2)
        fixture.cleanUp()
    }

    func testExportAsksAboutMissingFontsFirst() async throws {
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        store.playheadTime = .zero
        XCTAssertTrue(store.addGenerated(.title))
        let first = try XCTUnwrap(store.selection.first)
        store.playheadTime = CMTime(value: 30, timescale: 30)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let second = try XCTUnwrap(store.selection.first)
        store.selection = [first, second]
        store.titleInspector.setFont(VETitleFont.named("NoSuchFont-Bold", family: "No Such Font", style: "Bold"))

        let model = ExportModel(store: store, defaults: defaults)
        model.setOutputURL(fixture.directory.appendingPathComponent("titles.mp4"))
        XCTAssertTrue(model.canExport, model.exportDisabledReason ?? "")
        XCTAssertFalse(model.requestExport(), "asks first")
        XCTAssertFalse(model.isExporting)
        let fonts = try XCTUnwrap(model.missingFontConfirmation)
        XCTAssertEqual(fonts.count, 1)
        XCTAssertEqual(ExportModel.missingFontMessage(fonts),
                       "“No Such Font Bold” (2 titles) is not on this Mac. Those titles will be exported in the system "
                           + "font; install the font and export again to use it.")
        // Cancel: nothing exported.
        model.missingFontConfirmation = nil
        XCTAssertFalse(model.isExporting)
        // Export Anyway: it runs and finishes.
        XCTAssertFalse(model.requestExport())
        XCTAssertTrue(model.confirmMissingFonts(), model.refusal ?? "")
        XCTAssertNil(model.missingFontConfirmation)
        XCTAssertTrue(model.isExporting)
        let finished = await StoreFixture.wait(until: { !model.isExporting }, timeout: 60)
        XCTAssertTrue(finished)
        guard case .succeeded? = model.outcome else {
            return XCTFail("the export succeeded: \(String(describing: model.outcome))")
        }

        // With the font changed to the system font: no question.
        store.titleInspector.setFont(VETitleFont.system(weight: .semibold))
        XCTAssertTrue(store.engine.missingTitleFonts.isEmpty)
        model.outcome = nil
        model.setOutputURL(fixture.directory.appendingPathComponent("titles-2.mp4"))
        XCTAssertTrue(model.requestExport(), model.refusal ?? "")
        XCTAssertNil(model.missingFontConfirmation)
        let done = await StoreFixture.wait(until: { !model.isExporting }, timeout: 60)
        XCTAssertTrue(done)
    }

    func testTheMessageListsEveryFont() async throws {
        let store = fixture.store
        try fixture.configureSequence()
        store.playheadTime = .zero
        XCTAssertTrue(store.addGenerated(.title))
        store.titleInspector.setFont(VETitleFont.named("NoSuchFont-Bold", family: "No Such Font", style: "Bold"))
        store.playheadTime = CMTime(value: 300, timescale: 30)
        XCTAssertTrue(store.addGenerated(.title))
        store.titleInspector.setFont(VETitleFont.named("AbsentSans-Regular", family: "Absent Sans", style: "Regular"))
        let model = ExportModel(store: store, defaults: defaults)
        model.setOutputURL(fixture.directory.appendingPathComponent("two-fonts.mp4"))
        XCTAssertFalse(model.requestExport())
        XCTAssertEqual(ExportModel.missingFontMessage(try XCTUnwrap(model.missingFontConfirmation)),
                       "“No Such Font Bold” (1 title), “Absent Sans Regular” (1 title) are not on this Mac. Those "
                           + "titles will be exported in the system font; install the fonts and export again to use them.")
    }
}
