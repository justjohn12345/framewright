import AppKit
import Foundation
import UniformTypeIdentifiers
import FramewrightEngine

extension UTType {
    /// AppKit's file promise types (`NSFilePromiseReceiver.readableDraggedTypes`): what Photos, Mail
    /// and other apps put on a drag pasteboard instead of file URLs.
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

    /// Whether files of this type can be media Framewright imports: images, audio or video, and
    /// Live Photo bundles. Promises of anything else (a Mail PDF, a Numbers file) are not received.
    var isImportableMedia: Bool {
        conforms(to: .image) || conforms(to: .audiovisualContent) || conforms(to: .livePhotoBundle)
    }
}

/// Sandbox access to a folder for as long as something holds it: the Media folder's security scope,
/// held by the folder while the project is open and by every promise still receiving into it, so a
/// file arriving after New or Open can still be deleted there. Deinitialising stops the access (on
/// any thread).
final class SecurityScopeLease: @unchecked Sendable {
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
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
    /// Called on the main actor with a better name once one is known (a promised file's own name).
    var onRename: ((String) -> Void)? { get set }
    /// Called on the main actor with files that arrived after `receive`'s completion (a legacy
    /// promiser that writes more files than it listed): they are in the destination and belong to
    /// the receiver of this call.
    var onLateFiles: (([URL]) -> Void)? { get set }
    /// Kept alive while the source may still deliver (the destination's security scope).
    var securityScope: SecurityScopeLease? { get set }
    /// Starts delivering into `directory`. `completion` runs once on the main actor with the files
    /// that arrived (a promise may deliver more than one, e.g. a Live Photo's still and movie), or
    /// the error; never after `cancel()`.
    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void)
    /// Stops waiting: what already arrived and was not handed over is deleted at once, and a file
    /// that still arrives is deleted when it does.
    func cancel()
}

extension PromisedFile {
    // Promises that never rename, deliver late or hold a scope need not store these.
    var onRename: ((String) -> Void)? {
        get { nil }
        set {}
    }

    var onLateFiles: (([URL]) -> Void)? {
        get { nil }
        set {}
    }

    var securityScope: SecurityScopeLease? {
        get { nil }
        set {}
    }
}

/// File operations shared by the promises. `adopt` is safe to call from several threads at once:
/// choosing a free name and moving the file there happen under one lock, and a name another process
/// takes meanwhile is retried with the next number.
enum ReceivedFiles {
    private static let lock = NSLock()

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

    /// `name` usable as one file name in a folder: path separators and colons replaced, leading
    /// dots and spaces dropped (no hidden files, no "." or ".."); nil when nothing is left.
    static func sanitizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        while let first = cleaned.first, first == "." || first.isWhitespace {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name needs a letter or a digit ("-" left of " / " names nothing).
        return cleaned.contains { $0.isLetter || $0.isNumber } ? cleaned : nil
    }

    /// Moves (or, when that fails, copies) `source` into `directory` under `name` (sanitized; or the
    /// source's own name), keeping the source's extension, never replacing a file there. Returns
    /// where it went.
    static func adopt(_ source: URL, into directory: URL, name: String?) throws -> URL {
        var fileName = sanitizedName(source.lastPathComponent) ?? "Media"
        if let name = sanitizedName(name) {
            let ext = source.pathExtension
            fileName = ext.isEmpty || (name as NSString).pathExtension.lowercased() == ext.lowercased()
                ? name : "\(name).\(ext)"
        }
        lock.lock()
        defer { lock.unlock() }
        var lastError: Error?
        for _ in 0 ..< 8 {
            let destination = uniqueURL(in: directory, name: fileName)
            do {
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    throw error // taken meanwhile by another process: the next number
                } catch {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    /// The media files a delivered item holds: the file itself, or, for a folder (a PHPicker Live
    /// Photo bundle), each file inside it moved into `directory` on its own (the bundle is not
    /// kept: the parts are listed and imported like any other file, and the part not chosen is
    /// deleted without leaving an empty bundle behind).
    static func adoptItem(_ source: URL, into directory: URL, name: String?) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [try adopt(source, into: directory, name: name)]
        }
        let contents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var adopted: [URL] = []
        do {
            for file in contents {
                // Each part keeps its own name ("IMG_1234.HEIC", "IMG_1234.MOV"), unique in the folder.
                adopted.append(try adopt(file, into: directory, name: nil))
            }
        } catch {
            remove(adopted)
            throw error
        }
        return adopted
    }

    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A promise carried by an `NSItemProvider` (SwiftUI drops, PHPicker results): the provider's file
/// representation of its media type is loaded (the system fulfils a file promise, downloading an
/// iCloud original first) and moved into the destination (a Live Photo bundle's parts each on their
/// own). Cancelling cancels the load's Progress; a file taken after the cancel is deleted.
@MainActor
final class ItemProviderPromise: PromisedFile {
    let provider: NSItemProvider
    let typeIdentifier: String
    var onProgress: ((Double) -> Void)?
    var securityScope: SecurityScopeLease?
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
        if let name = ReceivedFiles.sanitizedName(provider.suggestedName) { return name }
        return UTType(typeIdentifier)?.localizedDescription ?? "Media"
    }

    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let name = provider.suggestedName
        let scope = securityScope
        let loading = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            // The file only exists until this handler returns: take it now (off the main thread).
            let result: Result<[URL], Error>
            if let url {
                do {
                    result = .success(try ReceivedFiles.adoptItem(url, into: directory, name: name))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(error ?? CocoaError(.fileReadUnknown))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    withExtendedLifetime(scope) {
                        guard let self, !self.cancelled else {
                            // Cancelled between taking the file and this hop (or dropped): delete it.
                            if case let .success(urls) = result { ReceivedFiles.remove(urls) }
                            return
                        }
                        self.observation = nil
                        completion(result)
                    }
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

/// What `PasteboardFilePromise` needs of AppKit's `NSFilePromiseReceiver` (tests use a double of
/// its contract).
protocol FilePromiseReceiving: AnyObject {
    /// The promised files' types; their count "should" be the number of files, but a legacy
    /// promiser may list a type once and write several files of it.
    var fileTypes: [String] { get }
    /// The promised files' names, empty until the promise is called in.
    var fileNames: [String] { get }
    /// Calls the promise in: `reader` runs on `operationQueue` once per file written (with an error
    /// when writing failed or was cancelled). Every receiver of one drag must use one destination.
    func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                              operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void)
}

extension NSFilePromiseReceiver: FilePromiseReceiving {}

/// The promises of one drop: AppKit requires every receiver of a drag to deliver into the same
/// folder, so they share a private staging folder inside the destination (hidden, named per drop).
/// Each file is moved out of it into the destination as soon as it arrives; the staging folder is
/// deleted when every delivery of the drop has settled or stopped.
final class PromiseDropSession: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var staging: URL?
    private var outstanding = 0

    /// The staging folder inside `directory` (created on first use).
    func stagingFolder(in directory: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let staging { return staging }
        let folder = directory.appendingPathComponent(".framewright-incoming-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        staging = folder
        return folder
    }

    func deliveryStarted() {
        lock.lock()
        outstanding += 1
        lock.unlock()
    }

    /// A delivery settled or stopped: the staging folder goes when none is left.
    func deliveryEnded() {
        lock.lock()
        outstanding -= 1
        let idle = outstanding <= 0
        let folder = staging
        lock.unlock()
        if idle, let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A file arrived for a stopped delivery: it is deleted, and the staging folder with it when
    /// nothing else is receiving there.
    func discardLate(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        let idle = outstanding <= 0
        let folder = staging
        lock.unlock()
        if idle, let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Whether the staging folder exists (tests).
    var stagingExists: Bool {
        lock.lock()
        defer { lock.unlock() }
        return staging.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

/// One pasteboard promise's delivery, shared by AppKit's reader calls (on the promise queue) and the
/// main actor. Each reader call settles on its own as it arrives: its file is moved out of the
/// drop's staging folder into the destination under a unique name at once (so two promised files
/// with one name never collide, whatever the promiser does on a collision), or deleted when the
/// delivery was stopped (cancelled, or its promise went away with its project). The delivery
/// completes when as many calls as promised files arrived; a call after that is a late file.
/// Holds the destination's security scope for as long as AppKit may still call.
final class FilePromiseDelivery: @unchecked Sendable {
    enum Event {
        /// A file arrived (its place in the destination: the parts of a bundle folder each on
        /// their own); `calls` of `expected` so far.
        case arrived([URL], calls: Int, expected: Int)
        /// Every promised file arrived or failed: the files and the errors.
        case completed([URL], [Error])
        /// A file beyond the promised count, after completion (its place in the destination).
        case late([URL])
        /// Nothing to do: the delivery was stopped and the file deleted.
        case discarded
    }

    private let lock = NSLock()
    private let session: PromiseDropSession
    private let destination: URL
    private let expected: Int
    private let scope: SecurityScopeLease?
    private var calls = 0
    private var adopted: [URL] = []
    private var errors: [Error] = []
    private var stopped = false
    private var completed = false

    init(session: PromiseDropSession, destination: URL, expected: Int, scope: SecurityScopeLease?) {
        self.session = session
        self.destination = destination
        self.expected = max(1, expected)
        self.scope = scope
        session.deliveryStarted()
    }

    /// One reader call (on the promise queue).
    func record(url: URL, error: Error?) -> Event {
        lock.lock()
        calls += 1
        if stopped {
            lock.unlock()
            if error == nil { session.discardLate(url) }
            return .discarded
        }
        var placed: [URL] = []
        if let error {
            errors.append(error)
        } else {
            do {
                placed = try ReceivedFiles.adoptItem(url, into: destination, name: nil)
                try? FileManager.default.removeItem(at: url) // an emptied bundle folder
            } catch {
                try? FileManager.default.removeItem(at: url)
                errors.append(error)
            }
        }
        if completed {
            lock.unlock()
            return placed.isEmpty ? .discarded : .late(placed)
        }
        adopted.append(contentsOf: placed)
        guard calls >= expected else {
            let event = Event.arrived(placed, calls: calls, expected: expected)
            lock.unlock()
            return event
        }
        completed = true
        let event = Event.completed(adopted, errors)
        adopted = [] // handed over
        lock.unlock()
        session.deliveryEnded()
        return event
    }

    /// The promise went away: a delivery still receiving stops (see `stop`); a completed one goes
    /// on handing its late files over.
    func abandon() {
        lock.lock()
        let wasCompleted = completed
        lock.unlock()
        if !wasCompleted { stop() }
    }

    /// Stops the delivery: what arrived and was not handed over is deleted now; later calls delete
    /// their file.
    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let wasCompleted = completed
        let files = adopted
        adopted = []
        lock.unlock()
        ReceivedFiles.remove(files)
        if !wasCompleted { session.deliveryEnded() }
    }

    /// Reader calls so far (tests).
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// The security scope held (tests: it lives until the delivery is released).
    var heldScope: SecurityScopeLease? { scope }
}

/// A promise read from a drag pasteboard as an `NSFilePromiseReceiver` (AppKit's file promise
/// API): the promising app writes its files, one reader call per file, on a background queue into
/// the drop's staging folder (`PromiseDropSession`); each is moved into the destination as it
/// arrives (`FilePromiseDelivery`). There is no progress but the count of files; cancelling deletes
/// what arrived at once and whatever arrives later. The row's name is the type and its place in the
/// drop until the first file's name is known.
@MainActor
final class PasteboardFilePromise: PromisedFile {
    let receiver: FilePromiseReceiving
    let session: PromiseDropSession
    /// Its place in the drop (0-based) and the drop's number of promises, for the row's name.
    let index: Int
    let count: Int
    var onProgress: ((Double) -> Void)?
    var onRename: ((String) -> Void)?
    var onLateFiles: (([URL]) -> Void)?
    var securityScope: SecurityScopeLease?
    private var cancelled = false
    /// The delivery, once called in (held in a box the deinitialiser may read).
    private let box = DeliveryBox()
    var delivery: FilePromiseDelivery? { box.delivery }
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Framewright file promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(receiver: FilePromiseReceiving, session: PromiseDropSession = PromiseDropSession(), index: Int = 0,
         count: Int = 1) {
        self.receiver = receiver
        self.session = session
        self.index = index
        self.count = max(1, count)
    }

    /// Whether `receiver` promises media (at least one of its types is an image, audio, video or a
    /// Live Photo bundle).
    static func promisesMedia(_ receiver: FilePromiseReceiving) -> Bool {
        receiver.fileTypes.contains { (UTType($0) ?? UTType(importedAs: $0)).isImportableMedia }
    }

    var displayName: String {
        if let name = receiver.fileNames.lazy.compactMap(ReceivedFiles.sanitizedName).first { return name }
        let type = receiver.fileTypes.first.flatMap { UTType($0)?.localizedDescription } ?? "Promised file"
        return count > 1 ? "\(type) \(index + 1) of \(count)" : type
    }

    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let staging: URL
        do {
            staging = try session.stagingFolder(in: directory)
        } catch {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(.failure(error)) }
            }
            return
        }
        let delivery = FilePromiseDelivery(session: session, destination: directory,
                                           expected: receiver.fileTypes.count, scope: securityScope)
        box.delivery = delivery
        // Late files are handed over even after the promise itself went away (its batch settled).
        let lateFiles = onLateFiles
        receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) { [weak self] url, error in
            // On `queue`: settle this call on its own (the file is moved, or deleted when stopped).
            let event = delivery.record(url: url, error: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case let .late(urls) = event {
                        // A cancelled delivery never reports late files (they are deleted).
                        if let lateFiles { lateFiles(urls) } else { ReceivedFiles.remove(urls) }
                        return
                    }
                    guard let self, !self.cancelled else {
                        if case let .completed(urls, _) = event { ReceivedFiles.remove(urls) }
                        return
                    }
                    switch event {
                    case let .arrived(urls, calls, expected):
                        if let first = urls.first { self.onRename?(first.lastPathComponent) }
                        self.onProgress?(Double(calls) / Double(expected))
                    case let .completed(urls, errors):
                        if let first = urls.first { self.onRename?(first.lastPathComponent) }
                        self.onProgress?(1)
                        if urls.isEmpty {
                            completion(.failure(errors.first ?? CocoaError(.fileReadUnknown)))
                        } else {
                            completion(.success(urls))
                        }
                    case .late, .discarded:
                        break
                    }
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        delivery?.stop()
    }

    // A promise released while still receiving (its batch went away) must not leave files behind:
    // its delivery stops, so what arrived is deleted now and later calls delete theirs. A completed
    // delivery goes on handing late files over.
    deinit {
        box.delivery?.abandon()
    }
}

/// Holds a pasteboard promise's delivery where its deinitialiser can reach it.
private final class DeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FilePromiseDelivery?

    var delivery: FilePromiseDelivery? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
