import AppKit
import FramewrightEngine
import XCTest
@testable import Framewright

/// Close, quit, save-failure and Finder-open flows of the document controller and app delegate,
/// with the alerts and the save panel replaced by scripted answers.
@MainActor
final class DocumentFlowTests: XCTestCase {
    private var fixture: StoreFixture!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        fixture = try StoreFixture()
        suiteName = "DocumentFlowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        fixture?.cleanUp()
    }

    /// The alerts shown, in order.
    private final class AlertLog {
        var titles: [String] = []
    }

    /// A document controller whose alerts answer with `answers` in order (then Cancel), recorded
    /// in `log`, and whose save panel returns `saveURL`.
    private func makeDocuments(answers: [NSApplication.ModalResponse], saveURL: URL? = nil,
                               log: AlertLog) -> DocumentController {
        let documents = DocumentController(store: fixture.store, defaults: defaults)
        var remaining = answers
        documents.runAlert = { alert in
            log.titles.append(alert.messageText)
            return remaining.isEmpty ? .alertSecondButtonReturn : remaining.removeFirst()
        }
        documents.chooseSaveURL = { _ in saveURL }
        return documents
    }

    private func makeDirty() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        XCTAssertTrue(fixture.store.isDirty)
    }

    func testClosingWithUnsavedChangesAsksOnceAndQuittingDoesNotAskAgain() async throws {
        try await makeDirty()
        let log = AlertLog()
        let documents = makeDocuments(answers: [.alertThirdButtonReturn], log: log) // Don't Save
        XCTAssertTrue(documents.confirmClosingWindow())
        XCTAssertEqual(log.titles.count, 1)
        XCTAssertTrue(documents.shouldTerminate(), "the last window closing quits without a second prompt")
        XCTAssertEqual(log.titles.count, 1)

        // A change after answering asks again (and Cancel keeps the app).
        fixture.store.report(fixture.store.engine.addTrack(of: .video, name: nil))
        XCTAssertFalse(documents.shouldTerminate())
        XCTAssertEqual(log.titles.count, 2)
    }

    func testCancellingTheCloseKeepsTheWindowAndQuitAsks() async throws {
        try await makeDirty()
        let log = AlertLog()
        let documents = makeDocuments(answers: [.alertSecondButtonReturn, .alertSecondButtonReturn], log: log)
        XCTAssertFalse(documents.confirmClosingWindow(), "Cancel keeps the window")
        XCTAssertFalse(documents.shouldTerminate(), "Cancel on quit keeps the app")
        XCTAssertEqual(log.titles.count, 2)

        // Through the real window delegate proxy: the guard refuses the close.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let closeGuard = WindowAccessor.CloseGuard(shouldClose: { documents.confirmClosingWindow() })
        closeGuard.attach(to: window)
        XCTAssertTrue(window.delegate === closeGuard)
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(log.titles.count, 3)
        closeGuard.shouldClose = { true }
        XCTAssertTrue(closeGuard.windowShouldClose(window))
    }

    func testSaveFailureIsReportedAndKeepsTheDocumentOpen() async throws {
        try await makeDirty()
        let log = AlertLog()
        let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Project.framewright")
        let documents = makeDocuments(answers: [.alertFirstButtonReturn], saveURL: unwritable, log: log) // Save
        XCTAssertFalse(documents.confirmClosingWindow(), "a failed save does not close the window")
        XCTAssertEqual(log.titles, ["Do you want to save the changes made to “Untitled”?",
                                    "The project could not be saved."])
        XCTAssertTrue(fixture.store.isDirty)
        XCTAssertNil(fixture.store.projectURL)

        // A successful Save As.
        let url = fixture.directory.appendingPathComponent("Saved.framewright")
        documents.chooseSaveURL = { _ in url }
        XCTAssertTrue(documents.save())
        XCTAssertFalse(fixture.store.isDirty)
        XCTAssertEqual(fixture.store.projectURL, url)
        XCTAssertEqual(documents.recentURLs.first?.standardizedFileURL.path, url.standardizedFileURL.path)
    }

    func testFinderOpenAtColdLaunchWaitsForTheWindow() async throws {
        try await makeDirty()
        let url = fixture.directory.appendingPathComponent("Launch.framewright")
        try fixture.store.save(to: url)
        let other = StoreFixtureStore.make(in: fixture.directory)
        let log = AlertLog()
        let documents = DocumentController(store: other, defaults: defaults)
        documents.runAlert = { alert in
            log.titles.append(alert.messageText)
            return .alertSecondButtonReturn
        }
        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [url])
        XCTAssertEqual(delegate.pendingProjectURLs, [url], "no window yet: kept")
        XCTAssertNil(other.projectURL)
        delegate.documents = documents
        XCTAssertEqual(other.projectURL?.standardizedFileURL.path, url.standardizedFileURL.path)
        XCTAssertTrue(delegate.pendingProjectURLs.isEmpty)
        XCTAssertEqual(other.clips.count, 1)
        XCTAssertTrue(log.titles.isEmpty, "a clean launch opens without asking")
    }

    /// Review L11: a project the loader had to adjust (here a fade in on a clip another clip touches,
    /// which the loader removes, review M8) says so when it opens, with the warnings, and a missing
    /// media file does not hide them.
    func testOpeningAnAdjustedProjectShowsTheLoadWarnings() async throws {
        let store = fixture.store
        let (_, tone) = try await fixture.importMedia()
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1, sourceIn: .zero,
                                  sourceOut: store.time(frames: 30), overwrite: true))
        XCTAssertTrue(store.place(asset: tone.assetID, at: store.time(frames: 30), videoTrack: 0, audioTrack: a1,
                                  sourceIn: store.time(frames: 30), sourceOut: store.time(frames: 60), overwrite: true))
        let second = try XCTUnwrap(store.selection.first)
        let url = fixture.directory.appendingPathComponent("Adjusted.framewright")
        try store.save(to: url)
        // Hand-edit the file: a fade in on the second clip, whose start the first clip touches.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
        var audioTracks = try XCTUnwrap(sequences[0]["audioTracks"] as? [[String: Any]])
        var clips = try XCTUnwrap(audioTracks[0]["clips"] as? [[String: Any]])
        let index = try XCTUnwrap(clips.firstIndex { ($0["id"] as? NSNumber)?.int64Value == second })
        let nextId = try XCTUnwrap(document["nextId"] as? NSNumber).int64Value
        clips[index]["spans"] = [["id": nextId, "kind": "transition", "lane": 0, "edge": "head",
                                  "start": ["value": 0, "timescale": 1], "end": ["value": 10, "timescale": 30]]]
        document["nextId"] = nextId + 1
        audioTracks[0]["clips"] = clips
        sequences[0]["audioTracks"] = audioTracks
        document["sequences"] = sequences
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        try store.open(url: url)
        let message = try XCTUnwrap(store.statusMessage)
        XCTAssertTrue(message.hasPrefix("The project was adjusted to load: "), message)
        XCTAssertTrue(message.contains("was removed"), message)
        XCTAssertTrue(message.contains("touches the start of clip"), message)
        XCTAssertTrue(store.clips[second]?.spans.isEmpty == true, "the fade in went")

        // With its media missing too, both are said.
        var moved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var assets = try XCTUnwrap(moved["assets"] as? [[String: Any]])
        assets[0]["url"] = fixture.directory.appendingPathComponent("gone.wav").path
        moved["assets"] = assets
        moved["assetBookmarks"] = nil // the bookmark would still find the file
        try JSONSerialization.data(withJSONObject: moved).write(to: url)
        try store.open(url: url)
        let both = try XCTUnwrap(store.statusMessage)
        XCTAssertTrue(both.hasPrefix("1 media file could not be found. The project was adjusted to load: "), both)
    }
}

/// A second store over its own engine (for flows that open a file into a fresh app).
@MainActor
enum StoreFixtureStore {
    static func make(in directory: URL) -> ProjectStore {
        ProjectStore(engine: VEEngine(cacheDirectory: directory.appendingPathComponent("Caches2")))
    }

}

