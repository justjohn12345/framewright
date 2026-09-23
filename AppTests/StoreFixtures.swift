import Foundation
import VidEditEngine
import XCTest
@testable import VidEdit

/// A store over a fresh engine with test media written to a scratch directory.
@MainActor
final class StoreFixture {
    let directory: URL
    let movieURL: URL
    let toneURL: URL
    let store: ProjectStore

    /// A 2 s 320x180 H.264 movie (60 frames at 30 fps) and a 3 s stereo WAV.
    init() throws {
        directory = try TestMediaFactory.scratchDirectory()
        movieURL = directory.appendingPathComponent("clip.mov")
        toneURL = directory.appendingPathComponent("tone.wav")
        try TestMediaFactory.writeMovie(to: movieURL, frames: 60)
        try TestMediaFactory.writeWAV(to: toneURL, seconds: 3)
        store = ProjectStore(engine: VEEngine(cacheDirectory: directory.appendingPathComponent("Caches")))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Imports the movie and the tone; returns (movie, tone).
    func importMedia() async throws -> (movie: VEAssetInfo, tone: VEAssetInfo) {
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([movieURL, toneURL]) { continuation.resume(returning: $0) }
        }
        let movie = try XCTUnwrap(imported.first { $0.hasVideo })
        let tone = try XCTUnwrap(imported.first { !$0.hasVideo })
        return (movie, tone)
    }

    /// Places the movie's picture on V1 at `seconds` (overwrite); returns the clip id.
    @discardableResult
    func placeMovie(_ movie: VEAssetInfo, at seconds: Double, track: VETrackID? = nil) throws -> VEClipID {
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: store.frameTime(seconds), videoTrack: track ?? v1,
                                  audioTrack: 0, overwrite: true), store.statusMessage ?? "")
        return try XCTUnwrap(store.selection.first)
    }

    /// Waits (suspending, so main-queue work such as engine callbacks runs) until `condition`
    /// holds or `timeout` passes. For async tests: a nested run loop inside an async test does not
    /// drain the main queue, because the test itself runs as a main-queue job.
    @discardableResult
    static func wait(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes (synchronous tests).
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
