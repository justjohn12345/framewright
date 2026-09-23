import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Export sheet's model: preset -> settings mapping, validation and disabled states, the size
/// estimate, the remembered folder (bookmark round trip), progress pacing, a real export through
/// the engine with its outcome, and the document controller's export-in-progress warning.
@MainActor
final class ExportModelTests: XCTestCase {
    private var fixture: StoreFixture!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        fixture = try StoreFixture()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "export-\(UUID())"))
        fixture.store.defaults = defaults
    }

    override func tearDown() async throws {
        fixture.store.engine.activeExport?.cancelAndWait(withTimeout: 2)
        fixture.cleanUp()
    }

    private func makeModel() -> ExportModel {
        ExportModel(store: fixture.store, defaults: defaults)
    }

    /// The movie on V1 at 0 (2 s, 320x180) with its audio.
    private func buildSequence() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
    }

    func testPresetMapsToSettings() throws {
        let model = makeModel()
        XCTAssertEqual(model.preset, .h264)
        XCTAssertEqual(model.container, .mp4)
        XCTAssertEqual(model.audioCodec, .aac)
        var settings = try XCTUnwrap(model.settings)
        XCTAssertEqual(settings.preset, .h264)
        XCTAssertEqual(settings.rateControl, .quality)
        XCTAssertEqual(settings.quality, 0.7, accuracy: 1e-9)
        XCTAssertEqual(settings.audioBitRate, 256_000)

        // ProRes: MOV only, PCM audio, no rate control.
        model.preset = .proRes422
        XCTAssertEqual(model.containers, [.mov])
        XCTAssertEqual(model.container, .mov)
        XCTAssertEqual(model.audioCodec, .pcm)
        XCTAssertTrue(model.isProRes)
        settings = try XCTUnwrap(model.settings)
        XCTAssertEqual(settings.fileExtension, "mov")

        // Back to HEVC: the PCM audio stays valid in MOV; bit rate typed in Mb/s.
        model.preset = .hevc
        XCTAssertEqual(model.containers, [.mp4, .mov])
        XCTAssertEqual(model.container, .mov, "a container the preset supports is kept")
        model.rateControl = .bitRate
        model.bitRateText = "12,5"
        settings = try XCTUnwrap(model.settings)
        XCTAssertEqual(settings.videoBitRate, 12_500_000)
        XCTAssertEqual(settings.rateControl, .bitRate)
        // MP4 cannot hold PCM: switching falls back to AAC.
        model.container = .mp4
        XCTAssertEqual(model.audioCodec, .aac)

        // AV1: MP4 or Matroska.
        model.preset = .av1
        XCTAssertEqual(model.containers, [.mp4, .mkv])
        model.container = .mkv
        XCTAssertEqual(model.contentType.preferredFilenameExtension, "mkv")

        // Custom width keeps the sequence aspect.
        model.resolution = .custom
        model.customWidthText = "960"
        XCTAssertEqual(model.outputSize, CGSize(width: 960, height: 540))
        XCTAssertEqual(model.sizeText, "960×540")
        model.customWidthText = "wide"
        XCTAssertNil(model.settings)
        XCTAssertEqual(model.validationMessage, "Type the width in pixels.")
        model.customWidthText = "8"
        XCTAssertNotNil(model.settings?.validationMessage)
        XCTAssertEqual(model.validationMessage, model.settings?.validationMessage)
    }

    func testEstimateAndDurationFollowTheSequence() async throws {
        let model = makeModel()
        XCTAssertEqual(model.estimatedSizeText, "—", "empty sequence")
        XCTAssertEqual(model.validationMessage, "The sequence is empty: there is nothing to export.")
        try await buildSequence()
        XCTAssertEqual(model.sequenceFrames, 60)
        XCTAssertEqual(model.durationText, fixture.store.durationString(frames: 60))
        model.rateControl = .bitRate
        model.bitRateText = "10"
        let settings = try XCTUnwrap(model.settings)
        let bytes = fixture.store.engine.estimatedFileSize(for: settings)
        // (10 Mb/s + 256 kb/s) x 2 s / 8, plus about 1 %.
        XCTAssertEqual(Double(bytes), (10_000_000.0 + 256_000.0) * 2 / 8 * 1.01, accuracy: 50_000)
        XCTAssertEqual(model.estimatedSizeText, "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        // Doubling the rate roughly doubles the estimate.
        model.bitRateText = "20"
        let doubled = fixture.store.engine.estimatedFileSize(for: try XCTUnwrap(model.settings))
        XCTAssertEqual(Double(doubled) / Double(bytes), 1.95, accuracy: 0.05)
    }

    func testFolderBookmarkRoundTrip() throws {
        let memory = ExportFolderMemory(defaults: defaults)
        XCTAssertNil(memory.load())
        let folder = fixture.directory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.save(folder: folder)
        XCTAssertNotNil(defaults.data(forKey: ExportFolderMemory.bookmarkKey))
        XCTAssertEqual(memory.load()?.standardizedFileURL.path, folder.standardizedFileURL.path)

        // The model remembers the folder of the chosen output and offers it next time.
        let model = makeModel()
        var offered: URL?
        model.chooseOutputURL = { name, start, type in
            offered = start
            XCTAssertEqual(type, .mpeg4Movie)
            return folder.appendingPathComponent(name)
        }
        model.chooseOutput()
        XCTAssertEqual(offered?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(model.outputURL?.lastPathComponent, "Untitled.mp4")
        // Changing the container clears the choice (the sandbox granted exactly that file): the
        // file must be chosen again, and the panel offers the same name and folder as a .mov.
        model.container = .mov
        XCTAssertNil(model.outputURL)
        XCTAssertTrue(model.outputNotice?.contains("choose the file again") ?? false, model.outputNotice ?? "")
        XCTAssertFalse(model.canExport)
        var offeredName: String?
        model.chooseOutputURL = { name, start, type in
            offeredName = name
            offered = start
            XCTAssertEqual(type, .quickTimeMovie)
            return folder.appendingPathComponent(name)
        }
        model.chooseOutput()
        XCTAssertEqual(offeredName, "Untitled.mov")
        XCTAssertEqual(offered?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(model.outputURL?.lastPathComponent, "Untitled.mov")
        XCTAssertNil(model.outputNotice)
        // A container whose extension the chosen file already has keeps it.
        model.preset = .proRes422 // MOV only
        XCTAssertEqual(model.outputURL?.lastPathComponent, "Untitled.mov")

        // A folder that no longer exists is not offered (the bookmark cannot resolve it).
        try FileManager.default.removeItem(at: folder)
        defaults.removeObject(forKey: ExportFolderMemory.bookmarkKey)
        XCTAssertNil(memory.load())
    }

    func testProgressIsPublishedAtMostTenTimesASecond() async throws {
        try await buildSequence()
        let model = makeModel()
        var clock: TimeInterval = 100
        model.now = { clock }
        model.setOutputURL(fixture.directory.appendingPathComponent("paced.mp4"))
        XCTAssertTrue(model.startExport(), model.refusal ?? "")
        let before = model.publishedProgressCount
        // 200 reports over 1 s of (fake) time: at most 10 get through, plus the final one.
        for i in 0 ..< 200 {
            clock += 0.005
            model.receive(ExportModel.Progress(fraction: Double(i) / 200, framesPerSecond: 100,
                                               secondsRemaining: 1, bytesWritten: 0), final: false)
        }
        model.receive(ExportModel.Progress(fraction: 1, framesPerSecond: 100, secondsRemaining: 0, bytesWritten: 0),
                      final: true)
        let published = model.publishedProgressCount - before
        XCTAssertGreaterThanOrEqual(published, 10)
        XCTAssertLessThanOrEqual(published, 11)
        XCTAssertEqual(model.progress?.fraction, 1)
        model.cancelExport()
        let ended = await StoreFixture.wait(until: { !model.isExporting }, timeout: 10)
        XCTAssertTrue(ended)
    }

    func testDisabledStatesAndARealExport() async throws {
        let store = fixture.store
        let model = makeModel()
        XCTAssertFalse(model.canExport)
        try await buildSequence()
        XCTAssertEqual(model.exportDisabledReason, "Choose where to save the file.")
        let url = fixture.directory.appendingPathComponent("export.mp4")
        model.setOutputURL(url)
        XCTAssertTrue(model.canExport, model.exportDisabledReason ?? "")

        // A gesture blocks Export (and the menu item).
        store.engine.beginCoalescing(withKey: "drag")
        XCTAssertTrue(store.isGestureActive)
        XCTAssertEqual(model.exportDisabledReason, "Finish the current drag first.")
        XCTAssertFalse(model.startExport())
        store.engine.cancelCoalescing()
        XCTAssertTrue(model.canExport)

        // Export: running state, no second export, the store knows.
        var revealed: URL?
        model.revealInFinder = { revealed = $0 }
        XCTAssertTrue(model.startExport(), model.refusal ?? "")
        XCTAssertTrue(model.isExporting)
        XCTAssertTrue(store.isExporting)
        XCTAssertFalse(model.canExport)
        XCTAssertEqual(model.exportDisabledReason, "An export is running.")
        // Playback does not start meanwhile (the transport says why).
        store.playbackActions.togglePlay()
        XCTAssertEqual(store.statusMessage, EnginePlaybackActions.exportingMessage)
        store.playbackActions.shuttleForward()
        XCTAssertFalse(store.playhead.isRunning)
        XCTAssertNotEqual(store.engine.playbackState, .playing)
        store.exportModel = model
        model.close()
        XCTAssertTrue(store.exportModel === model, "the sheet cannot close while exporting")

        let finished = await StoreFixture.wait(until: { !model.isExporting }, timeout: 60)
        XCTAssertTrue(finished)
        XCTAssertFalse(store.isExporting)
        guard case let .succeeded(outputURL, message)? = model.outcome else {
            return XCTFail("export failed: \(String(describing: model.outcome))")
        }
        XCTAssertEqual(outputURL.standardizedFileURL.path, url.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(message.contains("1920×1080"), message) // the sequence size (the clip is fitted into it)
        XCTAssertTrue(store.statusMessage?.hasPrefix("Exported export.mp4") ?? false, store.statusMessage ?? "")
        model.reveal()
        XCTAssertEqual(revealed, outputURL)
    }

    func testClosingOrQuittingWarnsAboutARunningExport() async throws {
        // 10 s of media, so the export is still running when the questions are asked.
        let (movie, _) = try await fixture.importMedia()
        for i in 0 ..< 5 {
            try fixture.placeMovie(movie, at: Double(i) * 2)
        }
        let documents = DocumentController(store: fixture.store, defaults: defaults)
        var alerts: [String] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn // Keep Exporting
        documents.runAlert = { alert in
            alerts.append(alert.messageText)
            return answer
        }
        XCTAssertTrue(documents.confirmStoppingExport(because: "Quitting"), "no export: nothing to ask")
        XCTAssertTrue(alerts.isEmpty)

        let model = makeModel()
        let url = fixture.directory.appendingPathComponent("long.mov")
        model.setOutputURL(url)
        model.preset = .proRes422
        XCTAssertTrue(model.startExport(), model.refusal ?? "")
        let exporting = fixture.store.engine.activeExport
        XCTAssertFalse(documents.shouldTerminate(), "Keep Exporting cancels the quit")
        XCTAssertEqual(alerts, ["An export is in progress."])
        XCTAssertFalse(exporting?.isFinished ?? true, "still exporting")

        answer = .alertFirstButtonReturn // Stop Export
        XCTAssertTrue(documents.confirmStoppingExport(because: "Closing the window"))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(exporting?.isFinished ?? true, "stopped before the window closes")
        let ended = await StoreFixture.wait(until: { !model.isExporting }, timeout: 10)
        XCTAssertTrue(ended)
        XCTAssertNil(model.outcome, "a cancelled export shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the unfinished file is deleted")
        XCTAssertEqual(fixture.store.statusMessage, "Export cancelled.")
    }
}
