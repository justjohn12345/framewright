import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

// Test doubles for Photos drops and Import from Photos: a drop's providers, a promise-carrying
// item provider, a scripted promise, and a double of NSFilePromiseReceiver's contract.

/// A drop's providers (SwiftUI's DropInfo cannot be made outside a drag).
struct FakeDropInfo: TimelineDropInfo {
    var location: CGPoint
    var providers: [NSItemProvider]

    func hasItemsConforming(to contentTypes: [UTType]) -> Bool {
        providers.contains { provider in
            contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
    }

    func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider] {
        providers.filter { provider in
            contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
    }
}

/// A Photos drag item: the file promise types plus a file representation of `type` whose load
/// waits until `deliver()` (or is cancelled). Its state is only touched on the main queue.
final class FakePromiseProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    private(set) var loadRequested = false
    private(set) var cancelled = false
    private var pending: (() -> Void)?

    init(name: String, file: URL, type: UTType) {
        provider.suggestedName = name
        for promise in UTType.filePromiseTypes {
            provider.registerDataRepresentation(forTypeIdentifier: promise.identifier, visibility: .all) { done in
                done(Data(), nil)
                return nil
            }
        }
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: 100)
            // A real provider completes once: whichever of delivery and cancellation comes first.
            let once = CompletionOnce(completion)
            let delivery = {
                // Like a promise keeper: a fresh temporary file the receiver takes over.
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("promise-\(UUID().uuidString).\(file.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: file, to: temporary)
                    progress.completedUnitCount = 100
                    once.call(temporary, nil)
                } catch {
                    once.call(nil, error)
                }
            }
            progress.cancellationHandler = {
                DispatchQueue.main.async { self?.cancelled = true }
                once.call(nil, CocoaError(.userCancelled))
            }
            DispatchQueue.main.async {
                self?.loadRequested = true
                self?.pending = delivery
                self?.failure = { error in once.call(nil, error) }
            }
            return progress
        }
    }

    private var failure: ((Error) -> Void)?

    /// Delivers the file (the promise is fulfilled).
    func deliver() {
        pending?()
        pending = nil
        failure = nil
    }

    /// The load fails (the source could not provide the file).
    func fail(_ message: String) {
        failure?(NSError(domain: "Provider", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
        pending = nil
        failure = nil
    }
}

/// Calls a file-representation completion at most once (from either thread).
final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((URL?, Bool, Error?) -> Void)?

    init(_ completion: @escaping (URL?, Bool, Error?) -> Void) {
        self.completion = completion
    }

    func call(_ url: URL?, _ error: Error?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(url, false, error)
    }
}

/// A promise implemented directly (no provider): progress, success or failure on demand.
final class ScriptedPromise: PromisedFile {
    let displayName: String
    var onProgress: ((Double) -> Void)?
    private var completion: (@MainActor (Result<[URL], Error>) -> Void)?
    private(set) var cancelled = false
    private(set) var directory: URL?

    init(name: String) {
        displayName = name
    }

    func receive(into directory: URL, completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.directory = directory
        self.completion = completion
    }

    /// A misbehaving source that still completes after `cancel()` (IncomingMedia must ignore it and
    /// delete what it hands over).
    var completesAfterCancel = false

    func cancel() {
        cancelled = true
        if !completesAfterCancel { completion = nil }
    }

    func progress(_ fraction: Double) {
        onProgress?(fraction)
    }

    /// Writes copies of `files` into the destination and reports them.
    func deliver(_ files: [URL]) throws {
        guard let directory, let completion else { return }
        let urls = try files.map { file -> URL in
            let target = directory.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: target)
            return target
        }
        self.completion = nil
        completion(.success(urls))
    }

    func fail(_ message: String) {
        completion?(.failure(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
        completion = nil
    }
}


/// A double of `NSFilePromiseReceiver`'s contract (`FilePromiseReceiving`): the promised types, the
/// names once called in, and a reader called on the receiver's operation queue when the test writes
/// a file (or reports an error). `finish()` releases the reader, as AppKit does when it is done.
final class FakeFilePromiseReceiver: FilePromiseReceiving, @unchecked Sendable {
    let fileTypes: [String]
    private(set) var fileNames: [String] = []
    private(set) var destination: URL?
    private var reader: ((URL, Error?) -> Void)?
    private var queue: OperationQueue?
    private(set) var receiveCalls = 0

    init(types: [UTType]) {
        fileTypes = types.map(\.identifier)
    }

    func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                              operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        receiveCalls += 1
        destination = destinationDir
        queue = operationQueue
        self.reader = reader
    }

    /// The promiser writes a copy of `file` named `name` into the destination and calls the reader
    /// (on the operation queue, like AppKit); returns where it wrote.
    @discardableResult
    func write(_ file: URL, as name: String) throws -> URL {
        let destination = try XCTUnwrap(destination, "called in")
        let target = destination.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
        fileNames.append(name)
        call(target, nil)
        return target
    }

    /// Writing a file failed or was cancelled (the reader still runs, with the error).
    func fail(_ message: String) {
        call(destination ?? URL(fileURLWithPath: "/dev/null"),
             NSError(domain: "Promise", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// AppKit is done with the promise: the reader (and what it holds) is released.
    func finish() {
        queue?.waitUntilAllOperationsAreFinished()
        reader = nil
    }

    private func call(_ url: URL, _ error: Error?) {
        guard let reader, let queue else { return }
        queue.addOperation { reader(url, error) }
        queue.waitUntilAllOperationsAreFinished()
    }
}
