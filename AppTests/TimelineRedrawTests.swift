import AppKit
import CoreMedia
import SwiftUI
import VidEditEngine
import XCTest
@testable import VidEdit

/// The redraw budget of the editor window while the playhead moves at the display rate, and
/// that the timeline actually paints its clips.
@MainActor
final class TimelineRedrawTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// Twenty 1 s clips back to back on V1 (and the tone on A1).
    private func makeTwentyClipSequence() async throws {
        let store = fixture.store
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        for index in 0 ..< 20 {
            XCTAssertTrue(store.place(asset: movie.assetID, at: CMTime(value: CMTimeValue(index), timescale: 1),
                                      videoTrack: v1, audioTrack: 0, sourceIn: .zero,
                                      sourceOut: CMTime(value: 1, timescale: 1), overwrite: true))
        }
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0,
                                  audioTrack: store.targetAudioTrackID, overwrite: true))
        XCTAssertEqual(store.clips.count, 21)
    }

    func testPlayheadAtSixtyHertzDoesNotRebuildTheTimeline() async throws {
        try await makeTwentyClipSequence()
        let store = fixture.store
        let defaults = UserDefaults(suiteName: "redraw-\(UUID())") ?? .standard
        let documents = DocumentController(store: store, defaults: defaults)
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
        host.layoutSubtreeIfNeeded()
        await StoreFixture.wait(until: { false }, timeout: 1.0) // settle: thumbnails, waveforms, first frames

        let builds = store.timelineBuildCount
        let canvasDraws = TimelineDiagnostics.canvasDraws
        let playheadUpdates = TimelineDiagnostics.playheadUpdates
        // Publish the playhead at 60 Hz for 2 s, as the engine's playback notifications do.
        let frame = await Self.publishPlayhead(store.playhead, hertz: 60, seconds: 2)
        let rebuilt = store.timelineBuildCount - builds
        let redrawn = TimelineDiagnostics.canvasDraws - canvasDraws
        let moved = TimelineDiagnostics.playheadUpdates - playheadUpdates
        print("60 Hz playhead for 2 s (\(frame) updates): timeline model builds \(rebuilt), canvas draws \(redrawn), "
            + "playhead overlay updates \(moved)")
        XCTAssertLessThanOrEqual(rebuilt, 1, "the timeline model is built once per model change, not per playhead move")
        XCTAssertLessThanOrEqual(redrawn, 2, "the clips are not redrawn while only the playhead moves")
        XCTAssertGreaterThan(moved, 30, "the playhead overlay follows the playhead")
    }

    /// Sets the playhead `hertz` times a second for `seconds`, suspending in between (so the main
    /// queue and run loop, and SwiftUI's updates, run as in the app); returns the number of updates.
    private static func publishPlayhead(_ playhead: PlayheadModel, hertz: Double, seconds: Double) async -> Int {
        let start = Date()
        var frame = 0
        while Date().timeIntervalSince(start) < seconds {
            frame += 1
            playhead.setTime(CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(hertz)))
            let next = start.addingTimeInterval(Double(frame) / hertz).timeIntervalSinceNow
            if next > 0 {
                try? await Task.sleep(nanoseconds: UInt64(next * 1e9))
            }
        }
        return frame
    }

    func testTimelinePaintsItsClips() async throws {
        let store = fixture.store
        let (movie, tone) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: CMTime(value: 1, timescale: 1), videoTrack: v1,
                                  audioTrack: 0, overwrite: true))
        let video = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1, overwrite: true))
        let audio = try XCTUnwrap(store.selection.first)
        store.selection = []
        // Wait for the peaks, so the audio clip shows its waveform strip.
        let peaksLoaded = await StoreFixture.wait(until: { store.waveforms.waveform(asset: tone.assetID) != nil },
                                                  timeout: 10)
        XCTAssertTrue(peaksLoaded)

        let size = CGSize(width: 1000, height: 400)
        let content = TimelineView(store: store)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width))

        // The track area starts right of the headers and below the ruler (each followed by a
        // 1 pt divider).
        let model = store.timelineModel
        func pixel(_ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let px = Int(TimelineView.headerWidth + 1 + x)
            let py = Int(TimelineView.rulerHeight + 1 + y)
            guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        let videoRect = try XCTUnwrap(model.rect(forClip: try XCTUnwrap(model.clip(id: video))))
        let audioRect = try XCTUnwrap(model.rect(forClip: try XCTUnwrap(model.clip(id: audio))))
        // Right end of the label band (no text there): the clip body colour.
        let videoBody = pixel(videoRect.maxX - 6, videoRect.minY + 4)
        XCTAssertGreaterThan(videoBody.b, videoBody.r + 0.2, "video clip body is painted blue: \(videoBody)")
        let audioBody = pixel(audioRect.maxX - 6, audioRect.minY + 4)
        XCTAssertGreaterThan(audioBody.g, audioBody.r + 0.15, "audio clip body is painted green: \(audioBody)")
        // Empty track space before the video clip is not.
        let empty = pixel(videoRect.minX - 20, videoRect.midY)
        XCTAssertLessThan(empty.b - empty.r, 0.15, "empty V1 space is not painted as a clip: \(empty)")
        // The waveform strip: bright green samples in the middle of the audio clip's content.
        var bright = 0
        let contentMidY = audioRect.minY + (audioRect.height + TimelineRenderer.labelHeight) / 2
        for dx in stride(from: audioRect.minX + 10, to: audioRect.maxX - 10, by: 3) {
            let sample = pixel(dx, contentMidY)
            if sample.g > 0.75, sample.r > 0.4 { bright += 1 }
        }
        XCTAssertGreaterThan(bright, 20, "the waveform strip is drawn")
        XCTAssertGreaterThan(store.waveforms.stripsRendered, 0)
    }
}
