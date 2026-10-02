import AppKit
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The luma waveform panel (View > Show Waveform): the layout remembers whether it shows (and Reset
/// Window Layout hides it); shown, its view is the engine's waveform view and is drawn with the program
/// monitor's frames; hidden, the engine lets go of it.
@MainActor
final class WaveformPanelTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("waveform")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    func testTheLayoutRemembersTheWaveform() throws {
        let defaults = try makeTestDefaults("waveform-layout")
        let layout = WindowLayoutModel(defaults: defaults)
        XCTAssertFalse(layout.showsWaveform, "hidden by default")
        layout.showsWaveform = true
        XCTAssertTrue(WindowLayoutModel(defaults: defaults).showsWaveform, "remembered across launches")
        layout.resetToDefaults()
        XCTAssertFalse(layout.showsWaveform)
        XCTAssertFalse(WindowLayoutModel(defaults: defaults).showsWaveform)
        // The store's View menu action.
        XCTAssertFalse(store.layout.showsWaveform)
        store.setWaveformVisible(true)
        XCTAssertTrue(store.layout.showsWaveform)
        store.setWaveformVisible(false)
        XCTAssertFalse(store.layout.showsWaveform)
    }

    /// What the window shows: the program monitor and, while the layout says so, the waveform panel.
    private struct Host: View {
        let store: ProjectStore
        @ObservedObject var layout: WindowLayoutModel

        var body: some View {
            HStack {
                ProgramMonitorView(attachID: ObjectIdentifier(store)) { view in store.attachProgramView(view) }
                if layout.showsWaveform {
                    WaveformPanel(store: store)
                        .frame(width: WindowLayoutModel.waveformPanelWidth)
                }
            }
        }
    }

    private func waveformViews(in view: NSView) -> [VEWaveformView] {
        var found: [VEWaveformView] = []
        if let waveform = view as? VEWaveformView { found.append(waveform) }
        for subview in view.subviews { found.append(contentsOf: waveformViews(in: subview)) }
        return found
    }

    private func settle(_ host: NSView) async {
        for _ in 0 ..< 5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    func testTheShownPanelIsDrawnWithTheProgramMonitorsFramesAndLetGoWhenHidden() async throws {
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        store.setWaveformVisible(true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Host(store: store, layout: store.layout))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        window.contentView = host
        window.orderFront(nil)
        defer {
            store.engine.attachWaveformView(nil)
            store.engine.attachProgramView(nil)
            window.orderOut(nil)
            window.close()
        }
        await settle(host)
        let waveform = try XCTUnwrap(waveformViews(in: host).first)
        XCTAssertTrue(store.engine.waveformView === waveform)
        XCTAssertGreaterThan(waveform.bounds.width, 100)
        // Each frame the program view shows draws the waveform (the program view renders on attach, and
        // again while the picture decodes).
        let program = try XCTUnwrap(store.engine.programView)
        let drawn = await StoreFixture.wait(until: {
            program.renderOnce()
            return waveform.drawCount > 0
        }, timeout: 10)
        XCTAssertTrue(drawn, "the waveform was drawn with the program monitor's frame")

        // Hidden: the panel goes, and the engine lets go of its view.
        store.setWaveformVisible(false)
        await settle(host)
        XCTAssertTrue(waveformViews(in: host).isEmpty)
        XCTAssertNil(store.engine.waveformView)
    }
}
