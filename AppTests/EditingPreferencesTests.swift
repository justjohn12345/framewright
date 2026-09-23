import AppKit
import Combine
import CoreMedia
import SwiftUI
import FramewrightEngine
import XCTest
@testable import Framewright

/// Editing preferences (Settings > Editing) reach open views at once (review 2026-09-23,
/// phase 6, finding 3): changing "Show durations as" re-formats the inspector's fields and the
/// timeline's transition labels without any model change.
@MainActor
final class EditingPreferencesTests: XCTestCase {
    private var fixture: StoreFixture!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "preferences-\(UUID())"))
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

    /// Lets SwiftUI process pending updates, then lays out and draws the hosting view.
    private static func display(_ host: NSView) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }

    func testChangingTheDurationDisplayReformatsOpenViewsWithoutAModelChange() async throws {
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        // Two clips meeting at 1 s with a 20-frame dissolve (its band shows its duration), and a
        // tone clip with a 20-frame fade-in.
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0, sourceIn: .zero,
                                  sourceOut: CMTime(value: 1, timescale: 1), overwrite: true))
        let a = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: movie.assetID, at: CMTime(value: 1, timescale: 1), videoTrack: v1,
                                  audioTrack: 0, sourceIn: CMTime(value: 1, timescale: 1),
                                  sourceOut: CMTime(value: 2, timescale: 1), overwrite: true))
        let b = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.addTransition(fromClip: a, toClip: b, duration: CMTime(value: 20, timescale: 30)).ok)
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1, overwrite: true))
        let toneClip = try XCTUnwrap(store.selection.first)
        store.selection = [toneClip]
        store.inspector.setValue(.fadeIn, 20)
        XCTAssertEqual(store.inspector.text(.fadeIn), "00:00:00:20")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let host = NSHostingView(rootView: TimelineView(store: store).frame(width: 1000, height: 400))
        window.contentView = host
        window.orderFront(nil)
        // Thumbnails and waveforms settle: wait until the canvas stops redrawing.
        var lastDraws = -1
        for _ in 0 ..< 50 where lastDraws != TimelineDiagnostics.canvasDraws {
            lastDraws = TimelineDiagnostics.canvasDraws
            await Self.display(host)
            await StoreFixture.wait(until: { false }, timeout: 0.1)
        }
        // Positive control: a change the canvas shows redraws it in this host.
        let controlDraws = TimelineDiagnostics.canvasDraws
        store.selection = []
        await Self.display(host)
        guard TimelineDiagnostics.canvasDraws > controlDraws else {
            throw XCTSkip("the timeline canvas does not draw in this test host")
        }
        store.selection = [toneClip]
        await Self.display(host)

        XCTAssertEqual(store.shortDurationString(frames: 20), "20f", "the dissolve's band label")
        let sheet = SpeedDurationModel(store: store, clipIDs: [a])
        XCTAssertEqual(sheet.durationText, "00:00:01:00 → 00:00:01:00")

        var storeChanges = 0
        var sheetChanges = 0
        let subscriptions = [store.objectWillChange.sink { _ in storeChanges += 1 },
                             sheet.objectWillChange.sink { _ in sheetChanges += 1 }]
        defer { subscriptions.forEach { $0.cancel() } }
        let changeCount = store.changeCount
        let draws = TimelineDiagnostics.canvasDraws
        let revision = store.preferences.revision
        store.defaults.set(DurationDisplay.seconds.rawValue, forKey: EditingPreferences.durationDisplayKey)
        await Self.display(host)

        XCTAssertEqual(store.changeCount, changeCount, "no model change")
        XCTAssertEqual(store.preferences.current.durationDisplay, .seconds)
        XCTAssertGreaterThan(store.preferences.revision, revision, "the canvases' redraw token changed")
        XCTAssertEqual(store.inspector.text(.fadeIn), "0.67 s")
        XCTAssertEqual(store.shortDurationString(frames: 20), "0.67s", "the band label re-formats")
        XCTAssertEqual(sheet.durationText, "1.00 s → 1.00 s")
        XCTAssertGreaterThan(storeChanges, 0, "views observing the store are told the preference changed")
        XCTAssertGreaterThan(sheetChanges, 0, "an open Speed/Duration sheet is told too")
        XCTAssertGreaterThan(TimelineDiagnostics.canvasDraws, draws, "the timeline redrew its labels")

        // Writing a value that does not change anything publishes nothing.
        storeChanges = 0
        store.defaults.set(DurationDisplay.seconds.rawValue, forKey: EditingPreferences.durationDisplayKey)
        store.defaults.set(true, forKey: "someUnrelatedKey")
        XCTAssertEqual(storeChanges, 0)
    }

    func testThePreferencesModelMirrorsItsDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "preferences-model-\(UUID())"))
        let model = EditingPreferencesModel(defaults: suite)
        XCTAssertEqual(model.current, EditingPreferences(), "missing values read as the defaults")
        suite.set(0.5, forKey: EditingPreferences.defaultTransitionSecondsKey)
        suite.set(LinkedCrossfadeMode.ask.rawValue, forKey: EditingPreferences.linkedCrossfadeKey)
        suite.set(DurationDisplay.frames.rawValue, forKey: EditingPreferences.durationDisplayKey)
        XCTAssertEqual(model.current.transitionSeconds, 0.5)
        XCTAssertEqual(model.current.linkedCrossfade, .ask)
        XCTAssertEqual(model.current.durationDisplay, .frames)
        XCTAssertEqual(model.current.transitionFrames(frameDuration: CMTime(value: 1, timescale: 30)), 15)
        suite.set(-3, forKey: EditingPreferences.defaultTransitionSecondsKey)
        suite.set("bogus", forKey: EditingPreferences.durationDisplayKey)
        XCTAssertEqual(model.current.transitionSeconds, EditingPreferences.defaultTransitionSeconds, "invalid: default")
        XCTAssertEqual(model.current.durationDisplay, .timecode)

        // Another suite: re-read at once.
        let otherName = "preferences-model-\(UUID())"
        let other = try XCTUnwrap(UserDefaults(suiteName: otherName))
        other.set(LinkedCrossfadeMode.never.rawValue, forKey: EditingPreferences.linkedCrossfadeKey)
        model.defaults = other
        XCTAssertEqual(model.current.linkedCrossfade, .never)

        // A write from another thread (through another instance of the suite) arrives on the
        // main thread.
        let written = expectation(description: "background write")
        DispatchQueue.global().async {
            UserDefaults(suiteName: otherName)?.set(DurationDisplay.seconds.rawValue,
                                                    forKey: EditingPreferences.durationDisplayKey)
            written.fulfill()
        }
        wait(for: [written], timeout: 5)
        XCTAssertTrue(StoreFixture.spin(until: { model.current.durationDisplay == .seconds }, timeout: 5))
    }
}
