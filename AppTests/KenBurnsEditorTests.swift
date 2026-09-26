import AppKit
import CoreGraphics
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Ken Burns editor bound to a Motion span: it opens when a Motion span is selected, switches
/// with the selection, closes on deselecting, on selecting a clip and on Escape (the span stays
/// selected; a click or Ken Burns… reopens it). Its boxes are the clip's placement at the span's
/// start and end (the picture fitted into the frame, then the edge's composed scale, position and
/// rotation): a body drag moves the clip, a corner drag scales it about its centre, each written live
/// as absolute placement converted over the base, one undo step each, Escape mid-drag cancels. The
/// boxes are re-read after an earlier span changes; the other visible clips are outlined at the
/// playhead; the hold-after caption; the range fields, the smoothing, Swap and the neighbour toggles.
/// Also the box geometry, the margin's mapping and which box a press grabs. The movie is 2 s (60
/// frames) at 320x180 (it fills the 1920x1080 frame); the long movie 10 s (300 frames).
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

    private let sequence = CGSize(width: 1920, height: 1080)

    /// The box of a clip filling the frame (no static values).
    private var fullFrame: KenBurnsBox {
        KenBurnsBox(center: CGPoint(x: 960, y: 540), size: CGSize(width: 1920, height: 1080), rotationDegrees: 0)
    }

    private func assertBox(_ box: KenBurnsBox, center: CGPoint, size: CGSize, rotation: Double = 0,
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.center.x, center.x, accuracy: 1e-6, "centre x " + message, file: file, line: line)
        XCTAssertEqual(box.center.y, center.y, accuracy: 1e-6, "centre y " + message, file: file, line: line)
        XCTAssertEqual(box.size.width, size.width, accuracy: 1e-6, "width " + message, file: file, line: line)
        XCTAssertEqual(box.size.height, size.height, accuracy: 1e-6, "height " + message, file: file, line: line)
        XCTAssertEqual(box.rotationDegrees, rotation, accuracy: 1e-9, "rotation " + message, file: file, line: line)
    }

    /// The Motion an edge of `span` shows (absolute).
    private func edge(_ span: VESpanID, of clip: VEClipID, atEnd: Bool) throws -> VEVideoParams {
        var motion = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&motion, atEdgeOfSpan: span, atEnd: atEnd,
                                                                 frameDuration: store.frameDuration))
        return motion
    }

    /// A 240x320 portrait still on the last video track at `seconds`.
    private func portraitStill(at seconds: Double) async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("portrait.heic")
        try TestMediaFactory.writeHEIC(to: url, width: 240, height: 320)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let photo = try XCTUnwrap(imported.first)
        XCTAssertTrue(photo.isStill)
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        return try fixture.placeMovie(photo, at: seconds, track: v2)
    }

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
        // A full-frame clip opens in Ken Burns mode (the automatic rule): the start rectangle is the
        // whole picture, the push in's end rectangle 1 / 1.25 of the frame about the same centre, and
        // the monitor shows the clip alone.
        XCTAssertEqual(model.mode, .kenBurns)
        assertBox(model.start, center: fullFrame.center, size: fullFrame.size, "the whole picture fills the frame")
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 1536, height: 864), "the push in")
        XCTAssertEqual(store.engine.programPreviewSoloClipID, clip)
        XCTAssertEqual(store.kenBurnsMode, .kenBurns)
        // In Transform mode the same values: the clip where it is, the whole frame, and a box 1.25
        // times the frame about the same centre.
        model.setMode(.transform)
        XCTAssertEqual(store.engine.programPreviewSoloClipID, 0, "the program again")
        XCTAssertEqual(model.start, fullFrame, "the clip where it is: the whole frame")
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 2400, height: 1350), "the push in")
        XCTAssertEqual(model.endFraming.scale, 1.25, accuracy: 1e-12)
        XCTAssertEqual(model.interpolation, .easeInOut, "FCP's default smoothing")
        XCTAssertEqual(model.rangeText(.start), "00:00:02:00")
        XCTAssertEqual(model.rangeText(.end), "00:00:07:00")
        XCTAssertEqual(model.rangeText(.duration), "00:00:05:00")
    }

    // MARK: Live drags

    func testDragsWriteTheSpanLiveOneUndoStepEachAndEscapeCancels() async throws {
        let clip = try await longClip()
        store.playheadTime = .zero
        store.addMotionSpanAtPlayhead(clip: clip, mode: .transform)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.mode, .transform, "Transform mode's boxes (Ken Burns mode: `testKenBurnsMode...`)")
        // The push in, asked for in Transform mode (a Move would end where it starts).
        var zoom = VESpanValuesUnchanged()
        zoom.scale = 1.25
        XCTAssertTrue(store.engine.setSpanValues(model.spanID, start: VESpanValuesUnchanged(), end: zoom).ok)
        let id = model.spanID
        let pushIn = model.end
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)

        // Each step of a body drag moves the clip by the drag, from the drag's origin.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: 0))
        XCTAssertTrue(model.isDragging)
        XCTAssertTrue(store.isGestureActive)
        XCTAssertEqual(try span(id).endValues.x, 100, accuracy: 1e-9, "the box's 100 px")
        XCTAssertEqual(model.end.center.x, 1060, accuracy: 1e-9)
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 150, height: -20))
        XCTAssertEqual(try span(id).endValues.x, 150, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.y, -20, accuracy: 1e-9)
        model.endDrag()
        XCTAssertFalse(model.isDragging)
        XCTAssertFalse(store.isGestureActive)
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        XCTAssertEqual(try edge(id, of: clip, atEnd: true).x, 150, accuracy: 1e-9, "the end shows the dragged box")
        XCTAssertEqual(try edge(id, of: clip, atEnd: true).scale, 1.25, accuracy: 1e-12, "its size kept")
        store.undo()
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9, "the drag was one undo step")
        XCTAssertEqual(model.end, pushIn, "re-read from the span")

        // A corner drag scales about the centre: the bottom-right corner pulled out along its
        // diagonal by a fifth of it is a box 1.2 times larger, centred where it was.
        model.applyDrag(.corner(.start, .bottomRight), origin: model.start,
                        translation: CGSize(width: 192, height: 108))
        model.endDrag()
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: CGSize(width: 2304, height: 1296))
        XCTAssertEqual(try span(id).startValues.scale, 1.2, accuracy: 1e-9)
        XCTAssertEqual(try span(id).startValues.x, 0, accuracy: 1e-9)
        // Only the movement along the diagonal counts (the aspect stays): the same corner moved
        // across the diagonal changes nothing.
        let grown = model.start
        model.applyDrag(.corner(.start, .bottomRight), origin: grown, translation: CGSize(width: 54, height: -96))
        XCTAssertEqual(model.start.size.width, grown.size.width, accuracy: 1e-6)
        store.cancelActiveGesture?()
        model.endDrag()
        store.undo()
        XCTAssertEqual(try span(id).startValues.scale, 1, accuracy: 1e-9)

        // Escape mid-drag reverts it; nothing is recorded.
        let undoName = store.undoActionName
        let changes = store.changeCount
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: -80, height: 30))
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
        model.applyDrag(.body(.end), origin: pushIn, translation: .zero)
        XCTAssertFalse(model.isDragging)
        XCTAssertNil(store.engine.coalescingKey)
        // A box goes off the frame, its centre up to a fifth of the frame beyond the edge (still
        // inside the margin the editor shows).
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 5000, height: -5000))
        model.endDrag()
        XCTAssertEqual(model.end.center.x, 1920 + 384, accuracy: 1e-6)
        XCTAssertEqual(model.end.center.y, -216, accuracy: 1e-6)
        XCTAssertEqual(try span(id).endValues.x, 1920 + 384 - 960, accuracy: 1e-6)
        XCTAssertEqual(try span(id).endValues.y, -216 - 540, accuracy: 1e-6)
        // A box placed further out (typed in the inspector) is not pulled in by a drag's first step:
        // it moves by the drag, and back towards the frame freely.
        store.inspector.commitSpanValue(.positionX, atEnd: true, "3000")
        XCTAssertEqual(model.end.center.x, 3960, accuracy: 1e-6)
        let far = model.end
        model.applyDrag(.body(.end), origin: far, translation: CGSize(width: 10, height: 0))
        XCTAssertEqual(model.end.center.x, 3960, accuracy: 1e-6, "no further out")
        model.applyDrag(.body(.end), origin: far, translation: CGSize(width: -40, height: 0))
        XCTAssertEqual(model.end.center.x, 3920, accuracy: 1e-6, "no jump: 40 px back in")
        model.endDrag()
        XCTAssertEqual(try span(id).endValues.x, 2960, accuracy: 1e-6)
        // A corner pulled past the centre stops at the smallest box (2 % of the frame's width), one
        // pulled far out at ten frames.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end,
                        translation: CGSize(width: -5000, height: -5000))
        model.endDrag()
        XCTAssertEqual(model.end.size.width, 1920 * KenBurnsModel.minimumBoxFraction, accuracy: 1e-6)
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end,
                        translation: CGSize(width: 90000, height: 50000))
        model.endDrag()
        XCTAssertEqual(model.end.size.width, 1920 * KenBurnsModel.maximumBoxFrames, accuracy: 1e-6)
        XCTAssertEqual(try span(id).endValues.scale, KenBurnsModel.maximumBoxFrames, accuracy: 1e-9)
        // During another gesture a drag is refused with the reason.
        store.cancelActiveGesture = {}
        model.applyDrag(.body(.start), origin: model.start, translation: CGSize(width: 10, height: 0))
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
        for mode in [KenBurnsMode.kenBurns, .transform] {
            try checkCancelledDrag(in: mode)
        }
    }

    /// `testMovementAfterACancelledDragChangesNothingUntilTheRelease` in one of the editor's modes. A
    /// body drag of 100 px moves the clip 100 px (Transform), or pans the rectangle 100 px over the
    /// picture, which moves the clip 125 px the other way at the push in's 1.25x (Ken Burns).
    private func checkCancelledDrag(in mode: KenBurnsMode) throws {
        let model = try XCTUnwrap(store.kenBurns)
        model.setMode(mode)
        XCTAssertEqual(model.mode, mode)
        let id = model.spanID
        let pushIn = model.end
        let undoName = store.undoActionName
        let before = try span(id)
        let moved = mode == .transform ? 100.0 : -125.0

        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 60, height: 0))
        XCTAssertTrue(model.isDragging)
        store.cancelActiveGesture?() // Escape, or Cmd-Z through the store
        XCTAssertFalse(model.isDragging)
        XCTAssertFalse(store.isGestureActive)
        // The same gesture moves on: nothing is written, no group opens.
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 120, height: 40))
        model.applyDrag(.corner(.end, .topLeft), origin: pushIn, translation: CGSize(width: 30, height: 0))
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
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 100, height: 0))
        model.endDrag()
        XCTAssertEqual(try span(id).endValues.x, before.endValues.x + moved, accuracy: 1e-9, "\(mode)")
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        // A gesture the system abandons after a cancel (no release) also ends the cancelled state.
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 10, height: 0))
        model.cancelDrag()
        model.gestureAbandoned()
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 10, height: 0))
        XCTAssertTrue(model.isDragging, "a new gesture after the abandoned one drags")
        model.endDrag()
        // Back to where this mode started (two drags, two undo steps).
        store.undo()
        store.undo()
        XCTAssertEqual(try span(id).endValues.x, before.endValues.x, accuracy: 1e-9)
    }

    /// Review L8: when the editor cannot open on the selected span, the status line says why once;
    /// later model changes do not try again (no status rewrite) until the selection changes or Ken
    /// Burns… is asked for. And why it cannot, for a clip without a picture.
    func testAnEditorThatCannotOpenIsNotRetriedOnEveryModelChange() async throws {
        let clip = try await longClip()
        let id = try motionSpan(clip, 0, 60)
        let assetID = try XCTUnwrap(store.clips[clip]).assetID
        store.assetsByID[assetID] = nil // the store has not caught up with the media
        store.select(span: id)
        XCTAssertNil(store.kenBurns)
        XCTAssertEqual(store.kenBurnsOpenFailures, 1)
        XCTAssertEqual(store.statusMessage, "The media of “long.mov” is not in the project, so Ken Burns does not "
            + "know its picture's size.")
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

    func testTheBoxesAreReReadAfterAnEarlierSpanChanges() async throws {
        let clip = try await longClip()
        // Lane 1: a zoom to 2x over [0, 60), then a chained span over [90, 150) starting from it.
        let zoom = try motionSpan(clip, 0, 60, scale: (1, 2))
        let later = try motionSpan(clip, 90, 150)
        store.select(span: later)
        let model = try XCTUnwrap(store.kenBurns)
        model.setMode(.transform)
        XCTAssertEqual(model.start.size.width, 3840, accuracy: 1e-6, "the zoom's held 2x")
        XCTAssertEqual(model.end.size.width, 3840, accuracy: 1e-6)
        XCTAssertEqual(model.caption, KenBurnsModel.holdCaption, "it ends before the clip")
        // The earlier span's end changes: the later span's boxes follow, its values stay.
        var to = VESpanValuesUnchanged()
        to.scale = 4
        XCTAssertTrue(store.engine.setSpanValues(zoom, start: VESpanValuesUnchanged(), end: to).ok)
        XCTAssertEqual(model.start.size.width, 7680, accuracy: 1e-6)
        XCTAssertEqual(try span(later).startValues.scale, 1, accuracy: 1e-12)
        store.undo()
        XCTAssertEqual(model.start.size.width, 3840, accuracy: 1e-6)
        // A drag on the later span is converted over the base it applies onto: its end box pulled to
        // twice its size shows 4x on screen, stored as 2x over the held 2x.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: 1920, height: 1080))
        model.endDrag()
        XCTAssertEqual(model.end.size.width, 7680, accuracy: 1e-6)
        XCTAssertEqual(try span(later).endValues.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(try edge(later, of: clip, atEnd: true).scale, 4, accuracy: 1e-9)
    }

    // MARK: Caption, fields, commands

    func testTheCaptionStatesTheHold() async throws {
        let clip = try await longClip()
        let id = try motionSpan(clip, 60, 120)
        store.select(span: id)
        XCTAssertEqual(try XCTUnwrap(store.kenBurns).caption, KenBurnsModel.holdCaption)
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
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: -300, height: 100))
        model.endDrag()
        let (start, end) = (model.start, model.end)
        model.swap()
        assertBox(model.start, center: end.center, size: end.size, "swapped")
        assertBox(model.end, center: start.center, size: start.size, "swapped")
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        store.undo()
        assertBox(model.start, center: start.center, size: start.size, "undone")
        assertBox(model.end, center: end.center, size: end.size, "undone")
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
        model.setMode(.transform)
        XCTAssertEqual(model.previous?.clipID, a)
        XCTAssertEqual(model.next?.clipID, d)
        XCTAssertTrue(model.canContinueFromPrevious)
        XCTAssertFalse(model.continuesFromPrevious, "B shows its own placement")
        model.setContinuesFromPrevious(true)
        XCTAssertTrue(model.continuesFromPrevious)
        XCTAssertEqual(store.undoActionName, "Match Previous Clip")
        XCTAssertEqual(model.startFraming.scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.startFraming.x, -100, accuracy: 1e-6)
        assertBox(model.start, center: CGPoint(x: 860, y: 540), size: CGSize(width: 2880, height: 1620),
                  "where A's last frame is")
        model.setLeadsIntoNext(true)
        XCTAssertTrue(model.leadsIntoNext)
        XCTAssertEqual(model.endFraming.scale, 1.2, accuracy: 1e-9)
        assertBox(model.end, center: CGPoint(x: 960, y: 580), size: CGSize(width: 2304, height: 1296),
                  "where D's first frame is")
        // Off: that edge shows the clip's own placement again.
        model.setContinuesFromPrevious(false)
        XCTAssertFalse(model.continuesFromPrevious)
        XCTAssertEqual(model.start, fullFrame)
        // B placed at half size, 200 px right: its own placement is a half-frame box there, and
        // continuing A puts the start box where A is (3x over B's half size, 300 px left of B).
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 200, y: 0, scale: 0.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: b).ok)
        assertBox(model.start, center: CGPoint(x: 1160, y: 540), size: CGSize(width: 960, height: 540))
        XCTAssertEqual(model.startFraming.scale, 0.5, accuracy: 1e-12)
        XCTAssertFalse(model.continuesFromPrevious)
        model.setContinuesFromPrevious(true)
        XCTAssertTrue(model.continuesFromPrevious)
        assertBox(model.start, center: CGPoint(x: 860, y: 540), size: CGSize(width: 2880, height: 1620))
        XCTAssertEqual(try span(id).startValues.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(try span(id).startValues.x, -300, accuracy: 1e-9)
        model.setContinuesFromPrevious(false)
        XCTAssertEqual(try span(id).startValues.scale, 1, accuracy: 1e-12)
        assertBox(model.start, center: CGPoint(x: 1160, y: 540), size: CGSize(width: 960, height: 540))
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

    /// A portrait still is pillarboxed as the compositor fits it: its box (Transform mode) is the
    /// fitted picture (810x1080 for 240x320 in a 1920x1080 frame), and the push in grows that box.
    /// Control-K opens it in Ken Burns mode (it spans the frame top to bottom, `automaticMode`).
    func testAPortraitStillsBoxIsItsFittedPicture() async throws {
        let still = try await portraitStill(at: 20)
        store.selection = [still]
        store.playheadTime = frames(600)
        store.addMotionSpanAtPlayhead()
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.mode, .kenBurns)
        model.setMode(.transform)
        XCTAssertEqual(model.pictureSize, CGSize(width: 240, height: 320))
        assertBox(model.start, center: CGPoint(x: 960, y: 540), size: CGSize(width: 810, height: 1080))
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 1012.5, height: 1350))
        // A corner drag keeps the picture's aspect, not the frame's.
        model.applyDrag(.corner(.end, .topLeft), origin: model.end, translation: CGSize(width: 101.25, height: 135))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 960, y: 540), size: CGSize(width: 810, height: 1080))
        XCTAssertEqual(model.endFraming.scale, 1, accuracy: 1e-9)
    }

    // MARK: A clip placed smaller, off centre or turned (review C1, the placement-box model)

    /// A picture in picture (static scale 0.3 at the lower right): the Start box is where the clip
    /// is, the End box the push in about the same centre. Dragging the End box to the top of the
    /// frame stores the matching position, a corner drag the matching scale, and the inspector's
    /// absolute values are what the box shows.
    func testAPictureInPictureIsMovedAndScaledWhereItIs() async throws {
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

        // The Start box is the picture in picture itself (576x324, centred 690 px right of and 324 px
        // below the frame's centre); the End box the push in, 1.25 times larger, same centre.
        assertBox(model.start, center: CGPoint(x: 1650, y: 864), size: CGSize(width: 576, height: 324), "the clip")
        assertBox(model.end, center: CGPoint(x: 1650, y: 864), size: CGSize(width: 720, height: 405), "the push in")
        XCTAssertEqual(model.startFraming.scale, 0.3, accuracy: 1e-12)
        XCTAssertEqual(model.startFraming.x, 690, accuracy: 1e-12)

        // The End box dragged up until its top edge meets the frame's: the clip slides to the top.
        let pushIn = model.end
        model.applyDrag(.body(.end), origin: pushIn, translation: CGSize(width: 0, height: 202.5 - 864))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 1650, y: 202.5), size: CGSize(width: 720, height: 405))
        XCTAssertEqual(model.end.corner(.topLeft).y, 0, accuracy: 1e-9, "at the top of the frame")
        XCTAssertEqual(try span(id).endValues.y, 202.5 - 864, accuracy: 1e-9, "relative to the static 324")
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.scale, 1.25, accuracy: 1e-9, "the push in's scale kept")
        XCTAssertEqual(try edge(id, of: clip, atEnd: true).y, -337.5, accuracy: 1e-9, "on screen")
        XCTAssertEqual(store.inspector.spanText(.positionY, atEnd: true, of: try span(id)), "-337.5 px",
                       "the inspector shows the box's placement")
        XCTAssertEqual(store.inspector.spanText(.positionY, atEnd: false, of: try span(id)), "324 px")

        // A corner drag to twice the box's size: 0.75 on screen, 2.5 over the static 0.3.
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: 360, height: 202.5))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 1650, y: 202.5), size: CGSize(width: 1440, height: 810))
        XCTAssertEqual(try span(id).endValues.scale, 2.5, accuracy: 1e-9)
        XCTAssertEqual(try edge(id, of: clip, atEnd: true).scale, 0.75, accuracy: 1e-9)
        XCTAssertEqual(store.inspector.spanText(.scale, atEnd: true, of: try span(id)), "75 %")
        // The start is untouched.
        assertBox(model.start, center: CGPoint(x: 1650, y: 864), size: CGSize(width: 576, height: 324))

        // Swap exchanges the two placements.
        let (start, end) = (model.start, model.end)
        model.swap()
        XCTAssertEqual(model.start.center.y, end.center.y, accuracy: 1e-9)
        XCTAssertEqual(model.start.size.width, end.size.width, accuracy: 1e-9)
        XCTAssertEqual(model.end.size.width, start.size.width, accuracy: 1e-9)
        store.undo()

        // Leading into the next clip (the same picture in picture) puts the End box on it.
        XCTAssertEqual(model.next?.clipID, neighbour)
        XCTAssertFalse(model.leadsIntoNext)
        model.setLeadsIntoNext(true)
        XCTAssertTrue(model.leadsIntoNext)
        assertBox(model.end, center: CGPoint(x: 1650, y: 864), size: CGSize(width: 576, height: 324))
        XCTAssertEqual(try span(id).endValues.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.y, 0, accuracy: 1e-9)
    }

    /// A turned, offset clip: its boxes turn with it (the corners where the compositor draws the
    /// picture's corners); a corner drag scales along the turned diagonal, a body drag moves in the
    /// frame's axes, and the rotation stays.
    func testATurnedClipsBoxesTurnWithIt() async throws {
        let clip = try await longClip()
        let placed = VEVideoParams(x: 100, y: 0, scale: 0.5, rotationDegrees: 90, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(placed, forClip: clip).ok)
        let id = try motionSpan(clip, 0, 90)
        store.select(span: id)
        let model = try XCTUnwrap(store.kenBurns)
        assertBox(model.start, center: CGPoint(x: 1060, y: 540), size: CGSize(width: 960, height: 540), rotation: 90)
        // The picture's top-left corner turned a quarter clockwise: right of and above the centre.
        let corner = model.end.corner(.topLeft)
        XCTAssertEqual(corner.x, 1060 + 270, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 540 - 480, accuracy: 1e-9)
        // That corner pulled out half its diagonal again: 1.5x.
        model.applyDrag(.corner(.end, .topLeft), origin: model.end, translation: CGSize(width: 135, height: -240))
        model.endDrag()
        assertBox(model.end, center: CGPoint(x: 1060, y: 540), size: CGSize(width: 1440, height: 810), rotation: 90)
        XCTAssertEqual(try span(id).endValues.scale, 1.5, accuracy: 1e-9)
        // A body drag down 100 px.
        model.applyDrag(.body(.end), origin: model.end, translation: CGSize(width: 0, height: 100))
        model.endDrag()
        XCTAssertEqual(try span(id).endValues.x, 0, accuracy: 1e-9)
        XCTAssertEqual(try span(id).endValues.y, 100, accuracy: 1e-9)
        let shown = try edge(id, of: clip, atEnd: true)
        XCTAssertEqual(shown.rotationDegrees, 90, accuracy: 1e-9, "the rotation stays")
        XCTAssertEqual(shown.scale, 0.75, accuracy: 1e-9)
        let expected = KenBurnsModel.box(for: shown, picture: model.pictureSize, sequence: sequence)
        assertBox(model.end, center: expected.center, size: expected.size, rotation: 90, "what the end shows")
        // A press on the turned corner grabs it.
        XCTAssertEqual(KenBurnsHit.target(at: model.end.corner(.bottomLeft), start: model.start, end: model.end),
                       .corner(.end, .bottomLeft))
    }

    // MARK: The other clips

    /// Every other clip visible at the playhead is outlined with its track's name, at its composed
    /// placement there: a zoomed-in full-frame background clip's box reaches past the frame. The
    /// edited clip, a clip away from the playhead and a hidden track's clip are not outlined.
    func testTheOtherVisibleClipsAreOutlinedAtThePlayhead() async throws {
        let (movie, _) = try await fixture.importMedia()
        let tracks = store.videoTracks
        XCTAssertGreaterThanOrEqual(tracks.count, 2)
        let v1 = tracks[0]
        let v2 = tracks[tracks.count - 1]
        let background = try fixture.placeMovie(movie, at: 0, track: v1.trackID) // [0, 60)
        let later = try fixture.placeMovie(movie, at: 2, track: v1.trackID) // [60, 120)
        let pip = try fixture.placeMovie(movie, at: 0, track: v2.trackID)
        let zoomed = VEVideoParams(x: 0, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(zoomed, forClip: background).ok)
        let corner = VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1)
        XCTAssertTrue(store.engine.setVideoParams(corner, forClip: pip).ok)
        let id = try motionSpan(pip, 0, 30)
        store.select(span: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.setPlayhead(frames(10))
        XCTAssertEqual(model.outlines.map(\.clipID), [background], "the clip under the edited one only")
        let outline = try XCTUnwrap(model.outlines.first)
        XCTAssertEqual(outline.trackName, v1.name)
        assertBox(outline.box, center: CGPoint(x: 960, y: 540), size: CGSize(width: 2880, height: 1620),
                  "a 1.5x full-frame clip reaches past the frame")
        // Its own Motion span composes in: 2x over [0, 30), held after, so 3x at frame 40.
        let zoom = try motionSpan(background, 0, 30, scale: (1, 2))
        store.select(span: id)
        XCTAssertNotNil(store.engine.spanInfo(zoom))
        model.setPlayhead(frames(40))
        assertBox(try XCTUnwrap(model.outlines.first).box, center: CGPoint(x: 960, y: 540),
                  size: CGSize(width: 5760, height: 3240))
        // Past the edited clip's end the next clip on V1 is outlined instead.
        model.setPlayhead(frames(70))
        XCTAssertEqual(model.outlines.map(\.clipID), [later])
        // A hidden track is not outlined; shown again, it is.
        model.setPlayhead(frames(10))
        XCTAssertTrue(store.engine.setTrack(v1.trackID, muted: true).ok)
        XCTAssertEqual(model.outlines, [], "V1 hidden")
        XCTAssertTrue(store.engine.setTrack(v1.trackID, muted: false).ok)
        XCTAssertEqual(model.outlines.map(\.clipID), [background])
    }

    // MARK: Geometry

    func testTheBoxGeometryAndItsInverse() {
        let wide = CGSize(width: 320, height: 180)
        // Identity: the fitted picture, filling the frame.
        let identity = KenBurnsModel.box(for: VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 0, opacity: 1),
                                         picture: wide, sequence: sequence)
        assertBox(identity, center: fullFrame.center, size: fullFrame.size, "identity")
        // 30 % in the lower right.
        let pip = KenBurnsModel.box(for: VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1),
                                    picture: wide, sequence: sequence)
        assertBox(pip, center: CGPoint(x: 1650, y: 864), size: CGSize(width: 576, height: 324))
        XCTAssertEqual(pip.corner(.bottomRight).x, 1938, accuracy: 1e-9, "18 px past the right edge")
        // Turned 30°: the corners turn about the centre.
        let turned = KenBurnsModel.box(for: VEVideoParams(x: -100, y: 50, scale: 0.5, rotationDegrees: 30, opacity: 1),
                                       picture: wide, sequence: sequence)
        assertBox(turned, center: CGPoint(x: 860, y: 590), size: CGSize(width: 960, height: 540), rotation: 30)
        let corner = turned.corner(.topRight)
        let theta = 30.0 * .pi / 180
        XCTAssertEqual(corner.x, 860 + cos(theta) * 480 + sin(theta) * 270, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 590 + sin(theta) * 480 - cos(theta) * 270, accuracy: 1e-9)
        XCTAssertEqual(turned.local(corner).x, 480, accuracy: 1e-9)
        XCTAssertEqual(turned.local(corner).y, -270, accuracy: 1e-9)
        // A portrait still is pillarboxed: its box is 607.5 wide in a 1920x1080 frame.
        let portrait = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(KenBurnsModel.fittedSize(picture: portrait, sequence: sequence),
                       CGSize(width: 607.5, height: 1080))
        let tall = KenBurnsModel.box(for: VEVideoParams(x: 0, y: 0, scale: 2, rotationDegrees: 0, opacity: 1),
                                     picture: portrait, sequence: sequence)
        assertBox(tall, center: CGPoint(x: 960, y: 540), size: CGSize(width: 1215, height: 2160))
        // Round trips: box -> values -> the same values.
        let cases: [(VEVideoParams, CGSize)] = [
            (VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: 690, y: 324, scale: 0.3, rotationDegrees: 0, opacity: 1), wide),
            (VEVideoParams(x: -100, y: 50, scale: 0.5, rotationDegrees: 30, opacity: 1), wide),
            (VEVideoParams(x: 12.5, y: -400, scale: 2, rotationDegrees: -90, opacity: 1), portrait),
        ]
        for (params, picture) in cases {
            let box = KenBurnsModel.box(for: params, picture: picture, sequence: sequence)
            let back = KenBurnsModel.motion(for: box, picture: picture, sequence: sequence)
            XCTAssertEqual(back.framing.x, params.x, accuracy: 1e-9)
            XCTAssertEqual(back.framing.y, params.y, accuracy: 1e-9)
            XCTAssertEqual(back.framing.scale, params.scale, accuracy: 1e-12)
            XCTAssertEqual(back.rotationDegrees, params.rotationDegrees, accuracy: 1e-12)
            let again = KenBurnsModel.box(for: VEVideoParams(x: back.framing.x, y: back.framing.y,
                                                             scale: back.framing.scale,
                                                             rotationDegrees: back.rotationDegrees, opacity: 1),
                                          picture: picture, sequence: sequence)
            assertBox(again, center: box.center, size: box.size, rotation: box.rotationDegrees, "round trip")
        }
        // Scale 0: an empty box at its position.
        let hidden = KenBurnsModel.box(for: VEVideoParams(x: 10, y: 0, scale: 0, rotationDegrees: 0, opacity: 1),
                                       picture: wide, sequence: sequence)
        XCTAssertEqual(hidden.size, .zero)
        XCTAssertEqual(hidden.center, CGPoint(x: 970, y: 540))
    }

    /// The margin: the frame fitted inside the monitor less 15 % of it on each side, and monitor
    /// points mapped to frame pixels and back. The default push in on a full-frame clip keeps its
    /// four corners on screen.
    func testTheMarginMapsMonitorPointsToFramePixelsAndBack() {
        let viewport = KenBurnsViewport(sequence: sequence, monitor: CGSize(width: 1000, height: 700))
        // Inside 700x490 the frame is 700 wide (height-limited it would be 871).
        XCTAssertEqual(viewport.frame.width, 700, accuracy: 1e-9)
        XCTAssertEqual(viewport.frame.height, 393.75, accuracy: 1e-9)
        XCTAssertEqual(viewport.frame.minX, 150, accuracy: 1e-9)
        XCTAssertEqual(viewport.frame.minY, 153.125, accuracy: 1e-9)
        XCTAssertEqual(viewport.scale, 700.0 / 1920, accuracy: 1e-12)
        XCTAssertEqual(viewport.view(CGPoint.zero).x, 150, accuracy: 1e-9)
        XCTAssertEqual(viewport.view(CGPoint.zero).y, 153.125, accuracy: 1e-9)
        XCTAssertEqual(viewport.view(CGPoint(x: 1920, y: 1080)).x, 850, accuracy: 1e-9)
        XCTAssertEqual(viewport.view(CGPoint(x: 1920, y: 1080)).y, 546.875, accuracy: 1e-9)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: 900), CGPoint(x: -300, y: 1300)] {
            let back = viewport.sequence(viewport.view(point))
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
        // A monitor point in the margin is off the frame: negative frame pixels.
        let off = viewport.sequence(CGPoint(x: 20, y: 20))
        XCTAssertLessThan(off.x, 0)
        XCTAssertLessThan(off.y, 0)
        XCTAssertEqual(viewport.sequence(CGSize(width: 70, height: 35)).width, 192, accuracy: 1e-9)
        // The 1.25x push in's corners lie inside the monitor.
        let pushIn = viewport.view(fullFrame.scaled(by: 1.25))
        for corner in pushIn.corners {
            XCTAssertTrue(CGRect(origin: .zero, size: viewport.monitor).contains(corner), "\(corner)")
        }
        // A tall monitor: width-limited inside the margin, centred vertically.
        let tall = KenBurnsViewport(sequence: sequence, monitor: CGSize(width: 600, height: 900))
        XCTAssertEqual(tall.frame.width, 420, accuracy: 1e-9)
        XCTAssertEqual(tall.frame.midY, 450, accuracy: 1e-9)
        // No margin: the usual letterbox fit.
        let closed = KenBurnsViewport(sequence: sequence, monitor: CGSize(width: 1920, height: 1200), margin: 0)
        XCTAssertEqual(closed.frame, CGRect(x: 0, y: 60, width: 1920, height: 1080))
    }

    // MARK: Which box a press grabs

    private func box(_ rect: CGRect, rotation: Double = 0) -> KenBurnsBox {
        KenBurnsBox(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size, rotationDegrees: rotation)
    }

    func testTheStartBoxIsReachableAroundAndInsideTheEnd() {
        // The default push in: the end (1.25x) around the start.
        let start = box(CGRect(x: 40, y: 22.5, width: 320, height: 180))
        let end = box(CGRect(x: 0, y: 0, width: 400, height: 225))
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 20, y: 100), start: start, end: end), .body(.end),
                       "the end's margin around the start")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 200, y: 110), start: start, end: end), .body(.start),
                       "inside both: the smaller one")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 65, y: 30), start: start, end: end), .body(.start),
                       "its label")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 398, y: 223), start: start, end: end),
                       .corner(.end, .bottomRight))
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 41, y: 23), start: start, end: end), .corner(.start, .topLeft))
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 380, y: 215), start: start, end: end), .body(.end),
                       "the end's label at its bottom-right")
        XCTAssertNil(KenBurnsHit.target(at: CGPoint(x: 500, y: 300), start: start, end: end))
    }

    func testCoincidingBoxesShareTheirHandles() {
        // An unanimated clip: both boxes are its placement.
        let same = box(CGRect(x: 100, y: 50, width: 400, height: 225))
        func target(_ x: CGFloat, _ y: CGFloat) -> KenBurnsHit.Target? {
            KenBurnsHit.target(at: CGPoint(x: x, y: y), start: same, end: same)
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

    func testATurnedBoxIsGrabbedInItsOwnAxes() {
        // A 200x100 box turned a quarter clockwise about (300, 300): it stands 100 wide, 200 tall.
        let turned = KenBurnsBox(center: CGPoint(x: 300, y: 300), size: CGSize(width: 200, height: 100),
                                 rotationDegrees: 90)
        let far = KenBurnsBox(center: CGPoint(x: 900, y: 900), size: CGSize(width: 10, height: 10), rotationDegrees: 0)
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 351, y: 201), start: turned, end: far),
                       .corner(.start, .topLeft), "the picture's top-left corner is at the upper right")
        XCTAssertEqual(KenBurnsHit.target(at: CGPoint(x: 300, y: 390), start: turned, end: far), .body(.start),
                       "inside the standing box")
        XCTAssertNil(KenBurnsHit.target(at: CGPoint(x: 390, y: 300), start: turned, end: far),
                     "outside it, though inside the unturned box")
    }
}
