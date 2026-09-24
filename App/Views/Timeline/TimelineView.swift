import AppKit
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers
import FramewrightEngine

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
/// Transitions are bands across their cut at the top of the row, labelled with their duration:
/// click selects (Delete removes it with its linked transition, Option-Delete only it; a right-click
/// offers both), double-click edits the duration in the inspector), dragging an
/// edge resizes symmetrically about the cut (whole frames, bounded by the media beyond the cut,
/// which the status line names when the drag reaches it; the linked transition follows unless the
/// Transition inspector's "Also change the linked transition" is off). Transitions dragged from
/// the Effects tab highlight the cut they would land on (red, with the reason, when it cannot
/// take one). Audio clips show their volume envelope over the waveform: a fade handle in each top
/// corner (drag to set the fade, never overlapping the other) and the gain line (drag vertically;
/// Option for fine steps; the value shows next to the pointer). Every such drag is one undo step.
///
/// Corner zones of audio clips: the top 16 pt of a row hold the transition strip, the clip's name
/// label and the fade handles at once. Priority is transition band, then fade handle, then clip
/// edge, gain line and body, so a press within `fadeHandleHitRadius` of a handle in the top
/// `fadeHandleZoneHeight` points grabs the handle (dragging the first points of a label that
/// starts at a zero-length fade adjusts the fade-in instead of moving the clip, as in Premiere).
/// On a clip narrower than `narrowClipWidth` the handle zone is only
/// `narrowFadeHandleZoneHeight` points tall (hit testing only; the handles are drawn the same),
/// so most of a small clip's label still selects and moves it.
///
/// Video clips with Motion keyframes show a diamond along their bottom edge for every frame that
/// shows a keyframe (where the keyframe plays with the clip's speed); clicking one moves the
/// playhead to that frame (and selects the clip), dragging from it moves the clip.
///
/// While the Ken Burns helper is open, the clip it edits shows the move's range as an accent band
/// with a green start edge and a red end edge (the rectangles' colours), following the range as it
/// changes (`KenBurnsBandView`).
///
/// Durations (transition labels, drop feedback) follow Settings > Editing > "Show durations as"
/// and re-format as soon as it changes (`ProjectStore.preferences`).
///
/// Redraw budget: the canvas depends on the model (`ProjectStore`, rebuilt once per model change),
/// the viewport and the Editing preferences, never on the playhead. The playhead line, the ruler
/// marker and the timecode are overlays observing `PlayheadModel` alone, so playback at the
/// display rate does not redraw the clips; the Ken Burns band observes `KenBurnsTimelineBand`
/// alone, so a range moving with the playhead or with typing does not either.
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
            thumbnails: thumbnails, waveforms: waveforms, snapTime: store.snapIndicator, marquee: gestures.marquee,
            gainTooltip: gestures.gainTooltip, transitionDrop: gestures.transitionDrop,
            formatFrames: { [frameDuration = store.frameDuration, display = store.editingPreferences.durationDisplay] in
                DurationFormat.shortString(frames: $0, frameDuration: frameDuration, display: display)
            }
        )
        // Reading the caches' versions makes new thumbnails and waveforms redraw the canvas, and
        // the preferences' revision re-formats the labels when the duration display changes.
        let redrawToken = thumbnails.version &+ waveforms.version &+ store.preferences.revision
        return Canvas { context, size in
            _ = redrawToken
            renderer.draw(in: &context, size: size)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .overlay(alignment: .topLeading) {
            KenBurnsBandView(band: store.kenBurnsBand, model: model)
                .allowsHitTesting(false)
        }
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
                                     modifiers: NSEvent.modifierFlags, clickCount: Self.currentClickCount)
                }
                .onEnded { _ in gestures.ended() }
        )
        .onChange(of: trackGestureActive) { _, active in
            if !active {
                // onEnded runs first for a normal release (the controller is idle by now).
                gestures.abandon()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): gestures.hover(at: location)
            case .ended: gestures.hover(at: nil)
            }
        }
        .onDrop(of: TimelineDropDelegate.types,
                delegate: TimelineDropDelegate(gestures: gestures, isAssetTargeted: $isDropTargeted))
        .background(ContextMenuCatcher { [gestures] point in gestures.contextMenuItems(at: point) })
        .clipped()
    }

    /// The click count of the mouse event being handled (1 when the current event is not a mouse
    /// press, release or drag: SwiftUI may run the gesture's callback while another event is
    /// current, and `NSEvent.clickCount` raises for non-mouse events).
    private static var currentClickCount: Int {
        guard let event = NSApp.currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return max(1, event.clickCount)
        default:
            return 1
        }
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

/// The Ken Burns helper's range on its clip in the timeline: a translucent accent band over the
/// clip's row from the range's first frame to the end of its last, the start edge green and the end
/// edge red (the helper's rectangles). It observes only the band (the range), and takes the
/// timeline's geometry as a value from the timeline's body, which is evaluated when the model or
/// the viewport changes: a range change redraws this overlay alone.
struct KenBurnsBandView: View {
    @ObservedObject var band: KenBurnsTimelineBand
    let model: TimelineViewModel

    /// Width of the start and end edges.
    static let edgeWidth: CGFloat = 2
    /// Size of the flags on top of the edges.
    static let flagSize: CGFloat = 6

    var body: some View {
        let _ = TimelineDiagnostics.kenBurnsBandUpdates += 1
        if let range = band.range, let rect = Self.rect(for: range, in: model) {
            Canvas { context, _ in
                Self.draw(rect, in: &context)
            }
            .accessibilityIdentifier("KenBurnsTimelineBand")
        }
    }

    /// The band's rectangle in the track area: the clip's row, from x of the range's start to x of
    /// its end (`TimelineViewModel.x(forTime:)`). Nil when the clip is not in the model.
    static func rect(for range: KenBurnsBandRange, in model: TimelineViewModel) -> CGRect? {
        guard let clip = model.clip(id: range.clipID), let row = model.layout(forTrack: clip.trackID) else { return nil }
        let x0 = model.x(forTime: range.start)
        let x1 = model.x(forTime: range.end)
        return CGRect(x: x0, y: row.y - model.scrollY, width: max(1, x1 - x0), height: row.height)
    }

    private static func draw(_ rect: CGRect, in context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.28)))
        var outline = Path()
        outline.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.5))
        outline.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 0.5))
        outline.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        outline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        context.stroke(outline, with: .color(.accentColor), lineWidth: 1)
        for (x, color, pointsRight) in [(rect.minX, Color.green, true), (rect.maxX, Color.red, false)] {
            let edge = CGRect(x: pointsRight ? x : x - edgeWidth, y: rect.minY, width: edgeWidth, height: rect.height)
            context.fill(Path(edge), with: .color(color))
            var flag = Path()
            flag.move(to: CGPoint(x: x, y: rect.minY))
            flag.addLine(to: CGPoint(x: x + (pointsRight ? flagSize : -flagSize), y: rect.minY))
            flag.addLine(to: CGPoint(x: x, y: rect.minY + flagSize))
            flag.closeSubpath()
            context.fill(flag, with: .color(color))
        }
    }
}

/// What a drop on the timeline offers: SwiftUI's `DropInfo`, or a test double (DropInfo cannot be
/// made outside SwiftUI; the drop logic below only needs these three).
@MainActor
protocol TimelineDropInfo {
    var location: CGPoint { get }
    func hasItemsConforming(to contentTypes: [UTType]) -> Bool
    func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider]
}

extension DropInfo: TimelineDropInfo {}

/// Drops on the track area: media from the bin (placed at the drop point, overwrite; hold
/// Command to insert), media files from the Finder and file promises from Photos (imported, then
/// placed there once they have arrived; `MediaDrop`, `IncomingMedia`) and transitions from the
/// Effects tab (added on the nearest cut; the cut is highlighted while dragging, in red with the
/// reason when it cannot take one). A transition is recognised by its exported content type
/// (`TransitionKind.contentType`, declared in Info.plist), which the Effects tab's drag source
/// (`TransitionReference`) provides; the payload itself is not read. The `handle...` methods take
/// any `TimelineDropInfo`, so the drop logic is tested without a real drag (which only a person or
/// a UI test can perform).
@MainActor
struct TimelineDropDelegate: DropDelegate {
    static let types: [UTType] = [.framewrightAssetReference, .framewrightCrossDissolve, .framewrightAudioCrossfade]
        + MediaDrop.types

    let gestures: TimelineGestureController
    @Binding var isAssetTargeted: Bool
    /// Whether Command is held (insert instead of overwrite); injectable for tests.
    var commandHeld: () -> Bool = { NSEvent.modifierFlags.contains(.command) }

    static func transitionKind(_ info: some TimelineDropInfo) -> TransitionKind? {
        TransitionKind.allCases.first { info.hasItemsConforming(to: [$0.contentType]) }
    }

    func validateDrop(info: DropInfo) -> Bool { handleValidate(info) }
    func dropEntered(info: DropInfo) { handleEntered(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { handleUpdated(info) }
    func dropExited(info: DropInfo) { handleExited(info) }
    func performDrop(info: DropInfo) -> Bool {
        handlePerform(info, pasteboardPromises: { PasteboardFilePromise.fromDragPasteboard() })
    }

    func handleValidate(_ info: some TimelineDropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    func handleEntered(_ info: some TimelineDropInfo) {
        if Self.transitionKind(info) == nil { isAssetTargeted = true }
    }

    func handleUpdated(_ info: some TimelineDropInfo) -> DropProposal? {
        guard let kind = Self.transitionKind(info) else { return DropProposal(operation: .copy) }
        let target = gestures.transitionDragUpdated(kind: kind, at: info.location)
        return DropProposal(operation: target?.allowed == true ? .copy : .forbidden)
    }

    func handleExited(_ info: some TimelineDropInfo) {
        isAssetTargeted = false
        gestures.transitionDragExited()
    }

    /// `pasteboardPromises`: the drag pasteboard's file promises (a real drop); see `MediaDrop`.
    func handlePerform(_ info: some TimelineDropInfo,
                       pasteboardPromises: () -> [PromisedFile] = { [] }) -> Bool {
        isAssetTargeted = false
        if let kind = Self.transitionKind(info) {
            return gestures.dropTransition(kind: kind, at: info.location)
        }
        guard let provider = info.itemProviders(for: [.framewrightAssetReference]).first else {
            guard MediaDrop.accepts(info) else { return false }
            let placement = gestures.placement(at: info.location, insert: commandHeld())
            if placement == nil {
                gestures.store.statusMessage = "Drop media on a track to place it; it is imported into the media bin."
            }
            return MediaDrop.perform(info, store: gestures.store, placement: placement,
                                     pasteboardPromises: pasteboardPromises)
        }
        let location = info.location
        let insert = commandHeld()
        let controller = gestures
        provider.loadDataRepresentation(forTypeIdentifier: UTType.framewrightAssetReference.identifier) { data, _ in
            guard let data, let reference = try? JSONDecoder().decode(AssetReference.self, from: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = controller.drop(assetID: reference.assetID, at: location, insert: insert)
                }
            }
        }
        return true
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
