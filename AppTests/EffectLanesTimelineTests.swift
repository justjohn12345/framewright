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
        store.revealTransitionLane(onTrack: v1)
        XCTAssertEqual(lanes(v1), [0, 1, 2, 3])
        store.revealTransitionLane(onTrack: nil)
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

    /// Review L7: a track's lane collapse stays with it when the tracks' numbers change (V1 removed:
    /// V2 becomes V1 and stays collapsed; a new track does not inherit it), and selecting a span on
    /// collapsed lanes opens them so it is never edited unseen.
    func testLaneCollapseFollowsItsTrackAndASelectedSpanOpensItsLanes() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        let clip = try place(movie, at: 0, from: 0, to: 2, video: v2)
        let span = try addSpan(.motion, lane: 1, clip: clip, 0, 30)
        store.setLanes(ofTrack: v2, collapsed: true)
        XCTAssertEqual(store.layout.collapsedLaneTracks, ["V2"])
        XCTAssertTrue(store.engine.removeTrack(v1).ok)
        XCTAssertEqual(store.track(v2)?.index, 0, "V2 is V1 now")
        XCTAssertEqual(store.layout.collapsedLaneTracks, ["V1"], "the collapse went with it")
        XCTAssertTrue(store.areLanesCollapsed(ofTrack: v2))
        XCTAssertTrue(store.engine.addTrack(of: .video, name: nil).ok)
        let added = try XCTUnwrap(store.videoTracks.first { $0.trackID != v2 }).trackID
        XCTAssertFalse(store.areLanesCollapsed(ofTrack: added), "a new track starts open")
        XCTAssertTrue(store.areLanesCollapsed(ofTrack: v2))
        XCTAssertEqual(lanes(v2), [])
        // A span of the collapsed track selected (the inspector, a menu, undo): its lanes open.
        store.select(span: span)
        XCTAssertFalse(store.areLanesCollapsed(ofTrack: v2))
        XCTAssertEqual(lanes(v2), [1, 2])
        // A new project's tracks do not take over the collapse by id.
        store.setLanes(ofTrack: v2, collapsed: true)
        store.newProject()
        XCTAssertEqual(store.layout.collapsedLaneTracks, ["V1"], "kept by number across projects")
    }

    // MARK: Selection
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

    /// Review L4: a span's drags stop at the next span of its lane (the free space around it), not at
    /// the clip's edge: a fast drag into a neighbour ends touching it instead of short of it.
    func testASpanDragStopsAtTheNextSpanOfItsLane() async throws {
        let clip = try await longClip()
        let first = try addSpan(.motion, lane: 1, clip: clip, 30, 60) // 1 s - 2 s
        try addSpan(.motion, lane: 1, clip: clip, 150, 210) // 5 s - 7 s
        store.refreshModel()
        let gestures = TimelineGestureController(store: store)
        // Pull the first span's end into the second in one step: it stops touching it.
        let tail = try lanePoint(v1, lane: 1, at: 2)
        drag(gestures, from: CGPoint(x: tail.x - 1, y: tail.y), to: [try lanePoint(v1, lane: 1, at: 6)], end: false)
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(150), "up to the next span")
        XCTAssertEqual(store.statusMessage, "Motion: 00:00:01:00 – 00:00:05:00")
        gestures.ended()
        store.undo()
        // The body flung past it: it ends where the next one starts.
        drag(gestures, from: try lanePoint(v1, lane: 1, at: 1.5), to: [try lanePoint(v1, lane: 1, at: 8.5)])
        XCTAssertEqual(store.engine.spanInfo(first)?.start, frames(120))
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(150))
        store.undo()
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(60))
        // And the head of the second, pulled back into the first, stops at its end.
        let head = try lanePoint(v1, lane: 1, at: 5)
        drag(gestures, from: CGPoint(x: head.x + 1, y: head.y), to: [try lanePoint(v1, lane: 1, at: 0.5)])
        XCTAssertEqual(store.engine.spanInfo(first)?.end, frames(60))
        XCTAssertEqual(store.clips[clip]?.spans.first { $0.spanID != first && $0.lane == 1 }?.start, frames(60))
    }

    /// Review L5: a fade out's bar cannot slide (its end stays on its clip's end): refused up front, as
    /// a fade in's start is, with the edge to drag instead.
    func testAFadeOutsBarDoesNotSlide() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try place(movie, at: 0, from: 0, to: 2, video: v1)
        XCTAssertTrue(store.addFade(at: .end, of: clip, frames: 15))
        let fade = try XCTUnwrap(store.selectedSpanID)
        store.refreshModel()
        let gestures = TimelineGestureController(store: store)
        drag(gestures, from: try lanePoint(v1, lane: 0, at: 1.75), to: [try lanePoint(v1, lane: 0, at: 1.3)], end: false)
        XCTAssertFalse(store.engine.isCoalescing, "no group opens")
        XCTAssertEqual(store.statusMessage, "A fade out ends on its clip's end: drag its left edge to change its length.")
        gestures.ended()
        XCTAssertEqual(store.engine.spanInfo(fade)?.start, frames(45))
        XCTAssertEqual(store.engine.spanInfo(fade)?.end, frames(60))
        // Its left edge still sets its length.
        let edge = try lanePoint(v1, lane: 0, at: 1.5)
        drag(gestures, from: CGPoint(x: edge.x + 1, y: edge.y), to: [CGPoint(x: edge.x - 24, y: edge.y)])
        XCTAssertEqual(store.engine.spanInfo(fade)?.start, frames(30))
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

    /// The review's test gap 6: a linked dissolve and crossfade dragged asymmetrically through the
    /// gesture keep the same shares; Escape in the middle of the drag puts both back, ignores the
    /// rest of the gesture and leaves no undo step.
    func testALinkedPairFollowsAnAsymmetricDragAndEscapeRevertsBoth() async throws {
        store.resizesLinkedTransitions = true
        let (movie, tone) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1)
        let b = try place(movie, at: 1, from: 1, to: 2, video: v1)
        let sa = try place(tone, at: 0, from: 0, to: 1, audio: a1)
        let sb = try place(tone, at: 1, from: 1, to: 2, audio: a1)
        XCTAssertTrue(store.engine.linkClip(a, withClip: sa).ok)
        XCTAssertTrue(store.engine.linkClip(b, withClip: sb).ok)
        let added = store.engine.addTransition(fromClip: a, toClip: b, duration: frames(10),
                                               options: [.includeLinked])
        XCTAssertTrue(added.ok, added.message)
        let dissolve = try XCTUnwrap(added.createdIDs.first?.int64Value)
        let crossfade = try XCTUnwrap(store.engine.spanInfo(dissolve)?.linkedSpanID)
        XCTAssertNotEqual(crossfade, 0)
        store.refreshModel()
        func shares(_ id: VESpanID) throws -> [Int64] {
            let span = try XCTUnwrap(store.engine.spanInfo(id))
            return [store.frames(span.shareBeforeCut), store.frames(span.shareAfterCut)]
        }
        let gestures = TimelineGestureController(store: store)
        // The dissolve's end 10 pt right: 6 frames more after the cut, on both.
        let end = try lanePoint(v1, lane: 0, at: 35.0 / 30)
        drag(gestures, from: CGPoint(x: end.x - 1, y: end.y), to: [CGPoint(x: end.x + 9, y: end.y)])
        XCTAssertEqual(try shares(dissolve), [5, 11])
        XCTAssertEqual(try shares(crossfade), [5, 11], "the linked crossfade follows")
        XCTAssertEqual(store.undoActionName, "Change Transitions", "one step for the pair")
        let undoName = store.undoActionName
        let changes = store.changeCount

        // Its start 10 pt left, then Escape mid-drag: both back, the rest of the gesture ignored.
        let start = try lanePoint(v1, lane: 0, at: 25.0 / 30)
        drag(gestures, from: CGPoint(x: start.x + 1, y: start.y), to: [CGPoint(x: start.x - 9, y: start.y)], end: false)
        XCTAssertEqual(try shares(dissolve), [11, 11])
        XCTAssertEqual(try shares(crossfade), [11, 11])
        XCTAssertTrue(store.isGestureActive)
        store.cancelActiveGesture?()
        XCTAssertEqual(try shares(dissolve), [5, 11])
        XCTAssertEqual(try shares(crossfade), [5, 11])
        gestures.changed(location: CGPoint(x: start.x - 20, y: start.y), startLocation: CGPoint(x: start.x + 1, y: start.y),
                         modifiers: [])
        XCTAssertEqual(try shares(dissolve), [5, 11], "the rest of the gesture is ignored")
        gestures.ended()
        XCTAssertFalse(store.isGestureActive)
        XCTAssertEqual(store.undoActionName, undoName, "no undo step")
        XCTAssertGreaterThanOrEqual(store.changeCount, changes)
        store.undo()
        XCTAssertEqual(try shares(dissolve), [5, 5])
        XCTAssertEqual(try shares(crossfade), [5, 5], "the drag was one step for both")
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

    // MARK: Scrolling (review M5)

    /// The scroll offsets stay inside the content when the rows get shorter: collapsing lanes, a
    /// removed span or track, a larger track area never leave the top rows hidden above blank space.
    func testScrollYIsClampedWhenTheRowsGetShorter() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try place(movie, at: 0, from: 0, to: 2, video: v1)
        try addSpan(.motion, lane: 1, clip: clip, 0, 10)
        try addSpan(.opacity, lane: 2, clip: clip, 0, 10)
        store.refreshModel()
        store.timelineViewportWidth = 800
        store.timelineViewportHeight = 60
        let tall = store.timelineModel.contentHeight
        XCTAssertGreaterThan(tall, 60)
        store.scrollY = 10_000
        store.clampTimelineScroll()
        XCTAssertEqual(store.scrollY, tall - 60, "at most the content below the track area")
        // Collapsing V1's lanes: the rows are shorter; the offset follows.
        store.toggleDisclosure(ofTrack: v1)
        XCTAssertTrue(store.areLanesCollapsed(ofTrack: v1))
        let collapsed = store.timelineModel.contentHeight
        XCTAssertLessThan(collapsed, tall)
        XCTAssertEqual(store.scrollY, max(0, collapsed - 60))
        // Expanding again and scrolling down, then a taller track area: clamped when it is resized.
        store.toggleDisclosure(ofTrack: v1)
        store.scrollY = 10_000
        store.clampTimelineScroll()
        store.timelineViewportHeight = 1000
        store.clampTimelineScroll()
        XCTAssertEqual(store.scrollY, 0, "everything fits")
        // A model change (a span removed) clamps too.
        store.timelineViewportHeight = 60
        store.scrollY = 10_000
        store.clampTimelineScroll()
        let before = store.scrollY
        let lane2 = try XCTUnwrap(store.clips[clip]?.spans.first { $0.lane == 2 })
        XCTAssertTrue(store.engine.removeSpan(lane2.spanID).ok)
        XCTAssertLessThan(store.scrollY, before)
        XCTAssertEqual(store.scrollY, max(0, store.timelineModel.contentHeight - 60))
        // Time too: zoomed out, the offset comes back inside the sequence.
        store.scrollX = 50_000
        store.clampTimelineScroll()
        XCTAssertEqual(store.scrollX, max(0, store.timelineModel.contentWidth - 800))
    }

    // MARK: What edits remove as a side effect (review M1)

    /// A move that makes a clip touch another's faded start removes the fade in: the status line
    /// says so, naming both clips.
    func testAMoveThatRemovesAFadeInSaysSo() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1) // x 0...50
        let b = try place(movie, at: 3, from: 0, to: 1, video: v1) // x 150...200
        XCTAssertTrue(store.addFade(at: .start, of: b, frames: 10))
        let fade = try XCTUnwrap(store.selectedSpanID)
        store.selection = [a]
        let row = try XCTUnwrap(store.timelineModel.layout(forTrack: v1))
        let gestures = TimelineGestureController(store: store)
        // Drag A's body 100 pt (2 s) right: A [2, 3) touches B's start.
        gestures.changed(location: CGPoint(x: 25, y: row.y + 20), startLocation: CGPoint(x: 25, y: row.y + 20),
                         modifiers: [])
        gestures.changed(location: CGPoint(x: 125, y: row.y + 20), startLocation: CGPoint(x: 25, y: row.y + 20),
                         modifiers: [])
        gestures.ended()
        XCTAssertEqual(try XCTUnwrap(store.clips[a]).timelineStart, store.frameTime(2))
        XCTAssertNil(store.engine.spanInfo(fade))
        XCTAssertEqual(store.statusMessage, "Removed the fade in on “clip.mov”: “clip.mov” now touches its start.")
        // Undo brings it back; the next plain edit's status line says nothing of it.
        store.undo()
        XCTAssertNotNil(store.engine.spanInfo(fade))
    }

    /// A ripple delete that brings another clip to the dissolve's clip removes the dissolve (review
    /// M2) and says which clip now follows.
    func testARippleDeleteThatRemovesADissolveSaysSo() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0.5, to: 1, video: v1)
        let b = try place(movie, at: 0.5, from: 0.5, to: 1, video: v1)
        _ = try place(movie, at: 1, from: 0.5, to: 1, video: v1)
        XCTAssertTrue(store.engine.addTransition(fromClip: a, toClip: b, duration: store.time(frames: 6)).ok)
        store.selection = [b]
        store.deleteSelection(ripple: true)
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        XCTAssertEqual(store.statusMessage,
                       "Removed the cross dissolve between “clip.mov” and “clip.mov”: “clip.mov” now follows “clip.mov”.")
        // Split inside a dissolve (Split at Playhead, Removing Transitions): said as a split.
        store.undo()
        XCTAssertEqual(store.sequence.transitions.count, 1)
        store.selection = [a]
        store.playheadTime = store.frameTime(0.5 - 1.0 / 30)
        store.splitAtPlayhead(breakingTransitions: true)
        XCTAssertTrue(store.sequence.transitions.isEmpty)
        XCTAssertEqual(store.statusMessage,
                       "Removed the cross dissolve between “clip.mov” and “clip.mov”: “clip.mov” was split inside it.")
    }

    /// A head trim past a Motion span folds what it held into the clip's values, and a tail trim
    /// that leaves nothing of a span removes it: both say so.
    func testATrimThatRemovesASpanSaysWhatBecameOfIt() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try place(movie, at: 0, from: 0, to: 2, video: v1) // 60 frames
        let zoom = try addSpan(.motion, lane: 1, clip: clip, 0, 10)
        var to = VESpanValuesUnchanged()
        to.scale = 2
        XCTAssertTrue(store.engine.setSpanValues(zoom, start: VESpanValuesUnchanged(), end: to).ok)
        let late = try addSpan(.opacity, lane: 2, clip: clip, 50, 60)
        XCTAssertTrue(store.report(store.engine.trimClipHead(clip, to: store.time(frames: 20), clamp: false)))
        XCTAssertNil(store.engine.spanInfo(zoom))
        XCTAssertEqual(try XCTUnwrap(store.clips[clip]).videoParams.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(store.statusMessage,
                       "The Motion span before the new start of “clip.mov” was folded into the clip's values.")
        XCTAssertTrue(store.report(store.engine.trimClipTail(clip, to: store.time(frames: 45), clamp: false)))
        XCTAssertNil(store.engine.spanInfo(late))
        XCTAssertEqual(store.statusMessage, "Removed the Fade span on “clip.mov”: nothing of it is left inside the clip.")
        // A plain edit afterwards says nothing more.
        XCTAssertTrue(store.report(store.engine.trimClipTail(clip, to: store.time(frames: 40), clamp: false)))
        XCTAssertNil(store.statusMessage)
    }

    /// Review M6: a transition dragged over two video tracks shows lane 0 on the row under the
    /// pointer only, below its clips, so a pointer held still keeps targeting the same row (with
    /// lane 0 shown on both rows the upper one grew and the lower one slid under the pointer).
    func testATransitionDragRevealsLaneZeroOnlyUnderThePointer() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        XCTAssertNotEqual(v1, v2)
        _ = try place(movie, at: 0, from: 0, to: 1, video: v1)
        _ = try place(movie, at: 1, from: 1, to: 2, video: v1)
        _ = try place(movie, at: 0, from: 0, to: 1, video: v2)
        _ = try place(movie, at: 1, from: 1, to: 2, video: v2)
        let gestures = TimelineGestureController(store: store)
        let before = store.timelineModel
        let lower = try XCTUnwrap(before.layout(forTrack: v1))
        let upper = try XCTUnwrap(before.layout(forTrack: v2))
        XCTAssertLessThan(upper.y, lower.y, "V2 is drawn above V1")
        // Near the top of V1's row, at the cut.
        let pointer = CGPoint(x: before.x(forTime: 1) + 3, y: lower.y - before.scrollY + 5)
        for _ in 0 ..< 4 {
            let target = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: pointer))
            XCTAssertEqual(target.trackID, v1, "the row under the pointer, every time")
            XCTAssertEqual(store.revealedTransitionTrack, v1)
            XCTAssertEqual(lanes(v1).first, 0)
            XCTAssertFalse(lanes(v2).contains(0), "the other row does not grow")
            XCTAssertEqual(store.timelineModel.layout(forTrack: v1)?.y, lower.y, "V1 did not move")
        }
        // Over V2: V2 shows lane 0 instead, and V1 gives its own back.
        let above = CGPoint(x: pointer.x, y: upper.y - before.scrollY + 5)
        let target = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: above))
        XCTAssertEqual(target.trackID, v2)
        XCTAssertEqual(store.revealedTransitionTrack, v2)
        XCTAssertFalse(lanes(v1).contains(0))
        XCTAssertEqual(lanes(v2).first, 0)
        // A crossfade over a video row targets nothing and reveals nothing.
        XCTAssertNil(gestures.transitionDragUpdated(kind: .audioCrossfade, at: above))
        XCTAssertNil(store.revealedTransitionTrack)
        gestures.transitionDragExited()
        XCTAssertNil(store.revealedTransitionTrack)
    }

    /// Review H4: a dissolve dropped on a clip's free edge becomes a fade, and says so: the preview is
    /// labelled "Fade" and the note says what it adds; a clip that already fades out says so (and
    /// how to change it), and the drop goes on the clip's other free edge when that is in reach.
    func testADissolveOnAFreeEdgeSaysItBecomesAFade() async throws {
        store.defaults.set(0.2, forKey: EditingPreferences.defaultTransitionSecondsKey) // 6 frames
        let (movie, tone) = try await fixture.importMedia()
        let a = try place(movie, at: 0, from: 0, to: 1, video: v1) // x 0...50, alone
        let b = try place(movie, at: 3, from: 0, to: 0.5, video: v1) // x 150...175, alone and short
        let gestures = TimelineGestureController(store: store)
        let row = try XCTUnwrap(store.timelineModel.layout(forTrack: v1))
        let nearAsEnd = CGPoint(x: 47, y: row.y + 30)

        let fade = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: nearAsEnd))
        XCTAssertEqual(fade.placement, .fadeOut(clip: a))
        XCTAssertTrue(fade.allowed)
        XCTAssertEqual(fade.previewLabel, "Fade", "the preview shows the conversion")
        XCTAssertEqual(fade.message, "No clip follows: this adds a fade to black.")
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: nearAsEnd))
        XCTAssertEqual(store.selectedSpan?.transitionStyle, .fadeOut)

        // Again at A's end: it already fades out (its start is out of reach).
        let again = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: nearAsEnd))
        XCTAssertFalse(again.allowed)
        XCTAssertEqual(again.message, "“clip.mov” already fades out: drag the fade's edge to lengthen it, or delete it.")
        XCTAssertFalse(gestures.dropTransition(kind: .crossDissolve, at: nearAsEnd))
        XCTAssertEqual(store.statusMessage, again.message)

        // B is short: with its end fading out, a drop near its end goes on its free start.
        let nearBsEnd = CGPoint(x: 173, y: row.y + 30)
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: nearBsEnd))
        XCTAssertEqual(store.selectedSpan?.transitionStyle, .fadeOut)
        let other = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: nearBsEnd))
        XCTAssertEqual(other.placement, .fadeIn(clip: b), "the other free edge, in reach")
        XCTAssertTrue(other.allowed)
        XCTAssertEqual(other.previewLabel, "Fade")
        XCTAssertEqual(other.message, "No clip precedes: this adds a fade from black.")
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: nearBsEnd))
        XCTAssertEqual(store.selectedSpan?.transitionStyle, .fadeIn)
        XCTAssertEqual(store.selectedSpan?.clipID, b)

        // Across a cut the preview is the transition itself.
        _ = try place(movie, at: 1, from: 1, to: 2, video: v1) // x 50...100, touching A's end
        let cut = try XCTUnwrap(gestures.transitionDragUpdated(kind: .crossDissolve, at: CGPoint(x: 52, y: row.y + 30)))
        XCTAssertEqual(cut.previewLabel, "Cross Dissolve")
        gestures.transitionDragExited()

        // On audio the fade goes to silence.
        _ = try place(tone, at: 0, from: 0, to: 2, audio: a1)
        let audioRow = try XCTUnwrap(store.timelineModel.layout(forTrack: a1))
        let silence = try XCTUnwrap(gestures.transitionDragUpdated(kind: .audioCrossfade,
                                                                   at: CGPoint(x: 97, y: audioRow.y + 20)))
        XCTAssertEqual(silence.message, "No clip follows: this adds a fade to silence.")
        XCTAssertEqual(silence.previewLabel, "Fade")
        gestures.transitionDragExited()
    }

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
        XCTAssertEqual(store.revealedTransitionTrack, v1, "on the row under the pointer")
        XCTAssertEqual(lanes(v1), [0, 1])
        XCTAssertEqual(target.placement, .fadeOut(clip: b), "B's free end: a fade out")
        XCTAssertEqual(target.title, "Fade Out")
        XCTAssertEqual(target.frames, 15)
        XCTAssertEqual(target.start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(target.end, 2, accuracy: 1e-9)
        gestures.transitionDragExited()
        XCTAssertNil(store.revealedTransitionTrack)
        XCTAssertEqual(lanes(v1), [1])
        // Dropped on lane 0 at the free end: a fade out span; at A's free start a fade in.
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 97, y: row.y + 70)))
        let fadeOut = try XCTUnwrap(store.selectedSpanID)
        XCTAssertEqual(store.engine.spanInfo(fadeOut)?.transitionStyle, .fadeOut)
        XCTAssertEqual(store.engine.spanInfo(fadeOut)?.clipID, b)
        XCTAssertNil(store.revealedTransitionTrack)
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 3, y: row.y + 30)))
        XCTAssertEqual(store.selectedSpan?.transitionStyle, .fadeIn)
        XCTAssertEqual(store.selectedSpan?.clipID, a)
        // At the cut: the cross dissolve, as before.
        XCTAssertTrue(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 51, y: row.y + 30)))
        XCTAssertEqual(store.sequence.transitions.count, 1)
        // A second fade out at B's end is refused with the reason.
        XCTAssertFalse(gestures.dropTransition(kind: .crossDissolve, at: CGPoint(x: 98, y: row.y + 30)))
        XCTAssertEqual(store.statusMessage,
                       "“clip.mov” already fades out: drag the fade's edge to lengthen it, or delete it.")

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
        // Again at the same frame (review L6): the span is selected, no second push in stacks on it.
        let changes = store.changeCount
        store.select(span: try XCTUnwrap(store.clips[clip]?.spans.first).spanID)
        store.selection = [clip]
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.changeCount, changes)
        XCTAssertEqual(store.selectedSpanID, first.spanID)
        XCTAssertEqual(store.statusMessage, "“long.mov” already has a Motion span starting here: it is selected (drag "
            + "on an empty lane to add another).")
        // A frame later: the next lane with room, then the third; then no room.
        store.playheadTime = frames(61)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.selectedEffectSpan?.lane, 2)
        store.playheadTime = frames(62)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.selectedEffectSpan?.lane, 3)
        let full = store.changeCount
        store.playheadTime = frames(63)
        keyboard.perform(.addMotionSpan, on: store)
        XCTAssertEqual(store.changeCount, full)
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

    /// Review L6: with nothing selected Control-K skips a locked or hidden top track (the clip below
    /// gets the span), and with two video clips selected it asks for one.
    func testControlKSkipsALockedOrHiddenTopTrackAndAsksForOneClip() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        let lower = try place(movie, at: 0, from: 0, to: 2, video: v1)
        let upper = try place(movie, at: 0, from: 0, to: 2, video: v2)
        store.selection = []
        store.playheadTime = frames(10)
        XCTAssertEqual(store.motionSpanClip()?.clipID, upper, "the top-most by default")
        XCTAssertTrue(store.engine.setTrack(v2, locked: true).ok)
        XCTAssertEqual(store.motionSpanClip()?.clipID, lower, "not the locked one")
        XCTAssertTrue(store.engine.setTrack(v2, locked: false).ok)
        XCTAssertTrue(store.engine.setTrack(v2, muted: true).ok)
        XCTAssertEqual(store.motionSpanClip()?.clipID, lower, "not the hidden one")
        store.addMotionSpanAtPlayhead()
        XCTAssertEqual(store.selectedEffectSpan?.clipID, lower)
        store.selection = [lower, upper]
        store.addMotionSpanAtPlayhead()
        XCTAssertEqual(store.statusMessage, "Select one video clip to add a Motion span (2 are selected).")
    }

    /// Held Control-K through the key monitor adds one span: the auto-repeat is swallowed.
    func testHeldControlKAddsOneMotionSpan() async throws {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        store.playheadTime = frames(10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            store.editorWindow = nil
            window.close()
        }
        store.editorWindow = window
        let keyboard = KeyboardController(store: store)
        func controlK(repeating: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{b}",
                                           charactersIgnoringModifiers: "k", isARepeat: repeating, keyCode: 40))
        }
        XCTAssertTrue(keyboard.handle(try controlK(repeating: false), window: window))
        XCTAssertEqual(store.engine.spans(forClip: id).count, 1, "one Motion span from the playhead")
        let changes = store.changeCount
        for _ in 0 ..< 5 {
            XCTAssertTrue(keyboard.handle(try controlK(repeating: true), window: window), "swallowed")
        }
        XCTAssertEqual(store.changeCount, changes, "the auto-repeat adds nothing")
        XCTAssertEqual(store.engine.spans(forClip: id).count, 1)
    }

    /// The bottom of a clip keeps its trim edges and its body (the spans are on the lanes below).
    func testTheBottomOfAClipWithSpansKeepsItsTrimEdges() async throws {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        let span = try addSpan(.motion, lane: 1, clip: id, 0, 60)
        store.refreshModel()
        let model = store.timelineModel
        let rect = try XCTUnwrap(model.rect(forClip: try XCTUnwrap(model.clip(id: id))))
        let y = rect.maxY - 4
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.minX + 0.5, y: y)), .clipHead(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.maxX - 0.5, y: y)), .clipTail(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.midX, y: y)), .clipBody(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.midX, y: rect.maxY + 7)), .span(span))
    }
}
