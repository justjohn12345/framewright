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

/// A typing run or a nudge burst left open (the text area keeps the focus while the Export sheet is up) does not
/// block an export, hold back an import or refuse removing media (review fix round, finding 2): each commits the run
/// as its undo step first; a run also ends by itself after a pause.
@MainActor
final class OpenEditGroupTests: XCTestCase {
    private var fixture: StoreFixture!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        fixture = try StoreFixture()
        defaults = try makeTestDefaults("open-edits")
        fixture.store.defaults = defaults
    }

    override func tearDown() async throws {
        TitleInspectorModel.typingIdleSeconds = 2.0
        fixture.store.engine.activeExport?.cancelAndWait(withTimeout: 2)
        fixture.cleanUp()
    }

    private func typedTitle() throws -> VEClipID {
        let store = fixture.store
        store.playheadTime = .zero
        XCTAssertTrue(store.addGenerated(.title))
        let title = try XCTUnwrap(store.selection.first)
        store.titleInspector.textChanged("Typed")
        XCTAssertNotNil(store.titleTypingGroup)
        XCTAssertNotNil(store.engine.coalescingKey)
        return title
    }

    func testAnExportStartsDuringATypingRun() async throws {
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let title = try typedTitle()
        store.showExportSheet()
        let model = try XCTUnwrap(store.exportModel)
        XCTAssertNil(store.titleTypingGroup, "opening the sheet commits the run")
        store.titleInspector.textChanged("Typed again") // the text area still has the focus
        model.setOutputURL(fixture.directory.appendingPathComponent("typed.mp4"))
        XCTAssertTrue(model.requestExport(), model.refusal ?? "")
        XCTAssertTrue(model.isExporting)
        XCTAssertNil(store.engine.coalescingKey)
        XCTAssertEqual(store.clips[title]?.title?.text, "Typed again")
        XCTAssertEqual(store.undoActionName, "Edit Title Text")
        let finished = await StoreFixture.wait(until: { !model.isExporting }, timeout: 60)
        XCTAssertTrue(finished)
    }

    func testImportsAndRemovingMediaCommitTheRun() async throws {
        let store = fixture.store
        _ = try typedTitle()
        // The import is added at once, not held back until the run ends.
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([fixture.movieURL]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(imported.count, 1)
        XCTAssertNil(store.titleTypingGroup)
        XCTAssertEqual(store.engine.deferredImportCount, 0)
        store.titleInspector.textChanged("Typed more")
        store.removeAsset(try XCTUnwrap(imported.first).assetID)
        XCTAssertNil(store.asset(try XCTUnwrap(imported.first).assetID), "removed: \(store.statusMessage ?? "")")
        // A burst of nudges is committed the same way.
        store.titleInspector.nudge(.tracking, steps: 1)
        XCTAssertNotNil(store.engine.coalescingKey)
        store.commitOpenEdits()
        XCTAssertNil(store.engine.coalescingKey)
    }

    func testARunEndsAfterAPause() async throws {
        TitleInspectorModel.typingIdleSeconds = 0.1
        let store = fixture.store
        _ = try typedTitle()
        let ended = await StoreFixture.wait(until: { store.titleTypingGroup == nil }, timeout: 3)
        XCTAssertTrue(ended)
        XCTAssertNil(store.engine.coalescingKey)
        XCTAssertEqual(store.undoActionName, "Edit Title Text")
    }
}
