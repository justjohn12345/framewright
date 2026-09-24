import AppKit
import CoreMedia
import SwiftUI
import FramewrightEngine
import XCTest
@testable import Framewright

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

    /// Moves the playhead 120 times (as the engine's 60 Hz playback notifications do) and forces
    /// the window to display after each move: the timeline model is not rebuilt and the canvas
    /// is not redrawn, while the playhead overlays follow. A positive control first proves the
    /// canvas does draw in this host when the model changes (else the test is skipped: its
    /// counts would mean nothing).
    func testPlayheadMovesDoNotRedrawTheTimeline() async throws {
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
        // Thumbnails, waveforms and the first frames settle: wait until the canvas stops redrawing.
        var lastDraws = -1
        for _ in 0 ..< 50 where lastDraws != TimelineDiagnostics.canvasDraws {
            lastDraws = TimelineDiagnostics.canvasDraws
            await Self.display(host)
            await StoreFixture.wait(until: { false }, timeout: 0.1)
        }

        // Positive control: a change the canvas shows (the selection) redraws it.
        let controlDraws = TimelineDiagnostics.canvasDraws
        store.selection = [try XCTUnwrap(store.clips.keys.min())]
        await Self.display(host)
        let controlRedrawn = TimelineDiagnostics.canvasDraws - controlDraws
        guard controlRedrawn > 0 else {
            throw XCTSkip("the timeline canvas does not draw in this test host (control redrew \(controlRedrawn) times)")
        }

        let builds = store.timelineBuildCount
        let canvasDraws = TimelineDiagnostics.canvasDraws
        let playheadUpdates = TimelineDiagnostics.playheadUpdates
        for frame in 1 ... 120 {
            store.playhead.setTime(CMTime(value: CMTimeValue(frame), timescale: 60))
            await Self.display(host)
        }
        let rebuilt = store.timelineBuildCount - builds
        let redrawn = TimelineDiagnostics.canvasDraws - canvasDraws
        let moved = TimelineDiagnostics.playheadUpdates - playheadUpdates
        print("120 playhead moves: timeline model builds \(rebuilt), canvas draws \(redrawn), "
            + "playhead overlay updates \(moved) (control: \(controlRedrawn) draws)")
        XCTAssertEqual(rebuilt, 0, "the timeline model is built once per model change, not per playhead move")
        XCTAssertLessThanOrEqual(redrawn, 2, "the clips are not redrawn while only the playhead moves")
        XCTAssertGreaterThanOrEqual(moved, 120, "the playhead overlays follow the playhead")

        // Layout changes that do not touch the tracks (the source monitor, the right panel's tab)
        // do not rebuild the timeline model either.
        store.layout.showsSourceMonitor = true
        await Self.display(host)
        store.layout.inspectorTab = .effects
        await Self.display(host)
        store.layout.showsSourceMonitor = false
        store.layout.inspectorTab = .inspector
        await Self.display(host)
        XCTAssertEqual(store.timelineBuildCount - builds, 0, "the layout does not rebuild the timeline model")

        // And the control again afterwards: the counter still sees redraws.
        let afterDraws = TimelineDiagnostics.canvasDraws
        store.selection = []
        await Self.display(host)
        XCTAssertGreaterThan(TimelineDiagnostics.canvasDraws, afterDraws)
    }

    /// With spans on lanes (a transition on lane 0, effect spans on two lanes, a Gain span on audio)
    /// the playhead moving still builds no timeline model and redraws no clips, and a span edit
    /// rebuilds the model once, however often the views read it.
    func testWithLanesAPlayheadTickBuildsNoModelAndASpanEditOne() async throws {
        try await makeTwentyClipSequence()
        let store = fixture.store
        let video = store.clips.values.filter { $0.trackKind == .video }.sorted { $0.timelineStart < $1.timelineStart }
        let audio = try XCTUnwrap(store.clips.values.first { $0.trackKind == .audio })
        let first = video[0]
        XCTAssertTrue(store.engine.addTransition(at: .end, of: video[19].clipID, duration: CMTime(value: 10, timescale: 30),
                                                 options: []).ok)
        let motion = try XCTUnwrap(store.engine.addSpan(kind: .motion, lane: 1, clip: first.clipID,
                                                        range: CMTimeRange(start: .zero, duration: CMTime(value: 20, timescale: 30))).span)
        XCTAssertTrue(store.engine.addSpan(kind: .opacity, lane: 2, clip: first.clipID,
                                           range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 30))).ok)
        XCTAssertTrue(store.engine.addSpan(kind: .gain, lane: 1, clip: audio.clipID,
                                           range: CMTimeRange(start: .zero, duration: CMTime(value: 30, timescale: 30))).ok)
        store.refreshModel()
        XCTAssertEqual(store.timelineModel.layout(forTrack: first.trackID)?.lanes, [0, 1, 2, 3])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 500),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TimelineView(store: store))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        var lastDraws = -1
        for _ in 0 ..< 50 where lastDraws != TimelineDiagnostics.canvasDraws {
            lastDraws = TimelineDiagnostics.canvasDraws
            await Self.display(host)
            await StoreFixture.wait(until: { false }, timeout: 0.1)
        }
        let controlDraws = TimelineDiagnostics.canvasDraws
        store.snapIndicator = 0.5
        await Self.display(host)
        store.snapIndicator = nil
        await Self.display(host)
        XCTAssertGreaterThan(TimelineDiagnostics.canvasDraws, controlDraws, "the canvas draws in this host")

        let builds = store.timelineBuildCount
        let canvasDraws = TimelineDiagnostics.canvasDraws
        for frame in 1 ... 60 {
            store.playhead.setTime(CMTime(value: CMTimeValue(frame), timescale: 60))
            await Self.display(host)
        }
        let rebuilt = store.timelineBuildCount - builds
        let redrawn = TimelineDiagnostics.canvasDraws - canvasDraws
        print("60 playhead moves with lanes: timeline model builds \(rebuilt), canvas draws \(redrawn)")
        XCTAssertEqual(rebuilt, 0, "a playhead tick builds no model")
        XCTAssertLessThanOrEqual(redrawn, 2, "and redraws no clips")

        // A span edit: one build, whatever reads the model afterwards.
        XCTAssertTrue(store.engine.setSpanRange(motion.spanID, range: CMTimeRange(start: CMTime(value: 2, timescale: 30),
                                                                                    duration: CMTime(value: 20, timescale: 30))).ok)
        await Self.display(host)
        _ = store.timelineModel
        _ = store.timelineContentHeight
        await Self.display(host)
        XCTAssertEqual(store.timelineBuildCount - builds, 1, "a span edit rebuilds the model once")
        XCTAssertEqual(store.timelineModel.span(id: motion.spanID)?.start ?? -1, 2.0 / 30, accuracy: 1e-9)
    }

    /// The Ken Burns editor open over the program monitor while its pictures land during a scrub,
    /// hosted with the timeline and the media bin in one window: the pictures have their own cache
    /// (`KenBurnsPictureLoader`), so a landing redraws the editor's overlay only, never the timeline
    /// model, the clips' canvas or a bin tile. Positive controls first prove the canvas and the tiles
    /// do redraw in this host when what they show changes.
    func testKenBurnsPicturesLandingRedrawNeitherTheTimelineNorTheBin() async throws {
        try await makeTwentyClipSequence()
        let store = fixture.store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = VStack(spacing: 0) {
            KenBurnsOverlayHost(store: store)
                .frame(height: 420)
            HStack(spacing: 0) {
                MediaBinView(store: store)
                    .frame(width: 420)
                TimelineView(store: store)
            }
        }
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        let clip = try XCTUnwrap(store.clips.values.filter { $0.trackKind == .video }
            .min { $0.timelineStart < $1.timelineStart })
        store.playheadTime = .zero
        // A Motion span over the first clip's second: the picture follows the playhead within it.
        let motion = try XCTUnwrap(store.engine.addSpan(kind: .motion, lane: 1, clip: clip.clipID,
                                                        range: CMTimeRange(start: .zero, duration: CMTime(value: 30, timescale: 30))).span)
        store.select(span: motion.spanID)
        let loader = try XCTUnwrap(store.kenBurns?.picture)
        // Thumbnails, waveforms, the tiles and the first picture settle.
        let firstPicture = await StoreFixture.wait(until: { loader.image != nil }, timeout: 20)
        XCTAssertTrue(firstPicture, "the helper's first picture arrives")
        var last = (-1, -1)
        for _ in 0 ..< 60 where last != (TimelineDiagnostics.canvasDraws, MediaBinDiagnostics.tileBodies) {
            last = (TimelineDiagnostics.canvasDraws, MediaBinDiagnostics.tileBodies)
            await Self.display(host)
            await StoreFixture.wait(until: { false }, timeout: 0.1)
        }

        // Positive controls: the canvas redraws for a change it shows, a tile for its selection.
        let controlDraws = TimelineDiagnostics.canvasDraws
        store.snapIndicator = 0.5
        await Self.display(host)
        store.snapIndicator = nil
        await Self.display(host)
        XCTAssertGreaterThan(TimelineDiagnostics.canvasDraws, controlDraws, "the canvas draws in this host")
        let controlTiles = MediaBinDiagnostics.tileBodies
        let selectedAsset = store.selectedAssetID
        store.selectedAssetID = selectedAsset == store.assets.first?.assetID ? store.assets.last?.assetID
            : store.assets.first?.assetID
        await Self.display(host)
        XCTAssertGreaterThan(MediaBinDiagnostics.tileBodies, controlTiles, "the bin's tiles draw in this host")
        await Self.display(host)

        let builds = store.timelineBuildCount
        let canvasDraws = TimelineDiagnostics.canvasDraws
        let tileBodies = MediaBinDiagnostics.tileBodies
        let versionBefore = store.thumbnails.version
        // A scrub through the clip's frames: wait for each picture to land and show.
        var landed: [ObjectIdentifier] = []
        for frame in stride(from: 3, through: 27, by: 3) {
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            let before = loader.image.map(ObjectIdentifier.init)
            store.playhead.setTime(time) // the overlay feeds the helper from the playhead
            await Self.display(host)
            let arrived = await StoreFixture.wait(until: {
                loader.pendingSeconds == nil && loader.image.map(ObjectIdentifier.init) != before
            }, timeout: 20)
            XCTAssertTrue(arrived, "the picture for frame \(frame) lands")
            if let image = loader.image { landed.append(ObjectIdentifier(image)) }
            await Self.display(host)
            XCTAssertLessThanOrEqual(loader.cachedCount, loader.capacity, "the helper's memory stays bounded")
        }
        let rebuilt = store.timelineBuildCount - builds
        let redrawn = TimelineDiagnostics.canvasDraws - canvasDraws
        let tiles = MediaBinDiagnostics.tileBodies - tileBodies
        print("\(landed.count) Ken Burns pictures landed: timeline model builds \(rebuilt), canvas draws \(redrawn), "
            + "bin tile bodies \(tiles)")
        XCTAssertEqual(Set(landed).count, 9, "nine distinct pictures landed and were shown")
        XCTAssertEqual(rebuilt, 0, "the timeline model is not rebuilt")
        XCTAssertEqual(redrawn, 0, "the clips' canvas is not redrawn")
        XCTAssertEqual(tiles, 0, "no bin tile is redrawn")
        XCTAssertEqual(store.thumbnails.version, versionBefore, "the shared thumbnail cache is untouched")
        store.closeKenBurns()
    }

    /// Lets SwiftUI process the pending updates (one main-queue turn), then makes the window
    /// lay out and display now, and renders the hosting view into a bitmap (which draws the
    /// SwiftUI content even while the window server does not composite the window).
    private static func display(_ host: NSView) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
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
        // (Left of the fade-out handle, which sits in the top-right corner of audio clips.)
        let audioBody = pixel(audioRect.maxX - 14, audioRect.minY + 4)
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
