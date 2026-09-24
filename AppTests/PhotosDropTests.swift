import AppKit
import CoreMedia
import FramewrightEngine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

/// Photos drops and Import from Photos (feature request 9), driven with a fake promise provider:
/// an `NSItemProvider` that carries the file promise types and delivers its file when the test says
/// so (or never, like an iCloud original that is still downloading), through the same
/// `TimelineDropInfo` path SwiftUI's drops take. Covered: the declared types, validate/hover/drop on
/// the media bin and the timeline, the Media folder next to a saved project, the untitled project's
/// folder question (asked once, kept with the project), cancelling, Live Photos, Finder file drops
/// on the timeline, the picker's configuration and its results. The real drag from Photos and the
/// PHPicker panel itself are by hand (see open-findings).
@MainActor
final class PhotosDropTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    /// Folder the untitled project's question answers with, and how often it was asked.
    private var chosenFolder: URL!
    private var folderQuestions = 0

    override func setUp() async throws {
        fixture = try StoreFixture()
        store.defaults = try XCTUnwrap(UserDefaults(suiteName: "photos-\(UUID())"))
        chosenFolder = fixture.directory.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
        folderQuestions = 0
        store.mediaFolder.chooseFolder = { [unowned self] _, _ in
            folderQuestions += 1
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

    private func saveProject() throws -> URL {
        let url = fixture.directory.appendingPathComponent("Holiday.framewright")
        try store.save(to: url)
        return url
    }

    private func asset(at url: URL) -> VEAssetInfo? {
        store.assets.first { ProjectStore.samePath($0.path, url.path) }
    }

    private func wait(_ what: String, until condition: () -> Bool) async {
        let met = await StoreFixture.wait(until: condition, timeout: 10)
        XCTAssertTrue(met, "timed out waiting: \(what)")
    }

    // MARK: Types

    func testTheDropTargetsAcceptFilePromisesAndFileURLs() throws {
        for type in UTType.filePromiseTypes {
            XCTAssertTrue(TimelineDropDelegate.types.contains(type))
            XCTAssertTrue(MediaDrop.types.contains(type))
        }
        for type in [UTType.filePromiseItemMetadata, .filePromiseURL] {
            XCTAssertTrue(UTType.filePromiseTypes.contains(type))
            let declared = try XCTUnwrap(UTType(type.identifier))
            XCTAssertTrue(declared.isDeclared, "\(type.identifier) is declared in Info.plist")
            XCTAssertFalse(declared.isDynamic)
        }
        XCTAssertTrue(TimelineDropDelegate.types.contains(.fileURL))
        // Every type AppKit's promise receiver reads from a drag pasteboard is accepted.
        for identifier in NSFilePromiseReceiver.readableDraggedTypes {
            let type = UTType(identifier) ?? UTType(importedAs: identifier)
            XCTAssertTrue(MediaDrop.types.contains(type), "\(identifier) is accepted")
        }
        XCTAssertEqual(UTType.filePromiseURL.identifier, kPasteboardTypeFileURLPromise as String)
    }

    // MARK: Media bin

    func testAPromiseDroppedOnTheBinArrivesInTheMediaFolderNextToTheProject() async throws {
        let project = try saveProject()
        let fake = FakePromiseProvider(name: "IMG_0001", file: fixture.movieURL, type: .quickTimeMovie)
        let info = FakeDropInfo(location: .zero, providers: [fake.provider])
        var targeted = false
        let delegate = MediaBinDropDelegate(store: store, isTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        XCTAssertTrue(delegate.handleValidate(info))
        delegate.handleEntered(info)
        XCTAssertTrue(targeted, "the bin highlights while a promise hovers")
        delegate.handleExited(info)
        XCTAssertFalse(targeted)
        XCTAssertTrue(delegate.handlePerform(info), "the drop is accepted before the file exists")
        XCTAssertFalse(targeted)

        await wait("the item is listed") { store.incoming.items.count == 1 && fake.loadRequested }
        XCTAssertEqual(store.incoming.items.first?.name, "IMG_0001")
        XCTAssertEqual(store.incoming.items.first?.state, .receiving)
        XCTAssertTrue(store.assets.isEmpty, "nothing is imported before it arrives")

        fake.deliver()
        let expected = project.deletingLastPathComponent().appendingPathComponent("Media/IMG_0001.mov")
        await wait("the file is imported") { asset(at: expected) != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertTrue(store.incoming.items.isEmpty)
        XCTAssertEqual(folderQuestions, 0, "a saved project's Media folder is made without asking")
        XCTAssertTrue(ImportedMediaFolder.hasMarker(expected.deletingLastPathComponent()), "the app's own folder")
        XCTAssertNil(store.engine.mediaFolderBookmark,
                     "derived from where the project is, never stored (Save As and copies use their own)")
    }

    func testACancelledItemIsNotImportedAndTheRestOfItsBatchIs() async throws {
        _ = try saveProject()
        let arrives = FakePromiseProvider(name: "IMG_0001", file: fixture.movieURL, type: .quickTimeMovie)
        let downloading = FakePromiseProvider(name: "IMG_0002", file: fixture.movieURL, type: .quickTimeMovie)
        let delegate = MediaBinDropDelegate(store: store, isTargeted: .constant(false))
        XCTAssertTrue(delegate.handlePerform(FakeDropInfo(location: .zero,
                                                          providers: [arrives.provider, downloading.provider])))
        await wait("both are listed") { store.incoming.items.count == 2 && arrives.loadRequested }
        arrives.deliver()
        await wait("the first arrives") { store.incoming.items.first?.state == .received }
        XCTAssertTrue(store.assets.isEmpty, "a batch is imported when all of it has settled")

        // The second never arrives (an iCloud original still downloading): cancel it.
        let waiting = try XCTUnwrap(store.incoming.items.first { $0.name == "IMG_0002" })
        store.incoming.cancel(waiting.id)
        await wait("the load is cancelled") { downloading.cancelled }
        await wait("the rest is imported") { store.assets.count == 1 }
        XCTAssertTrue(store.assets[0].path.hasSuffix("Media/IMG_0001.mov"))
        XCTAssertTrue(store.incoming.items.isEmpty)
        // A delivery after the cancel changes nothing.
        downloading.deliver()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.assets.count, 1)
    }

    func testProgressFailuresAndCancelAll() async throws {
        _ = try saveProject()
        let slow = ScriptedPromise(name: "Big.mov")
        let broken = ScriptedPromise(name: "Broken.mov")
        let stuck = ScriptedPromise(name: "Stuck.mov")
        XCTAssertTrue(store.incoming.receive([slow, broken, stuck]))
        XCTAssertTrue(store.incoming.isReceiving)
        slow.progress(0.25)
        XCTAssertEqual(store.incoming.items.first?.fraction, 0.25)
        broken.fail("the download failed")
        XCTAssertEqual(store.incoming.items.first { $0.name == "Broken.mov" }?.state, .failed("the download failed"))
        try slow.deliver([fixture.movieURL])
        store.incoming.cancelAll()
        XCTAssertTrue(stuck.cancelled)
        XCTAssertFalse(store.incoming.isReceiving)
        XCTAssertEqual(store.statusMessage?.contains("“Broken.mov” could not be received"), true)
        await wait("the arrived one is imported") { store.assets.count == 1 }
        XCTAssertEqual(store.incoming.completedBatches, 1)
    }

    // MARK: Timeline and the untitled project's folder

    func testAPromiseDroppedOnTheTimelineIsPlacedWhereItWasDroppedOnceItArrives() async throws {
        // Untitled: the folder is asked for once.
        let fake = FakePromiseProvider(name: "IMG_0003", file: fixture.movieURL, type: .quickTimeMovie)
        let gestures = TimelineGestureController(store: store)
        let delegate = TimelineDropDelegate(gestures: gestures, isAssetTargeted: .constant(false),
                                            commandHeld: { false })
        // V1 is the second row (y 66...130); 100 pt is 2 s at the default zoom.
        let info = FakeDropInfo(location: CGPoint(x: 100, y: 90), providers: [fake.provider])
        XCTAssertTrue(delegate.handleValidate(info))
        XCTAssertEqual(delegate.handleUpdated(info)?.operation, .copy)
        XCTAssertTrue(delegate.handlePerform(info))
        await wait("the item is listed") { fake.loadRequested }
        XCTAssertEqual(folderQuestions, 1)
        XCTAssertTrue(store.clips.isEmpty, "placed only once the file is there")
        fake.deliver()
        await wait("the clip is placed") { !store.clips.isEmpty }
        let clip = try XCTUnwrap(store.clips.values.first)
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        XCTAssertEqual(clip.trackID, v1)
        XCTAssertEqual(clip.timelineStart.secondsOrZero, 2, accuracy: 1e-9)
        let expected = chosenFolder.appendingPathComponent("Media/IMG_0003.mov")
        XCTAssertNotNil(asset(at: expected), "received into a Media folder inside the chosen folder")
        XCTAssertTrue(ImportedMediaFolder.hasMarker(expected.deletingLastPathComponent()))

        // Asked once per project: a second drop uses the same folder.
        let second = FakePromiseProvider(name: "IMG_0004", file: fixture.movieURL, type: .quickTimeMovie)
        XCTAssertTrue(delegate.handlePerform(FakeDropInfo(location: CGPoint(x: 400, y: 90), providers: [second.provider])))
        await wait("the second item is listed") { second.loadRequested }
        XCTAssertEqual(folderQuestions, 1)
        second.deliver()
        await wait("the second clip is placed") { store.clips.count == 2 }

        // Saved with the project: reopening does not ask again.
        let url = try saveProject()
        store.newProject()
        XCTAssertNil(store.engine.mediaFolderBookmark)
        try store.open(url: url)
        let third = ScriptedPromise(name: "Third")
        XCTAssertTrue(store.incoming.receive([third]))
        XCTAssertEqual(folderQuestions, 1)
        XCTAssertEqual(third.directory?.resolvingSymlinksInPath().path,
                       chosenFolder.appendingPathComponent("Media").resolvingSymlinksInPath().path)
        store.incoming.cancelAll()
    }

    func testDeclinedFolderQuestionImportsNothing() {
        store.mediaFolder.chooseFolder = { _, _ in nil }
        let promise = ScriptedPromise(name: "IMG")
        XCTAssertFalse(store.incoming.receive([promise]))
        XCTAssertNil(promise.directory, "never asked to deliver")
        XCTAssertTrue(store.incoming.items.isEmpty)
        XCTAssertEqual(store.statusMessage?.contains("no folder was chosen"), true)
    }

    func testFinderFilesDroppedOnTheTimelineArePlacedInDropOrder() async throws {
        let copy = fixture.directory.appendingPathComponent("second.mov")
        try FileManager.default.copyItem(at: fixture.movieURL, to: copy)
        let gestures = TimelineGestureController(store: store)
        let delegate = TimelineDropDelegate(gestures: gestures, isAssetTargeted: .constant(false),
                                            commandHeld: { false })
        let info = FakeDropInfo(location: CGPoint(x: 50, y: 90), providers: [
            NSItemProvider(object: fixture.movieURL as NSURL), NSItemProvider(object: copy as NSURL),
        ])
        XCTAssertTrue(delegate.handleValidate(info))
        XCTAssertTrue(delegate.handlePerform(info))
        await wait("both clips are placed") { store.clips.count == 2 }
        let starts = store.clips.values.map(\.timelineStart.secondsOrZero).sorted()
        XCTAssertEqual(starts[0], 1, accuracy: 1e-9)
        XCTAssertEqual(starts[1], 3, accuracy: 1e-9, "the second follows the first (2 s long)")
        XCTAssertEqual(folderQuestions, 0, "files the Finder hands over need no Media folder")
    }

    // MARK: Live Photos

    func testLivePhotosImportThePartTheUserChooses() async throws {
        _ = try saveProject()
        let still = fixture.directory.appendingPathComponent("IMG_0005.HEIC")
        let movie = fixture.directory.appendingPathComponent("IMG_0005.MOV")
        try TestMediaFactory.writeHEIC(to: still)
        try FileManager.default.copyItem(at: fixture.movieURL, to: movie)
        var asked: [Int] = []
        store.incoming.askLivePhoto = { count, _ in
            asked.append(count)
            return .video
        }
        let livePhoto = ScriptedPromise(name: "IMG_0005")
        XCTAssertTrue(store.incoming.receive([livePhoto]))
        try livePhoto.deliver([still, movie])
        await wait("the movie is imported") { store.assets.count == 1 }
        XCTAssertEqual(asked, [1])
        XCTAssertTrue(store.assets[0].path.hasSuffix("IMG_0005.MOV"))
        let media = try XCTUnwrap(livePhoto.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent("IMG_0005.HEIC").path),
                       "the part not imported is not left behind")

        // A remembered choice (Settings > Media > Live Photos) is not asked again; here the still.
        LivePhotoImportSetting.still.store(in: store.defaults)
        let stillCopy = fixture.directory.appendingPathComponent("IMG_0006.heic")
        let movieCopy = fixture.directory.appendingPathComponent("IMG_0006.mov")
        try FileManager.default.copyItem(at: still, to: stillCopy)
        try FileManager.default.copyItem(at: movie, to: movieCopy)
        let pair = ScriptedPromise(name: "IMG_0006")
        XCTAssertTrue(store.incoming.receive([pair]))
        try pair.deliver([movieCopy, stillCopy])
        await wait("the still is imported") { store.assets.count == 2 }
        XCTAssertEqual(asked, [1])
        let imported = try XCTUnwrap(store.assets.first { $0.path.hasSuffix("IMG_0006.heic") })
        XCTAssertTrue(imported.isStill, "an HEIC imports as a still")
    }

    func testUnrelatedItemsWithOneNameAreNeverPairedNorDeleted() async throws {
        _ = try saveProject()
        // An old phone's IMG_0001.HEIC and a new phone's unrelated IMG_0001.MOV (camera names wrap at
        // 9999), dropped together while a Live Photo choice is remembered: two separate promises.
        LivePhotoImportSetting.video.store(in: store.defaults)
        let still = fixture.directory.appendingPathComponent("IMG_0001.HEIC")
        let movie = fixture.directory.appendingPathComponent("IMG_0001.MOV")
        try TestMediaFactory.writeHEIC(to: still)
        try FileManager.default.copyItem(at: fixture.movieURL, to: movie)
        let oldPhone = ScriptedPromise(name: "IMG_0001 (old phone)")
        let newPhone = ScriptedPromise(name: "IMG_0001 (new phone)")
        XCTAssertTrue(store.incoming.receive([oldPhone, newPhone]))
        try oldPhone.deliver([still])
        try newPhone.deliver([movie])
        await wait("both are imported") { store.assets.count == 2 }
        let media = try XCTUnwrap(oldPhone.directory)
        for name in ["IMG_0001.HEIC", "IMG_0001.MOV"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path),
                          "\(name) is kept: the remembered choice applies to one promise's pair only")
        }
        // The same through PHPicker: each pick is its own item.
        let stillAgain = fixture.directory.appendingPathComponent("IMG_0002.heic")
        let movieAgain = fixture.directory.appendingPathComponent("IMG_0002.mov")
        try FileManager.default.copyItem(at: still, to: stillAgain)
        try FileManager.default.copyItem(at: movie, to: movieAgain)
        let pickedStill = FakePromiseProvider(name: "IMG_0002", file: stillAgain, type: .heic)
        let pickedMovie = FakePromiseProvider(name: "IMG_0002", file: movieAgain, type: .quickTimeMovie)
        store.photosPicker.receivePicked([pickedStill.provider, pickedMovie.provider])
        await wait("both picks are requested") { pickedStill.loadRequested && pickedMovie.loadRequested }
        pickedStill.deliver()
        pickedMovie.deliver()
        await wait("both picks are imported") { store.assets.count == 4 }
    }

    func testTheLivePhotoSettingRoundTripsWithTheQuestionsRememberedChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "live-photo-setting-\(UUID())"))
        XCTAssertEqual(LivePhotoImportSetting(defaults: defaults), .ask, "asks by default")
        XCTAssertNil(LivePhotos.rememberedChoice(in: defaults))
        // "Remember my choice" in the question: Settings shows it.
        XCTAssertEqual(LivePhotos.choice(for: .alertSecondButtonReturn, remember: true, defaults: defaults), .still)
        XCTAssertEqual(LivePhotoImportSetting(defaults: defaults), .still)
        XCTAssertEqual(defaults.string(forKey: LivePhotos.choiceKey), LivePhotoImportSetting.still.rawValue,
                       "the key and value the Settings picker binds to")
        // Without Remember nothing is stored; Cancel stores nothing.
        XCTAssertEqual(LivePhotos.choice(for: .alertFirstButtonReturn, remember: false, defaults: defaults), .video)
        XCTAssertNil(LivePhotos.choice(for: .alertThirdButtonReturn, remember: true, defaults: defaults))
        XCTAssertEqual(LivePhotoImportSetting(defaults: defaults), .still)
        // Settings back to Ask: the question comes back.
        LivePhotoImportSetting.ask.store(in: defaults)
        XCTAssertNil(defaults.object(forKey: LivePhotos.choiceKey))
        XCTAssertNil(LivePhotos.rememberedChoice(in: defaults))
        LivePhotoImportSetting.video.store(in: defaults)
        XCTAssertEqual(LivePhotos.rememberedChoice(in: defaults), .video)
        // What an empty value (the picker's Ask tag) means.
        defaults.set(LivePhotoImportSetting.ask.rawValue, forKey: LivePhotos.choiceKey)
        XCTAssertEqual(LivePhotoImportSetting(defaults: defaults), .ask)
        XCTAssertEqual(LivePhotoImportSetting.allCases.map(\.title),
                       ["Ask each time", "Import the video", "Import the still photo"])
        // The question names the setting.
        let alert = LivePhotos.makeAlert(count: 2)
        XCTAssertTrue(alert.informativeText.contains("Settings > Media > Live Photos"))
        XCTAssertTrue(alert.showsSuppressionButton)
    }

    func testLivePhotoPairingAndBundles() throws {
        let urls = ["a/IMG_1.HEIC", "a/IMG_1.MOV", "a/IMG_2.jpg", "a/clip.mov", "a/IMG_3.heic", "a/IMG_3.png"]
            .map { URL(fileURLWithPath: "/tmp/" + $0) }
        let (pairs, others) = LivePhotos.pairs(in: urls)
        XCTAssertEqual(pairs, [LivePhotos.Pair(still: urls[0], movie: urls[1])])
        XCTAssertEqual(others, [urls[2], urls[3], urls[4], urls[5]], "two stills with one name are no Live Photo")

        // A Live Photo bundle (PHPicker) is a folder with both parts.
        let bundle = fixture.directory.appendingPathComponent("IMG_7.pvt", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try TestMediaFactory.writeHEIC(to: bundle.appendingPathComponent("IMG_7.HEIC"))
        try FileManager.default.copyItem(at: fixture.movieURL, to: bundle.appendingPathComponent("IMG_7.MOV"))
        let expanded = LivePhotos.expand([bundle, fixture.movieURL])
        XCTAssertEqual(expanded.map(\.lastPathComponent), ["IMG_7.HEIC", "IMG_7.MOV", "clip.mov"])
        XCTAssertEqual(LivePhotos.pairs(in: expanded).pairs.count, 1)
    }

    // MARK: Import from Photos

    func testThePickerConfigurationAndItsResults() async throws {
        let configuration = PhotosImportPicker.configuration()
        XCTAssertEqual(configuration.selectionLimit, 0, "any number of items")
        XCTAssertEqual(configuration.preferredAssetRepresentationMode, .current, "HEIC and HEVC as they are")

        _ = try saveProject()
        let picked = FakePromiseProvider(name: "IMG_0008", file: fixture.movieURL, type: .quickTimeMovie)
        let unsupported = NSItemProvider(item: "text" as NSString, typeIdentifier: UTType.plainText.identifier)
        store.photosPicker.receivePicked([picked.provider, unsupported])
        XCTAssertEqual(store.statusMessage?.contains("not media"), true)
        await wait("the pick is listed") { picked.loadRequested }
        XCTAssertEqual(store.incoming.items.map(\.name), ["IMG_0008"])
        picked.deliver()
        await wait("imported") { store.assets.count == 1 }
        XCTAssertTrue(store.assets[0].path.hasSuffix("Media/IMG_0008.mov"))
        // A cancelled picker picks nothing.
        store.photosPicker.receivePicked([])
        XCTAssertTrue(store.incoming.items.isEmpty)
    }

    func testReplacingTheProjectDiscardsWhatIsStillArriving() async throws {
        _ = try saveProject()
        let arrived = ScriptedPromise(name: "Arrived")
        let pending = ScriptedPromise(name: "Pending")
        XCTAssertTrue(store.incoming.receive([arrived, pending]))
        try arrived.deliver([fixture.movieURL])
        let received = try XCTUnwrap(arrived.directory).appendingPathComponent(fixture.movieURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.path))
        store.newProject()
        XCTAssertTrue(pending.cancelled)
        XCTAssertTrue(store.incoming.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path), "never imported, so not kept")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.assets.isEmpty, "nothing reaches the new project")
    }
}
