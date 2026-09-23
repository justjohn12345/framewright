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
}

/// A second store over its own engine (for flows that open a file into a fresh app).
@MainActor
enum StoreFixtureStore {
    static func make(in directory: URL) -> ProjectStore {
        ProjectStore(engine: VEEngine(cacheDirectory: directory.appendingPathComponent("Caches2")))
    }
}
