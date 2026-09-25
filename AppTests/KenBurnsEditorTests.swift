import AppKit
import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Ken Burns editor bound to a Motion span (effect lanes round 2, item 4): it opens when a
/// Motion span is selected, switches with the selection, closes on deselecting, on selecting a clip
/// and on Escape (the span stays selected; a click or Ken Burns… reopens it); rectangle and corner
/// drags write the span as they move, one undo step each, Escape mid-drag cancels; the framings are
/// re-read after an earlier span changes; the picture is clamped to the span's range; the hold-after
/// caption; the range fields, the smoothing, Swap and the neighbour toggles. Also the geometry, the
/// picture loader and which rectangle a press grabs. The movie is 2 s (60 frames) at 320x180 (it
/// fills the 1920x1080 frame); the long movie 10 s (300 frames).
@MainActor
final class KenBurnsEditorTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "ken-burns-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    private func range(_ start: Int64, _ end: Int64) -> CMTimeRange {
        CMTimeRange(start: frames(start), end: frames(end))
    }

    private func longClip(at seconds: Double = 0) async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try TestMediaFactory.writeMovie(to: url, frames: 300)
        }
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        return try fixture.placeMovie(try XCTUnwrap(imported.first), at: seconds)
    }

    /// A Motion span through the engine (neutral unless values are given).
    @discardableResult
    private func motionSpan(_ clip: VEClipID, lane: Int = 1, _ start: Int64, _ end: Int64,
                            scale: (Double, Double)? = nil) throws -> VESpanID {
        let added = store.engine.addSpan(kind: .motion, lane: lane, clip: clip, range: range(start, end))
        let id = try XCTUnwrap(added.span, added.message).spanID
        if let scale {
            var from = VESpanValuesUnchanged()
            from.scale = scale.0
            var to = VESpanValuesUnchanged()
            to.scale = scale.1
            XCTAssertTrue(store.engine.setSpanValues(id, start: from, end: to).ok)
        }
        store.refreshModel()
        return id
    }

    private func span(_ id: VESpanID) throws -> VEEffectSpan {
        try XCTUnwrap(store.engine.spanInfo(id))
    }

    private var fullFrame: CGRect { CGRect(x: 0, y: 0, width: 1920, height: 1080) }

    // MARK: Opening and closing

    func testTheEditorOpensOnAMotionSpanSwitchesAndCloses() async throws {
        let clip = try await longClip()
        let first = try motionSpan(clip, 0, 90)
        let second = try motionSpan(clip, 150, 240)
        let fade = try XCTUnwrap(store.engine.addSpan(kind: .opacity, lane: 2, clip: clip, range: range(0, 30)).span)
        store.refreshModel()
        XCTAssertNil(store.kenBurns)

        // A click on the span in its lane opens the editor on it.
        let gestures = TimelineGestureController(store: store)
        let model = store.timelineModel
        let layout = try XCTUnwrap(model.layout(forTrack: try XCTUnwrap(store.clips[clip]).trackID))
        let lane1 = try XCTUnwrap(layout.laneY(1)) + 7
        gestures.changed(location: CGPoint(x: 50, y: lane1), startLocation: CGPoint(x: 50, y: lane1), modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.selectedSpanID, first)
        XCTAssertEqual(store.kenBurns?.spanID, first)
        XCTAssertEqual(store.engine.playbackState, .stopped)
        // Selecting the same span keeps the editor; another Motion span switches it.
        let opened = store.kenBurns
        store.select(span: first)
        XCTAssertTrue(store.kenBurns === opened)
        store.select(span: second)
        XCTAssertEqual(store.kenBurns?.spanID, second)
        // An Opacity span has no editor (the readout and the inspector instead).
        store.select(span: fade.spanID)
        XCTAssertNil(store.kenBurns)
        // Selecting a clip closes it (and deselects the span).
        store.select(span: first)
        XCTAssertNotNil(store.kenBurns)
        store.selection = [clip]
        XCTAssertNil(store.kenBurns)
        XCTAssertNil(store.selectedSpanID)
        // Escape closes it without a drag in progress; the span stays selected.
        store.select(span: first)
        let keyboard = KeyboardController(store: store)
        keyboard.perform(.cancel, on: store)
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.selectedSpanID, first)
        XCTAssertEqual(store.inspector.span?.spanID, first, "the inspector still shows it")
        // A click on the selected span reopens it, as does Ken Burns… in the inspector.
        gestures.changed(location: CGPoint(x: 50, y: lane1), startLocation: CGPoint(x: 50, y: lane1), modifiers: [])
        gestures.ended()
        XCTAssertEqual(store.kenBurns?.spanID, first)
        store.closeKenBurns()
        XCTAssertNil(store.kenBurns)
        store.showKenBurns(span: first)
        XCTAssertEqual(store.kenBurns?.spanID, first)
        // Escape through the key monitor: taken by the editor window, not by a text field.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            store.editorWindow = nil
            window.close()
        }
        store.editorWindow = window
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                    keyCode: 53))
        XCTAssertTrue(keyboard.handle(escape, window: window))
        XCTAssertNil(store.kenBurns)
        XCTAssertFalse(keyboard.handle(escape, window: window), "nothing to close: passed on")
        // Deselecting, removing the span and a new project close it too.
        store.showKenBurns(span: first)
        store.selectedSpanID = nil
        XCTAssertNil(store.kenBurns)
        store.select(span: second)
        XCTAssertTrue(store.engine.removeSpan(second).ok)
        XCTAssertNil(store.kenBurns)
        XCTAssertNil(store.selectedSpanID)
        store.select(span: first)
        store.newProject()
        XCTAssertNil(store.kenBurns)
    }

    func testANewMotionSpanOpensTheEditorOnItsPushIn() async throws {
        let clip = try await longClip()
        store.playheadTime = frames(60)
        store.addMotionSpanAtPlayhead(clip: clip)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.spanID, store.selectedSpanID)
        XCTAssertEqual(model.start, fullFrame, "the whole picture")
        XCTAssertEqual(model.end.width, 1920 * ProjectStore.defaultPushInFraction, accuracy: 1e-6, "a push in")
        XCTAssertEqual(model.end.midX, 960, accuracy: 1e-6)
        XCTAssertEqual(model.interpolation, .easeInOut, "FCP's default smoothing")
        XCTAssertEqual(model.rangeText(.start), "00:00:02:00")
        XCTAssertEqual(model.rangeText(.end), "00:00:07:00")
        XCTAssertEqual(model.rangeText(.duration), "00:00:05:00")
    }

    // MARK: Live drags

    func testDragsWriteTheSpanLiveOneUndoStepEachAndEscapeCancels() async throws {
        let clip = try await longClip()
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(clip: clip)
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID
        let pushIn = model.end
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)

        // Each step of the drag writes the span at once, from the drag's origin.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: 0), location: .zero)
        XCTAssertTrue(model.isDragging)
        XCTAssertTrue(store.isGestureActive)
        XCTAssertEqual(try span(id).endValues.x, -125, accuracy: 1e-9, "100 px of the rectangle at 1.25x")
        XCTAssertEqual(model.end.minX, pushIn.minX + 100, accuracy: 1e-9)
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 150, height: 0), location: .zero)
        XCTAssertEqual(try span(id).endValues.x, -187.5, accuracy: 1e-9)
        model.endDrag()
        XCTAssertFalse(model.isDragging)
        XCTAssertFalse(store.isGestureActive)
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        var edge = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&edge, atEdgeOfSpan: id, atEnd: true,
                                                                 frameDuration: store.frameDuration))
        XCTAssertEqual(edge.x, -187.5, accuracy: 1e-9, "the end shows the dragged rectangle")
        store.undo()
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9, "the drag was one undo step")
        XCTAssertEqual(model.end, pushIn, "re-read from the span")

        // A corner drag zooms: the opposite corner stays, the aspect stays the frame's.
        model.applyDrag(.corner(.start, .bottomRight), origin: model.start, translation: CGSize(width: -960, height: 0),
                        location: CGPoint(x: 960, y: 540))
        model.endDrag()
        XCTAssertEqual(model.start.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6)
        XCTAssertEqual(try span(id).startValues.scale, 2, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(try span(id).startValues.scale, 1, accuracy: 1e-9)

        // Escape mid-drag reverts it; nothing is recorded.
        let undoName = store.undoActionName
        let changes = store.changeCount
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: -80, height: 30), location: .zero)
        XCTAssertNotEqual(try span(id).endValues.x, 0)
        store.cancelActiveGesture?()
        XCTAssertFalse(model.isDragging)
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)
        XCTAssertEqual(model.end, pushIn)
        XCTAssertEqual(store.undoActionName, undoName)
        XCTAssertGreaterThanOrEqual(store.changeCount, changes)
        model.endDrag() // the cancelled gesture's release
        XCTAssertEqual(store.undoActionName, undoName)
        // A click without movement opens nothing.
        model.applyDrag(.body(.end), origin: pushIn, translation: .zero, location: .zero)
        XCTAssertFalse(model.isDragging)
        XCTAssertNil(store.engine.coalescingKey)
        // Rectangles stay inside the picture while dragged.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 5000, height: -5000), location: .zero)
        model.endDrag()
        XCTAssertEqual(model.end.maxX, 1920, accuracy: 1e-6)
        XCTAssertEqual(model.end.minY, 0, accuracy: 1e-6)
        // During another gesture a drag is refused with the reason.
        store.cancelActiveGesture = {}
        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: 10, height: 0), location: .zero)
        XCTAssertFalse(model.isDragging)
        XCTAssertEqual(model.note, "Finish the current drag first.")
        store.cancelActiveGesture = nil
    }

    /// Escape or Undo in the middle of a drag cancels the rest of that drag: the pointer moving on
    /// before the release writes nothing and opens no new undo step (review H2).
    func testMovementAfterACancelledDragChangesNothingUntilTheRelease() async throws {
        let clip = try await longClip()
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(clip: clip)
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID
        let pushIn = model.end
        let undoName = store.undoActionName
        let before = try span(id)

        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 60, height: 0), location: .zero)
        XCTAssertTrue(model.isDragging)
        store.cancelActiveGesture?() // Escape, or Cmd-Z through the store
        XCTAssertFalse(model.isDragging)
        XCTAssertFalse(store.isGestureActive)
        // The same gesture moves on: nothing is written, no group opens.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 120, height: 40), location: .zero)
        model.applyDrag(.corner(.end, .topLeft), origin: pushIn, translation: CGSize(width: 30, height: 0),
                        location: CGPoint(x: 400, y: 300))
        XCTAssertFalse(model.isDragging)
        XCTAssertNil(store.engine.coalescingKey)
        XCTAssertEqual(try span(id).endValues.x, before.endValues.x, accuracy: 1e-12)
        XCTAssertEqual(try span(id).endValues.scale, before.endValues.scale, accuracy: 1e-12)
        XCTAssertEqual(model.end, pushIn)
        model.endDrag() // the release
        XCTAssertEqual(store.undoActionName, undoName, "no undo step")
        XCTAssertEqual(try span(id).endValues.x, before.endValues.x, accuracy: 1e-12)
        XCTAssertEqual(model.end, pushIn)
        // The next gesture drags again.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: 0), location: .zero)
        model.endDrag()
        XCTAssertEqual(try span(id).endValues.x, -125, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        // A gesture the system abandons after a cancel (no release) also ends the cancelled state.
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 10, height: 0), location: .zero)
        model.cancelDrag()
        model.gestureAbandoned()
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 10, height: 0), location: .zero)
        XCTAssertTrue(model.isDragging, "a new gesture after the abandoned one drags")
        model.endDrag()
    }

    /// Review L8: when the editor cannot open on the selected span, the status line says why once;
    /// later model changes do not try again (no picture loader, no status rewrite) until the
    /// selection changes or Ken Burns… is asked for. And why it cannot, for a clip without a picture.
    func testAnEditorThatCannotOpenIsNotRetriedOnEveryModelChange() async throws {
        let clip = try await longClip()
        let id = try motionSpan(clip, 0, 60)
        let assetID = try XCTUnwrap(store.clips[clip]).assetID
        store.assetsByID[assetID] = nil // the store has not caught up with the media
        store.select(span: id)
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.kenBurnsOpenFailures, 1)
        XCTAssertEqual(store.statusMessage, "The media of “long.mov” is not in the project, so Ken Burns has no picture.")
        store.statusMessage = "something else"
        for n in 1 ... 5 {
            XCTAssertTrue(store.engine.setSpanInterpolation(id, interpolation: n % 2 == 0 ? .linear : .easeIn).ok)
        }
        XCTAssertEqual(store.kenBurnsOpenFailures, 1, "not retried per model change")
        XCTAssertEqual(store.statusMessage, "something else")
        // Asked for again (Ken Burns…), with the media there: it opens.
        store.refreshAssets()
        store.showKenBurns(span: id)
        XCTAssertEqual(store.kenBurns?.spanID, id)
        // The reason for a clip without a picture.
        let (_, tone) = try await fixture.importMedia()
        let span = try XCTUnwrap(store.engine.spanInfo(id))
        XCTAssertEqual(KenBurnsModel.problem(span: span, clip: try XCTUnwrap(store.clips[clip]), asset: tone,
                                             sequence: store.sequence), "Ken Burns works on a clip with a picture.")
        XCTAssertNil(KenBurnsModel.problem(span: span, clip: try XCTUnwrap(store.clips[clip]),
                                           asset: try XCTUnwrap(store.asset(assetID)), sequence: store.sequence))
    }

    // MARK: Re-reading

    func testTheFramingsAreReReadAfterAnEarlierSpanChanges() async throws {
        let clip = try await longClip()
        // Lane 1: a zoom to 2x over [0, 60), then a chained span over [90, 150) starting from it.
        let zoom = try motionSpan(clip, 0, 60, scale: (1, 2))
        let later = try motionSpan(clip, 90, 150)
        store.select(span: later)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6, "the zoom's held 2x")
        XCTAssertEqual(model.end.width, 960, accuracy: 1e-6)
        XCTAssertEqual(model.caption, KenBurnsModel.holdCaption, "it ends before the clip")
        // The earlier span's end changes: the later span's rectangles follow, its values stay.
        var to = VESpanValuesUnchanged()
        to.scale = 4
        XCTAssertTrue(store.engine.setSpanValues(zoom, start: VESpanValuesUnchanged(), end: to).ok)
        XCTAssertEqual(model.start.width, 480, accuracy: 1e-6)
        XCTAssertEqual(try span(later).startValues.scale, 1, accuracy: 1e-12)
        store.undo()
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6)
        // A drag on the later span is converted over the base it applies onto.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: -480, height: 0),
                        location: CGPoint(x: model.end.minX + 480, y: model.end.minY + 270))
        model.endDrag()
        XCTAssertEqual(model.end.width, 480, accuracy: 1e-6)
        XCTAssertEqual(try span(later).endValues.scale, 2, accuracy: 1e-9, "4x on screen over the held 2x")
    }

    // MARK: Picture, caption, fields, commands

    func testThePictureIsClampedToTheSpanAndTheCaptionStatesTheHold() async throws {
        let clip = try await longClip()
        let id = try motionSpan(clip, 60, 120)
        store.select(span: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.setPlayhead(frames(10))
        XCTAssertEqual(model.pictureFrame, frames(60), "before the span: its first frame")
        model.setPlayhead(frames(200))
        XCTAssertEqual(model.pictureFrame, frames(119), "after it: its last frame")
        model.setPlayhead(frames(90))
        XCTAssertEqual(model.pictureFrame, frames(90))
        XCTAssertEqual(model.pictureSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(model.caption, KenBurnsModel.holdCaption)
        // A span reaching the clip's end holds nothing after it: no caption.
        let tail = try motionSpan(clip, lane: 2, 240, 300)
        store.select(span: tail)
        XCTAssertNil(try XCTUnwrap(store.kenBurns).caption)
    }

    func testRangeFieldsSmoothingAndSwap() async throws {
        let clip = try await longClip()
        let other = try motionSpan(clip, 210, 270)
        store.playheadTime = frames(30)
        store.addMotionSpanAtPlayhead(clip: clip)
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID
        XCTAssertEqual([try span(id).start, try span(id).end], [frames(30), frames(180)])
        XCTAssertTrue(model.commitRange(.duration, "2s"))
        XCTAssertEqual(try span(id).end, frames(90))
        XCTAssertEqual(model.rangeText(.end), "00:00:03:00", "the fields follow the span")
        XCTAssertNil(model.note)
        XCTAssertTrue(model.commitRange(.end, "00:00:09:00"))
        XCTAssertEqual(try span(id).end, frames(210), "limited by the next span on the lane")
        XCTAssertEqual(model.note, "Limited to the free space on lane 1, 00:00:00:00 – 00:00:07:00.")
        XCTAssertFalse(model.commitRange(.start, "later"))
        XCTAssertTrue(model.note?.contains("is not a time") == true)
        model.nudgeRange(.start, steps: -1)
        XCTAssertEqual(try span(id).start, frames(29))
        XCTAssertNotNil(store.engine.spanInfo(other))

        // Smoothing and Swap, one undo step each.
        model.setInterpolation(.linear)
        XCTAssertEqual(try span(id).interpolation, .linear)
        XCTAssertEqual(model.interpolation, .linear)
        XCTAssertEqual(store.undoActionName, "Change Span Interpolation")
        let (start, end) = (model.start, model.end)
        model.swap()
        XCTAssertEqual(model.start.width, end.width, accuracy: 1e-6)
        XCTAssertEqual(model.end.width, start.width, accuracy: 1e-6)
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        store.undo()
        XCTAssertEqual(model.start.width, start.width, accuracy: 1e-6)
    }

    func testTheNeighbourTogglesMatchTheTouchingClips() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0) // [0, 60)
        let b = try fixture.placeMovie(movie, at: 2) // [60, 120)
        let d = try fixture.placeMovie(movie, at: 4) // [120, 180)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: -100, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: a).ok)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 40, scale: 1.2, rotationDegrees: 0, opacity: 1),
                                                  forClip: d).ok)
        let id = try motionSpan(b, 60, 120)
        store.select(span: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.previous?.clipID, a)
        XCTAssertEqual(model.next?.clipID, d)
        XCTAssertTrue(model.canContinueFromPrevious)
        XCTAssertFalse(model.continuesFromPrevious, "B shows its own framing")
        model.setContinuesFromPrevious(true)
        XCTAssertTrue(model.continuesFromPrevious)
        XCTAssertEqual(store.undoActionName, "Match Previous Clip")
        XCTAssertEqual(model.startFraming.scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.startFraming.x, -100, accuracy: 1e-6)
        model.setLeadsIntoNext(true)
        XCTAssertTrue(model.leadsIntoNext)
        XCTAssertEqual(model.endFraming.scale, 1.2, accuracy: 1e-9)
        // Off: that edge shows the clip's own framing again.
        model.setContinuesFromPrevious(false)
        XCTAssertFalse(model.continuesFromPrevious)
        XCTAssertEqual(model.startFraming.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(model.start, fullFrame)
        // B placed at half size, 200 px right (its own window): the toggles still match what the
        // neighbours show on screen, and the rectangles frame B's picture inside B's window. A's
        // 1.5x at -100 is 3x inside a 0.5 window 200 px right: a 640 px rectangle whose centre is
        // 600 window px / 3 = 200 px right of the frame's.
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 200, y: 0, scale: 0.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: b).ok)
        XCTAssertEqual(model.start, fullFrame, "neutral: B's whole picture in its window")
        XCTAssertEqual(model.startFraming.scale, 0.5, accuracy: 1e-12, "on screen: B's own half size")
        XCTAssertFalse(model.continuesFromPrevious)
        model.setContinuesFromPrevious(true)
        XCTAssertTrue(model.continuesFromPrevious)
        XCTAssertEqual(model.startFraming.scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.startFraming.x, -100, accuracy: 1e-6)
        XCTAssertEqual(try span(id).startValues.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(model.start.width, 640, accuracy: 1e-6)
        XCTAssertEqual(model.start.midX, 960 + 200, accuracy: 1e-6)
        XCTAssertEqual(model.windowCaption, "Inside the clip's framing: 50 %, right of centre")
        model.setContinuesFromPrevious(false)
        XCTAssertEqual(try span(id).startValues.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(model.start, fullFrame)
        // A span not starting on the clip's first frame cannot continue the previous clip.
        let later = try motionSpan(b, lane: 2, 70, 100)
        store.select(span: later)
        XCTAssertFalse(try XCTUnwrap(store.kenBurns).canContinueFromPrevious)
        // A neighbour that goes away goes from the editor.
        store.select(span: id)
        XCTAssertTrue(store.engine.removeClips([NSNumber(value: d)]).ok)
        XCTAssertNil(store.kenBurns?.next)
        XCTAssertFalse(store.kenBurns?.leadsIntoNext ?? true)
    }

    // MARK: A clip placed smaller or off centre (review C1)

    /// A picture-in-picture clip (static scale 0.3 at the lower right): the editor frames the clip's
    /// own picture inside its window, as Final Cut does. The rectangles are what the window shows (the
    /// whole frame box while the span is neutral), the window is outlined with a caption, and a drag
    /// stores values relative to the framing the clip already has (a scale near 1, never the ~3-8
    /// that made the clip a full-frame crop).
    func testAPictureInPictureClipIsEditedInsideItsOwnFraming() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0) // [0, 60)
        let neighbour = try fixture.placeMovie(movie, at: 2) // [60, 120)
        let pip = VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(pip, forClip: clip).ok)
        XCTAssertTrue(store.engine.setVideoParams(pip, forClip: neighbour).ok)
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(clip: clip)
        let model = try XCTUnwrap(store.kenBurns)
        let id = model.spanID

        // The neutral start is the whole picture; the push in is 80 % of it, centred.
        XCTAssertEqual(model.start.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(model.start.width, 1920, accuracy: 1e-6, "not 6400 px wide")
        XCTAssertEqual(model.end.width, 1920 * ProjectStore.defaultPushInFraction, accuracy: 1e-6)
        XCTAssertEqual(model.end.midX, 960, accuracy: 1e-6)
        XCTAssertEqual(model.end.midY, 540, accuracy: 1e-6)
        // The clip's window: the frame box through its static framing, outlined with a caption.
        let window = try XCTUnwrap(model.clipWindow)
        XCTAssertEqual(window.width, 576, accuracy: 1e-9)
        XCTAssertEqual(window.height, 324, accuracy: 1e-9)
        XCTAssertEqual(window.midX, 960 + 690, accuracy: 1e-9)
        XCTAssertEqual(window.midY, 540 + 324, accuracy: 1e-9)
        XCTAssertEqual(model.windowCaption, "Inside the clip's framing: 30 %, lower right")

        // A first drag step keeps the picture in its window: relative values near neutral.
        let pushIn = model.end
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: 0), location: .zero)
        XCTAssertEqual(try span(id).endValues.scale, 1.25, accuracy: 1e-9, "the push in's scale kept, not ~3.3")
        XCTAssertEqual(try span(id).endValues.x, -37.5, accuracy: 1e-9, "100 window px at 1.25x, in a 0.3 window")
        XCTAssertEqual(try span(id).endValues.y, 0, accuracy: 1e-9)
        model.endDrag()
        XCTAssertEqual(model.end.minX, pushIn.minX + 100, accuracy: 1e-6, "re-read from the span")
        var edge = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&edge, atEdgeOfSpan: id, atEnd: true,
                                                                 frameDuration: store.frameDuration))
        XCTAssertEqual(edge.scale, 0.375, accuracy: 1e-9, "on screen: 1.25 x 0.3")
        XCTAssertEqual(edge.x, 690 - 37.5, accuracy: 1e-9)

        // A corner drag to half the frame is a 2x zoom inside the window.
        model.applyDrag(.corner(.start, .bottomRight), origin: model.start, translation: CGSize(width: -960, height: 0),
                        location: CGPoint(x: 960, y: 540))
        model.endDrag()
        XCTAssertEqual(model.start.width, 960, accuracy: 1e-6)
        XCTAssertEqual(try span(id).startValues.scale, 2, accuracy: 1e-9)
        // The top-left quarter's centre (480 px left of and 270 px above the frame's) moves to the
        // window's centre at 2x: (960, 540) window px, 0.3 of that on screen.
        XCTAssertEqual(try span(id).startValues.x, 0.3 * 960, accuracy: 1e-9)
        XCTAssertEqual(try span(id).startValues.y, 0.3 * 540, accuracy: 1e-9)

        // Swap exchanges the two framings; the picture stays in its window.
        let (start, end) = (model.start, model.end)
        model.swap()
        XCTAssertEqual(model.start.width, end.width, accuracy: 1e-6)
        XCTAssertEqual(model.end.width, start.width, accuracy: 1e-6)
        XCTAssertEqual(model.end.midX, start.midX, accuracy: 1e-6)
        XCTAssertEqual(try span(id).startValues.scale, 1.25, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.scale, 2, accuracy: 1e-9)

        // The neighbour toggle: the next clip starts neutral in the same window, so leading into it
        // gives the end the window's own framing (relative scale 1), and turning it off does too.
        XCTAssertEqual(model.next?.clipID, neighbour)
        XCTAssertFalse(model.leadsIntoNext)
        model.setLeadsIntoNext(true)
        XCTAssertTrue(model.leadsIntoNext)
        XCTAssertEqual(try span(id).endValues.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)
        XCTAssertEqual(model.end.width, 1920, accuracy: 1e-6)
        XCTAssertEqual(model.endFraming.scale, 0.3, accuracy: 1e-9, "the framing on screen")
        XCTAssertEqual(model.endFraming.x, 690, accuracy: 1e-9)
        model.setLeadsIntoNext(false)
        XCTAssertEqual(try span(id).endValues.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(try span(id).startValues.scale, 1.25, accuracy: 1e-9, "the start keeps its framing")
    }

    /// An offset and turned clip: the rectangles move in the window's own axes, and the values
    /// written go back through the window's rotation and scale.
    func testATurnedAndOffsetClipIsEditedInItsWindowsAxes() async throws {
        let clip = try await longClip()
        let placed = VEVideoParams(x: 100, y: 0, scale: 0.5, rotationDegrees: 90, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(placed, forClip: clip).ok)
        let id = try motionSpan(clip, 0, 90)
        store.select(span: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.start, fullFrame, "neutral: the whole picture")
        XCTAssertEqual(model.windowCaption, "Inside the clip's framing: 50 %, right of centre, turned 90°")
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: -960, height: -540),
                        location: CGPoint(x: 960, y: 540))
        model.endDrag()
        XCTAssertEqual(try span(id).endValues.scale, 2, accuracy: 1e-9)
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 100, height: 0), location: .zero)
        model.endDrag()
        // The half-frame rectangle at the top-left is (960, 540) in the window's axes; moved 100 px
        // right it is (760, 540). Turned 90° (clockwise, +y down) and scaled by 0.5 on screen:
        // (-270, 380) from the clip's position.
        XCTAssertEqual(try span(id).endValues.x, -270, accuracy: 1e-6)
        XCTAssertEqual(try span(id).endValues.y, 380, accuracy: 1e-6)
        XCTAssertEqual(try span(id).endValues.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(model.end.minX, 100, accuracy: 1e-6)
        XCTAssertEqual(model.end.minY, 0, accuracy: 1e-6)
        var edge = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&edge, atEdgeOfSpan: id, atEnd: true,
                                                                 frameDuration: store.frameDuration))
        XCTAssertEqual(edge.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(edge.rotationDegrees, 90, accuracy: 1e-9)
        let rect = KenBurnsModel.rect(for: KenBurnsModel.windowFraming(edge, in: placed).framing,
                                      sequence: model.sequenceSize, rotationDegrees: 0)
        XCTAssertEqual(rect.minX, model.end.minX, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, model.end.minY, accuracy: 1e-6)
    }

    // MARK: Geometry

    func testKenBurnsGeometry() {
        let sequence = CGSize(width: 1920, height: 1080)
        // A rectangle's framing and back, with and without the clip's rotation.
        for rotation in [0.0, 30.0, -90.0] {
            let rect = CGRect(x: 300, y: 200, width: 960, height: 540)
            let framing = KenBurnsModel.framing(for: rect, sequence: sequence, rotationDegrees: rotation)
            XCTAssertEqual(framing.scale, 2, accuracy: 1e-12)
            let back = KenBurnsModel.rect(for: framing, sequence: sequence, rotationDegrees: rotation)
            XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9)
            XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9)
            XCTAssertEqual(back.width, rect.width, accuracy: 1e-9)
        }
        // Unrotated: the rectangle's centre (180 px right of and 70 px below the frame's centre, at
        // 2x) moves to the frame's centre.
        let framing = KenBurnsModel.framing(for: CGRect(x: 660, y: 340, width: 960, height: 540), sequence: sequence,
                                            rotationDegrees: 0)
        XCTAssertEqual(framing.x, -360, accuracy: 1e-9)
        XCTAssertEqual(framing.y, -140, accuracy: 1e-9)
        // The whole frame is the identity.
        let whole = KenBurnsModel.framing(for: CGRect(origin: .zero, size: sequence), sequence: sequence,
                                          rotationDegrees: 0)
        XCTAssertEqual(whole.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(whole.x, 0, accuracy: 1e-12)
        // A portrait picture is pillarboxed; the largest frame-shaped rectangle fits its width.
        let portrait = KenBurnsModel.fittedPicture(width: 1080, height: 1920, in: sequence)
        XCTAssertEqual(portrait.width, 607.5, accuracy: 1e-9)
        let largest = KenBurnsModel.largestRect(in: portrait, aspect: 16.0 / 9.0)
        XCTAssertEqual(largest.width, portrait.width, accuracy: 1e-9)
        XCTAssertEqual(largest.midY, 540, accuracy: 1e-9)
    }

    // MARK: Which rectangle a press grabs

    func testTheStartRectangleIsReachableUnderTheEnd() {
        // The default push in: the end (80 %) centred inside the start.
        let start = CGRect(x: 0, y: 0, width: 400, height: 225)
        let end = CGRect(x: 40, y: 22.5, width: 320, height: 180)
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 20, y: 100), start: start, end: end), .body(.start),
                       "the start's margin around the end")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 200, y: 110), start: start, end: end), .body(.end),
                       "inside both: the smaller one")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 25, y: 10), start: start, end: end), .body(.start), "its label")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 398, y: 223), start: start, end: end),
                       .corner(.start, .bottomRight))
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 41, y: 23), start: start, end: end), .corner(.end, .topLeft))
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 338, y: 195), start: start, end: end), .body(.end),
                       "the end's label at its bottom-right")
        XCTAssertNil(KenBurnsHit.target(at: CGPoint(x: 500, y: 300), start: start, end: end))
    }

    func testCoincidingRectanglesShareTheirHandles() {
        // An unanimated placed clip: both rectangles are the clip's framing.
        let rect = CGRect(x: 100, y: 50, width: 400, height: 225)
        func target(_ x: CGFloat, _ y: CGFloat) -> KenBurnsHit.Target? {
            KenBurnsHit.target(at: CGPoint(x: x, y: y), start: rect, end: rect)
        }
        XCTAssertEqual(target(110, 55), .body(.start), "the start's label (top-left)")
        XCTAssertEqual(target(490, 270), .body(.end), "the end's label (bottom-right)")
        XCTAssertEqual(target(101, 51), .corner(.start, .topLeft))
        XCTAssertEqual(target(101, 274), .corner(.start, .bottomLeft))
        XCTAssertEqual(target(499, 51), .corner(.end, .topRight))
        XCTAssertEqual(target(499, 274), .corner(.end, .bottomRight))
        XCTAssertEqual(target(300, 52), .body(.start), "the top edge")
        XCTAssertEqual(target(102, 150), .body(.start), "the left edge")
        XCTAssertEqual(target(300, 273), .body(.end), "the bottom edge")
        XCTAssertEqual(target(498, 150), .body(.end), "the right edge")
        XCTAssertEqual(target(300, 160), .body(.end), "the inside")
    }

    // MARK: Picture loader

    /// A picture source the test answers by hand: each fetch waits until `land` or `fail`.
    private final class ScriptedPictures {
        struct Request {
            let millis: Int64
            let completion: (CGImage?, Error?) -> Void
        }

        private(set) var requests: [Request] = []
        private var answered = 0

        func fetch(_ asset: VEAssetID, _ time: CMTime, _ size: Int, _ completion: @escaping (CGImage?, Error?) -> Void) {
            requests.append(Request(millis: time.value * 1000 / Int64(time.timescale), completion: completion))
        }

        var pending: Request? { answered < requests.count ? requests[answered] : nil }

        /// Answers the oldest open request with a picture (1x1, tagged by its time in the colour).
        @discardableResult
        func land() -> CGImage? {
            guard let request = pending else { return nil }
            answered += 1
            let image = Self.picture()
            request.completion(image, nil)
            return image
        }

        func fail() {
            guard let request = pending else { return }
            answered += 1
            request.completion(nil, NSError(domain: "Test", code: 1))
        }

        static func picture() -> CGImage? {
            CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    func testKenBurnsPictureLoaderShowsEveryLandedPictureWhileScrubbingOneFetchAtATime() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 4, fetch: source.fetch)
        // A scrub: many times while nothing has landed start one fetch.
        for frame in stride(from: 0, through: 12, by: 3) {
            loader.want(seconds: Double(frame) / 30)
        }
        XCTAssertEqual(loader.fetchesStarted, 1)
        XCTAssertEqual(source.pending?.millis, 0)
        XCTAssertNil(loader.image, "nothing to show before the first picture")

        // Three landings while the playhead keeps moving: each landed picture shows at once (the
        // preview never freezes on the first one), and the latest wanted time is fetched next.
        var shown: [CGImage] = []
        for step in 1 ... 3 {
            let landed = try XCTUnwrap(source.land())
            XCTAssertTrue(loader.image === landed, "landing \(step) shows its picture")
            shown.append(landed)
            XCTAssertEqual(loader.fetchesStarted, step + 1, "the latest time follows")
            XCTAssertEqual(source.pending?.millis, Int64((Double(12 + 3 * (step - 1)) / 30 * 1000).rounded()))
            loader.want(seconds: Double(12 + 3 * step) / 30) // the scrub goes on
        }
        XCTAssertEqual(Set(shown.map(ObjectIdentifier.init)).count, 3)

        // The scrub stops at 0.7 s: 0.6 s lands, then the wanted 0.7 s, which stays.
        source.land()
        let final = try XCTUnwrap(source.land())
        XCTAssertTrue(loader.image === final)
        XCTAssertNil(loader.pendingSeconds)
        XCTAssertNil(source.pending)
        // A kept time (0.5 s, the third landing) shows at once without a fetch; one the capacity of
        // four pushed out (0 s, the first) is fetched again.
        let fetches = loader.fetchesStarted
        loader.want(seconds: 0.5)
        XCTAssertTrue(loader.image === shown[2])
        XCTAssertEqual(loader.fetchesStarted, fetches)
        loader.want(seconds: 0)
        XCTAssertEqual(loader.fetchesStarted, fetches + 1)
        XCTAssertEqual(source.pending?.millis, 0)
        XCTAssertTrue(loader.image === shown[2], "the last picture stays up meanwhile")
    }

    func testKenBurnsPictureLoaderMovesOnAfterAFailedFetchAndKeepsTheLastPicture() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 4, fetch: source.fetch)
        loader.want(seconds: 1)
        let first = try XCTUnwrap(source.land())
        loader.want(seconds: 2)
        loader.want(seconds: 3) // wanted while 2 is in flight
        source.fail()
        XCTAssertEqual(loader.fetchesFailed, 1)
        XCTAssertTrue(loader.image === first, "the last picture stays up")
        XCTAssertEqual(source.pending?.millis, 3000, "the failure re-drives the loader to the latest time")
        source.fail()
        XCTAssertNil(source.pending, "a time that just failed is not fetched again in a loop")
        XCTAssertEqual(loader.fetchesStarted, 3)
        // Wanting another time and coming back tries it again.
        loader.want(seconds: 4)
        let fourth = try XCTUnwrap(source.land())
        XCTAssertTrue(loader.image === fourth)
        loader.want(seconds: 3)
        XCTAssertEqual(source.pending?.millis, 3000)
    }

    func testKenBurnsPictureLoaderMemoryIsBounded() throws {
        let source = ScriptedPictures()
        let loader = KenBurnsPictureLoader(assetID: 1, capacity: 5, fetch: source.fetch)
        // A long scrub back and forth over 300 distinct frames.
        for pass in 0 ..< 2 {
            for frame in 0 ..< 150 {
                loader.want(seconds: Double(pass == 0 ? frame : 149 - frame) / 30)
                source.land()
                XCTAssertLessThanOrEqual(loader.cachedCount, 5)
            }
        }
        XCTAssertEqual(loader.cachedCount, 5)
        // Memory pressure keeps only the picture on screen.
        let onScreen = loader.image
        loader.handleMemoryPressure()
        XCTAssertEqual(loader.cachedCount, 1)
        XCTAssertTrue(loader.image === onScreen)
    }

    func testTheEditorLoadsItsPictureFromTheEngineWithoutTheSharedCache() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.select(span: try motionSpan(clip, 0, 60))
        let loader = try XCTUnwrap(store.kenBurns?.picture)
        let thumbnails = store.thumbnails
        let requestsBefore = thumbnails.requestsStarted
        let versionBefore = thumbnails.version
        loader.want(seconds: 0.5)
        let landed = await StoreFixture.wait(until: { loader.image != nil }, timeout: 20)
        XCTAssertTrue(landed, "a real picture arrives from the engine")
        XCTAssertEqual(loader.image?.width, min(KenBurnsPictureLoader.maxDimension, Int(movie.width)),
                       "the whole picture, at most the editor's size")
        await StoreFixture.wait(until: { false }, timeout: 0.2)
        XCTAssertEqual(thumbnails.requestsStarted, requestsBefore, "the shared thumbnail cache is not used")
        XCTAssertEqual(thumbnails.version, versionBefore, "nothing bumps the timeline's and bin's redraw token")
    }
}
