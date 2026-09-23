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

    private func findPreviewView(in view: NSView) -> VEPreviewView? {
        if let preview = view as? VEPreviewView { return preview }
        for subview in view.subviews {
            if let found = findPreviewView(in: subview) { return found }
        }
        return nil
    }
}
