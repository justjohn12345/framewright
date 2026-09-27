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
        XCTAssertFalse(sheet.reversed)
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
        XCTAssertTrue(again.reversed)
        again.reversed = false
        XCTAssertTrue(again.apply())
        XCTAssertFalse(store.clips[video]?.reversed == true)
        XCTAssertEqual(store.clips[video]?.speedDenominator, 2, "the speed stays")
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
