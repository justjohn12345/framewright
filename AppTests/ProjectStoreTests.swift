import AVFoundation
import Combine
import VidEditEngine
import XCTest
@testable import VidEdit

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var directory: URL!
    private var movieURL: URL!
    private var wavURL: URL!

    override func setUp() async throws {
        directory = try TestMediaFactory.scratchDirectory()
        movieURL = directory.appendingPathComponent("clip.mov")
        wavURL = directory.appendingPathComponent("tone.wav")
        try TestMediaFactory.writeMovie(to: movieURL)
        try TestMediaFactory.writeWAV(to: wavURL)
    }

    override func tearDown() async throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeStore() -> ProjectStore {
        ProjectStore(engine: VEEngine(cacheDirectory: directory.appendingPathComponent("Caches")))
    }

    private func importAll(_ store: ProjectStore) async -> [VEAssetInfo] {
        await withCheckedContinuation { continuation in
            store.importMedia([movieURL, wavURL]) { continuation.resume(returning: $0) }
        }
    }

    func testImportInsertUndoRedoPublishes() async throws {
        let store = makeStore()
        var published: [UInt64] = []
        let subscription = store.$changeCount.sink { published.append($0) }
        defer { subscription.cancel() }

        let start = CFAbsoluteTimeGetCurrent()
        let imported = await importAll(store)
        XCTAssertLessThan(store.engine.mainThreadImportSeconds, 0.05)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 30)
        XCTAssertEqual(imported.count, 2, store.statusMessage ?? "")
        XCTAssertEqual(store.assets.count, 2)
        let movie = try XCTUnwrap(store.assets.first { $0.name == "clip.mov" })
        XCTAssertEqual(movie.kind, .video)
        XCTAssertEqual(movie.width, 320)
        XCTAssertEqual(movie.codecName, "H.264")
        let tone = try XCTUnwrap(store.assets.first { $0.name == "tone.wav" })
        XCTAssertEqual(tone.kind, .audio)
        XCTAssertEqual(store.selectedAssetID, imported.first?.assetID)
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(store.undoActionName, "Import")

        // Source monitor: mark 0.5...1.5 s and insert at the playhead on V1.
        store.showInSourceMonitor(movie.assetID)
        store.source.time = CMTime(value: 15, timescale: 30)
        store.markSourceIn()
        store.source.time = CMTime(value: 45, timescale: 30)
        store.markSourceOut()
        store.placeSource(overwrite: false)
        XCTAssertNil(store.statusMessage)
        XCTAssertEqual(store.clips.count, 1)
        let clip = try XCTUnwrap(store.clips.values.first)
        XCTAssertEqual(clip.trackID, store.targetVideoTrackID)
        XCTAssertEqual(clip.duration.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceIn.seconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(store.selection, [clip.clipID])
        XCTAssertEqual(store.undoActionName, "Insert")
        XCTAssertTrue(store.isDirty)

        // Drop the WAV on A1 at 3 s (overwrite).
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.dropAsset(tone.assetID, onTrack: a1, at: 3.01, overwrite: true))
        XCTAssertEqual(store.clips.count, 2)
        let audioClip = try XCTUnwrap(store.clips.values.first { $0.trackID == a1 })
        XCTAssertEqual(audioClip.timelineStart.seconds, 3, accuracy: 1e-9, "snapped to the frame grid")

        // Undo publishes.
        let countBeforeUndo = store.changeCount
        store.undo()
        XCTAssertGreaterThan(store.changeCount, countBeforeUndo)
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertTrue(store.canRedo)
        XCTAssertEqual(store.redoActionName, "Overwrite")
        store.redo()
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertFalse(store.canRedo)
        XCTAssertEqual(published.last, store.changeCount)
        XCTAssertGreaterThanOrEqual(Set(published).count, 5, "every change was published")

        // Split at the playhead (Cmd+K) with nothing selected splits what is under it.
        store.selection = []
        store.playheadTime = CMTime(value: 1, timescale: 2)
        store.splitAtPlayhead()
        XCTAssertNil(store.statusMessage)
        XCTAssertEqual(store.clips.count, 3)

        // Delete and ripple delete.
        let right = try XCTUnwrap(store.clips.values.filter { $0.trackID == clip.trackID }.max { $0.timelineStart < $1.timelineStart })
        store.selection = [right.clipID]
        store.deleteSelection(ripple: true)
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertTrue(store.selection.isEmpty)

        // Removing media in use is refused with a message.
        store.removeAsset(tone.assetID)
        XCTAssertNotNil(store.statusMessage)
        XCTAssertEqual(store.assets.count, 2)
    }

    func testSaveOpenAndNewProject() async throws {
        let store = makeStore()
        _ = await importAll(store)
        let movie = try XCTUnwrap(store.assets.first { $0.hasVideo })
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: store.targetVideoTrackID,
                                  audioTrack: 0, overwrite: true))
        let url = directory.appendingPathComponent("Store Test.videdit")
        try store.save(to: url)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.projectName, "Store Test")
        XCTAssertEqual(store.projectURL, url)

        store.newProject()
        XCTAssertEqual(store.assets.count, 0)
        XCTAssertEqual(store.clips.count, 0)
        XCTAssertNil(store.projectURL)

        try store.open(url: url)
        XCTAssertEqual(store.assets.count, 2)
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.statusMessage, "no missing media")

        XCTAssertThrowsError(try store.open(url: directory.appendingPathComponent("nope.videdit")))
        XCTAssertEqual(store.clips.count, 1, "a failed open keeps the project")
    }

    func testMoveTrimAndCoalescingThroughTheEngine() async throws {
        let store = makeStore()
        _ = await importAll(store)
        let movie = try XCTUnwrap(store.assets.first { $0.hasVideo })
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: store.targetVideoTrackID,
                                  audioTrack: 0, overwrite: true))
        let clipID = try XCTUnwrap(store.selection.first)
        let before = store.engine.projectJSON
        // A drag: several steps, one undo step.
        store.engine.beginCoalescing(withKey: "test.drag")
        for step in 1 ... 5 {
            let delta = CMTime(value: CMTimeValue(step * 3), timescale: 30)
            XCTAssertTrue(store.engine.moveClips([NSNumber(value: clipID)], by: delta, trackOffset: 0).ok)
        }
        store.engine.endCoalescing()
        XCTAssertEqual(try XCTUnwrap(store.clips[clipID]).timelineStart.seconds, 0.5, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.engine.projectJSON, before)

        // Escape during a trim reverts it.
        store.engine.beginCoalescing(withKey: "test.trim")
        XCTAssertTrue(store.engine.trimClipTail(clipID, to: CMTime(value: 1, timescale: 1), clamp: true).ok)
        store.engine.cancelCoalescing()
        XCTAssertEqual(store.engine.projectJSON, before)

        // Zoom and playhead stepping.
        store.pixelsPerSecond = 100
        store.zoomIn()
        XCTAssertEqual(store.pixelsPerSecond, 150, accuracy: 1e-9)
        store.playheadTime = .zero
        store.stepFrames(2)
        XCTAssertEqual(store.playheadTime, CMTime(value: 2, timescale: 30))
        store.stepFrames(-5)
        XCTAssertEqual(store.playheadTime, .zero)
    }

    func testKeyboardMapping() {
        XCTAssertEqual(KeyboardController.action(keyCode: 49, characters: " ", modifiers: []), .togglePlay)
        XCTAssertEqual(KeyboardController.action(keyCode: 38, characters: "j", modifiers: []), .shuttleReverse)
        XCTAssertEqual(KeyboardController.action(keyCode: 40, characters: "k", modifiers: []), .shuttleStop)
        XCTAssertEqual(KeyboardController.action(keyCode: 37, characters: "l", modifiers: []), .shuttleForward)
        XCTAssertEqual(KeyboardController.action(keyCode: 123, characters: "", modifiers: []), .stepBackward)
        XCTAssertEqual(KeyboardController.action(keyCode: 124, characters: "", modifiers: []), .stepForward)
        XCTAssertEqual(KeyboardController.action(keyCode: 51, characters: "", modifiers: []), .delete)
        XCTAssertEqual(KeyboardController.action(keyCode: 51, characters: "", modifiers: .shift), .rippleDelete)
        XCTAssertEqual(KeyboardController.action(keyCode: 34, characters: "i", modifiers: []), .markIn)
        XCTAssertEqual(KeyboardController.action(keyCode: 31, characters: "o", modifiers: []), .markOut)
        XCTAssertEqual(KeyboardController.action(keyCode: 53, characters: "", modifiers: []), .cancel)
        XCTAssertEqual(KeyboardController.action(keyCode: 0, characters: "a", modifiers: .command), .selectAll)
        XCTAssertNil(KeyboardController.action(keyCode: 40, characters: "k", modifiers: .command), "Cmd+K is the menu's")
        XCTAssertNil(KeyboardController.action(keyCode: 6, characters: "z", modifiers: .command))
    }

    func testPlaybackHookReceivesTransportRequests() {
        let store = makeStore()
        let keyboard = KeyboardController(store: store)
        keyboard.perform(.togglePlay, on: store)
        keyboard.perform(.shuttleForward, on: store)
        let placeholder = store.playbackActions as? PlaybackActionsPlaceholder
        XCTAssertEqual(placeholder?.requests, ["toggle", "forward"])
    }

    func testTimecodeFormatting() {
        let fd = CMTime(value: 1, timescale: 30)
        XCTAssertEqual(Timecode.string(CMTime(value: 3723 * 30 + 12, timescale: 30), frameDuration: fd), "01:02:03:12")
        XCTAssertEqual(Timecode.string(.zero, frameDuration: CMTime(value: 1001, timescale: 30000)), "00:00:00:00")
        XCTAssertEqual(Timecode.rulerLabel(seconds: 65, showFrames: false, fps: 30), "1:05")
        XCTAssertEqual(Timecode.rulerLabel(seconds: 1.5, showFrames: true, fps: 30), "0:01:15")
        XCTAssertEqual(CMTime.onFrameGrid(seconds: 1.01, frameDuration: fd), CMTime(value: 30, timescale: 30))
    }
}
