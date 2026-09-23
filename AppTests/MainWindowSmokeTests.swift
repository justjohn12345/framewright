import AppKit
import SwiftUI
import FramewrightEngine
import XCTest
@testable import Framewright

@MainActor
final class MainWindowSmokeTests: XCTestCase {
    /// Builds the whole editor window (every panel) around a store with media and clips, lays it
    /// out, lets it render, and checks the panels are there. Also writes a PNG of the window to
    /// the test's temporary directory for manual inspection.
    func testMainWindowBuildsAllPanels() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("smoke.mov")
        let tone = directory.appendingPathComponent("smoke.wav")
        try TestMediaFactory.writeMovie(to: movie, frames: 90)
        try TestMediaFactory.writeWAV(to: tone, seconds: 3)

        let store = ProjectStore(engine: VEEngine(cacheDirectory: directory.appendingPathComponent("Caches")))
        let documents = DocumentController(store: store, defaults: UserDefaults(suiteName: "smoke-\(UUID())") ?? .standard)
        var imported: [VEAssetInfo] = []
        let importDone = expectation(description: "import")
        store.importMedia([movie, tone]) {
            imported = $0
            importDone.fulfill()
        }
        wait(for: [importDone], timeout: 30)
        XCTAssertEqual(imported.count, 2)
        for asset in imported {
            store.place(asset: asset.assetID, at: store.sequence.duration,
                        videoTrack: asset.hasVideo ? store.targetVideoTrackID : 0,
                        audioTrack: asset.hasAudio ? store.targetAudioTrackID : 0, overwrite: true)
        }
        XCTAssertEqual(store.clips.count, 2)
        store.showInSourceMonitor(imported[0].assetID)
        store.selection = Set(store.clips.keys.prefix(1))
        store.playheadTime = CMTime(value: 1, timescale: 1)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Let thumbnails/waveforms arrive and SwiftUI settle.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if store.waveforms.waveform(asset: imported[1].assetID) != nil,
               store.thumbnails.image(asset: imported[0].assetID, seconds: 0, maxDimension: AssetTileView.thumbnailSize) != nil {
                break
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertNotNil(store.thumbnails.image(asset: imported[0].assetID, seconds: 0,
                                               maxDimension: AssetTileView.thumbnailSize), "bin thumbnail arrived")
        XCTAssertNotNil(store.waveforms.waveform(asset: imported[1].assetID), "waveform arrived")
        XCTAssertNotNil(findPreviewView(in: host), "the program monitor's Metal view is in the window")
        XCTAssertEqual(window.title, store.projectName)
        XCTAssertTrue(window.isDocumentEdited, "unsaved edits show in the title bar")

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FramewrightMainWindow.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("Main window snapshot: \(url.path)")
        }
        window.orderOut(nil)
        window.close()
    }

    /// The default layout (open findings 4-6): the source monitor is hidden and the program
    /// monitor takes the whole centre; the timeline is only as tall as its tracks; opening media
    /// shows the source monitor beside the program (which narrows), hiding it widens the program
    /// again; the Effects tab replaces the inspector's page without a second window.
    func testTheDefaultLayoutGivesTheProgramMonitorTheCentre() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        let documents = DocumentController(store: store, defaults: UserDefaults(suiteName: "layout-smoke-\(UUID())") ?? .standard)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, documents: documents))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        func settle() async {
            for _ in 0 ..< 5 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
            }
        }
        await settle()
        var previews = allPreviewViews(in: host)
        XCTAssertEqual(previews.count, 1, "only the program monitor: the source monitor is hidden by default")
        let program = try XCTUnwrap(previews.first)
        let wide = program.convert(program.bounds, to: nil)
        XCTAssertGreaterThan(wide.width, 800, "the program monitor spans the centre (\(wide))")
        // The timeline fits its four tracks, so the monitor keeps most of the height.
        let fitted = WindowLayoutModel.fittedTimelineHeight(contentHeight: store.timelineContentHeight)
        XCTAssertLessThan(fitted, 300)
        XCTAssertGreaterThan(wide.height, 900 - fitted - 120, "the monitors get the height the tracks do not need (\(wide))")

        store.showInSourceMonitor(movie.assetID)
        await settle()
        previews = allPreviewViews(in: host)
        XCTAssertEqual(previews.count, 2, "opening media shows the source monitor")
        let narrowed = program.convert(program.bounds, to: nil)
        XCTAssertLessThan(narrowed.width, wide.width - 200, "the program monitor makes room for it")

        store.setSourceMonitorVisible(false)
        await settle()
        XCTAssertEqual(allPreviewViews(in: host).count, 1)
        XCTAssertEqual(program.convert(program.bounds, to: nil).width, wide.width, accuracy: 1)

        store.layout.inspectorTab = .effects
        await settle()
        store.layout.inspectorTab = .inspector
        await settle()
        XCTAssertEqual(allPreviewViews(in: host).count, 1)
    }

    private func allPreviewViews(in view: NSView) -> [VEPreviewView] {
        var found: [VEPreviewView] = []
        if let preview = view as? VEPreviewView { found.append(preview) }
        for subview in view.subviews {
            found += allPreviewViews(in: subview)
        }
        return found
    }

    private func findPreviewView(in view: NSView) -> VEPreviewView? {
        if let preview = view as? VEPreviewView { return preview }
        for subview in view.subviews {
            if let found = findPreviewView(in: subview) { return found }
        }
        return nil
    }
}
