import AppKit
import Foundation
import UniformTypeIdentifiers
import FramewrightEngine

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


/// Media arriving from Photos (drops of file promises and "Import from Photos…"): each dropped or
/// picked batch is received into the project's Media folder (`ImportedMediaFolder`), shown in the
/// media bin while it arrives (with progress where the source reports it, and Cancel), then
/// imported through the normal import path (`ProjectStore.importMedia`) once every item of the
/// batch has arrived, failed or been cancelled; a received file the import refuses is deleted from
/// the Media folder. Live Photos (a still and its movie delivered by one promise) are imported as
/// the part the user chooses (asked once per batch unless Settings > Media > Live Photos says
/// which). Questions wait while a drag or another gesture is in progress and never stack: batches
/// that settle meanwhile queue behind the one being asked about. A batch dropped on the timeline is
/// placed where it was dropped, the items one after another in drop order, unless the timeline
/// changed since the drop (then, like when a gesture is in progress, the media stays in the bin
/// with a message); a drop point that is no longer empty takes the media as an insert. Nothing here
/// blocks: an iCloud item that downloads for minutes just stays "receiving".
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
        var name: String
        var fraction: Double?
        var state: State
    }

    /// Where a batch dropped on the timeline goes.
    struct Placement: Equatable {
        let trackID: VETrackID
        let seconds: Double
        let insert: Bool
        /// The engine's `changeCount` when the drop was made (after the drop's own bookkeeping): a
        /// different count when the media arrives means the timeline changed meanwhile.
        var changeCount: UInt64 = 0
    }

    private final class Batch {
        let id = UUID()
        var placement: Placement?
        var order: [UUID] = []
        var promises: [UUID: PromisedFile] = [:]
        var files: [UUID: [URL]] = [:]

        init(placement: Placement?) {
            self.placement = placement
        }
    }

    /// A settled batch waiting for its Live Photo question and its import.
    private struct Settlement {
        /// Each promise's files (Live Photos pair only within one).
        let deliveries: [[URL]]
        let placement: Placement?

        var hasLivePhotos: Bool {
            deliveries.contains { !LivePhotos.pairs(in: $0).pairs.isEmpty }
        }
    }

    /// Everything still arriving or waiting for its batch, in arrival order (the bin lists them).
    @Published private(set) var items: [Item] = []
    /// Asks which part of Live Photos to import (count of pairs); nil cancels them. Tests replace it.
    var askLivePhoto: (_ count: Int, _ defaults: UserDefaults) -> LivePhotos.Choice? = { count, defaults in
        LivePhotos.ask(count: count, defaults: defaults)
    }
    /// How long a question waits before looking again whether the gesture in progress has ended.
    var questionRetryInterval: TimeInterval = 0.25
    /// Batches completed, and questions put off because a gesture was in progress (diagnostics and
    /// tests).
    private(set) var completedBatches = 0
    private(set) var deferredQuestions = 0

    private unowned let store: ProjectStore
    /// Bumped by `discardAll()`: late files of an earlier project's promises are deleted, not imported.
    private var generation = 0
    private var batches: [UUID: Batch] = [:]
    private var settlements: [Settlement] = []
    private var isAsking = false
    private var retryScheduled = false

    init(store: ProjectStore) {
        self.store = store
    }

    /// Whether anything is still arriving or waiting to be imported.
    var isReceiving: Bool { !items.isEmpty || !settlements.isEmpty }

    /// Items still arriving (not yet received, failed or cancelled).
    var arrivingCount: Int { items.filter { $0.state == .receiving }.count }

    /// Starts receiving `promises` as one batch. Returns false (receiving nothing) when there is
    /// nothing to receive or no folder to receive into (the user cancelled the folder question).
    @discardableResult
    func receive(_ promises: [PromisedFile], placement: Placement? = nil) -> Bool {
        guard !promises.isEmpty else { return false }
        guard let folder = store.mediaFolder.resolve(for: store.engine) else {
            store.statusMessage = "Nothing was imported: no folder was chosen for the media."
            return false
        }
        let scope = store.mediaFolder.lease
        var placement = placement
        // Choosing the folder may have been an unsaved change of the project: the timeline is as
        // dropped from here on.
        placement?.changeCount = store.engine.changeCount
        let batch = Batch(placement: placement)
        let batchID = batch.id
        batches[batchID] = batch
        for promise in promises {
            let id = UUID()
            batch.order.append(id)
            batch.promises[id] = promise
            items.append(Item(id: id, batchID: batchID, name: promise.displayName, fraction: nil, state: .receiving))
            promise.securityScope = scope
            promise.onProgress = { [weak self] fraction in self?.update(id) { $0.fraction = fraction } }
            promise.onRename = { [weak self] name in self?.update(id) { $0.name = name } }
            let generation = self.generation
            promise.onLateFiles = { [weak self] urls in
                guard let self, self.generation == generation else {
                    ReceivedFiles.remove(urls) // the project they were for is gone
                    return
                }
                self.importLate(urls)
            }
        }
        for id in batch.order {
            batch.promises[id]?.receive(into: folder) { [weak self] result in
                self?.finished(id, in: batchID, result: result)
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

    /// Drops every batch without importing anything (the project is being replaced, or the app
    /// quits): what is still arriving is cancelled (what arrives later is deleted) and what arrived
    /// is deleted from the Media folder, also the batches waiting for a question.
    func discardAll() {
        for batch in batches.values {
            for (id, promise) in batch.promises where items.first(where: { $0.id == id })?.state == .receiving {
                promise.cancel()
            }
            ReceivedFiles.remove(batch.files.values.flatMap { $0 })
        }
        for settlement in settlements {
            ReceivedFiles.remove(settlement.deliveries.flatMap { $0 })
        }
        batches.removeAll()
        items.removeAll()
        settlements.removeAll()
        generation += 1
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func finished(_ id: UUID, in batchID: UUID, result: Result<[URL], Error>) {
        guard let batch = batches[batchID], let item = items.first(where: { $0.id == id }),
              item.state == .receiving else {
            if case let .success(urls) = result { ReceivedFiles.remove(urls) } // no longer wanted
            return
        }
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
        if !failures.isEmpty {
            store.statusMessage = failures.joined(separator: "\n")
        }
        // Live Photos pair only within what one promise delivered (one receiver's files, or a
        // PHPicker bundle): never across the items of a batch.
        let deliveries = batch.order.map { LivePhotos.expand(batch.files[$0] ?? []) }.filter { !$0.isEmpty }
        guard !deliveries.isEmpty else { return }
        settlements.append(Settlement(deliveries: deliveries, placement: batch.placement))
        processSettlements()
    }

    /// Handles the settled batches in order, one question at a time: a batch that needs the Live
    /// Photo question waits while a gesture is in progress (the question would appear mid-drag),
    /// and batches settling while a question is up wait behind it.
    private func processSettlements() {
        guard !isAsking else { return }
        while let next = settlements.first {
            let asks = next.hasLivePhotos && LivePhotos.rememberedChoice(in: store.defaults) == nil
            if asks && store.isGestureActive {
                deferredQuestions += 1
                scheduleRetry()
                return
            }
            settlements.removeFirst()
            isAsking = asks
            let files = choosingLivePhotoParts(next.deliveries)
            isAsking = false
            importSettled(files, placement: next.placement)
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + questionRetryInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryScheduled = false
                self.processSettlements()
            }
        }
    }

    /// Imports a settled batch's files; a file the import refuses (not media after all) is deleted
    /// from the Media folder. A batch dropped on the timeline is then placed (`ProjectStore.place`),
    /// unless the timeline changed since the drop.
    private func importSettled(_ files: [URL], placement: Placement?) {
        guard !files.isEmpty else { return }
        let store = self.store
        let before = store.engine.changeCount
        let unchangedSinceDrop = placement.map { $0.changeCount == before } ?? true
        store.importMedia(files) { imported in
            let importedFiles = files.filter { file in imported.contains { ProjectStore.samePath($0.path, file.path) } }
            ReceivedFiles.remove(files.filter { !importedFiles.contains($0) })
            guard let placement else { return }
            // The import itself is one change (ImportAssets); anything else changed the timeline.
            let own: UInt64 = importedFiles.isEmpty ? 0 : 1
            let changed = !unchangedSinceDrop || store.engine.changeCount != before + own
            store.place(imported: imported, from: files, at: placement, timelineChanged: changed, emptyRangeOnly: true)
        }
    }

    /// Files a promise delivered beyond what it promised: imported into the bin.
    private func importLate(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        store.importMedia(urls) { imported in
            ReceivedFiles.remove(urls.filter { url in !imported.contains { ProjectStore.samePath($0.path, url.path) } })
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

/// What a real drop's drag pasteboard holds, partitioned once by pasteboard item: an item with a
/// file URL is a file (the Finder), an item that carries a file promise and no file URL is a promise
/// (Photos), in pasteboard order. Promises of anything but media (a Mail PDF) are left out and
/// counted.
struct DragContents {
    var fileURLs: [URL] = []
    var promises: [PasteboardFilePromise] = []
    var refusedPromises = 0

    /// Reads `pasteboard` (the drag pasteboard during a drop); nil when it holds no items.
    @MainActor
    static func read(from pasteboard: NSPasteboard) -> DragContents? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) })
        let descriptions = items.map { item -> ItemDescription in
            let types = Set(item.types)
            let url = item.string(forType: .fileURL).flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0 : nil }
            return ItemDescription(fileURL: url, carriesPromise: !types.isDisjoint(with: promiseTypes))
        }
        // One receiver per item that can be read as one, in item order.
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        return partition(descriptions, receivers: receivers)
    }

    struct ItemDescription {
        let fileURL: URL?
        let carriesPromise: Bool
    }

    /// The partition of `items` (the pasteboard's items, in order) with `receivers` (one per item
    /// that carries a promise, in the same order).
    @MainActor
    static func partition(_ items: [ItemDescription], receivers: [FilePromiseReceiving]) -> DragContents {
        var contents = DragContents()
        var receiverIndex = 0
        var promised: [FilePromiseReceiving] = []
        for item in items {
            var receiver: FilePromiseReceiving?
            if item.carriesPromise, receiverIndex < receivers.count {
                receiver = receivers[receiverIndex]
                receiverIndex += 1
            }
            if let url = item.fileURL {
                contents.fileURLs.append(url) // a file the Finder hands over, whatever else it carries
            } else if let receiver {
                if PasteboardFilePromise.promisesMedia(receiver) {
                    promised.append(receiver)
                } else {
                    contents.refusedPromises += 1
                }
            }
        }
        let session = PromiseDropSession()
        contents.promises = promised.enumerated().map { index, receiver in
            PasteboardFilePromise(receiver: receiver, session: session, index: index, count: promised.count)
        }
        return contents
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
    /// `dragContents` reads a real drop's drag pasteboard (`DragContents.read`), partitioned once by
    /// item; without it (a test double, or a pasteboard with no items) the item providers are
    /// partitioned instead, each once: a provider with a file URL is a file, one with only promise
    /// types a promise. Returns whether anything is being imported.
    @discardableResult
    static func perform(_ info: some TimelineDropInfo, store: ProjectStore, placement: IncomingMedia.Placement?,
                        dragContents: () -> DragContents? = { nil }) -> Bool {
        var fileURLs: [URL] = []
        var fileProviders: [NSItemProvider] = []
        var promises: [PromisedFile] = []
        var refused = 0
        if let contents = dragContents(), !contents.fileURLs.isEmpty || !contents.promises.isEmpty
            || contents.refusedPromises > 0 {
            fileURLs = contents.fileURLs
            promises = contents.promises
            refused = contents.refusedPromises
        } else {
            for provider in info.itemProviders(for: types) {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    fileProviders.append(provider)
                } else if let promise = ItemProviderPromise(provider: provider) {
                    promises.append(promise)
                } else {
                    refused += 1
                }
            }
        }
        if refused > 0 {
            store.statusMessage = "Some dropped items are not media Framewright can import."
        }
        var started = false
        if !fileURLs.isEmpty || !fileProviders.isEmpty {
            let place: @MainActor ([URL]) -> Void = { urls in
                guard !urls.isEmpty else { return }
                if let placement {
                    store.importAndPlace(urls, at: placement)
                } else {
                    store.importMedia(urls)
                }
            }
            if fileProviders.isEmpty {
                place(fileURLs)
            } else {
                loadFileURLs(fileProviders) { urls in place(fileURLs + urls) }
            }
            started = true
        }
        if !promises.isEmpty {
            // Receiving (which may ask for the Media folder in a modal panel) starts on the next
            // main-queue turn, so the drag session completes first.
            let incoming = store.incoming
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = incoming.receive(promises, placement: placement)
                }
            }
            started = true
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
