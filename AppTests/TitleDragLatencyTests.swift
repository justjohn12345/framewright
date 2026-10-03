import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Measures box drags on the program monitor in the whole editor window: many small steps while paused over a video
/// clip in a 1080p sequence, a title and a lower third moved and widened, and the Transform box of a Motion span on
/// the movie moved as the baseline. The steps are made as the overlays make them (the models' `applyDrag`) and as a
/// hand makes them (pointer events sent through the window to the overlays' SwiftUI gestures).
///
/// Per step it reports
/// - the main thread's time in the step's call (the engine edit, the snapshot published to the program monitor and
///   the store's re-read; for an event, everything AppKit and SwiftUI do while dispatching it),
/// - the time until the main run loop next went idle (SwiftUI has updated the views, the overlay's box included, and
///   committed them),
/// - the time until the program monitor's frame source handed the compositor the frame showing the step, and
/// - the program's cache misses (a title picture rendered again).
///
/// Printed, not asserted: wall-clock numbers vary from Mac to Mac and with the load. FW_DRAG_STEPS sets the steps per
/// drag (a long drag to profile with `sample`).
@MainActor
final class TitleDragLatencyTests: XCTestCase {
    struct Sample {
        var callMs: Double
        var idleMs: Double
        var pictureMs: Double
        var misses: UInt64
        var presented: Bool
    }

    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var window: NSWindow?
    private var idleObserver: CFRunLoopObserver?
    /// When the main run loop last went idle (about to sleep), in `nowNanos` time.
    private var lastIdle: UInt64 = 0

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("titleDragLatency")
        try fixture.configureSequence() // 1920x1080, 30 fps
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastIdle = Self.nowNanos() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        idleObserver = observer
    }

    override func tearDown() async throws {
        if let idleObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), idleObserver, .commonModes)
        }
        idleObserver = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        fixture?.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    private nonisolated static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private nonisolated static var profiling: Bool { ProcessInfo.processInfo.environment["FW_DRAG_STEPS"] != nil }
    private nonisolated static var steps: Int { Int(ProcessInfo.processInfo.environment["FW_DRAG_STEPS"] ?? "") ?? 60 }

    private func pause(_ seconds: Double) async {
        await StoreFixture.wait(until: { false }, timeout: seconds)
    }

    // MARK: The project and the window

    /// The movie on V1 at 0, 20 more of it and of the tone later on (a project of some size), a lower third and a
    /// title over the movie; returns (movie, lower third, title) with the playhead on frame 10.
    private func makeProject() async throws -> (movie: VEClipID, lowerThird: VEClipID, title: VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0, overwrite: true))
        let clip = try XCTUnwrap(store.selection.first)
        for i in 0 ..< 20 {
            XCTAssertTrue(store.place(asset: movie.assetID, at: frames(Int64(300 + 60 * i)), videoTrack: v1,
                                      audioTrack: 0, overwrite: true))
            XCTAssertTrue(store.place(asset: tone.assetID, at: frames(Int64(300 + 90 * i)), videoTrack: 0,
                                      audioTrack: a1, overwrite: true))
        }
        store.targetVideoTrackID = v1
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let lowerThird = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.addGenerated(.title))
        let title = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(10)
        return (clip, lowerThird, title)
    }

    /// The editor window around the store (key when the app can be made active; `FirstClickHostingView` takes the
    /// clicks otherwise); returns once the program monitor presented the frame at the playhead with every layer drawn.
    /// Skips when the window is not visible.
    private func showWindow() async throws -> VEPreviewView {
        let documents = DocumentController(store: store, defaults: try makeTestDefaults("titleDragLatency.documents"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        self.window = window
        await pause(0.3)
        guard window.occlusionState.contains(.visible) else {
            // An occluded window's monitor does not draw (VEPreviewView): there would be nothing to measure.
            throw XCTSkip("the test window is not visible (the screen is locked or the window is covered)")
        }
        let view = try XCTUnwrap(store.engine.programView, "the window's program monitor is attached")
        let shown = await StoreFixture.wait(until: { view.renderCount > 0 && view.missingLayerCount == 0 }, timeout: 20)
        XCTAssertTrue(shown, "the program frame appeared")
        await StoreFixture.wait(until: { window.isKeyWindow }, timeout: 2)
        await pause(0.5)
        return view
    }

    // MARK: Measuring

    /// Runs `steps` steps (`step(i)` makes step i, `i` from 1), one per `pace` (a pointer at 60 Hz), each measured
    /// until the program presented it, then `end()`. Nil when `dragging()` is false after the second step (the steps
    /// did not reach the drag).
    private func measure(_ name: String, steps: Int = TitleDragLatencyTests.steps, pace: Double = 1.0 / 60,
                         step: (Int) -> Void, dragging: () -> Bool, end: () -> Void) async -> [Sample]? {
        var samples: [Sample] = []
        for i in 1 ... steps {
            let before = store.engine.playbackStats
            let t0 = Self.nowNanos()
            let host0 = CACurrentMediaTime()
            step(i)
            let t1 = Self.nowNanos()
            var after = before
            var presented = false
            var idle: UInt64 = 0
            // A profiler that suspends the process can starve the drawables: do not wait long then.
            let deadline = t0 + (Self.profiling ? 50_000_000 : 1_000_000_000)
            while Self.nowNanos() < deadline {
                if idle == 0, lastIdle > t1 { idle = lastIdle }
                after = store.engine.playbackStats
                presented = after.presentedFrames > before.presentedFrames
                if presented, idle != 0 { break }
                try? await Task.sleep(nanoseconds: 250_000)
            }
            if i == 2, !dragging() {
                end()
                return nil
            }
            while Self.nowNanos() < t0 + UInt64(pace * 1e9) {
                try? await Task.sleep(nanoseconds: 250_000)
            }
            samples.append(Sample(callMs: Double(t1 - t0) / 1e6, idleMs: idle > 0 ? Double(idle - t0) / 1e6 : 1000,
                                  pictureMs: presented ? (after.presentedHostTime - host0) * 1000 : 1000,
                                  misses: store.engine.playbackStats.cacheMisses - before.cacheMisses,
                                  presented: presented))
        }
        end()
        await pause(0.3)
        report(name, samples)
        return samples
    }

    private func report(_ name: String, _ samples: [Sample]) {
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "-" }
            let median = sorted[sorted.count / 2]
            let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            return String(format: "median %6.2f  p90 %6.2f  max %7.2f", median, p90, sorted.last ?? 0)
        }
        let misses = samples.reduce(0) { $0 + $1.misses }
        let hidden = window?.occlusionState.contains(.visible) == false
            ? " (the window was hidden: its monitor does not draw)" : ""
        let unpresented = samples.filter { !$0.presented }.count
        print("""
        [drag latency] \(name) (\(samples.count) steps)
          step's call on the main thread ms:  \(stats(samples.map(\.callMs)))
          step to main run loop idle ms:      \(stats(samples.map(\.idleMs)))
          step to picture handed out ms:      \(stats(samples.map(\.pictureMs)))
          program cache misses: \(misses)   steps without a new picture: \(unpresented)\(hidden)
        """)
    }

    // MARK: Pointer events

    /// The window point of `point` (sequence pixels) on the program monitor, as the layout places the picture now.
    private func windowPoint(ofSequencePoint point: CGPoint) throws -> NSPoint {
        let window = try XCTUnwrap(window)
        // SwiftUI's global space has its origin at the window's top left, title bar included.
        let area = MonitorFrame.programArea
        let viewport = KenBurnsViewport.editor(mode: store.kenBurnsMode, extent: store.kenBurnsExtent,
                                               sequence: CGSize(width: store.sequence.width,
                                                                height: store.sequence.height),
                                               monitor: area.size)
        let local = viewport.view(point)
        return NSPoint(x: area.minX + local.x, y: window.frame.height - (area.minY + local.y))
    }

    private var eventNumber = 0

    /// Sends a left-button event at `location` (window points) through the window, as AppKit delivers one.
    private func send(_ type: NSEvent.EventType, _ location: NSPoint) {
        eventNumber += 1
        guard let window, let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: eventNumber, clickCount: 1, pressure: 1) else {
            return
        }
        window.sendEvent(event)
    }

    /// A drag by pointer events from `start` (window points), (3, -2) points per step.
    private func pointerDrag(_ name: String, from start: NSPoint, dragging: () -> Bool) async -> [Sample]? {
        send(.mouseMoved, start)
        await pause(0.05)
        send(.leftMouseDown, start)
        await pause(0.05)
        var last = start
        return await measure(name, step: { i in
            last = NSPoint(x: start.x + CGFloat(3 * i), y: start.y - CGFloat(2 * i))
            send(.leftMouseDragged, last)
        }, dragging: dragging, end: { send(.leftMouseUp, last) })
    }

    // MARK: The drags

    /// Each drag made the way the overlays make their steps (the models' `applyDrag`).
    func testMeasureModelDrags() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let (movie, lowerThird, title) = try await makeProject()
        _ = try await showWindow()

        store.selection = [movie]
        store.addMotionSpanAtPlayhead(clip: movie, mode: .transform)
        let kenBurns = try XCTUnwrap(store.kenBurns)
        await pause(0.5)
        let origin = kenBurns.start
        _ = await measure("model: Transform box move (Motion span on the movie)", step: { i in
            kenBurns.applyDrag(.body(.start), origin: origin, translation: CGSize(width: 3 * i, height: 2 * i))
        }, dragging: { kenBurns.isDragging }, end: { kenBurns.endDrag() })

        for (name, id) in [("lower third", lowerThird), ("title", title)] {
            store.selectedSpanID = nil
            store.selection = [id]
            let box = try XCTUnwrap(store.titleBox)
            box.setPlayhead(frames(10))
            await pause(0.5)
            _ = await measure("model: \(name) move", step: { i in
                box.applyDrag(.body, translation: CGSize(width: 3 * i, height: 2 * i))
            }, dragging: { box.isDragging }, end: { box.endDrag() })
            _ = await measure("model: \(name) wrap width", step: { i in
                box.applyDrag(.edge(right: true), translation: CGSize(width: 3 * i, height: 0))
            }, dragging: { box.isDragging }, end: { box.endDrag() })
        }
    }

    /// The same drags made by pointer events through the window, as a hand makes them.
    func testMeasurePointerDrags() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let (movie, lowerThird, title) = try await makeProject()
        _ = try await showWindow()

        store.selection = [movie]
        store.addMotionSpanAtPlayhead(clip: movie, mode: .transform)
        let kenBurns = try XCTUnwrap(store.kenBurns)
        await pause(0.5)
        guard await pointerDrag("pointer: Transform box move (Motion span on the movie)",
                                from: try windowPoint(ofSequencePoint: kenBurns.start.center),
                                dragging: { kenBurns.isDragging }) != nil else {
            throw XCTSkip("synthetic mouse events do not reach SwiftUI gestures in this test host")
        }

        for (name, id) in [("lower third", lowerThird), ("title", title)] {
            store.selectedSpanID = nil
            store.selection = [id]
            let box = try XCTUnwrap(store.titleBox)
            box.setPlayhead(frames(10))
            await pause(0.5)
            let centre = try windowPoint(ofSequencePoint: box.box.center)
            let moved = await pointerDrag("pointer: \(name) move", from: centre, dragging: { box.isDragging })
            XCTAssertNotNil(moved, "the \(name)'s box took the drag")
            // The left edge (a moved title's right edge may be off the monitor).
            let edge = box.box.point(local: CGPoint(x: -box.box.size.width / 2, y: 0))
            let widened = await pointerDrag("pointer: \(name) wrap width", from: try windowPoint(ofSequencePoint: edge),
                                            dragging: { box.isDragging })
            XCTAssertNotNil(widened, "the \(name)'s edge took the drag")
        }
    }
}

/// A hosting view that takes the first click in a window that is not key: the test host is not the active app while
/// someone else uses the Mac, and its window then never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
