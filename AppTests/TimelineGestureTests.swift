import AppKit
import CoreMedia
import SwiftUI
import FramewrightEngine
import XCTest
@testable import Framewright

/// The timeline's gesture state machine driven with synthetic pointer locations. Geometry at the
/// default zoom (50 pt/s, no scroll): rows V2 y 0...64, V1 66...130, A1 132...180, A2 182...230.
@MainActor
final class TimelineGestureTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    private func start(_ clip: VEClipID) -> Double {
        store.clips[clip]?.timelineStart.secondsOrZero ?? -1
    }

    private func drag(_ gestures: TimelineGestureController, from: CGPoint, through points: [CGPoint],
                      end: Bool = true) {
        gestures.changed(location: from, startLocation: from, modifiers: [])
        for point in points {
            gestures.changed(location: point, startLocation: from, modifiers: [])
        }
        if end { gestures.ended() }
    }

    func testMoveIsOneUndoStepAndClickSelects() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = []
        let gestures = TimelineGestureController(store: store)

        // A click (no movement) selects.
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [])
        XCTAssertEqual(store.selection, [clip])
        XCTAssertEqual(gestures.drag, .idle)

        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 60, y: 90), CGPoint(x: 100, y: 90)])
        XCTAssertEqual(start(clip), 1, accuracy: 1e-9)
        XCTAssertFalse(store.engine.isCoalescing)
        XCTAssertEqual(store.undoActionName, "Move Clip")
        XCTAssertNil(store.cancelActiveGesture)
        store.undo()
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9, "the whole drag is one undo step")
        XCTAssertEqual(store.undoActionName, "Overwrite")
    }

    func testEscapeCancelsAndTheRestOfTheGestureIsIgnored() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let gestures = TimelineGestureController(store: store)
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 150, y: 90)], end: false)
        XCTAssertEqual(start(clip), 2, accuracy: 1e-9)
        XCTAssertNotNil(store.cancelActiveGesture)
        store.cancelActiveGesture?() // Escape
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9)
        XCTAssertEqual(gestures.drag, .cancelled)
        gestures.changed(location: CGPoint(x: 200, y: 90), startLocation: CGPoint(x: 50, y: 90), modifiers: [])
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9, "moves after Escape are ignored")
        gestures.ended()
        XCTAssertEqual(gestures.drag, .idle)
        XCTAssertEqual(store.undoActionName, "Overwrite", "nothing was recorded")
    }

    func testUndoDuringADragOnlyCancelsIt() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let gestures = TimelineGestureController(store: store)
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 150, y: 90)], end: false)
        store.undo() // Cmd+Z mid-drag
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9)
        XCTAssertNotNil(store.clips[clip], "the placement before the drag was not undone")
        XCTAssertEqual(store.undoActionName, "Overwrite")
        gestures.ended()
        XCTAssertEqual(gestures.drag, .idle)
    }

    func testAGestureAbandonedWithoutAnEndIsRevertedAndReset() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let gestures = TimelineGestureController(store: store)
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 150, y: 90)], end: false)
        store.snapIndicator = 3
        gestures.abandon()
        XCTAssertEqual(gestures.drag, .idle)
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9)
        XCTAssertFalse(store.engine.isCoalescing)
        XCTAssertNil(store.cancelActiveGesture)
        XCTAssertNil(store.snapIndicator)
        // The next gesture starts clean.
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 100, y: 90)])
        XCTAssertEqual(start(clip), 1, accuracy: 1e-9)
    }

    func testTrimAndMarquee() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        let gestures = TimelineGestureController(store: store)
        // Within 8 pt of the tail (x = 100): trim it to 1.5 s.
        drag(gestures, from: CGPoint(x: 97, y: 90), through: [CGPoint(x: 72, y: 90)])
        XCTAssertEqual(store.clips[clip]?.duration.secondsOrZero ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Trim Clip End")
        // A marquee over empty space selects what it crosses.
        store.selection = []
        drag(gestures, from: CGPoint(x: 300, y: 70), through: [CGPoint(x: 40, y: 120)], end: false)
        XCTAssertEqual(store.selection, [clip])
        XCTAssertNotNil(gestures.marquee)
        gestures.ended()
        XCTAssertNil(gestures.marquee)
    }

    func testDropOnARowPlacesAndOutsideIsRefused() async throws {
        let (movie, _) = try await fixture.importMedia()
        let gestures = TimelineGestureController(store: store)
        XCTAssertFalse(gestures.drop(assetID: movie.assetID, at: CGPoint(x: 100, y: 1000), insert: false),
                       "below the last row")
        XCTAssertFalse(gestures.drop(assetID: movie.assetID, at: CGPoint(x: -20, y: 90), insert: false),
                       "left of the track area")
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertTrue(gestures.drop(assetID: movie.assetID, at: CGPoint(x: 150, y: 90), insert: false))
        let placed = try XCTUnwrap(store.clips.values.first)
        XCTAssertEqual(placed.trackID, store.videoTracks.first?.trackID)
        XCTAssertEqual(placed.timelineStart.secondsOrZero, 3, accuracy: 1e-9)
    }

    func testMovingBetweenVideoRowsKeepsSelectedAudioOnItsTrack() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let video = try fixture.placeMovie(movie, at: 0)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1, overwrite: true))
        let audio = try XCTUnwrap(store.selection.first)
        store.selection = [video, audio] // unlinked clips, both selected
        let gestures = TimelineGestureController(store: store)
        // Drag the video clip from V1 up into the V2 row.
        drag(gestures, from: CGPoint(x: 50, y: 90), through: [CGPoint(x: 50, y: 60), CGPoint(x: 50, y: 30)])
        XCTAssertEqual(store.clips[video]?.trackID, store.videoTracks.first { $0.index == 1 }?.trackID)
        XCTAssertEqual(store.clips[audio]?.trackID, a1, "the audio clip is not moved to A2 by a video row offset")
    }

    func testSnappingUsesTheTimelineFromBeforeTheDrag() async throws {
        let (movie, _) = try await fixture.importMedia()
        let x = try fixture.placeMovie(movie, at: 0)
        let y = try fixture.placeMovie(movie, at: 3)
        store.selection = []
        let gestures = TimelineGestureController(store: store)
        // Grab Y at 4 s and pull it left: to 1 s (it overwrites X's second half, so X now ends at
        // 1 s), then on to 1.1 s. X's new end is the drag's own doing and must not attract Y.
        let origin = CGPoint(x: 200, y: 90)
        drag(gestures, from: origin, through: [CGPoint(x: 100, y: 90)], end: false)
        XCTAssertEqual(start(y), 1, accuracy: 1e-9)
        XCTAssertEqual(store.clips[x]?.timelineEnd.secondsOrZero ?? 0, 1, accuracy: 1e-9)
        gestures.changed(location: CGPoint(x: 105, y: 90), startLocation: origin, modifiers: [])
        XCTAssertEqual(start(y), 1.1, accuracy: 1e-9, "no snap to the previewed edge at 1 s")
        XCTAssertNil(store.snapIndicator)
        gestures.ended()
    }

    func testDraggingThePlayheadInTheTrackArea() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0) // V1, x 0...100
        store.selection = []
        store.playheadTime = CMTime(value: 3, timescale: 1) // x = 150
        let gestures = TimelineGestureController(store: store)
        // Empty space next to the playhead line grabs it (no marquee).
        drag(gestures, from: CGPoint(x: 152, y: 90), through: [CGPoint(x: 175, y: 90)], end: false)
        XCTAssertEqual(gestures.drag, .scrubbing)
        XCTAssertEqual(store.engine.playbackState, .scrubbing)
        XCTAssertEqual(store.playheadTime.seconds, 3.5, accuracy: 1e-9)
        XCTAssertNil(gestures.marquee)
        gestures.ended()
        XCTAssertEqual(store.engine.playbackState, .stopped)
        XCTAssertEqual(store.focusArea, .timeline)
        // With Option held the playhead is dragged anywhere, even from a clip, which stays put.
        gestures.changed(location: CGPoint(x: 50, y: 90), startLocation: CGPoint(x: 50, y: 90), modifiers: .option)
        gestures.changed(location: CGPoint(x: 60, y: 90), startLocation: CGPoint(x: 50, y: 90), modifiers: .option)
        gestures.ended()
        XCTAssertEqual(store.playheadTime, CMTime(value: 36, timescale: 30))
        XCTAssertEqual(start(clip), 0, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Overwrite", "no edit")
        // Escape during a playhead drag ends the scrub where it is.
        drag(gestures, from: CGPoint(x: 61, y: 20), through: [CGPoint(x: 80, y: 20)], end: false)
        XCTAssertEqual(gestures.drag, .scrubbing)
        store.cancelActiveGesture?()
        XCTAssertEqual(store.engine.playbackState, .stopped)
        gestures.ended()
        XCTAssertEqual(gestures.drag, .idle)
    }

    /// The real SwiftUI path: mouse events sent to a window hosting the timeline drive the
    /// track area's DragGesture into the controller. A completed drag is committed once, and
    /// the gesture state's reset after the release must not revert it (abandon()).
    func testARealDragThroughSwiftUIIsCommittedAndNotReverted() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = []
        let size = NSSize(width: 900, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TimelineView(store: store).frame(width: size.width, height: size.height))
        window.contentView = host
        // A click in a window that is not key only activates it: make it key first.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await StoreFixture.wait(until: { window.isKeyWindow }, timeout: 1)
        // A point of the track area (see testTimelinePaintsItsClips) in window coordinates.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: TimelineView.headerWidth + 1 + x, y: host.bounds.height - (TimelineView.rulerHeight + 1 + y))
        }
        var eventNumber = 0
        func send(_ type: NSEvent.EventType, _ location: NSPoint) async {
            eventNumber += 1
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: eventNumber, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            await StoreFixture.wait(until: { false }, timeout: 0.03)
        }
        await send(.leftMouseDown, point(50, 90))
        await send(.leftMouseDragged, point(60, 90))
        await send(.leftMouseDragged, point(80, 90))
        await send(.leftMouseDragged, point(100, 90))
        await send(.leftMouseUp, point(100, 90))
        let committed = await StoreFixture.wait(until: { !self.store.engine.isCoalescing && self.start(clip) != 0 },
                                                timeout: 2)
        if !committed, start(clip) == 0, store.undoActionName == "Overwrite", store.selection.isEmpty {
            throw XCTSkip("synthetic mouse events do not reach SwiftUI gestures in this test host")
        }
        XCTAssertEqual(start(clip), 1, accuracy: 1e-9)
        XCTAssertEqual(store.undoActionName, "Move Clip")
        XCTAssertNil(store.cancelActiveGesture)
        // Give SwiftUI time to reset the gesture state (which calls abandon() when it sees an
        // unfinished drag): the finished drag stays.
        await StoreFixture.wait(until: { false }, timeout: 0.3)
        XCTAssertEqual(start(clip), 1, accuracy: 1e-9, "the completed drag was reverted")
        XCTAssertEqual(store.undoActionName, "Move Clip")
    }
}
