import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Regression tests for the app findings of the 2026-09-23 review (docs/reviews): Delete with the
/// media bin focused (P1), edit keys during a gesture (E2), thumbnail and waveform caches across an
/// Open (P2), and the playhead after an edit shortens the sequence.
@MainActor
final class ReviewRegressionTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    // MARK: P1: Delete follows the focused panel

    func testDeleteWithTheBinFocusedNeverTouchesTheTimeline() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        XCTAssertEqual(store.selection, [clip])
        // A click on an asset tile: the bin has focus, the timeline selection stays.
        store.selectedAssetID = movie.assetID
        store.focusArea = .mediaBin
        let keyboard = KeyboardController(store: store)
        keyboard.perform(.delete, on: store)
        XCTAssertNotNil(store.clips[clip], "Delete in the bin removed the timeline selection")
        XCTAssertEqual(store.assets.count, 2, "the asset is in use: its removal is refused")
        XCTAssertNotNil(store.statusMessage)
        keyboard.perform(.rippleDelete, on: store)
        XCTAssertNotNil(store.clips[clip], "Shift+Delete in the bin rippled the timeline")
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertEqual(store.undoActionName, "Overwrite", "nothing was edited")

        // An unused asset is removed by Delete in the bin.
        store.selectedAssetID = tone.assetID
        keyboard.perform(.delete, on: store)
        XCTAssertEqual(store.assets.count, 1)
        XCTAssertNotNil(store.clips[clip])
    }

    // MARK: E2: edit keys while a gesture is in progress

    func testEditKeysDuringATimelineDragDoNotEdit() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let gestures = TimelineGestureController(store: store)
        let origin = CGPoint(x: 50, y: 90)
        gestures.changed(location: origin, startLocation: origin, modifiers: [])
        gestures.changed(location: CGPoint(x: 100, y: 90), startLocation: origin, modifiers: [])
        XCTAssertEqual(store.clips[clip]?.timelineStart.secondsOrZero ?? -1, 1, accuracy: 1e-9)
        store.playheadTime = CMTime(value: 45, timescale: 30) // inside the dragged clip

        KeyboardController(store: store).perform(.delete, on: store)
        store.splitAtPlayhead() // Cmd+K from the menu
        XCTAssertNotNil(store.clips[clip], "Delete during a drag")
        XCTAssertEqual(store.clips.count, 1, "Cmd+K during a drag")

        gestures.changed(location: CGPoint(x: 150, y: 90), startLocation: origin, modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.clips[clip]?.timelineStart.secondsOrZero ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Move Clip")
        store.undo()
        XCTAssertEqual(store.clips[clip]?.timelineStart.secondsOrZero ?? -1, 0, accuracy: 1e-9,
                       "the drag is one undo step")
    }

    func testDeleteDuringAnInspectorSliderDragIsIgnored() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let other = try fixture.placeMovie(movie, at: 5)
        store.selection = [other]
        // What a slider drag in the inspector does.
        let key = "inspector.opacity.\(clip)"
        store.engine.beginCoalescing(withKey: key)
        var params = VEVideoParamsIdentity()
        params.opacity = 0.5
        XCTAssertTrue(store.engine.performInCoalescingGroup(key) {
            store.engine.setVideoParams(params, forClip: clip)
        }.ok)
        KeyboardController(store: store).perform(.delete, on: store)
        XCTAssertNotNil(store.clips[other], "Delete during a slider drag")
        XCTAssertEqual(store.clips[clip]?.videoParams.opacity ?? 0, 0.5, accuracy: 1e-9)
        store.engine.endCoalescing()
        XCTAssertEqual(store.undoActionName, "Change Video Settings")
        XCTAssertEqual(store.clips[clip]?.videoParams.opacity ?? 0, 0.5, accuracy: 1e-9)
    }

    // MARK: P2: UI caches across Open

    func testAThumbnailRequestedBeforeAnOpenLoadsInTheReopenedProject() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let url = fixture.directory.appendingPathComponent("P2.framewright")
        try store.save(to: url)
        let cache = store.thumbnails
        XCTAssertNil(cache.image(asset: movie.assetID, seconds: 0.5, maxDimension: 111)) // starts a fetch
        try store.open(url: url) // same file: the same asset id names the same media
        XCTAssertNil(cache.image(asset: movie.assetID, seconds: 0.5, maxDimension: 111)) // starts a fetch
        let loaded = await StoreFixture.wait(until: {
            cache.image(asset: movie.assetID, seconds: 0.5, maxDimension: 111) != nil
        }, timeout: 10)
        XCTAssertTrue(loaded, "the previous project's completion poisoned the key (requests \(cache.requestsStarted))")
    }

    func testAWaveformRequestedBeforeAnOpenLoadsInTheReopenedProject() async throws {
        let (movie, tone) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let url = fixture.directory.appendingPathComponent("P2w.framewright")
        try store.save(to: url)
        let cache = store.waveforms
        // Let the import's own waveform job finish, then drop the peaks from memory so the next
        // request is an asynchronous load.
        let computed = await StoreFixture.wait(until: { store.engine.cachedWaveform(forAsset: tone.assetID) != nil },
                                               timeout: 10)
        XCTAssertTrue(computed)
        store.engine.handleMemoryPressure(true)
        XCTAssertNil(store.engine.cachedWaveform(forAsset: tone.assetID))
        XCTAssertNil(cache.waveform(asset: tone.assetID)) // starts a load
        try store.open(url: url)
        let loaded = await StoreFixture.wait(until: { cache.waveform(asset: tone.assetID) != nil }, timeout: 10)
        XCTAssertTrue(loaded, "the previous project's completion poisoned the waveform")
    }

    // MARK: The playhead after an edit shortens the sequence

    func testThePlayheadFollowsWhenAnEditShortensTheSequence() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0) // [0, 2 s)
        store.playheadTime = store.frameTime(1.8)
        XCTAssertEqual(store.playheadTime, CMTime(value: 54, timescale: 30))
        XCTAssertTrue(store.engine.trimClipTail(clip, to: CMTime(value: 1, timescale: 1), clamp: true).ok)
        let engineTime = store.engine.currentTime
        XCTAssertEqual(engineTime, CMTime(value: 29, timescale: 30), "the engine clamps to the last frame")
        let followed = await StoreFixture.wait(until: { store.playhead.time == engineTime }, timeout: 5)
        XCTAssertTrue(followed, "the UI playhead stayed at \(store.playhead.time.seconds) s")
        XCTAssertEqual(store.playheadTime, engineTime)
    }
}
