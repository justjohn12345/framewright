import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Linked transitions through the store (open finding 2): Delete removes a dissolve with its
/// linked crossfade as one undo step, Option-Delete and "Delete This Transition Only" remove one;
/// duration changes (inspector, handle drag) change both unless "Also change the linked
/// transition" is off, which is remembered. Also the Transition inspector's cut and offsets
/// (finding 1b), the through-edit note (1a) and the timeline's right-click menu.
@MainActor
final class LinkedTransitionStoreTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "linked-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var v1: VETrackID { store.videoTracks.first?.trackID ?? 0 }
    private var a1: VETrackID { store.audioTracks.first?.trackID ?? 0 }

    @discardableResult
    private func place(_ asset: VEAssetInfo, at: Double, from inSeconds: Double, to outSeconds: Double,
                       video: VETrackID = 0, audio: VETrackID = 0) throws -> VEClipID {
        XCTAssertTrue(store.place(asset: asset.assetID, at: store.frameTime(at), videoTrack: video, audioTrack: audio,
                                  sourceIn: CMTime(seconds: inSeconds, preferredTimescale: 600),
                                  sourceOut: CMTime(seconds: outSeconds, preferredTimescale: 600), overwrite: true),
                      store.statusMessage ?? "")
        return try XCTUnwrap(store.selection.first)
    }

    /// Picture + sound pairs A [0, 0.8 s) and B [0.8, 1.6 s) on V1/A1, linked, from separate
    /// source ranges; a dissolve and its crossfade added as one step (the default preference).
    /// Returns (dissolve, crossfade).
    private func linkedTransitions() async throws -> (VETransitionID, VETransitionID) {
        let (movie, tone) = try await fixture.importMedia()
        let va = try place(movie, at: 0, from: 0, to: 0.8, video: v1)
        let aa = try place(tone, at: 0, from: 0, to: 0.8, audio: a1)
        let vb = try place(movie, at: 0.8, from: 1.2, to: 2, video: v1)
        let ab = try place(tone, at: 0.8, from: 1.2, to: 2, audio: a1)
        XCTAssertTrue(store.engine.linkClip(va, withClip: aa).ok)
        XCTAssertTrue(store.engine.linkClip(vb, withClip: ab).ok)
        XCTAssertTrue(store.addTransition(.crossDissolve, from: va, to: vb, frames: 12), store.statusMessage ?? "")
        let dissolve = try XCTUnwrap(store.selectedTransitionID)
        let crossfade = try XCTUnwrap(store.linkedTransition(of: dissolve))
        XCTAssertEqual(store.linkedTransition(of: crossfade), dissolve)
        return (dissolve, crossfade)
    }

    func testDeleteRemovesTheLinkedPairAndOptionDeleteOnlyOne() async throws {
        let (dissolve, crossfade) = try await linkedTransitions()
        store.focusArea = .timeline
        store.selection = []
        store.selectedTransitionID = crossfade
        store.deleteSelection(ripple: false)
        XCTAssertTrue(store.sequence.transitions.isEmpty, "Delete on either removes both")
        XCTAssertNil(store.selectedTransitionID)
        XCTAssertEqual(store.undoActionName, "Remove Transitions")
        store.undo()
        XCTAssertEqual(store.sequence.transitions.count, 2, "one undo step")

        // Option-Delete: the key maps to its own action, which removes only the selected one.
        XCTAssertEqual(KeyboardController.action(keyCode: 51, characters: "\u{7f}", modifiers: .option),
                       .deleteTransitionOnly)
        XCTAssertEqual(KeyboardController.action(keyCode: 51, characters: "\u{7f}", modifiers: []), .delete)
        store.selectedTransitionID = dissolve
        KeyboardController(store: store).perform(.deleteTransitionOnly, on: store)
        XCTAssertNil(store.engine.transitionInfo(dissolve))
        XCTAssertNotNil(store.engine.transitionInfo(crossfade))
        store.undo()

        // The inspector's buttons.
        store.selectedTransitionID = crossfade
        XCTAssertEqual(store.inspector.linkedTransition, dissolve)
        store.inspector.deleteTransition(includingLinked: false)
        XCTAssertNil(store.engine.transitionInfo(crossfade))
        XCTAssertNotNil(store.engine.transitionInfo(dissolve))
        store.undo()
        store.selectedTransitionID = crossfade
        store.inspector.deleteTransition()
        XCTAssertTrue(store.sequence.transitions.isEmpty)
    }

    func testDurationChangesFollowTheLinkedTransitionUnlessTurnedOff() async throws {
        let (dissolve, crossfade) = try await linkedTransitions()
        store.selection = []
        store.selectedTransitionID = dissolve
        XCTAssertTrue(store.resizesLinkedTransitions, "on by default")
        store.inspector.commitText(.transitionDuration, "20")
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(dissolve)).duration), 20)
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(crossfade)).duration), 20,
                       "the linked crossfade follows")
        XCTAssertEqual(store.undoActionName, "Change Transition Durations")
        store.undo()
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(crossfade)).duration), 12, "one undo")

        // Turned off (and remembered in the preferences): only the selected one changes.
        store.resizesLinkedTransitions = false
        XCTAssertFalse(EditingPreferences(defaults: store.defaults).resizeLinkedTransitions)
        XCTAssertFalse(store.editingPreferences.resizeLinkedTransitions, "the observed preferences follow")
        store.inspector.commitText(.transitionDuration, "16")
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(dissolve)).duration), 16)
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(crossfade)).duration), 12)

        // A handle drag follows the same choice: on again, the pair resizes as one step.
        store.resizesLinkedTransitions = true
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let band = try XCTUnwrap(model.transition(id: dissolve))
        let row = try XCTUnwrap(model.layout(forTrack: v1))
        let tail = CGPoint(x: model.x(forTime: band.end) - 2, y: row.y + 5)
        XCTAssertEqual(model.hitTest(tail), .transitionTail(dissolve))
        gestures.changed(location: tail, startLocation: tail, modifiers: [])
        let moved = CGPoint(x: tail.x + 3 * CGFloat(model.pixelsPerSecond) / 30, y: tail.y) // +3 frames each side
        gestures.changed(location: moved, startLocation: tail, modifiers: [])
        gestures.ended()
        let draggedLength = store.frames(try XCTUnwrap(store.engine.transitionInfo(dissolve)).duration)
        XCTAssertGreaterThan(draggedLength, 16)
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(crossfade)).duration), draggedLength,
                       "the handle drag resized both")
        store.undo()
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(dissolve)).duration), 16)
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(crossfade)).duration), 12)
    }

    func testTheTransitionInspectorShowsTheCutAndTheOffsets() async throws {
        let (dissolve, _) = try await linkedTransitions()
        store.selection = []
        store.selectedTransitionID = dissolve
        let timing = try XCTUnwrap(store.inspector.transitionTiming)
        XCTAssertEqual(timing.cut, store.frameTime(0.8), "the cut is the outgoing clip's end")
        XCTAssertEqual(timing.framesBefore, 6)
        XCTAssertEqual(timing.framesAfter, 6)
        let fd = CMTime(value: 1, timescale: 30)
        XCTAssertEqual(timing.cutText(frameDuration: fd), "Cut at 00:00:00:24")

        // The offsets in each duration display (an odd length: the extra frame goes after the cut).
        let odd = TransitionTiming(cut: CMTime(value: 133, timescale: 30), framesBefore: 7, framesAfter: 8)
        XCTAssertEqual(odd.cutText(frameDuration: fd), "Cut at 00:00:04:13")
        XCTAssertEqual(odd.offsetsText(frameDuration: fd, display: .frames), "\u{2212}7f / +8f")
        XCTAssertEqual(odd.offsetsText(frameDuration: fd, display: .timecode), "\u{2212}00:00:00:07 / +00:00:00:08")
        XCTAssertEqual(odd.offsetsText(frameDuration: fd, display: .seconds), "\u{2212}0.23 s / +0.27 s")
        let fromRange = TransitionTiming(start: CMTime(value: 126, timescale: 30), end: CMTime(value: 141, timescale: 30),
                                         cut: CMTime(value: 133, timescale: 30), frameDuration: fd)
        XCTAssertEqual(fromRange, odd)
    }

    func testADissolveAtAThroughEditSaysSoInTheStatusLine() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try place(movie, at: 0, from: 0, to: 2, video: v1)
        store.selection = [clip]
        store.playheadTime = store.frameTime(1)
        store.splitAtPlayhead()
        XCTAssertEqual(store.clips.count, 2)
        store.addTransitionAtPlayhead(.crossDissolve)
        XCTAssertEqual(store.sequence.transitions.count, 1)
        XCTAssertTrue(store.statusMessage?.contains("Both sides show the same frames here; trim or move one side to see the dissolve")
            == true, store.statusMessage ?? "")
    }

    func testTheTimelinesRightClickMenuSelectsAndOffersTheTransitionActions() async throws {
        let (dissolve, crossfade) = try await linkedTransitions()
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let band = try XCTUnwrap(model.transition(id: crossfade))
        let row = try XCTUnwrap(model.layout(forTrack: a1))
        let point = CGPoint(x: model.x(forTime: (band.start + band.end) / 2), y: row.y + 5)
        store.selectedTransitionID = nil
        store.selection = [try XCTUnwrap(store.clips.keys.first)]
        let items = gestures.contextMenuItems(at: point)
        XCTAssertEqual(store.selectedTransitionID, crossfade, "the right-click selects what is under the pointer")
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertEqual(items.filter { !$0.isSeparator }.map(\.title),
                       ["Delete Transitions", "Delete This Transition Only", "Transition Duration…"])
        try XCTUnwrap(items.first { $0.title == "Delete This Transition Only" }).action()
        XCTAssertNil(store.engine.transitionInfo(crossfade))
        XCTAssertNotNil(store.engine.transitionInfo(dissolve))

        // On a clip: the clip's actions; on empty space: no menu.
        let clipRow = try XCTUnwrap(model.layout(forTrack: v1))
        let clipItems = gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 0.3), y: clipRow.y + 40))
        XCTAssertEqual(clipItems.filter { !$0.isSeparator }.map(\.title), ["Delete", "Ripple Delete", "Unlink", "Speed/Duration…"])
        XCTAssertFalse(store.selection.isEmpty)
        XCTAssertTrue(gestures.contextMenuItems(at: CGPoint(x: model.x(forTime: 5), y: clipRow.y + 40)).isEmpty)
    }
}
