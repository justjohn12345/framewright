import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

/// Receiving media from Photos after the motion/photos review: the pasteboard promise path
/// (`PasteboardFilePromise` over a double of `NSFilePromiseReceiver`'s contract: counts, errors,
/// cancel after a partial delivery, release while pending, the staging folder and name collisions),
/// the Media folder rules (a Media folder the app makes, adopted only with its marker, never stored
/// when derived from the project, Save As, duplicated project folders, the Trash, stale and failed
/// bookmarks, the security scope outliving New/Open), non-media promises, failed imports, late
/// placement (an edited timeline, a gesture or nudge, a refused drop, an occupied drop point, a drop
/// off the tracks), the Live Photo question queue, PHPicker's lifetime and Live Photo bundles,
/// quitting or replacing the project while media arrives, and concurrent adoption.
@MainActor
final class PhotosReceivingTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var chosenFolder: URL!
    private var folderQuestions: [String] = []

    override func setUp() async throws {
        fixture = try StoreFixture()
        store.defaults = try XCTUnwrap(UserDefaults(suiteName: "photos-receiving-\(UUID())"))
        chosenFolder = fixture.directory.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
        folderQuestions = []
        store.mediaFolder.chooseFolder = { [unowned self] _, message in
            folderQuestions.append(message)
            return chosenFolder
        }
        store.incoming.askLivePhoto = { _, _ in
            XCTFail("unexpected Live Photo question")
            return nil
        }
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func saveProject(in directory: URL? = nil, name: String = "Holiday") throws -> URL {
        let folder = directory ?? fixture.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).framewright")
        try store.save(to: url)
        return url
    }

    private func asset(at url: URL) -> VEAssetInfo? {
        store.assets.first { ProjectStore.samePath($0.path, url.path) }
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) async {
        let met = await StoreFixture.wait(until: condition, timeout: timeout)
        XCTAssertTrue(met, "timed out waiting: \(what)")
    }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func heic(_ name: String) throws -> URL {
        let url = fixture.directory.appendingPathComponent(name)
        try TestMediaFactory.writeHEIC(to: url)
        return url
    }

    // MARK: The pasteboard promise path

    func testAPasteboardPromiseMovesEachFileOutOfStagingAndCompletesAtThePromisedCount() async throws {
        let media = try XCTUnwrap(ImportedMediaFolder.prepareMediaFolder(in: fixture.directory))
        let receiver = FakeFilePromiseReceiver(types: [.heic, .quickTimeMovie])
        let session = PromiseDropSession()
        let promise = PasteboardFilePromise(receiver: receiver, session: session, index: 1, count: 3)
        XCTAssertEqual(promise.displayName, "\(UTType.heic.localizedDescription ?? "") 2 of 3",
                       "rows of one drop are told apart before the names are known")
        var names: [String] = []
        var fractions: [Double] = []
        var result: Result<[URL], Error>?
        promise.onRename = { names.append($0) }
        promise.onProgress = { fractions.append($0) }
        promise.receive(into: media) { result = $0 }
        let staging = try XCTUnwrap(receiver.destination)
        XCTAssertEqual(staging.deletingLastPathComponent().resolvingSymlinksInPath(), media.resolvingSymlinksInPath())
        XCTAssertTrue(staging.lastPathComponent.hasPrefix("."), "a hidden staging folder")

        try receiver.write(try heic("still.heic"), as: "IMG_0001.HEIC")
        await wait("the first file is settled on its own") { names == ["IMG_0001.HEIC"] }
        XCTAssertEqual(fractions, [0.5])
        XCTAssertNil(result, "one of two promised files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("IMG_0001.HEIC").path),
                      "moved into the Media folder at once")
        try receiver.write(fixture.movieURL, as: "IMG_0001.MOV")
        await wait("the promise completes") { result != nil }
        let urls = try XCTUnwrap(try result?.get())
        XCTAssertEqual(urls.map(\.lastPathComponent), ["IMG_0001.HEIC", "IMG_0001.MOV"])
        XCTAssertEqual(fractions.last, 1)
        XCTAssertFalse(session.stagingExists, "the staging folder is gone once the drop has settled")
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName, "IMG_0001.HEIC", "IMG_0001.MOV"])
    }

    func testFewerReaderCallsThanPromisedKeepTheItemUntilCancelWhichDeletesWhatArrivedAtOnce() async throws {
        _ = try saveProject()
        let receiver = FakeFilePromiseReceiver(types: [.heic, .quickTimeMovie])
        let promise = PasteboardFilePromise(receiver: receiver)
        XCTAssertTrue(store.incoming.receive([promise]))
        let media = try XCTUnwrap(store.mediaFolder.folder)
        try receiver.write(try heic("still.heic"), as: "IMG_0002.HEIC")
        await wait("the row takes the file's name") { store.incoming.items.first?.name == "IMG_0002.HEIC" }
        XCTAssertEqual(store.incoming.items.first?.state, .receiving, "the second file never comes")
        let arrived = media.appendingPathComponent("IMG_0002.HEIC")
        XCTAssertTrue(FileManager.default.fileExists(atPath: arrived.path))

        store.incoming.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: arrived.path), "deleted at once, not when all calls come")
        XCTAssertFalse(store.incoming.isReceiving)
        // A call after the cancel deletes its file.
        let late = try receiver.write(fixture.movieURL, as: "IMG_0002.MOV")
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName], "nothing of it is left")
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertTrue(store.assets.isEmpty)
    }

    func testMoreReaderCallsThanPromisedImportTheExtraFilesToo() async throws {
        _ = try saveProject()
        // A legacy promiser that lists one type and writes two files of it.
        let receiver = FakeFilePromiseReceiver(types: [.quickTimeMovie])
        XCTAssertTrue(store.incoming.receive([PasteboardFilePromise(receiver: receiver)]))
        try receiver.write(fixture.movieURL, as: "First.mov")
        await wait("the promised file is imported") { store.assets.count == 1 }
        try receiver.write(fixture.movieURL, as: "Second.mov")
        await wait("the extra file is imported too, not orphaned") { store.assets.count == 2 }
        XCTAssertNotNil(store.assets.first { $0.path.hasSuffix("Media/Second.mov") })
        // After New a late file of the old project's promise is deleted, not imported.
        store.newProject()
        let late = try receiver.write(fixture.movieURL, as: "Third.mov")
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        XCTAssertTrue(store.assets.isEmpty)
        let media = late.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent("Third.mov").path))
    }

    func testAReaderErrorFailsOnlyItsFile() async throws {
        _ = try saveProject()
        let partial = FakeFilePromiseReceiver(types: [.heic, .quickTimeMovie])
        let broken = FakeFilePromiseReceiver(types: [.quickTimeMovie])
        XCTAssertTrue(store.incoming.receive([PasteboardFilePromise(receiver: partial),
                                              PasteboardFilePromise(receiver: broken)]))
        partial.fail("the still could not be exported")
        try partial.write(fixture.movieURL, as: "IMG_0003.MOV")
        broken.fail("the original is not downloaded")
        await wait("the batch settles") { !store.incoming.isReceiving }
        await wait("the movie that arrived is imported") { store.assets.count == 1 }
        XCTAssertEqual(store.statusMessage?.contains("could not be received: the original is not downloaded"), true)
    }

    func testAPromiseReleasedWhilePendingDeletesWhatArrivedAndWhatComesLater() async throws {
        let media = try XCTUnwrap(ImportedMediaFolder.prepareMediaFolder(in: fixture.directory))
        let receiver = FakeFilePromiseReceiver(types: [.heic, .quickTimeMovie])
        let session = PromiseDropSession()
        weak var released: PasteboardFilePromise?
        weak var leaseHeld: SecurityScopeLease?
        do {
            let promise = PasteboardFilePromise(receiver: receiver, session: session)
            let lease = SecurityScopeLease(url: media)
            leaseHeld = lease
            promise.securityScope = lease
            released = promise
            promise.receive(into: media) { _ in XCTFail("never completes once released") }
            try receiver.write(try heic("still.heic"), as: "Gone.HEIC")
        }
        XCTAssertNil(released, "nothing else holds the promise")
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent("Gone.HEIC").path),
                       "what arrived is deleted when the promise goes")
        XCTAssertNotNil(leaseHeld, "the folder's security scope stays while AppKit may still call")
        let late = try receiver.write(fixture.movieURL, as: "Gone.MOV")
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        receiver.finish()
        await StoreFixture.wait(until: { leaseHeld == nil }, timeout: 2)
        XCTAssertNil(leaseHeld, "released with the reader")
        XCTAssertFalse(session.stagingExists)
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName])
    }

    func testTwoPromisedFilesWithOneNameBothArrive() async throws {
        _ = try saveProject()
        // Two items of one drag named alike (two phones): AppKit makes both deliver into one folder.
        let first = FakeFilePromiseReceiver(types: [.heic])
        let second = FakeFilePromiseReceiver(types: [.heic])
        let session = PromiseDropSession()
        XCTAssertTrue(store.incoming.receive([PasteboardFilePromise(receiver: first, session: session, index: 0, count: 2),
                                              PasteboardFilePromise(receiver: second, session: session, index: 1,
                                                                    count: 2)]))
        XCTAssertEqual(first.destination, second.destination, "one destination for the whole drag")
        try first.write(try heic("a.heic"), as: "IMG_0001.HEIC")
        try second.write(try heic("b.heic"), as: "IMG_0001.HEIC")
        await wait("both are imported") { store.assets.count == 2 }
        let media = try XCTUnwrap(store.mediaFolder.folder)
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName, "IMG_0001 2.HEIC", "IMG_0001.HEIC"])
    }

    func testAdoptingFromManyThreadsNeverLosesAFile() throws {
        let destination = fixture.directory.appendingPathComponent("Adopted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sources = try (0 ..< 16).map { index -> URL in
            let folder = fixture.directory.appendingPathComponent("source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("IMG_0001.mov")
            try FileManager.default.copyItem(at: fixture.movieURL, to: file)
            return file
        }
        let results = UnsafeResults(count: sources.count)
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            results.set(index, Result { try ReceivedFiles.adopt(sources[index], into: destination, name: "IMG_0001") })
        }
        let adopted = try results.values.map { try $0.get() }
        XCTAssertEqual(Set(adopted.map(\.lastPathComponent)).count, 16, "each got its own name")
        XCTAssertEqual(files(in: destination).count, 16)
        // Names from a source are sanitized: they never leave the folder.
        let odd = fixture.directory.appendingPathComponent("odd.mov")
        try FileManager.default.copyItem(at: fixture.movieURL, to: odd)
        let placed = try ReceivedFiles.adopt(odd, into: destination, name: "../../escape/.hidden:name")
        XCTAssertEqual(placed.deletingLastPathComponent().resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertFalse(placed.lastPathComponent.hasPrefix("."))
        XCTAssertNil(ReceivedFiles.sanitizedName(".."))
        XCTAssertNil(ReceivedFiles.sanitizedName(" / "), "a name of separators only is no name")
    }

    /// Results written from several threads at distinct indexes.
    private final class UnsafeResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<URL, Error>?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        func set(_ index: Int, _ result: Result<URL, Error>) {
            lock.lock()
            storage[index] = result
            lock.unlock()
        }

        var values: [Result<URL, Error>] {
            lock.lock()
            defer { lock.unlock() }
            return storage.compactMap { $0 }
        }
    }

    // MARK: Drag pasteboard contents and non-media

    func testTheDragPasteboardIsPartitionedOncePerItemAndNonMediaPromisesAreRefused() {
        let movie = FakeFilePromiseReceiver(types: [.quickTimeMovie])
        let pdf = FakeFilePromiseReceiver(types: [.pdf])
        let finderWithPromise = FakeFilePromiseReceiver(types: [.jpeg])
        let livePhoto = FakeFilePromiseReceiver(types: [.heic, .quickTimeMovie])
        let file = URL(fileURLWithPath: "/tmp/From Finder.mov")
        let contents = DragContents.partition([
            .init(fileURL: nil, carriesPromise: true),  // Photos: a movie
            .init(fileURL: nil, carriesPromise: true),  // Mail: a PDF
            .init(fileURL: file, carriesPromise: true), // a file URL and a promise: the file
            .init(fileURL: nil, carriesPromise: false), // text: nothing
            .init(fileURL: nil, carriesPromise: true),  // a Live Photo
        ], receivers: [movie, pdf, finderWithPromise, livePhoto])
        XCTAssertEqual(contents.fileURLs, [file])
        XCTAssertEqual(contents.refusedPromises, 1)
        XCTAssertEqual(contents.promises.count, 2)
        XCTAssertTrue(contents.promises[0].receiver === movie)
        XCTAssertTrue(contents.promises[1].receiver === livePhoto)
        XCTAssertTrue(contents.promises[0].session === contents.promises[1].session, "one staging folder per drag")
        XCTAssertEqual(contents.promises[1].displayName, "\(UTType.heic.localizedDescription ?? "") 2 of 2")
    }

    func testANonMediaPromiseIsNotReceivedAndAFileTheImportRefusesIsDeleted() async throws {
        _ = try saveProject()
        // A Mail PDF dropped on the bin: its provider offers no media type.
        let pdf = NSItemProvider()
        for type in UTType.filePromiseTypes {
            pdf.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
                done(Data(), nil)
                return nil
            }
        }
        pdf.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { done in
            done(Data("%PDF".utf8), nil)
            return nil
        }
        let delegate = MediaBinDropDelegate(store: store, isTargeted: .constant(false))
        XCTAssertFalse(delegate.handlePerform(FakeDropInfo(location: .zero, providers: [pdf])))
        XCTAssertEqual(store.statusMessage, "Some dropped items are not media Framewright can import.")
        await StoreFixture.wait(until: { false }, timeout: 0.1)
        XCTAssertFalse(store.incoming.isReceiving)

        // A promised "movie" that is not one: received, refused by the import, deleted.
        let fake = fixture.directory.appendingPathComponent("Not a movie.mov")
        try Data("not media".utf8).write(to: fake)
        let promise = ScriptedPromise(name: "Not a movie")
        XCTAssertTrue(store.incoming.receive([promise]))
        try promise.deliver([fake])
        let received = try XCTUnwrap(promise.directory).appendingPathComponent("Not a movie.mov")
        await wait("the refused file is deleted") { !FileManager.default.fileExists(atPath: received.path) }
        XCTAssertTrue(store.assets.isEmpty)
    }

    // MARK: The Media folder

    func testThePanelsFolderGetsAMediaFolderAndAnExistingMediaFolderNeedsTheMarker() async throws {
        // Untitled: the question, then a Media folder inside the chosen one, stored with the project.
        let untitled = ScriptedPromise(name: "One")
        XCTAssertTrue(store.incoming.receive([untitled]))
        XCTAssertEqual(folderQuestions.count, 1)
        let media = chosenFolder.appendingPathComponent("Media")
        XCTAssertEqual(untitled.directory?.resolvingSymlinksInPath(), media.resolvingSymlinksInPath())
        XCTAssertTrue(ImportedMediaFolder.hasMarker(media))
        XCTAssertNotNil(store.engine.mediaFolderBookmark, "a folder the user chose is stored")
        store.incoming.cancelAll()

        // A saved project whose folder holds the user's own "Media" folder: left alone.
        store.newProject()
        let projectFolder = fixture.directory.appendingPathComponent("Trip", isDirectory: true)
        let usersOwn = projectFolder.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: usersOwn, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: usersOwn.appendingPathComponent("notes.txt"))
        _ = try saveProject(in: projectFolder)
        let saved = ScriptedPromise(name: "Two")
        XCTAssertTrue(store.incoming.receive([saved]))
        let second = projectFolder.appendingPathComponent("Media 2")
        XCTAssertEqual(saved.directory?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        XCTAssertEqual(files(in: usersOwn), ["notes.txt"], "the user's folder is untouched")
        XCTAssertNil(store.engine.mediaFolderBookmark, "derived from the project, not stored")
        store.incoming.cancelAll()
        // With the marker the app's own folder is adopted again.
        XCTAssertEqual(ImportedMediaFolder.prepareMediaFolder(in: projectFolder)?.resolvingSymlinksInPath(),
                       second.resolvingSymlinksInPath())
    }

    func testWhenTheProjectsFolderIsNotWritableThePanelAsksWithTheReason() throws {
        let readOnly = fixture.directory.appendingPathComponent("ReadOnly", isDirectory: true)
        _ = try saveProject(in: readOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let promise = ScriptedPromise(name: "Sandboxed")
        XCTAssertTrue(store.incoming.receive([promise]))
        XCTAssertEqual(folderQuestions.count, 1)
        XCTAssertTrue(folderQuestions[0].contains("cannot make a “Media” folder next to “Holiday”"), folderQuestions[0])
        XCTAssertEqual(promise.directory?.resolvingSymlinksInPath(),
                       chosenFolder.appendingPathComponent("Media").resolvingSymlinksInPath())
        store.incoming.cancelAll()
    }

    func testSaveAsElsewhereAndACopiedProjectFolderUseTheirOwnMediaFolder() async throws {
        let original = fixture.directory.appendingPathComponent("A", isDirectory: true)
        let projectA = try saveProject(in: original)
        let first = ScriptedPromise(name: "First")
        XCTAssertTrue(store.incoming.receive([first]))
        try first.deliver([fixture.movieURL])
        await wait("imported into A/Media") { store.assets.count == 1 }
        XCTAssertTrue(store.assets[0].path.contains("/A/Media/"))

        // Save As into B: the next drop goes to B/Media.
        let movedTo = fixture.directory.appendingPathComponent("B", isDirectory: true)
        _ = try saveProject(in: movedTo)
        let second = ScriptedPromise(name: "Second")
        XCTAssertTrue(store.incoming.receive([second]))
        XCTAssertEqual(second.directory?.resolvingSymlinksInPath(),
                       movedTo.appendingPathComponent("Media").resolvingSymlinksInPath())
        store.incoming.cancelAll()

        // A copy of folder A (Finder's Duplicate) opened from the copy: its own Media folder.
        let copy = fixture.directory.appendingPathComponent("A copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        try store.open(url: copy.appendingPathComponent(projectA.lastPathComponent))
        let third = ScriptedPromise(name: "Third")
        XCTAssertTrue(store.incoming.receive([third]))
        XCTAssertEqual(third.directory?.resolvingSymlinksInPath(),
                       copy.appendingPathComponent("Media").resolvingSymlinksInPath(),
                       "the copy's Media folder (it has the marker), not the original's")
        store.incoming.cancelAll()
        XCTAssertEqual(folderQuestions.count, 0)
    }

    func testAnEarlierVersionsStoredMediaFolderIsDroppedOnSaveAsAndInACopy() throws {
        // Earlier versions stored the Media folder next to the project (no marker).
        let original = fixture.directory.appendingPathComponent("Old", isDirectory: true)
        let legacyMedia = original.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyMedia, withIntermediateDirectories: true)
        let project = try saveProject(in: original)
        store.engine.mediaFolderBookmark = try legacyMedia.bookmarkData()
        try store.save(to: project)
        // Its own location: the stored folder is still used.
        let here = ScriptedPromise(name: "Here")
        XCTAssertTrue(store.incoming.receive([here]))
        XCTAssertEqual(here.directory?.resolvingSymlinksInPath(), legacyMedia.resolvingSymlinksInPath())
        store.incoming.cancelAll()

        // A copy of the folder: the stored folder is the original's; dropped, the copy's own is made.
        let copy = fixture.directory.appendingPathComponent("Old copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("Media"))
        try store.open(url: copy.appendingPathComponent(project.lastPathComponent))
        let there = ScriptedPromise(name: "There")
        XCTAssertTrue(store.incoming.receive([there]))
        XCTAssertEqual(there.directory?.resolvingSymlinksInPath(),
                       copy.appendingPathComponent("Media").resolvingSymlinksInPath())
        XCTAssertNil(store.engine.mediaFolderBookmark)
        store.incoming.cancelAll()

        // Save As elsewhere drops a stored folder next to the old location.
        try store.open(url: project)
        XCTAssertNotNil(store.engine.mediaFolderBookmark)
        let elsewhere = fixture.directory.appendingPathComponent("Elsewhere", isDirectory: true)
        let moved = try saveProject(in: elsewhere)
        XCTAssertNil(store.engine.mediaFolderBookmark, "not saved into the new file")
        let reopened = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertFalse(reopened.contains("mediaFolderBookmark"))
    }

    func testAStoredFolderInTheTrashOrGoneIsNotUsedAndAMovedOneIsFollowed() throws {
        // A folder the user chose (untitled project), then saved.
        let first = ScriptedPromise(name: "First")
        XCTAssertTrue(store.incoming.receive([first]))
        store.incoming.cancelAll()
        let project = try saveProject(in: fixture.directory.appendingPathComponent("P", isDirectory: true))
        XCTAssertNotNil(store.engine.mediaFolderBookmark)

        // Moved (renamed): the bookmark follows it and is rewritten when stale.
        let moved = fixture.directory.appendingPathComponent("Chosen moved", isDirectory: true)
        try FileManager.default.moveItem(at: chosenFolder, to: moved)
        let before = store.engine.mediaFolderBookmark
        try store.open(url: project)
        let followed = ScriptedPromise(name: "Followed")
        XCTAssertTrue(store.incoming.receive([followed]))
        XCTAssertEqual(followed.directory?.resolvingSymlinksInPath(),
                       moved.appendingPathComponent("Media").resolvingSymlinksInPath())
        XCTAssertNotEqual(store.engine.mediaFolderBookmark, before, "the stale bookmark is rewritten")
        store.incoming.cancelAll()

        // In the Trash: refused (and forgotten); the project's own Media folder is used instead.
        let trash = fixture.directory.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: moved, to: trash.appendingPathComponent("Chosen moved"))
        store.newProject()
        try store.open(url: project)
        store.mediaFolder.trashFolders = [trash]
        let trashed = ScriptedPromise(name: "Trashed")
        XCTAssertTrue(store.incoming.receive([trashed]))
        XCTAssertEqual(trashed.directory?.resolvingSymlinksInPath(),
                       project.deletingLastPathComponent().appendingPathComponent("Media").resolvingSymlinksInPath())
        XCTAssertNil(store.engine.mediaFolderBookmark, "a folder in the Trash is forgotten")
        store.incoming.cancelAll()

        // Gone altogether: the project's own Media folder, without a question.
        store.engine.mediaFolderBookmark = Data("not a bookmark".utf8)
        store.mediaFolder.reset()
        let gone = ScriptedPromise(name: "Gone")
        XCTAssertTrue(store.incoming.receive([gone]))
        XCTAssertEqual(gone.directory?.resolvingSymlinksInPath(),
                       project.deletingLastPathComponent().appendingPathComponent("Media").resolvingSymlinksInPath())
        store.incoming.cancelAll()
        XCTAssertEqual(folderQuestions.count, 1)
    }

    func testTheFoldersSecurityScopeOutlivesNewWhileAPromiseMayStillDeliver() async throws {
        let receiver = FakeFilePromiseReceiver(types: [.quickTimeMovie])
        XCTAssertTrue(store.incoming.receive([PasteboardFilePromise(receiver: receiver)]))
        weak var lease: SecurityScopeLease?
        lease = store.mediaFolder.lease
        XCTAssertNotNil(lease, "the chosen folder's scope")
        store.newProject()
        XCTAssertNil(store.mediaFolder.lease, "the folder forgets it")
        XCTAssertNotNil(lease, "the promise still holds it")
        let late = try receiver.write(fixture.movieURL, as: "Late.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path), "deleted: it belongs to the old project")
        receiver.finish()
        await StoreFixture.wait(until: { lease == nil }, timeout: 2)
        XCTAssertNil(lease, "released once AppKit is done")
    }

    // MARK: Placement of media that arrives late

    private func timelineDrop(_ fake: FakePromiseProvider, at location: CGPoint = CGPoint(x: 100, y: 90),
                              insert: Bool = false) -> Bool {
        let gestures = TimelineGestureController(store: store)
        let delegate = TimelineDropDelegate(gestures: gestures, isAssetTargeted: .constant(false),
                                            commandHeld: { insert })
        return delegate.handlePerform(FakeDropInfo(location: location, providers: [fake.provider]))
    }

    func testMediaArrivingAfterAnEditStaysInTheBinWithAMessage() async throws {
        _ = try saveProject()
        let (movie, _) = try await fixture.importMedia()
        let fake = FakePromiseProvider(name: "Late", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(timelineDrop(fake))
        await wait("requested") { fake.loadRequested }
        // The user goes on editing while an iCloud original downloads.
        try fixture.placeMovie(movie, at: 10)
        let edited = store.clips
        fake.deliver()
        await wait("imported") { store.assets.count == 3 }
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertEqual(store.clips.keys.sorted(), edited.keys.sorted(), "nothing placed over the edits")
        XCTAssertEqual(store.statusMessage?.contains("the timeline changed after the drop"), true, store.statusMessage ?? "")
    }

    func testMediaArrivingDuringAGestureOrANudgeBurstStaysInTheBin() async throws {
        _ = try saveProject()
        let fake = FakePromiseProvider(name: "During", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(timelineDrop(fake))
        await wait("requested") { fake.loadRequested }
        store.cancelActiveGesture = {} // a drag in progress
        fake.deliver()
        await wait("imported") { store.assets.count == 1 }
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertEqual(store.statusMessage?.contains("a drag or a nudge was in progress"), true)
        store.cancelActiveGesture = nil

        // A nudge burst (an Accumulate group the inspector keeps open between key presses) blocks
        // placing like a gesture. (The engine defers an import while any group is open, so this is
        // what a placement that lands mid-burst meets.)
        let asset = try XCTUnwrap(store.assets.first)
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        store.engine.beginCoalescing(withKey: "nudge", mode: .accumulate)
        store.nudgeGroup = "nudge"
        XCTAssertFalse(store.isGestureActive, "a nudge burst is not a gesture")
        store.place(imported: [asset], from: [URL(fileURLWithPath: asset.path)],
                    at: IncomingMedia.Placement(trackID: v1, seconds: 0, insert: false,
                                                changeCount: store.engine.changeCount),
                    timelineChanged: false, emptyRangeOnly: true)
        XCTAssertTrue(store.clips.isEmpty, "not placed while the burst is open")
        XCTAssertEqual(store.statusMessage?.contains("a drag or a nudge was in progress"), true)
        store.engine.endCoalescing()
        store.nudgeGroup = nil
    }

    func testARefusedPlacementSaysWhyAndAnOccupiedDropPointTakesAnInsert() async throws {
        _ = try saveProject()
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        // A locked track: the drop is kept in the bin with the engine's reason.
        XCTAssertTrue(store.engine.setTrack(v1, locked: true).ok)
        let refused = FakePromiseProvider(name: "Refused", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(timelineDrop(refused))
        await wait("requested") { refused.loadRequested }
        refused.deliver()
        await wait("the reason is shown") { store.statusMessage?.contains("is in the media bin") == true }
        XCTAssertTrue(store.statusMessage?.contains("locked") == true, store.statusMessage ?? "")
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertTrue(store.engine.setTrack(v1, locked: false).ok)

        // A clip where it was dropped: the arriving media is inserted, nothing is overwritten.
        let existing = try fixture.placeMovie(movie, at: 2)
        let occupied = FakePromiseProvider(name: "Occupied", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(timelineDrop(occupied, at: CGPoint(x: 100, y: 90)))
        await wait("requested") { occupied.loadRequested }
        occupied.deliver()
        await wait("placed") { store.clips.values.filter { $0.trackKind == .video }.count == 2 }
        let moved = try XCTUnwrap(store.clips[existing])
        XCTAssertEqual(moved.timelineStart.secondsOrZero, 4, accuracy: 1e-6, "the clip there moved on, whole")
        XCTAssertEqual(store.statusMessage, "Inserted where it was dropped: the timeline there was no longer empty.")
    }

    func testADropOffTheTracksImportsIntoTheBin() async throws {
        _ = try saveProject()
        let fake = FakePromiseProvider(name: "Off", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(timelineDrop(fake, at: CGPoint(x: 100, y: 5000)))
        XCTAssertEqual(store.statusMessage, "Drop media on a track to place it; it is imported into the media bin.")
        await wait("requested") { fake.loadRequested }
        fake.deliver()
        await wait("imported") { store.assets.count == 1 }
        XCTAssertTrue(store.clips.isEmpty)
    }

    // MARK: Live Photo questions

    func testLivePhotoQuestionsWaitForAGestureAndNeverStack() async throws {
        _ = try saveProject()
        store.incoming.questionRetryInterval = 0.05
        var open = 0
        var asked = 0
        var nested: ScriptedPromise?
        store.incoming.askLivePhoto = { [unowned self] _, _ in
            open += 1
            asked += 1
            XCTAssertEqual(open, 1, "one question at a time")
            // While the first question is up, a second batch settles (a main-queue completion runs
            // inside the modal session).
            if let second = nested {
                nested = nil
                try? second.deliver([try! self.heic("IMG_0011.heic"), self.copyMovie("IMG_0011.mov")])
            }
            open -= 1
            return .video
        }
        let first = ScriptedPromise(name: "IMG_0010")
        let second = ScriptedPromise(name: "IMG_0011")
        nested = second
        XCTAssertTrue(store.incoming.receive([first]))
        XCTAssertTrue(store.incoming.receive([second]))
        store.cancelActiveGesture = {} // mid-drag
        try first.deliver([try heic("IMG_0010.heic"), copyMovie("IMG_0010.mov")])
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertEqual(asked, 0, "no question mid-drag")
        XCTAssertGreaterThan(store.incoming.deferredQuestions, 0)
        XCTAssertTrue(store.incoming.isReceiving, "waiting to be imported")
        store.cancelActiveGesture = nil
        await wait("both batches are imported") { store.assets.count == 2 }
        XCTAssertEqual(asked, 2, "asked once per batch, one after the other")
        XCTAssertTrue(store.assets.allSatisfy { $0.path.hasSuffix(".mov") })
    }

    private func copyMovie(_ name: String) -> URL {
        let url = fixture.directory.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: fixture.movieURL, to: url)
        return url
    }

    func testCancellingTheLivePhotoQuestionLeavesNothingBehind() async throws {
        _ = try saveProject()
        store.incoming.askLivePhoto = { _, _ in nil }
        let pair = ScriptedPromise(name: "IMG_0020")
        XCTAssertTrue(store.incoming.receive([pair]))
        try pair.deliver([try heic("IMG_0020.heic"), copyMovie("IMG_0020.mov")])
        let media = try XCTUnwrap(pair.directory)
        await wait("settled") { !store.incoming.isReceiving }
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName])
        XCTAssertTrue(store.assets.isEmpty)
    }

    // MARK: PHPicker

    func testAPickedLivePhotoBundleIsUnpackedAndThePartNotChosenLeavesNoBundle() async throws {
        _ = try saveProject()
        let bundle = fixture.directory.appendingPathComponent("IMG_0030.pvt", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try TestMediaFactory.writeHEIC(to: bundle.appendingPathComponent("IMG_0030.HEIC"))
        try FileManager.default.copyItem(at: fixture.movieURL, to: bundle.appendingPathComponent("IMG_0030.MOV"))
        store.incoming.askLivePhoto = { _, _ in .still }
        let picked = FakePromiseProvider(name: "IMG_0030", file: bundle, type: .livePhotoBundle)
        store.photosPicker.finishPicking([picked.provider])
        XCTAssertFalse(store.incoming.isReceiving, "received after the sheet has gone, not inside the callback")
        await wait("requested") { picked.loadRequested }
        picked.deliver()
        await wait("the still is imported") { store.assets.count == 1 }
        let media = try XCTUnwrap(store.mediaFolder.folder)
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName, "IMG_0030.HEIC"], "no bundle is left")
        XCTAssertTrue(store.assets[0].isStill)
    }

    func testAPickerWhoseSheetWentAwayWithoutItsDelegateCanBeShownAgain() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSViewController()
        window.contentViewController?.view = NSView()
        store.editorWindow = window
        let picker = store.photosPicker
        picker.presentSheet = { _, _ in } // the sheet never shows (or goes away unannounced)
        picker.present()
        XCTAssertEqual(picker.presentations, 1)
        XCTAssertNotNil(picker.picker)
        XCTAssertFalse(picker.isPresenting, "File > Import from Photos… stays enabled")
        picker.present()
        XCTAssertEqual(picker.presentations, 2, "a stale picker does not block the menu item")
        store.editorWindow = nil
    }

    func testAnItemProviderErrorAndACancelBeforeTheMainHop() async throws {
        _ = try saveProject()
        let failing = FakePromiseProvider(name: "Broken", file: fixture.movieURL, type: .quickTimeMovie)
        let racing = FakePromiseProvider(name: "Racing", file: fixture.movieURL, type: .quickTimeMovie)
        let delegate = MediaBinDropDelegate(store: store, isTargeted: .constant(false))
        XCTAssertTrue(delegate.handlePerform(FakeDropInfo(location: .zero, providers: [failing.provider, racing.provider])))
        await wait("requested") { failing.loadRequested && racing.loadRequested }
        failing.fail("the file could not be exported")
        await wait("failed") { store.incoming.items.first { $0.name == "Broken" }?.state != .receiving }
        // The file is taken, then the item is cancelled before the result reaches the main actor.
        racing.deliver()
        let racingID = try XCTUnwrap(store.incoming.items.first { $0.name == "Racing" }?.id)
        store.incoming.cancel(racingID)
        await wait("settled") { !store.incoming.isReceiving }
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        let media = try XCTUnwrap(store.mediaFolder.folder)
        XCTAssertEqual(files(in: media), [ImportedMediaFolder.markerName], "the file taken after the cancel is deleted")
        XCTAssertTrue(store.assets.isEmpty)
        XCTAssertEqual(store.statusMessage?.contains("“Broken” could not be received"), true)
    }

    func testASourceCompletingAfterCancelIsIgnoredAndItsFilesDeleted() async throws {
        _ = try saveProject()
        let rogue = ScriptedPromise(name: "Rogue")
        rogue.completesAfterCancel = true
        XCTAssertTrue(store.incoming.receive([rogue]))
        store.incoming.cancelAll()
        try rogue.deliver([fixture.movieURL])
        let delivered = try XCTUnwrap(rogue.directory).appendingPathComponent(fixture.movieURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivered.path))
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertTrue(store.assets.isEmpty)
    }

    // MARK: Quitting, New and Open while media arrives

    func testQuitNewAndOpenAskWhileMediaIsArriving() async throws {
        let project = try saveProject()
        let documents = DocumentController(store: store,
                                           defaults: try XCTUnwrap(UserDefaults(suiteName: "docs-\(UUID())")))
        var alerts: [String] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn // Keep Waiting
        documents.runAlert = { alert in
            alerts.append(alert.messageText + " " + alert.informativeText)
            return answer
        }
        let arrived = ScriptedPromise(name: "Arrived")
        let pending = ScriptedPromise(name: "Pending")
        XCTAssertTrue(store.incoming.receive([arrived, pending]))
        try arrived.deliver([fixture.movieURL])
        let received = try XCTUnwrap(arrived.directory).appendingPathComponent(fixture.movieURL.lastPathComponent)
        XCTAssertFalse(store.isDirty, "a saved project: only the arriving media asks")

        XCTAssertFalse(documents.shouldTerminate(), "Keep Waiting keeps the app")
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].contains("Media from Photos is still arriving."))
        XCTAssertTrue(alerts[0].contains("Quitting stops receiving the item still arriving"), alerts[0])
        XCTAssertFalse(pending.cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.path))
        documents.newProject()
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(alerts[1].contains("Starting a new project stops receiving"))
        XCTAssertEqual(store.projectURL, project, "New was cancelled")
        XCTAssertFalse(documents.confirmClosingWindow())
        XCTAssertTrue(alerts[2].contains("Closing the window stops receiving"))
        documents.openRecent(project)
        XCTAssertTrue(alerts[3].contains("Opening another project stops receiving"))

        answer = .alertFirstButtonReturn // Stop
        XCTAssertTrue(documents.shouldTerminate())
        XCTAssertTrue(pending.cancelled)
        XCTAssertFalse(store.incoming.isReceiving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path), "what arrived is not left behind")
        XCTAssertEqual(alerts.count, 5, "no unsaved-changes question for a saved project")
    }
}
