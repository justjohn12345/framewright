import AppKit
import CoreMedia
import SwiftUI
import VidEditEngine

/// The timeline: ruler, track headers and the track area drawn in a `Canvas`.
///
/// Gestures on the track area (see `TimelineGestureController`): click selects (shift-click
/// toggles; linked partners come along), dragging on empty space draws a marquee, dragging a
/// clip body moves the selection (snapping to clip edges, the playhead and the sequence start;
/// vertical movement changes tracks within the same kind; the engine applies overwrite
/// semantics), dragging within 8 pt of a clip edge trims it. Every drag is one coalesced undo
/// step, committed on release; Escape cancels it. Dragging in the ruler scrubs the program
/// monitor (silently; the frame shows as soon as it decodes), and so does dragging the playhead
/// line in the track area (press on empty space next to it, or anywhere with Option held; see
/// `TimelineGestureController`). A press anywhere gives the timeline the keyboard focus (a text
/// field that had it ends editing). Media dropped from the bin lands
/// at the drop position and row (overwrite; hold Command to insert). Scroll to pan,
/// Option/Command-scroll to zoom.
///
/// Redraw budget: the canvas depends on the model (`ProjectStore`, rebuilt once per model change)
/// and the viewport, never on the playhead. The playhead line, the ruler marker and the
/// timecode are overlays observing `PlayheadModel` alone, so playback at the display rate does
/// not redraw the clips.
struct TimelineView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var viewport: TimelineViewport
    @ObservedObject var thumbnails: ThumbnailCache
    @ObservedObject var waveforms: WaveformCache
    @StateObject private var gestures: TimelineGestureController

    @State private var canvasSize: CGSize = .zero
    @State private var isDropTargeted = false
    /// True while the track-area drag gesture is active; reset by SwiftUI when the gesture ends
    /// or is cancelled, which catches gestures that end without onEnded.
    @GestureState private var trackGestureActive = false

    static let headerWidth: CGFloat = 170
    static let rulerHeight: CGFloat = 26
    static let scrollBarHeight: CGFloat = 12

    init(store: ProjectStore) {
        self.store = store
        viewport = store.viewport
        thumbnails = store.thumbnails
        waveforms = store.waveforms
        _gestures = StateObject(wrappedValue: TimelineGestureController(store: store))
    }

    var body: some View {
        let model = store.timelineModel
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerControls
                    .frame(width: Self.headerWidth, height: Self.rulerHeight)
                ruler(model)
            }
            Divider()
            HStack(spacing: 0) {
                headers(model)
                    .frame(width: Self.headerWidth)
                Divider()
                trackArea(model)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.headerWidth)
                scrollBar(model)
            }
            .frame(height: Self.scrollBarHeight)
        }
        .background(ScrollWheelCatcher { handleScroll($0) })
        .accessibilityIdentifier("Timeline")
    }

    // MARK: Corner

    private var cornerControls: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Add Video Track") { store.report(store.engine.addTrack(of: .video, name: nil)) }
                Button("Add Audio Track") { store.report(store.engine.addTrack(of: .audio, name: nil)) }
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a track")
            Spacer()
            PlayheadTimecode(playhead: store.playhead, frameDuration: store.frameDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Ruler

    private func ruler(_ model: TimelineViewModel) -> some View {
        let fps = Timecode.framesPerSecond(store.frameDuration)
        return Canvas { context, size in
            let interval = model.rulerInterval()
            let showFrames = interval < 1
            let minor = interval / 5
            var t = max(0, (model.time(forX: 0) / minor).rounded(.down) * minor)
            let end = model.time(forX: size.width)
            var count = 0
            while t <= end, count < 5000 {
                let x = model.x(forTime: t)
                let isMajor = abs((t / interval).rounded() * interval - t) < minor / 10
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 10 : 4)))
                context.stroke(tick, with: .color(.secondary), lineWidth: 1)
                if isMajor {
                    let label = Text(Timecode.rulerLabel(seconds: t, showFrames: showFrames, fps: fps))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                t += minor
                count += 1
            }
        }
        .frame(height: Self.rulerHeight)
        .overlay(alignment: .topLeading) {
            PlayheadMarker(playhead: store.playhead, viewport: viewport, style: .rulerMarker)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let current = store.timelineModel
                    var seconds = current.time(forX: value.location.x)
                    // The playhead is what moves: it is never its own snap target.
                    if let snap = current.snap(seconds, excluding: [], includePlayhead: false) {
                        seconds = snap.time
                    }
                    store.scrub(toSeconds: max(0, seconds))
                }
                .onEnded { _ in store.endScrub() }
        )
        .clipped()
    }

    // MARK: Headers

    private func headers(_ model: TimelineViewModel) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            ForEach(model.trackLayouts, id: \.track.id) { layout in
                TrackHeaderView(store: store, track: layout.track, height: layout.height)
                    .offset(y: layout.y - model.scrollY)
            }
        }
        .clipped()
    }

    // MARK: Track area

    private func trackArea(_ model: TimelineViewModel) -> some View {
        let renderer = TimelineRenderer(
            model: model, selection: store.selection,
            selectedTransitionID: store.selectedTransitionID,
            targetTrackIDs: [store.targetVideoTrackID, store.targetAudioTrackID], assets: store.assetsByID,
            thumbnails: thumbnails, waveforms: waveforms, snapTime: store.snapIndicator, marquee: gestures.marquee
        )
        // Reading the caches' versions makes new thumbnails and waveforms redraw the canvas.
        let redrawToken = thumbnails.version &+ waveforms.version
        return Canvas { context, size in
            _ = redrawToken
            renderer.draw(in: &context, size: size)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .overlay(alignment: .topLeading) {
            PlayheadMarker(playhead: store.playhead, viewport: viewport, style: .line)
                .allowsHitTesting(false)
        }
        .overlay(isDropTargeted ? RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 2) : nil)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear {
                    canvasSize = geometry.size
                    store.timelineViewportWidth = geometry.size.width
                }
                .onChange(of: geometry.size) { _, newSize in
                    canvasSize = newSize
                    store.timelineViewportWidth = newSize.width
                }
        })
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($trackGestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    gestures.changed(location: value.location, startLocation: value.startLocation,
                                     modifiers: NSEvent.modifierFlags)
                }
                .onEnded { _ in gestures.ended() }
        )
        .onChange(of: trackGestureActive) { _, active in
            if !active {
                // onEnded runs first for a normal release (the controller is idle by now).
                gestures.abandon()
            }
        }
        .dropDestination(for: AssetReference.self) { items, location in
            guard let item = items.first else { return false }
            return gestures.drop(assetID: item.assetID, at: location, insert: NSEvent.modifierFlags.contains(.command))
        } isTargeted: { isDropTargeted = $0 }
        .clipped()
    }

    // MARK: Scrolling

    private func contentWidth(_ model: TimelineViewModel) -> CGFloat {
        CGFloat((model.sequenceEnd + 30) * model.pixelsPerSecond)
    }

    private func clampScroll(_ model: TimelineViewModel) {
        let maxX = max(0, contentWidth(model) - canvasSize.width)
        store.scrollX = min(max(0, store.scrollX), maxX)
        let maxY = max(0, model.contentHeight - canvasSize.height)
        store.scrollY = min(max(0, store.scrollY), maxY)
    }

    private func handleScroll(_ scroll: ScrollWheelCatcher.Scroll) {
        let model = store.timelineModel
        if scroll.modifiers.contains(.option) || scroll.modifiers.contains(.command) {
            let anchor = scroll.location.x - Self.headerWidth
            store.zoom(by: exp(Double(scroll.deltaY) * 0.01), anchorX: max(0, anchor))
            return
        }
        let horizontal = abs(scroll.deltaX) > abs(scroll.deltaY) || scroll.modifiers.contains(.shift)
        let tallContent = model.contentHeight > canvasSize.height
        if horizontal {
            store.scrollX -= abs(scroll.deltaX) > 0 ? scroll.deltaX : scroll.deltaY
        } else if tallContent, scroll.location.y > Self.rulerHeight {
            store.scrollY -= scroll.deltaY
        } else {
            store.scrollX -= scroll.deltaY
        }
        clampScroll(store.timelineModel)
    }

    private func scrollBar(_ model: TimelineViewModel) -> some View {
        GeometryReader { geometry in
            let total = max(contentWidth(model), geometry.size.width)
            let fraction = geometry.size.width / total
            let knobWidth = max(30, geometry.size.width * fraction)
            let travel = max(1, geometry.size.width - knobWidth)
            let maxScroll = max(1, total - geometry.size.width)
            let knobX = min(travel, max(0, store.scrollX / maxScroll * travel))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(Color.secondary.opacity(0.45))
                    .frame(width: knobWidth)
                    .offset(x: knobX)
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let x = value.location.x - knobWidth / 2
                store.scrollX = min(maxScroll, max(0, x / travel * maxScroll))
            })
        }
    }
}

/// The playhead drawn over the timeline: a line through the track area, or the triangle in
/// the ruler. It observes only the playhead and the viewport.
struct PlayheadMarker: View {
    enum Style {
        case line
        case rulerMarker
    }

    @ObservedObject var playhead: PlayheadModel
    @ObservedObject var viewport: TimelineViewport
    let style: Style

    var body: some View {
        let _ = TimelineDiagnostics.playheadUpdates += 1
        let x = CGFloat(playhead.time.secondsOrZero * viewport.pixelsPerSecond) - viewport.scrollX
        GeometryReader { geometry in
            switch style {
            case .line:
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: geometry.size.height)
                    .offset(x: x - 0.75)
            case .rulerMarker:
                Path { path in
                    let bottom = geometry.size.height
                    path.move(to: CGPoint(x: x - 6, y: bottom - 12))
                    path.addLine(to: CGPoint(x: x + 6, y: bottom - 12))
                    path.addLine(to: CGPoint(x: x, y: bottom))
                    path.closeSubpath()
                }
                .fill(Color.red)
            }
        }
        .allowsHitTesting(false)
    }
}

/// "HH:MM:SS:FF" of a playhead; observes only the playhead.
struct PlayheadTimecode: View {
    @ObservedObject var playhead: PlayheadModel
    let frameDuration: CMTime

    var body: some View {
        Text(Timecode.string(playhead.time, frameDuration: frameDuration))
    }
}
