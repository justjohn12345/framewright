import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Reverse Clip in the app: the menu toggle (and its check mark), the inspector's Reverse box and
/// Source rows, the Speed/Duration sheet's Reverse box, the timeline's "◀" badge and the mirrored
/// media times its thumbnails and waveforms are drawn from; every change one undo step, linked
/// audio following.
@MainActor
final class ReverseClipTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "reverse-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// The movie's picture on V1 over [0, 1 s) from source 0.5 s, linked to the tone on A1.
    private func linkedPair() async throws -> (video: VEClipID, audio: VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0,
                                  sourceIn: store.frameTime(0.5), sourceOut: store.frameTime(1.5), overwrite: true))
        let video = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: store.frameTime(0.5), sourceOut: store.frameTime(1.5), overwrite: true))
        let audio = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(video, withClip: audio).ok)
        return (video, audio)
    }

    func testTheMenuToggleReversesTheSelectionWithItsLinkedAudioInOneUndoStep() async throws {
        let (video, audio) = try await linkedPair()
        store.selection = [video]
        XCTAssertFalse(store.selectionIsReversed)
        XCTAssertEqual(store.reversibleSelection.map(\.clipID), [video])
        store.toggleReverseSelection()
        XCTAssertTrue(store.clips[video]?.reversed == true)
        XCTAssertTrue(store.clips[audio]?.reversed == true, "the linked audio follows")
        XCTAssertTrue(store.selectionIsReversed, "the menu item is checked")
        XCTAssertEqual(store.undoActionName, "Reverse Clip")
        let clip = try XCTUnwrap(store.clips[video])
        XCTAssertEqual(clip.mediaIn.seconds, 0.5, accuracy: 1e-9, "it shows the same media")
        XCTAssertEqual(clip.mediaOut.seconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(clip.timelineStart, .zero)
        store.undo()
        XCTAssertFalse(store.clips[video]?.reversed == true)
        XCTAssertFalse(store.clips[audio]?.reversed == true, "one undo step for both")
        store.redo()
        XCTAssertTrue(store.selectionIsReversed)
        store.toggleReverseSelection()
        XCTAssertFalse(store.clips[video]?.reversed == true)
        XCTAssertEqual(store.undoActionName, "Play Clip Forward")

        // The clip's context menu offers the same, checked when it plays backwards.
        store.setReversed(true)
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let row = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[video]).trackID))
        let items = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 0.5), y: row.y + 20))
        let item = try XCTUnwrap(items.first { $0.title == "Reverse Clip" })
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(item.isChecked)
        item.action()
        XCTAssertFalse(store.clips[video]?.reversed == true)

        // Nothing to reverse: a still, or nothing selected.
        store.selection = []
        XCTAssertFalse(store.setReversed(true))
        XCTAssertEqual(store.statusMessage, "Select the clips to reverse.")
    }

    func testTheInspectorsReverseBoxAndSourceRows() async throws {
        let (video, audio) = try await linkedPair()
        store.selection = [video, audio]
        XCTAssertEqual(inspector.speedTarget?.clipID, video)
        let before = try XCTUnwrap(store.clips[video])
        XCTAssertEqual(InspectorModel.sourceRangeTexts(of: before).in, Timecode.duration(before.sourceIn))
        inspector.setReversed(true)
        let reversed = try XCTUnwrap(store.clips[video])
        XCTAssertTrue(reversed.reversed)
        XCTAssertTrue(store.clips[audio]?.reversed == true)
        let rows = InspectorModel.sourceRangeTexts(of: reversed)
        XCTAssertEqual(rows.in, Timecode.duration(before.sourceIn) + " (reversed)", "the media range it shows")
        XCTAssertEqual(rows.out, Timecode.duration(before.sourceOut) + " (reversed)")
        let count = store.changeCount
        inspector.setReversed(true)
        XCTAssertEqual(store.changeCount, count, "already reversed: nothing to do")
        inspector.setReversed(false)
        XCTAssertFalse(store.clips[video]?.reversed == true)
        store.undo()
        XCTAssertTrue(store.clips[video]?.reversed == true)
    }

    func testTheSpeedSheetsReverseBoxIsOneUndoStepWithTheSpeed() async throws {
        let (video, audio) = try await linkedPair()
        let sheet = SpeedDurationModel(store: store, clipIDs: [video])
        XCTAssertEqual(sheet.reversed, false)
        sheet.entry = .percent
        sheet.text = "50"
        sheet.reversed = true
        XCTAssertTrue(sheet.apply(), sheet.message ?? "")
        let clip = try XCTUnwrap(store.clips[video])
        XCTAssertEqual(clip.speedDenominator, 2)
        XCTAssertTrue(clip.reversed)
        XCTAssertTrue(store.clips[audio]?.reversed == true)
        XCTAssertFalse(store.engine.isCoalescing)
        store.undo()
        let undone = try XCTUnwrap(store.clips[video])
        XCTAssertEqual(undone.speedDenominator, 1, "speed and direction were one undo step")
        XCTAssertFalse(undone.reversed)
        // A reversed clip's sheet opens checked; unchecking plays it forward.
        store.redo()
        let again = SpeedDurationModel(store: store, clipIDs: [video])
        XCTAssertEqual(again.reversed, true)
        again.reversed = false
        XCTAssertTrue(again.apply())
        XCTAssertFalse(store.clips[video]?.reversed == true)
        XCTAssertEqual(store.clips[video]?.speedDenominator, 2, "the speed stays")
    }

    /// M1 of the post-lanes review: on a selection mixing a reversed and a forward clip the sheet's
    /// Reverse box starts mixed; a new speed alone keeps each clip's direction, and setting the box
    /// reverses every clip in the same undo step as the speed, the status line saying so.
    func testTheSpeedSheetOnAMixedSelectionChangesDirectionOnlyWhenTheBoxIsSet() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 4)
        store.selection = [a]
        XCTAssertTrue(store.setReversed(true))
        store.selection = [a, b]
        store.showSpeedSheet()
        let ids = try XCTUnwrap(store.speedSheetClipIDs)
        let sheet = SpeedDurationModel(store: store, clipIDs: ids)
        XCTAssertNil(sheet.reversed, "the box starts in the mixed state")
        XCTAssertEqual(sheet.reverseSources.map(\.wrappedValue), [true, false],
                       "the checkbox's sources: each clip's own direction")
        sheet.entry = .percent
        sheet.text = "50"
        XCTAssertTrue(sheet.apply(), sheet.message ?? "")
        XCTAssertEqual(store.clips[a]?.speedDenominator, 2)
        XCTAssertEqual(store.clips[b]?.speedDenominator, 2)
        XCTAssertTrue(store.clips[a]?.reversed == true, "only the speed was asked for: a stays reversed")
        XCTAssertFalse(store.clips[b]?.reversed == true, "and b stays forward")
        XCTAssertEqual(store.undoActionName, "Change Speed")
        store.undo()
        XCTAssertEqual(store.clips[a]?.speedDenominator, 1)
        XCTAssertTrue(store.clips[a]?.reversed == true)

        // The box set on: both clips play backwards, in the same undo step as the speed.
        let touched = SpeedDurationModel(store: store, clipIDs: ids)
        touched.entry = .percent
        touched.text = "50"
        // A click on the mixed checkbox sets every source (SwiftUI's mixed Toggle turns them all on).
        for source in touched.reverseSources { source.wrappedValue = true }
        XCTAssertEqual(touched.reversed, true)
        XCTAssertEqual(touched.reverseSources.map(\.wrappedValue), [true, true])
        XCTAssertTrue(touched.apply(), touched.message ?? "")
        XCTAssertTrue(store.clips[a]?.reversed == true)
        XCTAssertTrue(store.clips[b]?.reversed == true)
        XCTAssertEqual(store.clips[b]?.speedDenominator, 2)
        XCTAssertEqual(store.statusMessage, "Reversed 1 clip.")
        store.undo()
        XCTAssertEqual(store.clips[a]?.speedDenominator, 1, "one undo step")
        XCTAssertEqual(store.clips[b]?.speedDenominator, 1)
        XCTAssertTrue(store.clips[a]?.reversed == true)
        XCTAssertFalse(store.clips[b]?.reversed == true)

        // The box set off: both play forward.
        let off = SpeedDurationModel(store: store, clipIDs: ids)
        off.reversed = false
        XCTAssertTrue(off.apply(), off.message ?? "")
        XCTAssertFalse(store.clips[a]?.reversed == true)
        XCTAssertFalse(store.clips[b]?.reversed == true)
        XCTAssertEqual(store.statusMessage, "Played 1 clip forward.")
    }

    /// Review L2: a still linked to music, the pair selected by a click, Option-Cmd-R: the music is
    /// reversed on its own (a still has no direction) and the status line says so.
    func testReversingSoundLinkedToAStillReversesTheSoundAlone() async throws {
        let (_, tone) = try await fixture.importMedia()
        let photoURL = fixture.directory.appendingPathComponent("photo.heic")
        try TestMediaFactory.writeHEIC(to: photoURL)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([photoURL]) { continuation.resume(returning: $0) }
        }
        let photo = try XCTUnwrap(imported.first)
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: photo.assetID, at: .zero, videoTrack: v1, audioTrack: 0, overwrite: true))
        let still = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: store.frameTime(0.5), sourceOut: store.frameTime(1.5), overwrite: true))
        let music = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(still, withClip: music).ok)
        store.select(clip: still, extend: false)
        XCTAssertEqual(store.selection, [still, music])
        XCTAssertEqual(store.reversibleSelection.map(\.clipID), [music])
        store.toggleReverseSelection()
        XCTAssertTrue(store.clips[music]?.reversed == true, "the music is reversed")
        XCTAssertFalse(store.clips[still]?.reversed == true)
        XCTAssertEqual(store.statusMessage, "“photo.heic” is a still image, which has no direction: its linked "
            + "“tone.wav” was reversed on its own.")
        XCTAssertEqual(store.undoActionName, "Reverse Clip")
        store.toggleReverseSelection()
        XCTAssertFalse(store.clips[music]?.reversed == true)
        XCTAssertEqual(store.statusMessage, "“photo.heic” is a still image, which has no direction: its linked "
            + "“tone.wav” was played forward on its own.")
    }

    func testTheTimelineShowsABadgeAndMirroredMediaTimes() async throws {
        let (video, _) = try await linkedPair()
        store.selection = [video]
        let forward = try XCTUnwrap(store.timelineModel.clips.first { $0.id == video })
        XCTAssertEqual(forward.title, forward.name)
        XCTAssertEqual(forward.mediaTime(atClipTime: 0.75), 0.75, accuracy: 1e-12)
        store.toggleReverseSelection()
        let clip = try XCTUnwrap(store.timelineModel.clips.first { $0.id == video })
        XCTAssertTrue(clip.reversed)
        XCTAssertEqual(clip.title, "◀ " + clip.name)
        // The first timeline instant shows the latest media (1.5 s), the last the earliest (0.5 s): the
        // thumbnail strip asks for these media times (the cache stays keyed by media time).
        XCTAssertEqual(clip.mediaTime(atClipTime: clip.sourceIn), 1.5, accuracy: 1e-9)
        XCTAssertEqual(clip.mediaTime(atClipTime: clip.sourceIn + (clip.end - clip.start) * clip.speed), 0.5,
                       accuracy: 1e-9)
        XCTAssertEqual(clip.mediaEnd, 2, accuracy: 1e-9, "the 2 s movie's end is the mirror")
    }
}
