import AppKit
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Ken Burns helper and the Motion UI after the motion/photos review: typed Start/End/Duration
/// text survives model changes (finding 11) and equivalent or padded text changes nothing (25),
/// which rectangle a press grabs when they overlap or coincide (12), a click without movement and
/// the drag reducer (16), a duration typed with the playhead off the clip (17), a neighbour going
/// away after a rectangle was moved (18), held Control-K through the key monitor (15), the Clip
/// menu's item (25; both inert since Motion keyframes became effect spans), the helper staying open
/// on the same clip and closing on a multi-selection, durations following the display preference,
/// no keyframe markers at the trim edges, and a nudge on a split piece whose Motion span ends on its
/// out point.
/// The movie is 2 s (60 frames) at 320x180 on a 1920x1080 30 fps sequence; 50 pt/s, V1 at y 66...130.
@MainActor
final class MotionReviewTests: XCTestCase {
    private var fixture: StoreFixture!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "motion-review-\(UUID())"))
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    private func clip(_ id: VEClipID) throws -> VEClipInfo {
        try XCTUnwrap(store.clips[id])
    }

    private func placedClip() async throws -> VEClipID {
        let (movie, _) = try await fixture.importMedia()
        let id = try fixture.placeMovie(movie, at: 0)
        store.selection = [id]
        return id
    }

    /// A 10 s movie (300 frames) on V1 at 0 s, selected alone.
    private func longClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 300)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        let id = try fixture.placeMovie(try XCTUnwrap(imported.first), at: 0)
        store.selection = [id]
        return id
    }

    // MARK: Typed range text (finding 11, 25)

    func testTypedRangeTextSurvivesASaveAModelChangeAndThePlayhead() async throws {
        let id = try await longClip()
        store.playheadTime = frames(30)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromPlayhead
        model.startText = "00:00:02:00"
        model.durationText = "3s"
        XCTAssertTrue(model.hasUncommittedText)

        // A save, a Media folder bookmark (an unsaved change), an import landing, an undo and redo,
        // the playhead moving with a From playhead range: none of them replaces what is typed.
        try store.save(to: fixture.directory.appendingPathComponent("Typed.framewright"))
        store.engine.mediaFolderBookmark = try fixture.directory.bookmarkData()
        store.refreshModel()
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([fixture.toneURL]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 5, y: 0, scale: 1, rotationDegrees: 0, opacity: 1),
                                                  forClip: id).ok)
        store.refreshModel()
        model.setPlayhead(frames(45))
        XCTAssertEqual(model.startText, "00:00:02:00", "typed Start kept")
        XCTAssertEqual(model.durationText, "3s", "typed Duration kept")
        XCTAssertEqual(model.endText, model.endString, "a field not being typed in follows the range")

        // Committing both (Apply's path) takes both: the Start moves the range, the Duration its end.
        XCTAssertTrue(model.commitFields())
        XCTAssertEqual(model.range, .custom)
        XCTAssertEqual(model.currentSpan, KenBurnsModel.FrameSpan(first: 60, last: 149))
        XCTAssertEqual(model.startText, "00:00:02:00")
        XCTAssertEqual(model.durationText, model.durationString(frames: 90))
        XCTAssertFalse(model.hasUncommittedText)
    }

    func testPaddedOrEquivalentTextChangesNothing() async throws {
        let id = try await longClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(model.range, .wholeClip)
        model.endText = model.endString + " "
        XCTAssertFalse(model.hasUncommittedText, "spaces around a value are not a change (Return presses Apply)")
        XCTAssertTrue(model.commitEnd())
        XCTAssertEqual(model.endText, model.endString)
        // The same frame written another way keeps the range.
        model.startText = "0f"
        XCTAssertTrue(model.commitStart())
        XCTAssertEqual(model.range, .wholeClip, "0f is the start the range already has")
        XCTAssertEqual(model.startText, model.startString)
        model.range = .fromClipStart
        model.durationText = "5s" // the default: 150 frames
        XCTAssertTrue(model.commitDuration())
        XCTAssertEqual(model.range, .fromClipStart)
        XCTAssertEqual(model.durationText, model.durationString(frames: 150))
    }

    func testADurationTypedWithThePlayheadOffTheClipIsRefused() async throws {
        let id = try await longClip()
        store.playheadTime = frames(60)
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromPlayhead
        model.setPlayhead(frames(400)) // after the clip
        XCTAssertNotNil(model.rangeProblem)
        model.durationText = "2s"
        XCTAssertFalse(model.commitDuration())
        XCTAssertEqual(model.rangeNote, "Move the playhead over the clip to start the move there.")
        // Back over the clip: the default duration, not a zero-frame one.
        model.setPlayhead(frames(30))
        XCTAssertNil(model.rangeProblem)
        XCTAssertEqual(model.durationFrames, 150)
        XCTAssertEqual(model.currentSpan, KenBurnsModel.FrameSpan(first: 30, last: 179))
    }

    func testTheDurationFormatFollowsThePreferenceWhileOpen() async throws {
        let id = try await longClip()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        model.range = .fromClipStart
        XCTAssertEqual(model.durationText, "00:00:05:00")
        store.defaults.set(DurationDisplay.frames.rawValue, forKey: EditingPreferences.durationDisplayKey)
        await StoreFixture.wait(until: { model.durationDisplay == .frames }, timeout: 2)
        XCTAssertEqual(model.durationText, "150f")
        XCTAssertEqual(model.startText, model.durationString(frames: 0))
    }

    // MARK: Which rectangle a press grabs (finding 12)

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

    // MARK: Drags (finding 16) and neighbours (finding 18)

    func testAClickWithoutMovementDoesNotPinARectangle() async throws {
        let id = try await longClip()
        // The clip moves right over its length and is zoomed in (a Motion span over the whole clip):
        // the rectangles show its framing at the range's ends, so they move with the range.
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: CMTimeRange(start: .zero, duration: frames(300)))
        let span = try XCTUnwrap(added.span, added.message)
        var start = VESpanValuesUnchanged()
        start.x = 0
        start.scale = 2
        var end = VESpanValuesUnchanged()
        end.x = 300
        end.scale = 2
        XCTAssertTrue(store.engine.setSpanValues(span.spanID, start: start, end: end).ok)
        store.refreshModel()
        store.beginKenBurns(clip: id)
        let model = try XCTUnwrap(store.kenBurns)
        let before = model.end
        model.applyDrag(.body(.end), origin: model.end, translation: .zero, location: CGPoint(x: 10, y: 10))
        model.applyDrag(.corner(.end, .topLeft), origin: model.end, translation: .zero, location: .zero)
        XCTAssertFalse(model.editedEnd, "a click is not a move")
        XCTAssertEqual(model.end, before)
        // It still follows the range.
        model.range = .custom
        model.endText = "00:00:05:00"
        XCTAssertTrue(model.commitEnd())
        XCTAssertNotEqual(model.end, before, "the push in at the new range's end framing")
        let following = model.end
        // A real drag moves it from its origin (not from wherever an earlier step left it).
        model.applyDrag(.body(.end), origin: following, translation: CGSize(width: -40, height: 0), location: .zero)
        XCTAssertTrue(model.editedEnd)
        let moved = model.end
        model.applyDrag(.body(.end), origin: following, translation: CGSize(width: -60, height: 0), location: .zero)
        XCTAssertEqual(model.end.minX, moved.minX - 20, accuracy: 1e-9, "each step from the drag's origin")
    }

    func testARectangleMovedNextToANeighbourStaysWhenTheNeighbourGoes() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 2)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 100, y: 0, scale: 1.5, rotationDegrees: 0,
                                                                opacity: 1), forClip: a).ok)
        store.selection = [b]
        store.beginKenBurns(clip: b)
        let model = try XCTUnwrap(store.kenBurns)
        XCTAssertTrue(model.continuesFromPrevious, "the previous clip is placed: followed by default")
        model.move(.start, from: model.start, by: CGSize(width: 30, height: 10))
        let moved = model.start
        // The previous clip is trimmed away from the cut (a frame's gap): no neighbour any more.
        XCTAssertTrue(store.engine.trimClipTail(a, to: frames(59), clamp: false).ok)
        store.refreshModel()
        XCTAssertNil(model.previous)
        XCTAssertFalse(model.continuesFromPrevious)
        XCTAssertEqual(model.start, moved, "the rectangle the user moved stays")
        // Turning a toggle by hand still resets its rectangle (the user's choice).
        XCTAssertTrue(model.editedStart)
    }

    // MARK: Helper lifetime (finding 25)

    func testKenBurnsReopenedOnTheSameClipKeepsItAndAMultiSelectionClosesIt() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0)
        let b = try fixture.placeMovie(movie, at: 3)
        store.selection = [a]
        store.beginKenBurns(clip: a)
        let model = try XCTUnwrap(store.kenBurns)
        model.move(.end, from: model.end, by: CGSize(width: 20, height: 0))
        store.beginKenBurns(clip: a)
        XCTAssertTrue(store.kenBurns === model, "pressing Ken Burns… again keeps the open helper")
        store.selection = [a, b]
        XCTAssertNil(store.kenBurns, "Shift-adding another clip closes the helper")
        store.selection = [a, b]
        store.beginKenBurns(clip: a)
        XCTAssertEqual(store.selection, [a], "the helper edits its clip alone")
    }

    // MARK: Keys and menus (findings 15, 25)

    func testHeldControlKAddsOneMotionSpan() async throws {
        let id = try await placedClip()
        store.playheadTime = frames(10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        store.editorWindow = window
        let keyboard = KeyboardController(store: store)
        func controlK(repeating: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{b}",
                                           charactersIgnoringModifiers: "k", isARepeat: repeating, keyCode: 40))
        }
        XCTAssertTrue(keyboard.handle(try controlK(repeating: false), window: window))
        XCTAssertEqual(try clip(id).spans.count, 1, "one Motion span from the playhead")
        let changes = store.changeCount
        for _ in 0 ..< 5 {
            XCTAssertTrue(keyboard.handle(try controlK(repeating: true), window: window), "swallowed")
        }
        XCTAssertEqual(store.changeCount, changes, "the auto-repeat adds nothing")
        XCTAssertEqual(try clip(id).spans.count, 1)
        store.editorWindow = nil
    }

    // MARK: Trim edges at the bottom of a clip (test gap 4)

    func testTheBottomOfAClipWithSpansKeepsItsTrimEdges() async throws {
        let id = try await placedClip()
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: CMTimeRange(start: .zero, duration: frames(60)))
        XCTAssertTrue(added.ok, added.message)
        store.refreshModel()
        let model = store.timelineModel
        let rect = try XCTUnwrap(model.rect(forClip: try XCTUnwrap(model.clip(id: id))))
        let y = rect.maxY - 4 // where the keyframe markers used to be: the spans are on the lanes below
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.minX + 0.5, y: y)), .clipHead(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.maxX - 0.5, y: y)), .clipTail(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.midX, y: y)), .clipBody(id))
        XCTAssertEqual(model.hitTest(CGPoint(x: rect.midX, y: rect.maxY + 7)), .span(try XCTUnwrap(added.span).spanID))
    }

    func testANudgeOnASplitPieceMovesTheStaticValueUnderItsSpan() async throws {
        let id = try await placedClip()
        // A Motion span moving the clip left by 150 over its 60 frames, then a split at frame 30: the
        // left piece keeps the span's first half, which ends on its out point.
        let added = store.engine.addSpan(kind: .motion, lane: 1, clip: id,
                                         range: CMTimeRange(start: .zero, duration: frames(60)))
        let span = try XCTUnwrap(added.span, added.message)
        var start = VESpanValuesUnchanged()
        start.x = 0
        var end = VESpanValuesUnchanged()
        end.x = -150
        XCTAssertTrue(store.engine.setSpanValues(span.spanID, start: start, end: end).ok)
        XCTAssertTrue(store.engine.splitClip(id, at: frames(30)).ok)
        store.selection = [id]
        store.playheadTime = frames(29) // the left piece's last frame
        let pieceSpan = try XCTUnwrap(store.engine.spans(forClip: id).first { $0.kind == .motion })
        XCTAssertEqual(pieceSpan.end, frames(30), "the span ends on the piece's out point")
        XCTAssertEqual(pieceSpan.endValues.x, -75, accuracy: 1e-9, "cut exactly at the split")
        let shownBefore = try clip(id).motion(at: frames(29)).x
        // The row edits the static value (what the span composes onto), whatever the playhead shows.
        XCTAssertEqual(try XCTUnwrap(inspector.value(.positionX)), 0, accuracy: 1e-12)
        inspector.nudge(.positionX, steps: 1)
        inspector.endNudgeBurst()
        XCTAssertEqual(try XCTUnwrap(inspector.value(.positionX)), 1, accuracy: 1e-9)
        XCTAssertEqual(try clip(id).videoParams.x, 1, accuracy: 1e-9)
        XCTAssertEqual(try clip(id).motion(at: frames(29)).x, shownBefore + 1, accuracy: 1e-9,
                       "the frame shows the span plus the nudged static value")
    }
}
