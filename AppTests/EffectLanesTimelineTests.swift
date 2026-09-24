import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The effect lanes in the timeline (effect lanes round 2, items 1, 2 and 5): which lanes a track
/// shows and their heights, collapsing them (remembered by the layout), span hit testing, the span
/// selection (exclusive with the clips), body and edge drags with snapping, refusals with the free
/// range, range drags creating Motion, Opacity and Gain spans with their defaults, transitions on
/// lane 0 (asymmetric edges, sliding, a dissolve turned into a fade out, fades in), Delete and the
/// context menu, drops from the Effects tab, and Control-K. The movie is 2 s (60 frames) at 30 fps;
/// the long movie 10 s (300 frames). The timeline is at 50 pt/s: a second is 50 pt, a frame 5/3 pt.
@MainActor
final class EffectLanesTimelineTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "lanes-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private var v1: VETrackID { store.videoTracks.first?.trackID ?? 0 }
    private var a1: VETrackID { store.audioTracks.first?.trackID ?? 0 }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    private func range(_ start: Int64, _ end: Int64) -> CMTimeRange {
        CMTimeRange(start: frames(start), end: frames(end))
    }

    /// A 10 s movie (300 frames) on V1 at 0 s.
    private func longClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 300)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        return try fixture.placeMovie(try XCTUnwrap(imported.first), at: 0)
    }

    /// Source [from, to) seconds of `asset` at `at` seconds on the given tracks.
    @discardableResult
    private func place(_ asset: VEAssetInfo, at: Double, from: Double, to: Double, video: VETrackID = 0,
                       audio: VETrackID = 0) throws -> VEClipID {
        XCTAssertTrue(store.place(asset: asset.assetID, at: store.frameTime(at), videoTrack: video, audioTrack: audio,
                                  sourceIn: CMTime(seconds: from, preferredTimescale: 600),
                                  sourceOut: CMTime(seconds: to, preferredTimescale: 600), overwrite: true),
                      store.statusMessage ?? "")
        return try XCTUnwrap(store.selection.first)
    }

    /// A point in the middle of `lane` of a track at `seconds`.
    private func lanePoint(_ track: VETrackID, lane: Int, at seconds: Double) throws -> CGPoint {
        let model = store.timelineModel
        let layout = try XCTUnwrap(model.layout(forTrack: track))
        let top = try XCTUnwrap(layout.laneY(lane), "lane \(lane) is shown")
        return CGPoint(x: model.x(forTime: seconds), y: top - model.scrollY + TimelineViewModel.laneHeight / 2)
    }

    private func drag(_ gestures: TimelineGestureController, from: CGPoint, to points: [CGPoint],
                      modifiers: NSEvent.ModifierFlags = [], end: Bool = true) {
        gestures.changed(location: from, startLocation: from, modifiers: modifiers)
        for point in points {
            gestures.changed(location: point, startLocation: from, modifiers: modifiers)
        }
        if end { gestures.ended() }
    }

    private func lanes(_ track: VETrackID) -> [Int] {
        store.timelineModel.layout(forTrack: track)?.lanes ?? []
    }

    @discardableResult
    private func addSpan(_ kind: VESpanKind, lane: Int, clip: VEClipID, _ start: Int64, _ end: Int64) throws -> VESpanID {
        let added = store.engine.addSpan(kind: kind, lane: lane, clip: clip, range: range(start, end))
        return try XCTUnwrap(added.span, added.message).spanID
    }

    // MARK: Lanes

    func testWhichLanesATrackShows() {
        typealias Span = TimelineViewModel.Span
        func span(_ lane: Int) -> Span {
            Span(id: Int64(lane + 1), clipID: 1, trackID: 10, lane: lane, kind: lane == 0 ? .transition : .motion,
                 start: 0, end: 1)
        }
        let lanes = TimelineViewModel.lanes
        XCTAssertEqual(lanes(false, [span(1)], false, true), [], "an empty track shows no lanes")
        XCTAssertEqual(lanes(true, [span(0), span(1)], true, false), [], "collapsed")
        XCTAssertEqual(lanes(true, [], false, false), [1], "one empty effect lane to create spans on")
        XCTAssertEqual(lanes(true, [span(1)], false, false), [1, 2], "the used lanes plus an empty one")
        XCTAssertEqual(lanes(true, [span(2)], false, false), [1, 2, 3])
        XCTAssertEqual(lanes(true, [span(1), span(2), span(3)], false, false), [1, 2, 3], "never more than 3")
        XCTAssertEqual(lanes(true, [span(0)], false, false), [0, 1], "lane 0 with a transition")
        XCTAssertEqual(lanes(true, [], false, true), [0, 1], "lane 0 while a transition is dragged over")

        // Heights: the row, then 14 pt per lane; rows follow each other with their lanes.
        var model = TimelineViewModel()
        var video = TimelineViewModel.Track(id: 10, kind: .video, index: 0, name: "V1")
        video.lanes = [0, 1, 2]
        var audio = TimelineViewModel.Track(id: 20, kind: .audio, index: 0, name: "A1")
        audio.lanes = [1]
        model.tracks = [video, audio]
        let v = model.trackLayouts[0]
        XCTAssertEqual(v.rowHeight, TimelineViewModel.videoTrackHeight)
        XCTAssertEqual(v.height, TimelineViewModel.videoTrackHeight + 3 * TimelineViewModel.laneHeight)
        XCTAssertEqual(v.laneY(0), TimelineViewModel.videoTrackHeight)
        XCTAssertEqual(v.laneY(2), TimelineViewModel.videoTrackHeight + 2 * TimelineViewModel.laneHeight)
        XCTAssertNil(v.laneY(3))
        XCTAssertEqual(v.lane(atContentY: 10), nil, "the row of clips")
        XCTAssertEqual(v.lane(atContentY: TimelineViewModel.videoTrackHeight + 15), 1)
        XCTAssertEqual(model.trackLayouts[1].y, v.height + TimelineViewModel.trackSpacing)
        XCTAssertEqual(model.contentHeight, v.height + TimelineViewModel.trackSpacing + TimelineViewModel.audioTrackHeight
            + TimelineViewModel.laneHeight)
    }

    func testSpanBarsAndTheirHitTesting() throws {
        var model = TimelineViewModel()
        model.pixelsPerSecond = 100
        var track = TimelineViewModel.Track(id: 10, kind: .video, index: 0, name: "V1")
        track.lanes = [0, 1]
        model.tracks = [track]
        model.clips = [.init(id: 1, trackID: 10, start: 0, end: 4), .init(id: 2, trackID: 10, start: 4, end: 8)]
        model.spans = [
            .init(id: 50, clipID: 1, trackID: 10, lane: 0, kind: .transition, start: 3.5, end: 4.3, cut: 4),
            // An effect span reaching past its clip is drawn within it.
            .init(id: 60, clipID: 1, trackID: 10, lane: 1, kind: .motion, start: 1, end: 5),
        ]
        let row = TimelineViewModel.videoTrackHeight
        let lane0 = row + 7
        let lane1 = row + TimelineViewModel.laneHeight + 7
        let dissolve = try XCTUnwrap(model.rect(forSpan: try XCTUnwrap(model.span(id: 50))))
        XCTAssertEqual(dissolve.minX, 350, accuracy: 1e-9)
        XCTAssertEqual(dissolve.maxX, 430, accuracy: 1e-9, "a transition straddles its cut")
        let motion = try XCTUnwrap(model.rect(forSpan: try XCTUnwrap(model.span(id: 60))))
        XCTAssertEqual(motion.maxX, 400, accuracy: 1e-9, "clipped to its clip")
        XCTAssertEqual(model.hitTest(CGPoint(x: 352, y: lane0)), .spanHead(50))
        XCTAssertEqual(model.hitTest(CGPoint(x: 390, y: lane0)), .span(50))
        XCTAssertEqual(model.hitTest(CGPoint(x: 428, y: lane0)), .spanTail(50))
        XCTAssertEqual(model.hitTest(CGPoint(x: 600, y: lane0)), .lane(track: 10, lane: 0))
        XCTAssertEqual(model.hitTest(CGPoint(x: 103, y: lane1)), .spanHead(60))
        XCTAssertEqual(model.hitTest(CGPoint(x: 250, y: lane1)), .span(60))
        XCTAssertEqual(model.hitTest(CGPoint(x: 398, y: lane1)), .spanTail(60))
        XCTAssertEqual(model.hitTest(CGPoint(x: 50, y: lane1)), .lane(track: 10, lane: 1))
        // The row of clips above keeps its own zones.
        XCTAssertEqual(model.hitTest(CGPoint(x: 398, y: 30)), .clipTail(1))
        // Span edges are snap targets only for span drags.
        XCTAssertNil(model.snap(4.3, excluding: [1, 2]), "a clip drag does not snap to spans")
        XCTAssertEqual(model.snap(4.31, excluding: [1, 2], excludingSpans: [])?.target, .spanEnd(50))
        XCTAssertNotEqual(model.snap(4.31, excluding: [1, 2], excludingSpans: [50])?.target, .spanEnd(50),
                          "never the dragged span itself")
    }

    func testTheStoreShowsTheLanesInUseAndCollapsesThem() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        XCTAssertEqual(lanes(v1), [1], "a track with clips: one empty effect lane")
        XCTAssertEqual(lanes(v2), [], "an empty track: none")
        let base = 2 * TimelineViewModel.videoTrackHeight + 2 * TimelineViewModel.audioTrackHeight
            + 3 * TimelineViewModel.trackSpacing
        XCTAssertEqual(store.timelineContentHeight, base + TimelineViewModel.laneHeight, "the fitted height has the lane")
        try addSpan(.motion, lane: 1, clip: clip, 0, 30)
        store.refreshModel()
        XCTAssertEqual(lanes(v1), [1, 2])
        try addSpan(.opacity, lane: 3, clip: clip, 0, 30)
        store.refreshModel()
        XCTAssertEqual(lanes(v1), [1, 2, 3])
        XCTAssertTrue(store.engine.addTransition(at: .end, of: clip, duration: frames(10), options: []).ok)
        store.refreshModel()
        XCTAssertEqual(lanes(v1), [0, 1, 2, 3], "lane 0 with the fade out")
        XCTAssertEqual(store.timelineContentHeight, base + 4 * TimelineViewModel.laneHeight)

        // The disclosure collapses the lanes of a track with clips, remembered as "V1".
        let builds = store.timelineBuildCount
        store.toggleDisclosure(ofTrack: v1)
        XCTAssertEqual(lanes(v1), [])
        XCTAssertEqual(store.layout.collapsedLaneTracks, ["V1"])
        XCTAssertTrue(store.areLanesCollapsed(ofTrack: v1))
        XCTAssertEqual(store.timelineContentHeight, base)
        XCTAssertEqual(store.timelineBuildCount, builds + 1, "rebuilt once")
        store.toggleDisclosure(ofTrack: v1)
        XCTAssertEqual(lanes(v1), [0, 1, 2, 3])
        // On an empty track it collapses the row.
        store.toggleDisclosure(ofTrack: v2)
        XCTAssertTrue(store.isTrackCollapsed(v2))
        XCTAssertTrue(store.layout.collapsedLaneTracks.isEmpty)

        // A transition dragged over the timeline shows lane 0 on the tracks of its kind.
        XCTAssertTrue(store.engine.removeTransition(try XCTUnwrap(store.engine.spans(forClip: clip).first {
            $0.kind == .transition
        }).spanID).ok)
        store.refreshModel()
        XCTAssertEqual(lanes(v1), [1, 2, 3])
        store.revealTransitionLane(.video)
        XCTAssertEqual(lanes(v1), [0, 1, 2, 3])
        store.revealTransitionLane(nil)
        XCTAssertEqual(lanes(v1), [1, 2, 3])

        // The header's row keeps the row's height; its lanes follow below it.
        let layout = try XCTUnwrap(store.timelineModel.layout(forTrack: v1))
        XCTAssertEqual(layout.rowHeight, TimelineViewModel.videoTrackHeight)
        XCTAssertEqual(layout.height, TimelineViewModel.videoTrackHeight + 3 * TimelineViewModel.laneHeight)
    }

    func testCollapsedLanesPersistInTheLayout() throws {
        let suite = "lanes-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(WindowLayoutModel.laneKey(video: true, index: 0), "V1")
        XCTAssertEqual(WindowLayoutModel.laneKey(video: false, index: 1), "A2")
        layout.setLanesCollapsed(true, key: "V1")
        layout.setLanesCollapsed(true, key: "A2")
        XCTAssertEqual(WindowLayoutModel(defaults: defaults).collapsedLaneTracks, ["V1", "A2"], "survives a relaunch")
        layout.setLanesCollapsed(false, key: "V1")
        XCTAssertEqual(WindowLayoutModel(defaults: defaults).collapsedLaneTracks, ["A2"])
        layout.resetToDefaults()
        XCTAssertTrue(WindowLayoutModel(defaults: defaults).collapsedLaneTracks.isEmpty)
    }

    // MARK: Selection

    func testASpanClickSelectsItAloneAndAClipClickClearsIt() async throws {
        let clip = try await longClip()
        let span = try addSpan(.motion, lane: 1, clip: clip, 30, 90)
        store.refreshModel()
        store.selection = [clip]
        let gestures = TimelineGestureController(store: store)
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 2), to: [])
        XCTAssertEqual(store.selectedSpanID, span)
        XCTAssertTrue(store.selection.isEmpty, "exclusive with the clip selection")
        XCTAssertNil(store.selectedTransitionID, "an effect span is no transition")
        XCTAssertEqual(store.selectedEffectSpan?.spanID, span)
        // A click on the clip selects it and clears the span.
        drag(gestures, from: CGPoint(x: 150, y: 90), to: [])
        XCTAssertEqual(store.selection, [clip])
        XCTAssertNil(store.selectedSpanID)
        // A click on an empty lane deselects everything.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 2), to: [])
        drag(gestures, from: try lanePoint(v1, lane: 2, at: 6), to: [])
        XCTAssertNil(store.selectedSpanID)
        XCTAssertTrue(store.selection.isEmpty)
        // A removed span is deselected.
        store.select(span: span)
        XCTAssertTrue(store.engine.removeSpan(span).ok)
        XCTAssertNil(store.selectedSpanID)
    }

    // MARK: Drags

    func testBodyAndEdgeDragsSnapAndAreOneUndoStepEach() async throws {
        let clip = try await longClip()
        let span = try addSpan(.motion, lane: 1, clip: clip, 30, 90) // 1 s - 3 s: x 50...150
        store.refreshModel()
        let gestures = TimelineGestureController(store: store)
        func current() throws -> [CMTime] {
            let info = try XCTUnwrap(store.engine.spanInfo(span))
            return [info.start, info.end]
        }
        // The bar moves by the pointer: 50 pt is a second.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 2), to: [try lanePoint(v1, lane: 1, at: 3)], end: false)
        XCTAssertTrue(store.isGestureActive)
        XCTAssertEqual(try current(), [frames(60), frames(120)])
        XCTAssertEqual(store.statusMessage, "Motion: 00:00:02:00 – 00:00:04:00")
        gestures.ended()
        XCTAssertEqual(store.undoActionName, "Change Span Range")
        XCTAssertFalse(store.isGestureActive)
        store.undo()
        XCTAssertEqual(try current(), [frames(30), frames(90)], "the drag was one undo step")

        // Snapping: the end snaps to the playhead at 5 s from within 8 pt.
        store.playheadTime = frames(150)
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 2), to: [try lanePoint(v1, lane: 1, at: 3.93)])
        XCTAssertEqual(try current(), [frames(90), frames(150)], "the end on the playhead")

        // The tail edge trims (the head stays), snapping to the clip's end; the head trims.
        let tail = try lanePoint(v1, lane: 1, at: 5)
        drag(gestures, from: CGPoint(x: tail.x - 1, y: tail.y), to: [try lanePoint(v1, lane: 1, at: 9.95)])
        XCTAssertEqual(try current(), [frames(90), frames(300)], "snapped to the clip's end")
        let head = try lanePoint(v1, lane: 1, at: 3)
        drag(gestures, from: CGPoint(x: head.x + 1, y: head.y), to: [try lanePoint(v1, lane: 1, at: -2)])
        XCTAssertEqual(try current(), [frames(0), frames(300)], "within the clip")

        // Escape mid-drag reverts it; the rest of the gesture is ignored.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 5), to: [try lanePoint(v1, lane: 1, at: 1)], end: false)
        store.cancelActiveGesture?()
        XCTAssertEqual(try current(), [frames(0), frames(300)])
        gestures.ended()
        XCTAssertFalse(store.engine.isCoalescing)
    }

    func testARefusedDragSaysWhereTheLaneIsFree() async throws {
        let clip = try await longClip()
        let first = try addSpan(.motion, lane: 1, clip: clip, 30, 60) // 1 s - 2 s
        try addSpan(.motion, lane: 1, clip: clip, 150, 210) // 5 s - 7 s
        store.refreshModel()
        let gestures = TimelineGestureController(store: store)
        // Pull the first span's end into the second: refused, the free range named.
        let tail = try lanePoint(v1, lane: 1, at: 2)
        drag(gestures, from: CGPoint(x: tail.x - 1, y: tail.y), to: [try lanePoint(v1, lane: 1, at: 6)], end: false)
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(60), "refused: unchanged")
        let message = try XCTUnwrap(store.statusMessage)
        XCTAssertTrue(message.contains("The nearest free range is"), message)
        XCTAssertTrue(message.contains("00:00:05:00"), message)
        gestures.ended()
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(60))
    }

    // MARK: Creating spans

    func testRangeDragsCreateMotionOpacityAndGainSpans() async throws {
        let clip = try await longClip()
        let gestures = TimelineGestureController(store: store)
        // A video lane: a Motion span over the range, with the Ken Burns push in, one undo step.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 1), to: [try lanePoint(v1, lane: 1, at: 2),
                                                                     try lanePoint(v1, lane: 1, at: 3)], end: false)
        XCTAssertEqual(gestures.creation?.start ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(gestures.creation?.end ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(gestures.creation?.kind, .motion)
        XCTAssertTrue(store.engine.spans(forClip: clip).isEmpty, "nothing is added before the release")
        gestures.ended()
        XCTAssertNil(gestures.creation)
        let motion = try XCTUnwrap(store.engine.spans(forClip: clip).first)
        XCTAssertEqual(motion.kind, .motion)
        XCTAssertEqual(motion.lane, 1)
        XCTAssertEqual([motion.start, motion.end], [frames(30), frames(90)])
        XCTAssertEqual(motion.startValues.scale, 1, accuracy: 1e-12, "the whole picture")
        XCTAssertEqual(motion.endValues.scale, 1 / ProjectStore.defaultPushInFraction, accuracy: 1e-9, "a push in")
        XCTAssertEqual(motion.interpolation, .easeInOut)
        XCTAssertEqual(store.undoActionName, "Add Motion Span")
        XCTAssertEqual(store.selectedSpanID, motion.spanID, "selected")
        store.undo()
        XCTAssertTrue(store.engine.spans(forClip: clip).isEmpty, "one undo step")

        // Option: an Opacity span. Touching the clip's end it fades out, at its start in, else 1 -> 1.
        store.refreshModel()
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 8), to: [try lanePoint(v1, lane: 1, at: 9.97)],
             modifiers: .option)
        let fadeOut = try XCTUnwrap(store.engine.spans(forClip: clip).first { $0.end == frames(300) })
        XCTAssertEqual(fadeOut.kind, .opacity)
        XCTAssertEqual([fadeOut.startValues.opacity, fadeOut.endValues.opacity], [1, 0])
        XCTAssertEqual(store.undoActionName, "Add Opacity Span")
        store.refreshModel()
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 0.03), to: [try lanePoint(v1, lane: 1, at: 1)],
             modifiers: .option)
        let fadeIn = try XCTUnwrap(store.engine.spans(forClip: clip).first { $0.start == .zero })
        XCTAssertEqual([fadeIn.startValues.opacity, fadeIn.endValues.opacity], [0, 1])
        store.refreshModel()
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 4), to: [try lanePoint(v1, lane: 1, at: 5)],
             modifiers: .option)
        let middle = try XCTUnwrap(store.engine.spans(forClip: clip).first { $0.start == frames(120) })
        XCTAssertEqual([middle.startValues.opacity, middle.endValues.opacity], [1, 1])

        // Under two frames: nothing.
        store.refreshModel()
        let count = store.engine.spans(forClip: clip).count
        drag(gestures, from: try lanePoint(v1, lane: 2, at: 6), to: [try lanePoint(v1, lane: 2, at: 6.2),
                                                                     try lanePoint(v1, lane: 2, at: 6.02)])
        XCTAssertEqual(store.engine.spans(forClip: clip).count, count)
        XCTAssertEqual(store.statusMessage, "Drag over at least two frames to create a span.")
        // Over another span of the lane: shown in red, refused with the free range.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 6), to: [try lanePoint(v1, lane: 1, at: 8.5)], end: false)
        XCTAssertNotNil(gestures.creation?.problem)
        gestures.ended()
        XCTAssertEqual(store.engine.spans(forClip: clip).count, count)
        XCTAssertTrue(store.statusMessage?.contains("nearest free range") == true, store.statusMessage ?? "")

        // An audio lane: a Gain span, 0 -> 0 dB.
        let (_, tone) = try await fixture.importMedia()
        let sound = try place(tone, at: 0, from: 0, to: 3, audio: a1)
        drag(gestures, from: try lanePoint(a1, lane: 1, at: 0.5), to: [try lanePoint(a1, lane: 1, at: 2)])
        let gain = try XCTUnwrap(store.engine.spans(forClip: sound).first)
        XCTAssertEqual(gain.kind, .gain)
        XCTAssertEqual([gain.startValues.gainDb, gain.endValues.gainDb], [0, 0])
        XCTAssertEqual([gain.start, gain.end], [frames(15), frames(60)])
    }

    // MARK: Transitions on lane 0

    func testTransitionEdgesMoveIndependentlyAndADissolveEndOnTheCutFadesOut() async throws {
        let (movie, _) = try await fixture.importMedia()
        // A [0, 1 s) and B [1 s, 2 s): 30 frames of media beyond the cut each way.
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1)
        let added = store.engine.addTransition(fromClip: a, toClip: b, duration: frames(10))
        let id = try XCTUnwrap(added.createdIDs.first?.int64Value, added.message)
        store.refreshModel()
        XCTAssertEqual(lanes(v1), [0, 1])
        func shares() throws -> [Int64] {
            let span = try XCTUnwrap(store.engine.spanInfo(id))
            return [store.frames(span.shareBeforeCut), store.frames(span.shareAfterCut)]
        }
        XCTAssertEqual(try shares(), [5, 5])
        let gestures = TimelineGestureController(store: store)
        // The end edge (35 frames: x 58.3) 10 pt to the right: 6 frames more after the cut only.
        let end = try lanePoint(v1, lane: 0, at: 35.0 / 30)
        drag(gestures, from: CGPoint(x: end.x - 1, y: end.y), to: [CGPoint(x: end.x + 9, y: end.y)], end: false)
        XCTAssertEqual(try shares(), [5, 11], "asymmetric: only the after share changed")
        XCTAssertEqual(store.selectedTransitionID, id)
        XCTAssertTrue(store.statusMessage?.hasPrefix("Cross Dissolve: 5f before / 11f after the cut (31% / 69%)") == true,
                      store.statusMessage ?? "")
        gestures.ended()
        XCTAssertEqual(store.undoActionName, "Change Transition")
        store.undo()
        XCTAssertEqual(try shares(), [5, 5], "one undo step")

        // The start edge 10 pt to the left: 6 frames more before the cut.
        let start = try lanePoint(v1, lane: 0, at: 25.0 / 30)
        drag(gestures, from: CGPoint(x: start.x + 1, y: start.y), to: [CGPoint(x: start.x - 9, y: start.y)])
        XCTAssertEqual(try shares(), [11, 5])
        // The bar slides the split (10 pt: 6 frames later).
        drag(gestures, from: try lanePoint(v1, lane: 0, at: 0.9), to: [try lanePoint(v1, lane: 0, at: 1.1)])
        XCTAssertEqual(try shares(), [5, 11])

        // The end dragged onto the cut: a fade out, and the status line says so.
        let tail = try lanePoint(v1, lane: 0, at: 41.0 / 30)
        drag(gestures, from: CGPoint(x: tail.x - 1, y: tail.y), to: [try lanePoint(v1, lane: 0, at: 0.5)], end: false)
        let fade = try XCTUnwrap(store.engine.spanInfo(id))
        XCTAssertEqual(fade.transitionStyle, .fadeOut)
        XCTAssertEqual(fade.end, frames(30), "held on the cut")
        XCTAssertTrue(store.statusMessage?.contains("Fade Out") == true, store.statusMessage ?? "")
        XCTAssertTrue(store.statusMessage?.contains("fades out") == true, store.statusMessage ?? "")
        gestures.ended()

        // A fade in keeps its start on its clip's start; its end edge sets its length.
        XCTAssertTrue(store.addFade(at: .start, of: a, frames: 10))
        let fadeIn = try XCTUnwrap(store.selectedSpanID)
        store.refreshModel()
        drag(gestures, from: try lanePoint(v1, lane: 0, at: 0.01), to: [try lanePoint(v1, lane: 0, at: 0.2)])
        XCTAssertEqual(store.engine.spanInfo(fadeIn)?.end, frames(10), "the start does not move")
        XCTAssertTrue(store.statusMessage?.contains("starts on its clip's start") == true, store.statusMessage ?? "")
        let fadeEnd = try lanePoint(v1, lane: 0, at: 10.0 / 30)
        drag(gestures, from: CGPoint(x: fadeEnd.x - 1, y: fadeEnd.y), to: [CGPoint(x: fadeEnd.x + 9, y: fadeEnd.y)])
        XCTAssertEqual(store.engine.spanInfo(fadeIn)?.end, frames(16))
        XCTAssertEqual(store.engine.spanInfo(fadeIn)?.start, .zero)
    }

    /// Audio crossfades and fades are lane-0 spans on the audio track, dragged like video ones.
    func testAudioFadesAreDraggedOnLaneZero() async throws {
        let (_, tone) = try await fixture.importMedia()
        let clip = try place(tone, at: 0, from: 0, to: 3, audio: a1) // 90 frames
        XCTAssertTrue(store.addFade(at: .end, of: clip, frames: 30))
        store.refreshModel()
        XCTAssertEqual(lanes(a1), [0, 1])
        let fade = try XCTUnwrap(store.selectedSpanID)
        XCTAssertEqual(store.clips[clip]?.audioParams.fadeOutDuration, frames(30))
        let gestures = TimelineGestureController(store: store)
        let start = try lanePoint(a1, lane: 0, at: 2)
        let target = try lanePoint(a1, lane: 0, at: 1.5)
        drag(gestures, from: CGPoint(x: start.x + 1, y: start.y), to: [CGPoint(x: target.x + 1, y: target.y)])
        XCTAssertEqual(store.clips[clip]?.audioParams.fadeOutDuration, frames(45), "the fade out got longer")
        XCTAssertEqual(store.engine.spanInfo(fade)?.transitionStyle, .fadeOut)
        store.undo()
        XCTAssertEqual(store.clips[clip]?.audioParams.fadeOutDuration, frames(30))
    }

    // MARK: Delete, menus

    func testDeleteAndTheContextMenuActOnTheSelectedSpan() async throws {
        let clip = try await longClip()
        let span = try addSpan(.motion, lane: 1, clip: clip, 30, 90)
        store.refreshModel()
        let gestures = TimelineGestureController(store: store)
        let items = gestures.contextMenuItems(at: try lanePoint(v1, lane: 1, at: 2))
        XCTAssertEqual(store.selectedSpanID, span, "a right-click selects the span")
        XCTAssertEqual(items.filter { !$0.isSeparator }.map(\.title), ["Set Interpolation", "Move to Lane", "Remove"])
        let interpolation = try XCTUnwrap(items.first { $0.title == "Set Interpolation" })
        XCTAssertEqual(interpolation.submenu.first { $0.isChecked }?.title, "Linear")
        try XCTUnwrap(interpolation.submenu.first { $0.title == "Hold" }).action()
        XCTAssertEqual(store.engine.spanInfo(span)?.interpolation, .hold)
        let lanesMenu = try XCTUnwrap(items.first { $0.title == "Move to Lane" })
        XCTAssertFalse(try XCTUnwrap(lanesMenu.submenu.first { $0.title == "Lane 1" }).isEnabled, "its lane")
        try XCTUnwrap(lanesMenu.submenu.first { $0.title == "Lane 3" }).action()
        XCTAssertEqual(store.engine.spanInfo(span)?.lane, 3)
        XCTAssertEqual(store.undoActionName, "Move Span to Lane")

        // Delete removes the selected span, one undo step.
        store.focusArea = .timeline
        XCTAssertTrue(store.canDelete)
        KeyboardController(store: store).perform(.delete, on: store)
        XCTAssertNil(store.engine.spanInfo(span))
        XCTAssertNil(store.selectedSpanID)
        XCTAssertEqual(store.clips.count, 1, "the clip stays")
        XCTAssertEqual(store.undoActionName, "Remove Span")
        store.undo()
        XCTAssertNotNil(store.engine.spanInfo(span))
        // During a gesture nothing is removed.
        store.select(span: span)
        store.cancelActiveGesture = {}
        store.deleteSelection(ripple: false)
        XCTAssertNotNil(store.engine.spanInfo(span))
        store.cancelActiveGesture = nil
    }

    // MARK: Drops from the Effects tab

    func testTransitionsAndEffectsDropOntoLanes() async throws {
        // Half a second: a fade in, a dissolve and a fade out all fit on two 1 s clips.
        store.defaults.set(0.5, forKey: EditingPreferences.defaultTransitionSecondsKey)
        let (movie, tone) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1) // x 0...50, nothing before it
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1) // x 50...100, nothing after it
        let gestures = TimelineGestureController(store: store)
        let row = try XCTUnwrap(store.timelineModel.layout(forTrack: v1))
        // Dragging a transition over the timeline shows lane 0 on the video tracks.
        let atEnd = CGPoint(x: 97, y: row.y + 30)
        let target = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: atEnd))
        XCTAssertEqual(store.revealedTransitionLane, .video)
        XCTAssertEqual(lanes(v1), [0, 1])
        XCTAssertEqual(target.placement, .fadeOut(clip: b), "B's free end: a fade out")
        XCTAssertEqual(target.title, "Fade Out")
        XCTAssertEqual(target.frames, 15)
        XCTAssertEqual(target.start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(target.end, 2, accuracy: 1e-9)
        gestures.transitionDragExited()
        XCTAssertNil(store.revealedTransitionLane)
        XCTAssertEqual(lanes(v1), [1])
        // Dropped on lane 0 at the free end: a fade out span; at A's free start a fade in.
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 97, y: row.y + 70)))
        let fadeOut = try XCTUnwrap(store.selectedSpanID)
        XCTAssertEqual(store.engine.spanInfo(fadeOut)?.transitionStyle, .fadeOut)
        XCTAssertEqual(store.engine.spanInfo(fadeOut)?.clipID, b)
        XCTAssertNil(store.revealedTransitionLane)
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 3, y: row.y + 30)))
        XCTAssertEqual(store.selectedSpan?.transitionStyle, .fadeIn)
        XCTAssertEqual(store.selectedSpan?.clipID, a)
        // At the cut: the cross dissolve, as before.
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 51, y: row.y + 30)))
        XCTAssertEqual(store.sequence.transitions.count, 1)
        // A second fade out at B's end is refused with the reason.
        XCTAssertFalse(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 98, y: row.y + 30)))
        XCTAssertTrue(store.statusMessage?.contains("already has a transition at its end") == true,
                      store.statusMessage ?? "")

        // The Fade effect onto an effect lane: an Opacity span of the default length from the drop
        // point, fading out when it reaches the clip's end.
        store.refreshModel()
        let fadeTarget = try XCTUnwrap(gestures.effectDragUpdated(kind: .fade, at: try lanePoint(v1, lane: 1, at: 1.7)))
        XCTAssertEqual(fadeTarget.clipID, b)
        XCTAssertEqual(fadeTarget.lane, 1)
        XCTAssertEqual(fadeTarget.start, 1.5, accuracy: 1e-9, "half a second back from B's end")
        XCTAssertEqual(fadeTarget.end, 2, accuracy: 1e-9)
        XCTAssertTrue(fadeTarget.allowed)
        XCTAssertTrue(gestures.dropEffect(kind: .fade, at: try lanePoint(v1, lane: 1, at: 1.7)))
        XCTAssertNil(gestures.effectDrop)
        let opacity = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual(opacity.kind, .opacity)
        XCTAssertEqual([opacity.startValues.opacity, opacity.endValues.opacity], [1, 0], "touches the clip's end")
        // Dropped on the clip itself it takes the first lane with room.
        store.refreshModel()
        XCTAssertTrue(gestures.dropEffect(kind: .fade, at: CGPoint(x: 60, y: row.y + 30)))
        XCTAssertEqual(store.selectedEffectSpan?.lane, 2)
        // Gain goes on audio only.
        XCTAssertNil(gestures.effectDragUpdated(kind: .gain, at: CGPoint(x: 60, y: row.y + 30)))
        let sound = try place(tone, at: 0, from: 0, to: 3, audio: a1)
        let audioRow = try XCTUnwrap(store.timelineModel.layout(forTrack: a1))
        XCTAssertTrue(gestures.dropEffect(kind: .gain, at: CGPoint(x: 10, y: audioRow.y + 20)))
        XCTAssertEqual(store.selectedEffectSpan?.kind, .gain)
        XCTAssertEqual(store.selectedEffectSpan?.clipID, sound)

        // Through the drop delegate: the effect's type is recognised and dropped.
        store.refreshModel()
        var targeted = false
        let delegate = TimelineDropDelegate(gestures: gestures,
                                            isAssetTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        let provider = NSItemProvider()
        provider.register(EffectReference(kind: .fade))
        let info = FakeDropInfo(location: try lanePoint(v1, lane: 3, at: 0.2), providers: [provider])
        XCTAssertTrue(delegate.handleValidate(info))
        delegate.handleEntered(info)
        XCTAssertFalse(targeted)
        XCTAssertEqual(delegate.handleUpdated(info)?.operation, .copy)
        XCTAssertTrue(delegate.handlePerform(info))
        XCTAssertEqual(store.selectedEffectSpan?.lane, 3)
        XCTAssertEqual(store.selectedEffectSpan?.clipID, a)
    }

    // MARK: Control-K

    func testControlKAddsAMotionSpanAtThePlayhead() async throws {
        XCTAssertEqual(KeyboardController.action(keyCode: 40, characters: "k", modifiers: .control), .addMotionSpan)
        XCTAssertEqual(KeyboardController.action(keyCode: 40, characters: "k", modifiers: []), .shuttleStop)
        XCTAssertFalse(KeyboardController.Action.addMotionSpan.isTransportOrCancel, "editor window only")
        XCTAssertTrue(KeyboardController.Action.addMotionSpan.ignoresRepeat)
        store.addMotionSpanAtPlayhead()
        XCTAssertEqual(store.statusMessage, "Select a video clip, or move the playhead over one, to add a Motion span.")

        let clip = try await longClip()
        store.selection = []
        store.playheadTime = frames(60)
        let keyboard = KeyboardController(store: store)
        keyboard.perform(.addMotionSpan, on: store)
        let first = try XCTUnwrap(store.selectedEffectSpan)
        XCTAssertEqual([first.start, first.end], [frames(60), frames(210)], "5 s from the playhead")
        XCTAssertEqual(first.lane, 1)
        XCTAssertEqual(store.undoActionName, "Add Motion Span")
        // Again at the same frame: the next lane with room, then the third; then no room.
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.selectedEffectSpan?.lane, 2)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.selectedEffectSpan?.lane, 3)
        let changes = store.changeCount
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.changeCount, changes)
        XCTAssertTrue(store.statusMessage?.hasPrefix("No effect lane of “long.mov” has room there") == true,
                      store.statusMessage ?? "")
        // Near the clip's end: to its end.
        store.playheadTime = frames(250)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual([store.selectedEffectSpan?.start, store.selectedEffectSpan?.end], [frames(250), frames(300)])
        // On its last frame: refused.
        store.playheadTime = frames(299)
        store.selection = [clip]
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertTrue(store.statusMessage?.hasPrefix("Less than two frames") == true, store.statusMessage ?? "")
        // The selected clip, with the playhead off it: refused with the reason.
        store.playheadTime = frames(400)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.statusMessage, "Move the playhead over “long.mov” to add a Motion span there.")
        // During a gesture: nothing.
        store.playheadTime = frames(220)
        store.cancelActiveGesture = {}
        let before = store.changeCount
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.changeCount, before)
        store.cancelActiveGesture = nil
        // The clip's context menu offers it.
        let gestures = TimelineGestureController(store: store)
        let items = gestures.contextMenuItems(at: CGPoint(x: 20, y: 90))
        XCTAssertEqual(items.filter { !$0.isSeparator }.map(\.title),
                       ["Delete", "Ripple Delete", "Link", "Speed/Duration…", "Add Motion Span at Playhead"])
        try XCTUnwrap(items.first { $0.title == "Add Motion Span at Playhead" }).action()
        XCTAssertEqual(store.selectedEffectSpan?.start, frames(220))
        XCTAssertEqual(store.selectedEffectSpan?.lane, 2, "lane 1 has the span added near the end")
    }
}
