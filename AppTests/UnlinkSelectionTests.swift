import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Unlink leaves one clip selected (hands-on round, 2026-09-27): a click selects a linked pair, so
/// after Unlink the selection used to hold both clips and a drag moved both and Delete removed both,
/// which read as "Unlink does nothing". A successful Unlink keeps the clip it was invoked for (the
/// clicked clip, the inspector's clip, else the clip last clicked or the first selected) and says so.
/// Geometry at the default zoom (50 pt/s, no scroll): V1 y 66...130, A1 132...180.
@MainActor
final class UnlinkSelectionTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "unlink-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// The movie's picture on V1 and the tone on A1, both [0, 1 s), linked.
    private func linkedPair() async throws -> (video: VEClipID, audio: VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let video = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let audio = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(video, withClip: audio).ok)
        store.selection = []
        return (video, audio)
    }

    private func click(_ gestures: TimelineGestureController, at point: CGPoint) {
        gestures.changed(location: point, startLocation: point, modifiers: [])
        gestures.ended()
    }

    private func drag(_ gestures: TimelineGestureController, from: CGPoint, to: CGPoint) {
        gestures.changed(location: from, startLocation: from, modifiers: [])
        gestures.changed(location: CGPoint(x: from.x + 5, y: from.y), startLocation: from, modifiers: [])
        gestures.changed(location: to, startLocation: from, modifiers: [])
        gestures.ended()
    }

    private func start(_ clip: VEClipID) -> Double {
        store.clips[clip]?.timelineStart.secondsOrZero ?? -1
    }

    func testUnlinkKeepsTheClickedClipSelectedSoADragAndDeleteActOnItAlone() async throws {
        let (video, audio) = try await linkedPair()
        let gestures = TimelineGestureController(store: store)
        click(gestures, at: CGPoint(x: 25, y: 90))
        XCTAssertEqual(store.selection, [video, audio], "a click selects the linked pair")

        store.linkOrUnlinkSelection()
        XCTAssertEqual(store.clips[video]?.linkedClipID, 0)
        XCTAssertEqual(store.clips[audio]?.linkedClipID, 0)
        XCTAssertEqual(store.selection, [video], "the clicked clip stays selected, alone")
        XCTAssertEqual(store.statusMessage, "Unlinked “clip.mov” from “tone.wav”.")
        XCTAssertEqual(store.undoActionName, "Unlink")

        // A drag moves the one clip; its former partner stays.
        drag(gestures, from: CGPoint(x: 25, y: 90), to: CGPoint(x: 75, y: 90))
        XCTAssertEqual(start(video), 1, accuracy: 1e-9)
        XCTAssertEqual(start(audio), 0, accuracy: 1e-9, "the unlinked sound does not move")
        XCTAssertEqual(store.selection, [video])

        // Delete removes the one clip.
        store.focusArea = .timeline
        store.deleteSelection(ripple: false)
        XCTAssertNil(store.clips[video])
        XCTAssertNotNil(store.clips[audio], "the unlinked sound is not deleted")
        store.undo()
        XCTAssertNotNil(store.clips[video])
        XCTAssertNotNil(store.clips[audio])
    }

    /// Review L4: Unlink with several linked pairs selected (a marquee, Select All) unlinks every pair
    /// in one undo step and keeps one clip of each selected: the clicked clip for its pair, the
    /// picture for the others.
    func testUnlinkWithSeveralPairsUnlinksEveryPairAndKeepsOneClipOfEach() async throws {
        let (video, audio) = try await linkedPair()
        let (movie, tone) = (try XCTUnwrap(store.asset(try XCTUnwrap(store.clips[video]).assetID)),
                             try XCTUnwrap(store.asset(try XCTUnwrap(store.clips[audio]).assetID)))
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: store.frameTime(2), videoTrack: v1, audioTrack: 0,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let video2 = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: tone.assetID, at: store.frameTime(2), videoTrack: 0, audioTrack: a1,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let audio2 = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(video2, withClip: audio2).ok)

        // Both pairs selected by clicks (the second extending): the second pair's sound was clicked.
        store.select(clip: video, extend: false)
        store.select(clip: audio2, extend: true)
        XCTAssertEqual(store.selection, [video, audio, video2, audio2])
        store.linkOrUnlinkSelection()
        for clip in [video, audio, video2, audio2] {
            XCTAssertEqual(store.clips[clip]?.linkedClipID, 0, "every selected pair is unlinked")
        }
        XCTAssertEqual(store.selection, [video, audio2], "the clicked sound for its pair, the picture for the other")
        XCTAssertEqual(store.statusMessage, "Unlinked 2 pairs of clips.")
        XCTAssertEqual(store.undoActionName, "Unlink")
        store.undo()
        XCTAssertEqual(store.clips[video]?.linkedClipID, audio, "one undo step")
        XCTAssertEqual(store.clips[video2]?.linkedClipID, audio2)

        // Select All (no clicked clip): the picture of each pair.
        store.selectAll()
        XCTAssertEqual(store.selection, [video, audio, video2, audio2])
        store.linkOrUnlinkSelection()
        XCTAssertEqual(store.clips[video]?.linkedClipID, 0)
        XCTAssertEqual(store.clips[video2]?.linkedClipID, 0)
        XCTAssertEqual(store.selection, [video, video2])
    }

    func testTheContextMenuAndTheInspectorKeepTheClipTheyActOn() async throws {
        let (video, audio) = try await linkedPair()
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let a1 = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[audio]).trackID))

        // The context menu on the sound: the pair is selected, Unlink keeps the clicked sound.
        let items = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 0.5), y: a1.y + 20))
        XCTAssertEqual(store.selection, [video, audio])
        try XCTUnwrap(items.first { $0.title == "Unlink" }).action()
        XCTAssertEqual(store.selection, [audio])
        XCTAssertEqual(store.statusMessage, "Unlinked “tone.wav” from “clip.mov”.")

        // The inspector's button keeps the inspector's clip (the pair's picture).
        store.undo()
        XCTAssertEqual(store.clips[video]?.linkedClipID, audio)
        store.select(clip: audio, extend: false)
        XCTAssertEqual(store.selection, [video, audio])
        store.linkOrUnlinkSelection(keeping: video)
        XCTAssertEqual(store.selection, [video])

        // Clip > Link / Unlink with the pair selected by a click on the sound keeps the sound.
        store.undo()
        store.select(clip: audio, extend: false)
        store.linkOrUnlinkSelection()
        XCTAssertEqual(store.selection, [audio])

        // The selection never grows back to a partner by itself: relinking and a model change keep
        // what is selected.
        store.undo()
        XCTAssertEqual(store.clips[video]?.linkedClipID, audio)
        store.selection = [audio]
        store.refreshModel()
        XCTAssertEqual(store.selection, [audio])
        // A clip that goes away leaves the selection (unlinked first, so only the sound goes).
        XCTAssertTrue(store.engine.unlinkClip(video).ok)
        store.selection = [video, audio]
        XCTAssertTrue(store.engine.removeClips([NSNumber(value: audio)]).ok)
        XCTAssertNil(store.clips[audio])
        XCTAssertEqual(store.selection, [video])
    }
}
