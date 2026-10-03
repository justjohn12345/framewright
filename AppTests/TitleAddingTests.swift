import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Adding titles, lower thirds and colour mattes (titles design section 9; slice 1): Clip > Add Title (⌃T), Add Lower
/// Third (⇧⌃T) and Add Colour Matte put the preset at the playhead above the target video track (a new track when
/// none is free), one undo step, select it and ask the inspector to focus the title's text; the items are disabled
/// during a drag; ⌃T is the keyboard controller's, so a text field keeps its own.
@MainActor
final class TitleAddingTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// The 2 s movie on V1 at 0, V1 targeted.
    private func footage() async throws -> VEClipID {
        let media = try await fixture.importMedia()
        let clip = try fixture.placeMovie(media.movie, at: 0)
        store.targetVideoTrackID = try XCTUnwrap(store.videoTracks.first).trackID
        return clip
    }

    func testAddTitleGoesAboveTheTargetAndIsOneUndoStep() async throws {
        let movie = try await footage()
        XCTAssertEqual(store.videoTracks.count, 2)
        store.playheadTime = frames(15)
        let requestsBefore = store.inspectorFocusRequest?.serial ?? 0
        XCTAssertTrue(store.canAddGenerated)
        XCTAssertTrue(store.addGenerated(.title))
        let title = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(store.selection.count, 1, "the new title alone is selected")
        let info = try XCTUnwrap(store.clips[title])
        XCTAssertEqual(info.generatorKind, .title)
        XCTAssertEqual(info.trackID, store.videoTracks[1].trackID, "on V2, over the footage")
        XCTAssertEqual(info.timelineStart, frames(15))
        XCTAssertEqual(info.duration, CMTime(value: 5, timescale: 1))
        XCTAssertEqual(info.name, "Title")
        XCTAssertEqual(store.undoActionName, "Add Title")
        XCTAssertEqual(store.layout.inspectorTab, .inspector)
        XCTAssertEqual(store.inspectorFocusRequest?.field, .titleText)
        XCTAssertEqual(store.inspectorFocusRequest?.serial, requestsBefore + 1)
        XCTAssertEqual(store.clips[movie]?.duration, frames(60), "nothing overwritten")
        XCTAssertFalse(store.assets.contains { $0.generatorKind != .none }, "the bin shows media only")

        // V2 is taken there: a lower third goes on a new V3, in the same undo step.
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let lowerThird = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(store.videoTracks.count, 3)
        XCTAssertEqual(store.clips[lowerThird]?.trackID, store.videoTracks[2].trackID)
        XCTAssertEqual(store.clips[lowerThird]?.name, "Name")
        XCTAssertEqual(store.undoActionName, "Add Lower Third")
        store.undo()
        XCTAssertEqual(store.videoTracks.count, 2, "one undo takes the clip and its track back")
        XCTAssertNil(store.clips[lowerThird])
        store.undo()
        XCTAssertNil(store.clips[title])
        XCTAssertEqual(store.undoActionName, "Overwrite")
    }

    func testAColourMatteIsSelectedWithoutAskingForText() async throws {
        _ = try await footage()
        store.playheadTime = frames(90) // after the footage: V1 is free
        let requests = store.inspectorFocusRequest
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let matte = try XCTUnwrap(store.clips[try XCTUnwrap(store.selection.first)])
        XCTAssertEqual(matte.generatorKind, .colourMatte)
        XCTAssertEqual(matte.trackID, store.videoTracks[1].trackID, "above the target, even where V1 is free")
        XCTAssertEqual(matte.name, "Colour Matte")
        XCTAssertEqual(store.inspectorFocusRequest, requests, "a matte has no text to focus")
        XCTAssertEqual(store.undoActionName, "Add Colour Matte")
    }

    func testTheTargetTrackDecides() async throws {
        _ = try await footage()
        store.playheadTime = frames(0)
        store.targetVideoTrackID = store.videoTracks[1].trackID // V2 targeted: above it, a new V3
        XCTAssertTrue(store.addGenerated(.title))
        XCTAssertEqual(store.videoTracks.count, 3)
        XCTAssertEqual(store.clips[try XCTUnwrap(store.selection.first)]?.trackID, store.videoTracks[2].trackID)
        // A locked track above the target is passed over.
        store.targetVideoTrackID = store.videoTracks[0].trackID
        XCTAssertTrue(store.engine.setTrack(store.videoTracks[1].trackID, locked: true).ok)
        store.playheadTime = frames(180)
        XCTAssertTrue(store.addGenerated(.title))
        XCTAssertEqual(store.clips[try XCTUnwrap(store.selection.first)]?.trackID, store.videoTracks[2].trackID)
    }

    func testTheItemsWaitForADragAndADropOnSoundIsRefused() async throws {
        _ = try await footage()
        store.cancelActiveGesture = {}
        XCTAssertFalse(store.canAddGenerated)
        let changes = store.changeCount
        XCTAssertFalse(store.addGenerated(.title))
        XCTAssertEqual(store.statusMessage, "Finish the current drag first.")
        XCTAssertEqual(store.changeCount, changes)
        store.cancelActiveGesture = nil
        XCTAssertTrue(store.canAddGenerated)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertFalse(store.dropGenerated(.title, onTrack: a1, at: 0, insert: false))
        XCTAssertEqual(store.statusMessage, "Drop a title on a video track.")
        XCTAssertEqual(store.changeCount, changes)
    }

    func testADroppedTileOverwritesOrInserts() async throws {
        let movie = try await footage()
        let v1 = store.videoTracks[0].trackID
        XCTAssertTrue(store.dropGenerated(.lowerThird, onTrack: v1, at: 1, insert: false))
        let lowerThird = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(store.clips[lowerThird]?.timelineStart, frames(30))
        XCTAssertEqual(store.clips[movie]?.duration, frames(30), "the footage is cut where it lands")
        store.undo()
        XCTAssertTrue(store.dropGenerated(.colourMatte, onTrack: v1, at: 0, insert: true))
        XCTAssertEqual(store.clips[movie]?.timelineStart, CMTime(value: 5, timescale: 1), "rippled by the matte")
    }

    /// A sequence without video tracks (a project file can have none; the app keeps one of each kind) gets one with
    /// its first title (review fix round, finding 14).
    func testATitleInASequenceWithoutVideoTracksMakesOne() async throws {
        let saved = fixture.directory.appendingPathComponent("no-video.framewright")
        try store.save(to: saved)
        var project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any])
        var sequences = try XCTUnwrap(project["sequences"] as? [[String: Any]])
        sequences[0]["videoTracks"] = [Any]()
        project["sequences"] = sequences
        try JSONSerialization.data(withJSONObject: project).write(to: saved)
        try store.open(url: saved)
        XCTAssertTrue(store.videoTracks.isEmpty, store.engine.loadWarnings.joined(separator: " "))
        XCTAssertTrue(store.canAddGenerated)
        XCTAssertTrue(store.addGenerated(.title))
        XCTAssertEqual(store.videoTracks.count, 1)
        XCTAssertEqual(store.clips[try XCTUnwrap(store.selection.first)]?.trackID, store.videoTracks[0].trackID)
        XCTAssertEqual(store.videoTracks[0].name, "V1")
        store.undo()
        XCTAssertTrue(store.videoTracks.isEmpty, "one undo takes the title and its track")
    }

    func testControlTIsTheKeyboardControllers() async throws {
        XCTAssertEqual(KeyboardController.action(keyCode: 17, characters: "t", modifiers: .control), .addTitle)
        XCTAssertEqual(KeyboardController.action(keyCode: 17, characters: "T", modifiers: [.control, .shift]),
                       .addLowerThird)
        XCTAssertEqual(KeyboardController.action(keyCode: 17, characters: "t", modifiers: [.control, .shift]),
                       .addLowerThird)
        XCTAssertNil(KeyboardController.action(keyCode: 17, characters: "t", modifiers: []))
        XCTAssertNil(KeyboardController.action(keyCode: 17, characters: "t", modifiers: .command))
        XCTAssertNil(KeyboardController.action(keyCode: 17, characters: "t", modifiers: [.control, .option]))
        XCTAssertFalse(KeyboardController.Action.addTitle.isTransportOrCancel, "editor window only")
        XCTAssertTrue(KeyboardController.Action.addTitle.ignoresRepeat)
        XCTAssertTrue(KeyboardController.Action.addLowerThird.ignoresRepeat)
        _ = try await footage()
        store.playheadTime = frames(0)
        let keyboard = KeyboardController(store: store)
        keyboard.perform(.addTitle, on: store)
        XCTAssertEqual(store.clips[try XCTUnwrap(store.selection.first)]?.generatorKind, .title)
        keyboard.perform(.addLowerThird, on: store)
        XCTAssertEqual(store.undoActionName, "Add Lower Third")
        // A text field being edited keeps Control-T (transpose).
        XCTAssertFalse(KeyboardController.shouldHandleKeys(firstResponder: NSTextView()))
    }
}
