import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Transitions and gain in the timeline: hit testing of the gain line, a transition on lane 0
/// fitted to the media, selected by a double-click and deleted; the gain drag (synthetic points);
/// transition drops with their feedback; the linked-crossfade preference; and the menu commands'
/// refusals. Geometry at the default zoom (50 pt/s, no scroll): rows V2 y 0...64, V1 66...130 (its
/// lanes below it when it has clips).
@MainActor
final class TimelineEffectsTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "effects-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private func drag(_ gestures: TimelineGestureController, from: CGPoint, through points: [CGPoint],
                      modifiers: NSEvent.ModifierFlags = [], end: Bool = true) {
        gestures.changed(location: from, startLocation: from, modifiers: modifiers)
        for point in points {
            gestures.changed(location: point, startLocation: from, modifiers: modifiers)
        }
        if end { gestures.ended() }
    }

    /// Places source [inSeconds, outSeconds) of `asset` at `at` on the given tracks (0: none).
    @discardableResult
    private func place(_ asset: VEAssetInfo, at: Double, from inSeconds: Double, to outSeconds: Double,
                       video: VETrackID = 0, audio: VETrackID = 0) throws -> VEClipID {
        XCTAssertTrue(store.place(asset: asset.assetID, at: store.frameTime(at), videoTrack: video, audioTrack: audio,
                                  sourceIn: CMTime(seconds: inSeconds, preferredTimescale: 600),
                                  sourceOut: CMTime(seconds: outSeconds, preferredTimescale: 600), overwrite: true),
                      store.statusMessage ?? "")
        return try XCTUnwrap(store.selection.first)
    }

    private var v1: VETrackID { store.videoTracks.first?.trackID ?? 0 }
    private var a1: VETrackID { store.audioTracks.first?.trackID ?? 0 }

    // MARK: Hit testing

    func testHitTestingTheGainLine() throws {
        var model = TimelineViewModel()
        model.pixelsPerSecond = 100
        model.frameSeconds = 1.0 / 30.0
        model.tracks = [
            .init(id: 10, kind: .video, index: 0, name: "V1"),
            .init(id: 20, kind: .audio, index: 0, name: "A1"),
        ]
        model.clips = [
            .init(id: 1, trackID: 10, start: 0, end: 4),
            .init(id: 3, trackID: 20, start: 0, end: 4, isAudio: true, gainDb: 0, fadeIn: 1, fadeOut: 0.5),
        ]
        let v1Top: CGFloat = 0
        let a1Top = TimelineViewModel.videoTrackHeight + TimelineViewModel.trackSpacing
        let clip = try XCTUnwrap(model.clip(id: 3))
        // Fades are lane-0 spans now: the clip's top corners select and trim it like any clip.
        XCTAssertEqual(model.hitTest(CGPoint(x: 103, y: a1Top + 5)), .clipBody(3))
        XCTAssertEqual(model.hitTest(CGPoint(x: 3, y: a1Top + 5)), .clipHead(3))
        // The gain line: 0 dB at 24/84 of the content height below the label.
        let content = try XCTUnwrap(model.contentRect(forClip: clip))
        let gainY = TimelineViewModel.gainY(0, in: content)
        XCTAssertEqual(gainY, content.minY + content.height * 24 / 84, accuracy: 1e-9)
        XCTAssertEqual(model.hitTest(CGPoint(x: 200, y: gainY + 2)), .gainLine(3))
        XCTAssertEqual(model.hitTest(CGPoint(x: 200, y: gainY + 8)), .clipBody(3))
        XCTAssertEqual(TimelineViewModel.gainY(-60, in: content), content.maxY, accuracy: 1e-9)
        XCTAssertEqual(TimelineViewModel.gainY(100, in: content), content.minY, accuracy: 1e-9, "clamped")
        // Video clips have no gain line.
        XCTAssertEqual(model.hitTest(CGPoint(x: 200, y: v1Top + 20)), .clipBody(1))
    }

    // MARK: Hover

    /// Review finding 7: the cursor is set when the hovered kind of thing changes, not on every
    /// pointer event, and leaving the track area restores the arrow.
    func testHoverSetsTheCursorOnlyWhenItsShapeChanges() async throws {
        let (_, tone) = try await fixture.importMedia()
        let clip = try place(tone, at: 0, from: 0, to: 3, audio: a1) // x 0...150 on A1 (y 132...180)
        let gestures = TimelineGestureController(store: store)
        var applied: [TimelineGestureController.PointerCursor] = []
        gestures.applyCursor = { applied.append($0) }
        let model = store.timelineModel
        let content = try XCTUnwrap(model.contentRect(forClip: try XCTUnwrap(model.clip(id: clip))))
        let lineY = TimelineViewModel.gainY(0, in: content)
        // Twenty moves over the body, then twenty along the gain line, then twenty over the body.
        for x in stride(from: 40.0, to: 60.0, by: 1) { gestures.hover(at: CGPoint(x: x, y: lineY + 10)) }
        for x in stride(from: 40.0, to: 60.0, by: 1) { gestures.hover(at: CGPoint(x: x, y: lineY)) }
        for x in stride(from: 40.0, to: 60.0, by: 1) { gestures.hover(at: CGPoint(x: x, y: lineY + 10)) }
        XCTAssertEqual(applied, [.arrow, .resizeUpDown, .arrow], "one change per shape, not per event")
        XCTAssertEqual(gestures.cursorChanges, 3)
        // Onto the clip's tail edge and out of the area: the arrow comes back once.
        gestures.hover(at: CGPoint(x: 148, y: lineY + 10))
        gestures.hover(at: CGPoint(x: 149, y: lineY + 10))
        gestures.hover(at: nil)
        XCTAssertEqual(applied, [.arrow, .resizeUpDown, .arrow, .resizeLeftRight, .arrow])
        XCTAssertNil(gestures.cursor)
        // Leaving while the arrow is up changes nothing (another view's cursor is not fought).
        gestures.hover(at: CGPoint(x: 50, y: lineY + 10))
        gestures.hover(at: nil)
        XCTAssertEqual(applied.count, 6)
        XCTAssertEqual(applied.last, .arrow)
    }

    // MARK: Drags

    /// A transition is a bar on lane 0: a double-click selects it and asks the inspector to focus its
    /// duration, Delete removes it, an edge dragged far beyond the media stops where the clips'
    /// media ends (the engine fits it and says so). The edges and the fade conversion are covered
    /// by `EffectLanesTimelineTests`.
    func testATransitionOnLaneZeroIsFittedSelectedAndDeleted() async throws {
        let (movie, _) = try await fixture.importMedia()
        // A: source [0, 1) at 0; B: source [1, 2) at 1: 30 frames of media beyond the cut each way.
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1)
        let added = store.engine.addTransition(fromClip: a, toClip: b, duration: CMTime(value: 10, timescale: 30))
        XCTAssertTrue(added.ok, added.message)
        let transition = try XCTUnwrap(added.createdIDs.first?.int64Value)
        store.refreshModel()
        let model = store.timelineModel
        let layout = try XCTUnwrap(model.layout(forTrack: v1))
        let laneY = try XCTUnwrap(layout.laneY(0)) + 7
        func after() -> Int64 { store.frames(store.engine.spanInfo(transition)?.shareAfterCut ?? .zero) }
        let gestures = TimelineGestureController(store: store)
        // The end edge (x 58.3) far to the right: B has 30 frames before its in point; fitted, said so.
        drag(gestures, from: CGPoint(x: 57.5, y: laneY), through: [CGPoint(x: 400, y: laneY)], end: false)
        XCTAssertEqual(store.selectedTransitionID, transition)
        XCTAssertTrue(store.isGestureActive)
        XCTAssertEqual(after(), 30, "all the media B has before its in point")
        XCTAssertTrue(store.statusMessage?.contains("shortened") == true, store.statusMessage ?? "")
        gestures.ended()
        XCTAssertFalse(store.engine.isCoalescing)
        store.undo()
        XCTAssertEqual(after(), 5, "one undo step")

        // Double-click selects the transition and asks the inspector to focus its duration.
        store.selectedTransitionID = nil
        gestures.changed(location: CGPoint(x: 50, y: laneY), startLocation: CGPoint(x: 50, y: laneY), modifiers: [],
                         clickCount: 2)
        gestures.ended()
        XCTAssertEqual(store.selectedTransitionID, transition)
        XCTAssertEqual(store.inspectorFocusRequest?.field, .transitionDuration)
        XCTAssertNotNil(store.inspector.transition)
        // Delete removes it.
        store.focusArea = .timeline
        store.deleteSelection(ripple: false)
        XCTAssertNil(store.engine.transitionInfo(transition))
    }

    func testGainLineDragWithFineControlAndTooltip() async throws {
        let (_, tone) = try await fixture.importMedia()
        let clip = try place(tone, at: 0, from: 0, to: 3, audio: a1)
        let model = store.timelineModel
        let content = try XCTUnwrap(model.contentRect(forClip: try XCTUnwrap(model.clip(id: clip))))
        let lineY = TimelineViewModel.gainY(0, in: content)
        let dbPerPoint = (TimelineViewModel.gainMaxDb - TimelineViewModel.gainMinDb) / Double(content.height)
        let gestures = TimelineGestureController(store: store)
        // Down 5 pt.
        drag(gestures, from: CGPoint(x: 75, y: lineY), through: [CGPoint(x: 75, y: lineY + 2), CGPoint(x: 75, y: lineY + 5)],
             end: false)
        let expected = (-5 * dbPerPoint * 10).rounded() / 10
        XCTAssertEqual(store.clips[clip]?.audioParams.gainDb ?? 0, expected, accuracy: 1e-9)
        XCTAssertEqual(gestures.gainTooltip?.text, TimelineGestureController.gainText(expected))
        XCTAssertTrue(gestures.gainTooltip?.text.hasSuffix("dB") == true)
        gestures.ended()
        XCTAssertNil(gestures.gainTooltip)
        XCTAssertEqual(store.undoActionName, "Change Audio Settings")

        // Option: ten times finer, and Option on the gain line does not grab the playhead.
        let newY = TimelineViewModel.gainY(expected, in: content)
        drag(gestures, from: CGPoint(x: 75, y: newY), through: [CGPoint(x: 75, y: newY + 5)], modifiers: .option,
             end: false)
        if case .gain = gestures.drag {} else { XCTFail("expected a gain drag, got \(gestures.drag)") }
        let fine = ((expected - 5 * dbPerPoint / 10) * 10).rounded() / 10
        XCTAssertEqual(store.clips[clip]?.audioParams.gainDb ?? 0, fine, accuracy: 1e-9)
        gestures.ended()
        store.undo()
        XCTAssertEqual(store.clips[clip]?.audioParams.gainDb ?? 0, expected, accuracy: 1e-9, "one step per drag")

        // Up far: clamped to the top of the line's range.
        drag(gestures, from: CGPoint(x: 75, y: newY), through: [CGPoint(x: 75, y: newY - 400)])
        XCTAssertEqual(store.clips[clip]?.audioParams.gainDb ?? 0, TimelineViewModel.gainMaxDb, accuracy: 1e-9)

        // Hovering the line shows its value.
        gestures.hover(at: CGPoint(x: 75, y: TimelineViewModel.gainY(TimelineViewModel.gainMaxDb, in: content) + 1))
        XCTAssertEqual(gestures.gainTooltip?.text, "+24.0 dB")
        gestures.hover(at: nil)
        XCTAssertNil(gestures.gainTooltip)
    }

    // MARK: Transitions from the panel and the menu

    func testTransitionDropFeedbackAndRefusal() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1)
        // C ends at the end of the media and D starts at its start: no transition fits.
        let c = try place(movie, at: 4, from: 1, to: 2, video: v1)
        let d = try place(movie, at: 5, from: 0, to: 1, video: v1)
        let gestures = TimelineGestureController(store: store)

        let target = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: CGPoint(x: 55, y: 100)))
        XCTAssertEqual(gestures.transitionDrop, target)
        XCTAssertEqual(target.fromClipID, a)
        XCTAssertEqual(target.toClipID, b)
        XCTAssertTrue(target.allowed)
        XCTAssertEqual(target.frames, 30, "the default 1 s fits the 30 frames of media on each side")
        XCTAssertNil(gestures.transitionDragUpdated(kind: .audioCrossfade, at: CGPoint(x: 55, y: 100)),
                     "a crossfade does not go on a video track")
        XCTAssertNil(gestures.transitionDragUpdated(kind: .crossDissolve, at: CGPoint(x: 150, y: 100)),
                     "no cut within reach")

        let refused = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: CGPoint(x: 248, y: 100)))
        XCTAssertEqual(refused.fromClipID, c)
        XCTAssertEqual(refused.toClipID, d)
        XCTAssertFalse(refused.allowed)
        XCTAssertTrue(refused.message.contains("clip.mov"), refused.message)
        XCTAssertTrue(refused.message.contains("after its out point"), refused.message)
        XCTAssertFalse(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 248, y: 100)))
        XCTAssertEqual(store.statusMessage, refused.message, "a refused drop says why")
        XCTAssertNil(gestures.transitionDrop)
        XCTAssertTrue(store.sequence.transitions.isEmpty)

        // A shorter default is used as is; the drop adds and selects the transition.
        store.defaults.set(0.5, forKey: EditingPreferences.defaultTransitionSecondsKey)
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 52, y: 100)))
        let added = try XCTUnwrap(store.sequence.transitions.first)
        XCTAssertEqual(store.frames(added.duration), 15)
        XCTAssertEqual(store.selectedTransitionID, added.transitionID)
        XCTAssertEqual(store.undoActionName, "Add Transition")

        gestures.transitionDragExited()
        XCTAssertNil(gestures.transitionDrop)
    }

    /// Two linked picture+sound pairs meeting at 1 s on V1/A1.
    private func linkedPairs() async throws -> (VEClipID, VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let va = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let aa = try place(tone, at: 0, from: 0, to: 1, audio: a1)
        let vb = try place(movie, at: 1, from: 1, to: 2, video: v1)
        let ab = try place(tone, at: 1, from: 1, to: 2, audio: a1)
        XCTAssertTrue(store.engine.linkClip(va, withClip: aa).ok)
        XCTAssertTrue(store.engine.linkClip(vb, withClip: ab).ok)
        return (va, vb)
    }

    func testLinkedCrossfadePreference() async throws {
        let (va, vb) = try await linkedPairs()
        // Always (the default): dissolve + crossfade, one undo step.
        store.selection = []
        store.playheadTime = CMTime(value: 25, timescale: 30)
        store.targetVideoTrackID = v1
        store.addTransitionAtPlayhead(.crossDissolve)
        XCTAssertEqual(store.sequence.transitions.count, 2, store.statusMessage ?? "")
        XCTAssertEqual(store.undoActionName, "Add Transitions")
        XCTAssertEqual(store.frames(store.sequence.transitions[0].duration), 30, "the default duration")
        store.undo()
        XCTAssertTrue(store.sequence.transitions.isEmpty, "both came off in one undo")

        // Never: the dissolve alone.
        store.defaults.set(LinkedCrossfadeMode.never.rawValue, forKey: EditingPreferences.linkedCrossfadeKey)
        XCTAssertTrue(store.addTransition(.crossDissolve, from: va, to: vb))
        XCTAssertEqual(store.sequence.transitions.count, 1)
        store.undo()

        // Ask: waits for the answer.
        store.defaults.set(LinkedCrossfadeMode.ask.rawValue, forKey: EditingPreferences.linkedCrossfadeKey)
        XCTAssertFalse(store.addTransition(.crossDissolve, from: va, to: vb))
        XCTAssertEqual(store.pendingLinkedTransition?.fromClipID, va)
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        store.resolvePendingTransition(includeLinked: true)
        XCTAssertNil(store.pendingLinkedTransition)
        XCTAssertEqual(store.sequence.transitions.count, 2)
        store.undo()
        XCTAssertFalse(store.addTransition(.crossDissolve, from: va, to: vb))
        store.resolvePendingTransition(includeLinked: nil) // cancelled
        XCTAssertTrue(store.sequence.transitions.isEmpty)

        // The audio crossfade alone from its menu item, on the target audio track.
        store.targetAudioTrackID = a1
        store.addTransitionAtPlayhead(.audioCrossfade)
        XCTAssertEqual(store.sequence.transitions.count, 1)
        XCTAssertEqual(store.sequence.transitions.first?.trackID, a1)
    }

    /// Review finding 1 through the store: the dissolve is fitted to its own cut and the linked
    /// crossfade to its (tighter) one, in one undo step; the status line names the shortening.
    func testALinkedCrossfadeIsFittedToItsOwnCut() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let va = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let aa = try place(tone, at: 0, from: 0, to: 1, audio: a1)
        let vb = try place(movie, at: 1, from: 1, to: 2, video: v1)
        // The incoming sound starts 0.1 s into the file: 3 frames of media before its in point.
        let ab = try place(tone, at: 1, from: 0.1, to: 1.1, audio: a1)
        XCTAssertTrue(store.engine.linkClip(va, withClip: aa).ok)
        XCTAssertTrue(store.engine.linkClip(vb, withClip: ab).ok)
        let audioLimit = store.engine.transitionLimit(fromClip: aa, toClip: ab).maximumFrames
        XCTAssertGreaterThan(audioLimit, 0)
        XCTAssertLessThan(audioLimit, 30)
        XCTAssertGreaterThanOrEqual(store.engine.transitionLimit(fromClip: va, toClip: vb).maximumFrames, 30)
        let before = store.changeCount
        XCTAssertTrue(store.addTransition(.crossDissolve, from: va, to: vb), store.statusMessage ?? "")
        XCTAssertEqual(store.changeCount, before + 1, "one undo step")
        func frames(onTrack track: VETrackID) -> Int64? {
            store.sequence.transitions.first { $0.trackID == track }.map { store.frames($0.duration) }
        }
        XCTAssertEqual(frames(onTrack: v1), 30, "the dissolve keeps the default 1 s: its cut has the media")
        XCTAssertEqual(frames(onTrack: a1), audioLimit, "the crossfade is as long as its own cut allows")
        XCTAssertTrue(store.statusMessage?.contains("linked clips' transition was shortened") == true,
                      store.statusMessage ?? "nil")
        store.undo()
        XCTAssertTrue(store.sequence.transitions.isEmpty, "both came off in one undo")
    }

    /// Review finding 5: when the linked audio's cut cannot take a crossfade, the dissolve is
    /// added alone and the status line says why.
    func testASkippedLinkedCrossfadeIsExplained() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let va = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let aa = try place(tone, at: 0, from: 2, to: 3, audio: a1) // ends where the file ends
        let vb = try place(movie, at: 1, from: 1, to: 2, video: v1)
        let ab = try place(tone, at: 1, from: 0, to: 1, audio: a1) // starts where the file starts
        XCTAssertTrue(store.engine.linkClip(va, withClip: aa).ok)
        XCTAssertTrue(store.engine.linkClip(vb, withClip: ab).ok)
        XCTAssertEqual(store.engine.transitionLimit(fromClip: aa, toClip: ab).maximumFrames, 0)
        XCTAssertTrue(store.addTransition(.crossDissolve, from: va, to: vb), store.statusMessage ?? "")
        XCTAssertEqual(store.sequence.transitions.count, 1)
        XCTAssertEqual(store.sequence.transitions.first?.trackID, v1)
        XCTAssertTrue(store.statusMessage?.contains("The linked clips got no transition") == true,
                      store.statusMessage ?? "nil")
        XCTAssertTrue(store.statusMessage?.contains("tone.wav") == true, store.statusMessage ?? "nil")
    }

    /// Review finding 6: Add Cross Dissolve picks a cut at an edge of the clip under the playhead,
    /// else the nearest cut within 2 s, else refuses.
    func testTheCutAtThePlayheadPrefersTheClipUnderIt() async throws {
        let (movie, _) = try await fixture.importMedia()
        // A [0, 1) | B [1, 3), a gap, D [3.2, 4.2) | E [4.2, 5.2), a gap, F [8, 9) on its own.
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 0, to: 2, video: v1)
        let d = try place(movie, at: 3.2, from: 0, to: 1, video: v1)
        let e = try place(movie, at: 4.2, from: 1, to: 2, video: v1)
        try place(movie, at: 8, from: 0, to: 1, video: v1)
        func cut(at seconds: Double) -> [VEClipID]? {
            store.nearestCut(onTrack: v1, toSeconds: seconds).map { [$0.0, $0.1] }
        }
        XCTAssertEqual(cut(at: 2.9), [a, b], "B is under the playhead: its own cut, although D|E is nearer")
        XCTAssertEqual(cut(at: 1.0), [a, b], "on the cut itself")
        XCTAssertEqual(cut(at: 3.1), [d, e], "in the gap: the nearest cut within 2 s")
        XCTAssertEqual(cut(at: 4.6), [d, e])
        XCTAssertNil(cut(at: 6.5), "no cut within 2 s")
        XCTAssertNil(cut(at: 8.5), "F is under the playhead but meets no other clip, and no cut is near")

        store.targetVideoTrackID = v1
        store.selection = []
        store.playheadTime = store.frameTime(6.5)
        store.addTransitionAtPlayhead(.crossDissolve)
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        XCTAssertTrue(store.statusMessage?.hasPrefix("Move the playhead near a cut") == true, store.statusMessage ?? "nil")
        XCTAssertNil(store.selectedTransitionID)
    }

    func testCommandsDoNothingDuringAGestureAndReportRefusals() async throws {
        let (movie, _) = try await fixture.importMedia()
        _ = try place(movie, at: 0, from: 1, to: 2, video: v1)
        _ = try place(movie, at: 1, from: 0, to: 1, video: v1)
        store.targetVideoTrackID = v1
        store.cancelActiveGesture = {}
        store.addTransitionAtPlayhead(.crossDissolve)
        store.nudgeGain(1)
        store.showSpeedSheet()
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        XCTAssertNil(store.speedSheetClipIDs)
        store.cancelActiveGesture = nil
        // No media beyond the cut: refused with the reason (Shift+Cmd+D).
        store.addTransitionAtPlayhead(.crossDissolve)
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        XCTAssertTrue(store.statusMessage?.contains("No transition fits this cut") == true, store.statusMessage ?? "")
        store.nudgeGain(1)
        XCTAssertEqual(store.statusMessage, "Select an audio clip to change its gain.")
    }

    func testSpeedDurationSheet() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1)
        store.selection = [a]
        store.showSpeedSheet()
        XCTAssertEqual(store.speedSheetClipIDs, [a])
        let sheet = SpeedDurationModel(store: store, clipIDs: [a])
        XCTAssertEqual(sheet.entry, .percent)
        XCTAssertEqual(sheet.text, "100")
        sheet.text = "50"
        XCTAssertEqual(sheet.durations?.after, 60)
        // Without ripple the slower clip would run into B: refused, the sheet stays open.
        sheet.ripple = .none
        XCTAssertFalse(sheet.apply())
        XCTAssertNotNil(sheet.message)
        XCTAssertEqual(store.speedSheetClipIDs, [a])
        // Rippling the clip's own tracks moves B.
        sheet.ripple = .syncedTracks
        XCTAssertTrue(sheet.apply())
        XCTAssertNil(store.speedSheetClipIDs)
        XCTAssertEqual(store.frames(store.clips[a]?.duration ?? .zero), 60)
        XCTAssertEqual(store.clips[b]?.timelineStart.seconds ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Change Speed")
        // Ratio entry, and conversion between the forms.
        let ratio = SpeedDurationModel(store: store, clipIDs: [a])
        ratio.entry = .ratio
        XCTAssertEqual(ratio.text, "0.5")
        ratio.text = "1/3"
        ratio.entry = .percent
        XCTAssertEqual(ratio.text, "33.3")
        ratio.text = "fast"
        XCTAssertFalse(ratio.apply())
        XCTAssertTrue(ratio.message?.contains("not a speed") == true)
    }
}
