import AppKit
import Foundation
import UniformTypeIdentifiers
import FramewrightEngine

extension UTType {
    /// AppKit's file promise types (`NSFilePromiseReceiver.readableDraggedTypes`): what Photos, Mail
    /// and other apps put on a drag pasteboard instead of file URLs. Declared as imported types in
    /// Info.plist.
    static let filePromiseItemMetadata = UTType(importedAs: "com.apple.NSFilePromiseItemMetaData")
    /// `kPasteboardTypeFileURLPromise`.
    static let filePromiseURL = UTType(importedAs: "com.apple.pasteboard.promised-file-url")
    /// Photos' Live Photo bundle (a folder with the still and the movie), offered by PHPicker.
    static let livePhotoBundle = UTType(importedAs: "com.apple.live-photo-bundle")

    /// The file promise types drop targets accept alongside file URLs: every type AppKit's promise
    /// receiver reads from a drag pasteboard (`NSFilePromiseReceiver.readableDraggedTypes`: the
    /// promise metadata, the promised content type and the legacy promise type) and the promised
    /// file URL.
    static let filePromiseTypes: [UTType] = {
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { UTType($0) ?? UTType(importedAs: $0) }
        for required in [UTType.filePromiseItemMetadata, .filePromiseURL] where !types.contains(required) {
            types.append(required)
        }
        return types
    }()
}

/// A file another process promised to deliver (a Photos drag, a PHPicker result): delivered into a
/// directory of our choosing, possibly after a long wait (an iCloud item downloads first), and
/// cancellable meanwhile.
@MainActor
protocol PromisedFile: AnyObject {
    /// What to call it while it arrives.
    var displayName: String { get }
    /// Called on the main actor with the fraction received (0...1) when the source reports it.
    var onProgress: ((Double) -> Void)? { get set }
    /// Starts delivering into `directory`. `completion` runs once on the main actor with the files
    /// that arrived (a promise may deliver more than one, e.g. a Live Photo's still and movie), or
    /// the error; never after `cancel()`.
    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void)
    /// Stops waiting; a file that still arrives is deleted.
    func cancel()
}

/// File operations shared by the promises.
enum ReceivedFiles {
    /// A name in `directory` that is not taken: `name`, else "stem 2.ext", "stem 3.ext", ...
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let numbered = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let url = directory.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    /// Moves (or, when that fails, copies) `source` into `directory` under `name` (or the source's
    /// own name), keeping the source's extension. Returns where it went.
    static func adopt(_ source: URL, into directory: URL, name: String?) throws -> URL {
        var fileName = source.lastPathComponent
        if let name, !name.isEmpty {
            let ext = source.pathExtension
            fileName = ext.isEmpty || (name as NSString).pathExtension.lowercased() == ext.lowercased()
                ? name : "\(name).\(ext)"
        }
        let destination = uniqueURL(in: directory, name: fileName)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A promise carried by an `NSItemProvider` (SwiftUI drops, PHPicker results): the provider's file
/// representation of its media type is loaded (the system fulfils a file promise, downloading an
/// iCloud original first) and moved into the destination. Cancelling cancels the load's Progress.
@MainActor
final class ItemProviderPromise: PromisedFile {
    let provider: NSItemProvider
    let typeIdentifier: String
    var onProgress: ((Double) -> Void)?
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    /// The media type to load, in order of preference: a Live Photo bundle (so the user can choose
    /// its movie or its still), a movie, an image (HEIC before JPEG: the original), audio. Nil when
    /// the provider offers no media.
    static func mediaTypeIdentifier(of provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers
        if registered.contains(UTType.livePhotoBundle.identifier) {
            return UTType.livePhotoBundle.identifier
        }
        let types = registered.compactMap { UTType($0) }
        let order: [(UTType) -> Bool] = [
            { $0.conforms(to: .movie) },
            { $0.conforms(to: .heic) || $0.conforms(to: .heif) },
            { $0.conforms(to: .image) },
            { $0.conforms(to: .audio) },
            { $0.conforms(to: .audiovisualContent) },
        ]
        for matches in order {
            if let type = types.first(where: matches) { return type.identifier }
        }
        return nil
    }

    init?(provider: NSItemProvider) {
        guard let type = Self.mediaTypeIdentifier(of: provider) else { return nil }
        self.provider = provider
        typeIdentifier = type
    }

    var displayName: String {
        if let name = provider.suggestedName, !name.isEmpty { return name }
        return UTType(typeIdentifier)?.localizedDescription ?? "Media"
    }

    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let name = provider.suggestedName
        let loading = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            // The file only exists until this handler returns: take it now (off the main thread).
            let result: Result<[URL], Error>
            if let url {
                do {
                    result = .success([try ReceivedFiles.adopt(url, into: directory, name: name)])
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(error ?? CocoaError(.fileReadUnknown))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled else {
                        if case let .success(urls) = result { ReceivedFiles.remove(urls) }
                        return
                    }
                    self.observation = nil
                    completion(result)
                }
            }
        }
        progress = loading
        observation = loading.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled else { return }
                    self.onProgress?(fraction)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        observation = nil
        progress?.cancel()
    }
}

/// A promise read from a drag pasteboard as an `NSFilePromiseReceiver` (AppKit's file promise
/// API): the promising app writes its files into the destination on a background queue, one
/// reader call per file. There is no progress; cancelling ignores (and deletes) what arrives later.
@MainActor
final class PasteboardFilePromise: PromisedFile {
    let receiver: NSFilePromiseReceiver
    var onProgress: ((Double) -> Void)?
    private var cancelled = false
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Framewright file promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(receiver: NSFilePromiseReceiver) {
        self.receiver = receiver
    }

    /// The receivers of the current drag (`NSPasteboard(name: .drag)`), read while a drop is
    /// performed.
    static func fromDragPasteboard() -> [PasteboardFilePromise] {
        let receivers = NSPasteboard(name: .drag).readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return (receivers as? [NSFilePromiseReceiver] ?? []).map(PasteboardFilePromise.init)
    }

    var displayName: String {
        receiver.fileTypes.first.flatMap { UTType($0)?.localizedDescription } ?? "Promised file"
    }

    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let expected = max(1, receiver.fileTypes.count)
        var arrived: [URL] = []
        var failure: Error?
        var calls = 0
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [weak self] url, error in
            // On `queue`, one call per promised file.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    calls += 1
                    if let error {
                        failure = error
                    } else {
                        arrived.append(url)
                    }
                    guard calls == expected else { return }
                    guard let self, !self.cancelled else {
                        ReceivedFiles.remove(arrived)
                        return
                    }
                    self.onProgress?(1)
                    if arrived.isEmpty {
                        completion(.failure(failure ?? CocoaError(.fileReadUnknown)))
                    } else {
                        completion(.success(arrived))
                    }
                }
            }
        }
    }

    func cancel() {
        cancelled = true
    }
}

/// Live Photos: a still and a short movie that belong together, delivered together by one promise
/// (Photos names them alike: IMG_1234.HEIC and IMG_1234.MOV; PHPicker hands a bundle folder holding
/// both). Files of different promises are never paired, however alike their names (camera names
/// wrap at IMG_9999, so two unrelated items can share one).
enum LivePhotos {
    enum Choice: String {
        case video
        case still
    }

    struct Pair: Equatable {
        let still: URL
        let movie: URL
    }

    /// UserDefaults key of the remembered choice ("video" or "still"; absent or empty: ask). Settings
    /// > Media > Live Photos shows and changes it (`LivePhotoImportSetting`).
    static let choiceKey = "livePhotoImport"

    /// The remembered choice in `defaults`, nil when the app asks.
    static func rememberedChoice(in defaults: UserDefaults) -> Choice? {
        defaults.string(forKey: choiceKey).flatMap(Choice.init(rawValue:))
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// The files of `urls` with folders replaced by the files they hold (a Live Photo bundle).
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles]) else {
                return [url]
            }
            return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// Splits `urls` into Live Photo pairs (one still and one movie with the same name, ignoring
    /// case and extension) and the other files, both in the order they first appear.
    static func pairs(in urls: [URL]) -> (pairs: [Pair], others: [URL]) {
        var groups: [String: [URL]] = [:]
        for url in urls {
            groups[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(url)
        }
        var pairs: [Pair] = []
        var others: [URL] = []
        var seen: Set<String> = []
        for url in urls {
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
            let group = groups[key] ?? []
            let stills = group.filter(isImage)
            let movies = group.filter(isMovie)
            if group.count == 2, stills.count == 1, movies.count == 1 {
                if seen.insert(key).inserted {
                    pairs.append(Pair(still: stills[0], movie: movies[0]))
                }
            } else {
                others.append(url)
            }
        }
        return (pairs, others)
    }

    /// The question for `count` Live Photos, with "Remember my choice"; it names the setting that
    /// changes a remembered choice later.
    @MainActor
    static func makeAlert(count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Import the Live Photo’s video or its still photo?"
            : "Import the \(count) Live Photos’ videos or their still photos?"
        alert.informativeText = "A Live Photo is a still photo with a short movie around it. A remembered choice can "
            + "be changed in Settings > Media > Live Photos."
        alert.addButton(withTitle: "Video")
        alert.addButton(withTitle: "Still Photo")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"
        return alert
    }

    /// The choice an answer to `makeAlert` means (nil: Cancel); with `remember` it is stored under
    /// `choiceKey`, which Settings > Media > Live Photos shows.
    static func choice(for response: NSApplication.ModalResponse, remember: Bool, defaults: UserDefaults) -> Choice? {
        let choice: Choice?
        switch response {
        case .alertFirstButtonReturn: choice = .video
        case .alertSecondButtonReturn: choice = .still
        default: choice = nil
        }
        if let choice, remember {
            LivePhotoImportSetting(choice).store(in: defaults)
        }
        return choice
    }

    /// Asks which part of the Live Photos to import. Nil when cancelled.
    @MainActor
    static func ask(count: Int, defaults: UserDefaults) -> Choice? {
        let alert = makeAlert(count: count)
        let response = alert.runModal()
        return choice(for: response, remember: alert.suppressionButton?.state == .on, defaults: defaults)
    }
}

/// Settings > Media > Live Photos: ask each time, or import the video or the still photo without
/// asking (the choice "Remember my choice" stores). Stored under `LivePhotos.choiceKey`; the raw
/// values are what the Settings picker binds to.
enum LivePhotoImportSetting: String, CaseIterable, Identifiable {
    case ask = ""
    case video
    case still

    init(_ choice: LivePhotos.Choice?) {
        switch choice {
        case .video: self = .video
        case .still: self = .still
        case nil: self = .ask
        }
    }

    init(defaults: UserDefaults) {
        self.init(LivePhotos.rememberedChoice(in: defaults))
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .video: return "Import the video"
        case .still: return "Import the still photo"
        }
    }

    /// The part to import without asking (nil: ask).
    var choice: LivePhotos.Choice? { LivePhotos.Choice(rawValue: rawValue) }

    func store(in defaults: UserDefaults) {
        if self == .ask {
            defaults.removeObject(forKey: LivePhotos.choiceKey)
        } else {
            defaults.set(rawValue, forKey: LivePhotos.choiceKey)
        }
    }
}

/// Where the media received from Photos goes: a "Media" folder next to the project file (created
/// when the app may write there), else a folder the user picks once (always for an untitled
/// project). The choice is kept for the session and stored in the project
/// (`VEEngine.mediaFolderBookmark`, saved with it); New/Open forget it (`reset()`).
@MainActor
final class ImportedMediaFolder {
    static let folderName = "Media"

    /// Asks for a folder (`suggested` to start in, `message` to explain); nil when cancelled.
    /// Tests replace it.
    var chooseFolder: (_ suggested: URL?, _ message: String) -> URL? = { suggested, message in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggested
        panel.prompt = "Keep Media Here"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The folder in use for this project (nil until first needed).
    private(set) var folder: URL?
    /// Times the user was asked (diagnostics and tests).
    private(set) var promptCount = 0
    private var accessing: URL?

    /// Forgets the folder (the project changed).
    func reset() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        folder = nil
    }

    /// The folder for `engine`'s project, asking when needed; nil when the user cancelled.
    func resolve(for engine: VEEngine) -> URL? {
        if let folder, Self.isWritableDirectory(folder) { return folder }
        if let data = engine.mediaFolderBookmark, let url = resolveBookmark(data) {
            folder = url
            return url
        }
        if let project = engine.projectURL {
            let candidate = project.deletingLastPathComponent().appendingPathComponent(Self.folderName, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)) != nil,
               Self.isWritableDirectory(candidate) {
                adopt(candidate, engine: engine)
                return candidate
            }
        }
        let message = engine.projectURL == nil
            ? "Choose where to keep media imported from Photos for this untitled project. The folder is saved with the project."
            : "Framewright cannot create a “\(Self.folderName)” folder next to “\(engine.projectName)”. "
                + "Choose where to keep media imported from Photos."
        promptCount += 1
        guard let chosen = chooseFolder(engine.projectURL?.deletingLastPathComponent(), message) else { return nil }
        if chosen.startAccessingSecurityScopedResource() {
            accessing?.stopAccessingSecurityScopedResource()
            accessing = chosen
        }
        guard Self.isWritableDirectory(chosen) else { return nil }
        adopt(chosen, engine: engine)
        return chosen
    }

    private func adopt(_ url: URL, engine: VEEngine) {
        folder = url
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                              relativeTo: nil))
            ?? (try? url.bookmarkData())
        if let bookmark, bookmark != engine.mediaFolderBookmark {
            engine.mediaFolderBookmark = bookmark
        }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                         bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        if url.startAccessingSecurityScopedResource() {
            accessing?.stopAccessingSecurityScopedResource()
            accessing = url
        }
        return Self.isWritableDirectory(url) ? url : nil
    }

    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }
}

/// Media arriving from Photos (drops of file promises and "Import from Photos…"): each dropped or
/// picked batch is received into the project's Media folder (`ImportedMediaFolder`), shown in the
/// media bin while it arrives (with progress where the source reports it, and Cancel), then
/// imported through the normal import path (`ProjectStore.importMedia`) once every item of the
/// batch has arrived, failed or been cancelled. Live Photos (a still and its movie) are imported
/// as the part the user chooses (asked once per batch unless a choice was remembered). A batch
/// dropped on the timeline is placed where it was dropped, the items one after another in drop
/// order. Nothing here blocks: an iCloud item that downloads for minutes just stays "receiving".
@MainActor
final class IncomingMedia: ObservableObject {
    enum State: Equatable {
        case receiving
        case received
        case failed(String)
        case cancelled

        var isSettled: Bool { self != .receiving }
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let batchID: UUID
        let name: String
        var fraction: Double?
        var state: State
    }

    /// Where a batch dropped on the timeline goes.
    struct Placement: Equatable {
        let trackID: VETrackID
        let seconds: Double
        let insert: Bool
    }

    private final class Batch {
        let id = UUID()
        let placement: Placement?
        var order: [UUID] = []
        var promises: [UUID: PromisedFile] = [:]
        var files: [UUID: [URL]] = [:]

        init(placement: Placement?) {
            self.placement = placement
        }
    }

    /// Everything still arriving or waiting for its batch, in arrival order (the bin lists them).
    @Published private(set) var items: [Item] = []
    /// Asks which part of Live Photos to import (count of pairs); nil cancels them. Tests replace it.
    var askLivePhoto: (_ count: Int, _ defaults: UserDefaults) -> LivePhotos.Choice? = { count, defaults in
        LivePhotos.ask(count: count, defaults: defaults)
    }
    /// Batches completed (diagnostics and tests).
    private(set) var completedBatches = 0

    private unowned let store: ProjectStore
    private var batches: [UUID: Batch] = [:]

    init(store: ProjectStore) {
        self.store = store
    }

    var isReceiving: Bool { !items.isEmpty }

    /// Starts receiving `promises` as one batch. Returns false (receiving nothing) when there is
    /// nothing to receive or no folder to receive into (the user cancelled the folder question).
    @discardableResult
    func receive(_ promises: [PromisedFile], placement: Placement? = nil) -> Bool {
        guard !promises.isEmpty else { return false }
        guard let folder = store.mediaFolder.resolve(for: store.engine) else {
            store.statusMessage = "Nothing was imported: no folder was chosen for the media."
            return false
        }
        let batch = Batch(placement: placement)
        batches[batch.id] = batch
        for promise in promises {
            let id = UUID()
            batch.order.append(id)
            batch.promises[id] = promise
            items.append(Item(id: id, batchID: batch.id, name: promise.displayName, fraction: nil, state: .receiving))
            promise.onProgress = { [weak self] fraction in self?.update(id) { $0.fraction = fraction } }
        }
        for id in batch.order {
            batch.promises[id]?.receive(into: folder) { [weak self] result in
                self?.finished(id, in: batch.id, result: result)
            }
        }
        return true
    }

    /// Stops waiting for one item (the rest of its batch goes on).
    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == .receiving,
              let batch = batches[item.batchID] else { return }
        batch.promises[id]?.cancel()
        update(id) { $0.state = .cancelled }
        completeIfSettled(batch)
    }

    /// Stops waiting for everything still arriving.
    func cancelAll() {
        for item in items where item.state == .receiving {
            cancel(item.id)
        }
    }

    /// Drops every batch without importing anything (the project is being replaced): what is
    /// still arriving is cancelled and what arrived is deleted from the Media folder.
    func discardAll() {
        for batch in batches.values {
            for (id, promise) in batch.promises where items.first(where: { $0.id == id })?.state == .receiving {
                promise.cancel()
            }
            ReceivedFiles.remove(batch.files.values.flatMap { $0 })
        }
        batches.removeAll()
        items.removeAll()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func finished(_ id: UUID, in batchID: UUID, result: Result<[URL], Error>) {
        guard let batch = batches[batchID], let item = items.first(where: { $0.id == id }),
              item.state == .receiving else { return }
        switch result {
        case let .success(urls):
            batch.files[id] = urls
            update(id) {
                $0.state = .received
                $0.fraction = 1
            }
        case let .failure(error):
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
        completeIfSettled(batch)
    }

    private func completeIfSettled(_ batch: Batch) {
        let states = items.filter { $0.batchID == batch.id }
        guard states.allSatisfy({ $0.state.isSettled }) else { return }
        let failures = states.compactMap { item -> String? in
            if case let .failed(reason) = item.state { return "“\(item.name)” could not be received: \(reason)" }
            return nil
        }
        items.removeAll { $0.batchID == batch.id }
        batches[batch.id] = nil
        completedBatches += 1
        // Live Photos pair only within what one promise delivered (one receiver's files, or a
        // PHPicker bundle): never across the items of a batch.
        let deliveries = batch.order.map { LivePhotos.expand(batch.files[$0] ?? []) }
        let files = choosingLivePhotoParts(deliveries)
        if !failures.isEmpty {
            store.statusMessage = failures.joined(separator: "\n")
        }
        guard !files.isEmpty else { return }
        let placement = batch.placement
        let store = self.store
        store.importMedia(files) { imported in
            guard let placement else { return }
            store.place(imported: imported, from: files, at: placement)
        }
    }

    /// The files to import: each delivery's Live Photo pair (a still and a movie that one promise
    /// delivered together) reduced to the chosen part (the other one, our own copy, is deleted), in
    /// order. The remembered choice (Settings > Media > Live Photos) applies to those pairs only.
    private func choosingLivePhotoParts(_ deliveries: [[URL]]) -> [URL] {
        let urls = deliveries.flatMap { $0 }
        let pairs = deliveries.flatMap { LivePhotos.pairs(in: $0).pairs }
        guard !pairs.isEmpty else { return urls }
        let choice = LivePhotos.rememberedChoice(in: store.defaults) ?? askLivePhoto(pairs.count, store.defaults)
        var dropped: Set<URL> = []
        for pair in pairs {
            switch choice {
            case .video: dropped.insert(pair.still)
            case .still: dropped.insert(pair.movie)
            case nil:
                dropped.insert(pair.still)
                dropped.insert(pair.movie)
            }
        }
        ReceivedFiles.remove(Array(dropped))
        return urls.filter { !dropped.contains($0) }
    }
}

/// Drops of media files: Finder file URLs and file promises (Photos), on the media bin and the
/// timeline. Works with any `TimelineDropInfo` (SwiftUI's `DropInfo`, or a test double).
@MainActor
enum MediaDrop {
    /// What the drop targets accept besides their own in-app types.
    static let types: [UTType] = [.fileURL] + UTType.filePromiseTypes

    static func accepts(_ info: some TimelineDropInfo) -> Bool {
        info.hasItemsConforming(to: types)
    }

    /// Imports the drop: files right away (through `ProjectStore.importMedia`, or placed on the
    /// timeline at `placement`), promises through `ProjectStore.incoming` into the Media folder
    /// (starting on the next main-queue turn).
    /// `pasteboardPromises` reads the drag pasteboard's `NSFilePromiseReceiver`s for a real drop;
    /// providers that carry promise types stand in when it has none (a test double, or a source
    /// the pasteboard does not describe). Returns whether anything is being imported.
    @discardableResult
    static func perform(_ info: some TimelineDropInfo, store: ProjectStore, placement: IncomingMedia.Placement?,
                        pasteboardPromises: () -> [PromisedFile] = { [] }) -> Bool {
        let fileProviders = info.itemProviders(for: [.fileURL])
        let promiseProviders = info.itemProviders(for: UTType.filePromiseTypes).filter { provider in
            !fileProviders.contains { $0 === provider }
        }
        var started = false
        if !fileProviders.isEmpty {
            loadFileURLs(fileProviders) { urls in
                guard !urls.isEmpty else { return }
                if let placement {
                    store.importAndPlace(urls, at: placement)
                } else {
                    store.importMedia(urls)
                }
            }
            started = true
        }
        if !promiseProviders.isEmpty {
            // The pasteboard's promises are read now, while the drop is performed; receiving them
            // (which may ask for the Media folder in a modal panel) starts on the next main-queue
            // turn, so the drag session completes first.
            var promises = pasteboardPromises()
            if promises.isEmpty {
                promises = promiseProviders.compactMap { ItemProviderPromise(provider: $0) }
                if promises.count < promiseProviders.count {
                    store.statusMessage = "Some dropped items are not media Framewright can import."
                }
            }
            if !promises.isEmpty {
                let incoming = store.incoming
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = incoming.receive(promises, placement: placement)
                    }
                }
                started = true
            }
        }
        return started
    }

    /// Loads the file URLs of `providers`, calling `completion` on the main actor with them in
    /// provider order (the ones that failed to load left out).
    static func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let url, url.isFileURL { urls[index] = url }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                completion(urls.compactMap { $0 })
            }
        }
    }
}
