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

    /// Review M7 (the replacement for the Ken Burns band test the lanes round removed): every step of
    /// a Ken Burns drag changes the model (the span's values), but nothing the timeline draws, so no
    /// step rebuilds the timeline's content model or redraws its clips; the drag's end neither. A
    /// span range change afterwards rebuilds it once. A positive control first proves the canvas
    /// does redraw in this host.
    func testAKenBurnsDragBuildsNoTimelineModelAndRedrawsNoClips() async throws {
        try await makeTwentyClipSequence()
        let store = fixture.store
        let first = try XCTUnwrap(store.clips.values.filter { $0.trackKind == .video }.min { $0.timelineStart < $1.timelineStart })
        let motion = try XCTUnwrap(store.engine.addSpan(kind: .motion, lane: 1, clip: first.clipID,
                                                        range: CMTimeRange(start: .zero, duration: CMTime(value: 20, timescale: 30))).span)
        store.refreshModel()
        store.select(span: motion.spanID)
        let model = try XCTUnwrap(store.kenBurns)
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
        var redrawn = 0
        // In both of the editor's modes (the full-frame clip opens in Ken Burns mode).
        XCTAssertEqual(model.mode, .kenBurns)
        for mode in [KenBurnsMode.kenBurns, .transform] {
            model.setMode(mode)
            await Self.display(host)
            let modeBuilds = store.timelineBuildCount
            let modeDraws = TimelineDiagnostics.canvasDraws
            let changes = store.changeCount
            let origin = model.end
            for step in 1 ... 20 {
                // The end's bottom-right corner pulled in: a zoom that grows with every step.
                let pulled = CGFloat(step) * 20
                model.applyDrag(.corner(.end, .bottomRight), origin: origin,
                                translation: CGSize(width: -pulled, height: -pulled * 9 / 16))
                await Self.display(host)
            }
            model.endDrag()
            await Self.display(host)
            let rebuilt = store.timelineBuildCount - modeBuilds
            let modeRedrawn = TimelineDiagnostics.canvasDraws - modeDraws
            redrawn += modeRedrawn
            print("20 Ken Burns drag steps (\(mode.title)): timeline model builds \(rebuilt), canvas draws "
                + "\(modeRedrawn), model changes \(store.changeCount - changes)")
            XCTAssertGreaterThanOrEqual(store.changeCount - changes, 20, "every step changed the model (\(mode))")
            XCTAssertEqual(rebuilt, 0, "a drag step changes nothing the timeline draws (\(mode))")
            XCTAssertLessThanOrEqual(modeRedrawn, 2, "and redraws no clips (\(mode))")
            XCTAssertEqual(store.undoActionName, "Change Span Values")
        }

        // A span range change is drawn: one build.
        XCTAssertTrue(store.engine.setSpanRange(motion.spanID, range: CMTimeRange(start: CMTime(value: 2, timescale: 30),
                                                                                    duration: CMTime(value: 20, timescale: 30))).ok)
        await Self.display(host)
        _ = store.timelineModel
        XCTAssertEqual(store.timelineBuildCount - builds, 1)
        XCTAssertGreaterThan(TimelineDiagnostics.canvasDraws, canvasDraws + redrawn, "and redrawn")
    }

    /// The Ken Burns editor open over the program monitor (the layout the app uses, a plain picture
    /// in place of the Metal view) while the playhead scrubs, hosted with the timeline and the media
    /// bin in one window: the other clips' outlines follow the playhead (a different clip of V1 under
    /// it at each step) and redraw the editor's overlay only, never the timeline model, the clips'
    /// canvas or a bin tile. Positive controls first prove the canvas and the tiles do redraw in this
    /// host when what they show changes.
    func testKenBurnsOutlinesFollowingThePlayheadRedrawNeitherTheTimelineNorTheBin() async throws {
        try await makeTwentyClipSequence()
        let store = fixture.store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = VStack(spacing: 0) {
            ProgramMonitorLayout(store: store) { Color.black }
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
        let videoClips = store.clips.values.filter { $0.trackKind == .video }
            .sorted { $0.timelineStart < $1.timelineStart }
        let clip = try XCTUnwrap(videoClips.first)
        store.playheadTime = .zero
        // A Motion span over the first clip's second: the editor opens on it.
        let motion = try XCTUnwrap(store.engine.addSpan(kind: .motion, lane: 1, clip: clip.clipID,
                                                        range: CMTimeRange(start: .zero, duration: CMTime(value: 30, timescale: 30))).span)
        store.select(span: motion.spanID)
        let model = try XCTUnwrap(store.kenBurns)
        model.setMode(.transform) // the outlines are Transform mode's (Ken Burns shows the clip alone)
        // Thumbnails, waveforms and the tiles settle.
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
        // A scrub over the next nine clips: the overlay reads each one's outline at the playhead.
        var outlined: [VEClipID] = []
        for index in 1 ... 9 {
            store.playhead.setTime(CMTime(value: CMTimeValue(index * 30 + 15), timescale: 30))
            await Self.display(host)
            outlined.append(contentsOf: model.outlines.map(\.clipID))
        }
        let rebuilt = store.timelineBuildCount - builds
        let redrawn = TimelineDiagnostics.canvasDraws - canvasDraws
        let tiles = MediaBinDiagnostics.tileBodies - tileBodies
        print("9 playhead steps with the Ken Burns editor open: timeline model builds \(rebuilt), canvas draws "
            + "\(redrawn), bin tile bodies \(tiles)")
        XCTAssertEqual(outlined, videoClips[1 ... 9].map(\.clipID), "the overlay followed the playhead")
        XCTAssertEqual(rebuilt, 0, "the timeline model is not rebuilt")
        XCTAssertEqual(redrawn, 0, "the clips' canvas is not redrawn")
        XCTAssertEqual(tiles, 0, "no bin tile is redrawn")
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

    /// Review L1: the track area starts where the ruler does (the playhead line under the ruler's
    /// triangle, clips and hits at the ruler's x), and the time scroll bar too.
    func testTheTrackAreaAndTheRulerShareTheirOrigin() async throws {
        let store = fixture.store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TimelineView(store: store))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for _ in 0 ..< 5 { await Self.display(host) }
        let rulerFrame = TimelineDiagnostics.rulerFrame
        let tracksFrame = TimelineDiagnostics.trackAreaFrame
        XCTAssertGreaterThan(rulerFrame.width, 100)
        XCTAssertEqual(tracksFrame.minX, rulerFrame.minX, accuracy: 0.01, "the same origin: \(tracksFrame) \(rulerFrame)")
        XCTAssertEqual(tracksFrame.maxX, rulerFrame.maxX, accuracy: 0.01)
        XCTAssertEqual(tracksFrame.minX, TimelineView.headerWidth, accuracy: 0.01)
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

    /// The lanes paint their spans: a Motion span's bar in its colour on lane 1 under its clip, a
    /// fade out's bar on lane 0, the empty part of a lane not.
    func testTheLanesPaintTheirSpans() async throws {
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 1) // 1 s - 3 s
        store.selection = []
        let motion = try XCTUnwrap(store.engine.addSpan(kind: .motion, lane: 1, clip: clip,
                                                        range: CMTimeRange(start: CMTime(value: 30, timescale: 30),
                                                                           duration: CMTime(value: 30, timescale: 30))).span)
        XCTAssertTrue(store.engine.addTransition(at: .end, of: clip, duration: CMTime(value: 15, timescale: 30),
                                                 options: []).ok)
        store.refreshModel()
        store.pixelsPerSecond = 200
        let size = CGSize(width: 1000, height: 400)
        let renderer = ImageRenderer(content: TimelineView(store: store)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let model = store.timelineModel
        func pixel(_ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let px = Int(TimelineView.headerWidth + 1 + x)
            let py = Int(TimelineView.rulerHeight + 1 + y)
            guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        let bar = try XCTUnwrap(model.rect(forSpan: try XCTUnwrap(model.span(id: motion.spanID))))
        // Right end of the bar (clear of its icon and name): the Motion colour, orange; the lane past
        // the clip is not. (ImageRenderer tints the whole view for the AppKit views it cannot draw,
        // so the lane is compared with the bar rather than with a fixed colour.)
        let inside = pixel(bar.maxX - 4, bar.midY)
        let empty = pixel(model.x(forTime: 3.8), bar.midY)
        XCTAssertGreaterThan(inside.r, inside.b + 0.3, "the Motion bar is painted: \(inside)")
        XCTAssertGreaterThan(inside.r, inside.g, "\(inside)")
        XCTAssertGreaterThan(empty.g - inside.g, 0.15, "the empty lane is lighter: \(empty) vs \(inside)")
        XCTAssertGreaterThan(empty.b - inside.b, 0.15, "\(empty) vs \(inside)")
        let fade = try XCTUnwrap(model.spans.first { $0.kind == .transition })
        let fadeBar = try XCTUnwrap(model.rect(forSpan: fade))
        let purple = pixel(fadeBar.maxX - 4, fadeBar.midY)
        XCTAssertGreaterThan(purple.b, purple.g + 0.2, "the fade out on lane 0 is painted: \(purple)")
    }
}
