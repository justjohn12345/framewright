import AppKit
import CoreMedia
import SwiftUI
import VidEditEngine

/// The timeline: ruler, track headers and the track area drawn in a `Canvas`.
///
/// Gestures on the track area: click selects (shift-click toggles; linked partners come along),
/// dragging on empty space draws a marquee, dragging a clip body moves the selection (snapping
/// to clip edges, the playhead and the sequence start; vertical movement changes tracks within
/// the same kind; the engine applies overwrite semantics), dragging within 8 pt of a clip edge
/// trims it. Every drag is one coalesced undo step, committed on release; Escape cancels it.
/// Dragging in the ruler scrubs the playhead. Media dropped from the bin lands at the drop
/// position and row (overwrite; hold Command to insert). Scroll to pan, Option/Command-scroll to zoom.
struct TimelineView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var thumbnails: ThumbnailCache
    @ObservedObject var waveforms: WaveformCache

    @State private var drag: DragState = .idle
    @State private var marquee: CGRect?
    @State private var canvasSize: CGSize = .zero
    @State private var isDropTargeted = false

    static let headerWidth: CGFloat = 170
    static let rulerHeight: CGFloat = 26
    static let scrollBarHeight: CGFloat = 12
    /// Distance the pointer must travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    init(store: ProjectStore) {
        self.store = store
        thumbnails = store.thumbnails
        waveforms = store.waveforms
    }

    enum DragState: Equatable {
        case idle
        /// Pressed, not moved far enough yet.
        case pending(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, wasSelected: Bool)
        case moving(ids: [Int64], origin: CGPoint, start: Double, end: Double, excluded: Set<Int64>,
                    originKind: TimelineViewModel.TrackKind, originIndex: Int)
        case trimmingHead(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case trimmingTail(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case marquee(origin: CGPoint, base: Set<Int64>)
        /// Escape pressed: ignore the rest of the gesture.
        case cancelled
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
        .background(ScrollWheelCatcher { handleScroll($0, model: model) })
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
            Text(Timecode.string(store.playheadTime, frameDuration: store.frameDuration))
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
            let px = model.x(forTime: model.playhead)
            var marker = Path()
            marker.move(to: CGPoint(x: px - 6, y: size.height - 12))
            marker.addLine(to: CGPoint(x: px + 6, y: size.height - 12))
            marker.addLine(to: CGPoint(x: px, y: size.height))
            marker.closeSubpath()
            context.fill(marker, with: .color(.red))
        }
        .frame(height: Self.rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var seconds = model.time(forX: value.location.x)
                    if let snap = model.snap(seconds, excluding: []), snap.target != .playhead {
                        seconds = snap.time
                    }
                    store.setPlayhead(seconds: seconds)
                }
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
        let assetsByID = Dictionary(store.assets.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        let renderer = TimelineRenderer(
            model: model, size: canvasSize, selection: store.selection,
            selectedTransitionID: store.selectedTransitionID,
            targetTrackIDs: [store.targetVideoTrackID, store.targetAudioTrackID], assets: assetsByID,
            thumbnails: thumbnails, waveforms: waveforms, snapTime: store.snapIndicator, marquee: marquee
        )
        // Reading the caches' versions makes new thumbnails and waveforms redraw the canvas.
        let redrawToken = thumbnails.version &+ waveforms.version
        return Canvas { context, _ in
            _ = redrawToken
            renderer.draw(in: &context)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
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
                .onChanged { dragChanged($0) }
                .onEnded { dragEnded($0) }
        )
        .dropDestination(for: AssetReference.self) { items, location in
            drop(items, at: location)
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

    private func handleScroll(_ scroll: ScrollWheelCatcher.Scroll, model: TimelineViewModel) {
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

    // MARK: Gestures

    private func dragChanged(_ value: DragGesture.Value) {
        let model = store.timelineModel
        switch drag {
        case .idle:
            begin(at: value.startLocation, model: model)
            dragChanged(value)
        case let .pending(hit, origin, extend, _):
            guard hypot(value.location.x - origin.x, value.location.y - origin.y) >= Self.dragThreshold else { return }
            startDrag(hit: hit, origin: origin, extend: extend, model: model)
            if drag != .idle { dragChanged(value) }
        case let .moving(ids, origin, start, end, excluded, originKind, originIndex):
            var delta = model.time(forX: value.location.x) - model.time(forX: origin.x)
            let snapped = model.snapMove(start: start, end: end, delta: delta, excluding: excluded)
            delta = snapped.delta
            delta = model.snapToFrame(start + delta) - start
            if start + delta < 0 { delta = -start }
            var trackOffset = 0
            if let row = model.layout(atY: value.location.y), row.track.kind == originKind {
                trackOffset = row.track.index - originIndex
            }
            store.snapIndicator = snapped.snap?.time
            let frames = Int64((delta / max(model.frameSeconds, 1e-9)).rounded())
            let deltaTime = CMTimeMultiply(store.frameDuration, multiplier: Int32(clamping: frames))
            let result = store.engine.moveClips(ids.map { NSNumber(value: $0) }, by: deltaTime,
                                                trackOffset: trackOffset)
            if !result.ok { store.statusMessage = result.message }
        case let .trimmingHead(clip, origin, edge, excluded):
            let time = trimTime(edge: edge, origin: origin, location: value.location, excluded: excluded, model: model)
            store.report(store.engine.trimClipHead(clip, to: store.frameTime(time), clamp: true))
        case let .trimmingTail(clip, origin, edge, excluded):
            let time = trimTime(edge: edge, origin: origin, location: value.location, excluded: excluded, model: model)
            store.report(store.engine.trimClipTail(clip, to: store.frameTime(time), clamp: true))
        case let .marquee(origin, base):
            let rect = CGRect(x: origin.x, y: origin.y, width: value.location.x - origin.x,
                              height: value.location.y - origin.y).standardized
            marquee = rect
            store.selection = base.union(model.expandingLinks(model.clipIDs(intersecting: rect)))
        case .cancelled:
            break
        }
    }

    private func trimTime(edge: Double, origin: CGPoint, location: CGPoint, excluded: Set<Int64>,
                          model: TimelineViewModel) -> Double {
        var time = edge + model.time(forX: location.x) - model.time(forX: origin.x)
        let snap = model.snap(time, excluding: excluded)
        if let snap { time = snap.time }
        store.snapIndicator = snap?.time
        return max(0, time)
    }

    /// Press: select according to what was hit.
    private func begin(at point: CGPoint, model: TimelineViewModel) {
        let extend = NSEvent.modifierFlags.contains(.shift)
        let hit = model.hitTest(point)
        store.focusArea = .timeline
        store.statusMessage = nil
        switch hit {
        case let .clipBody(id), let .clipHead(id), let .clipTail(id):
            let wasSelected = store.selection.contains(id)
            if extend || !wasSelected {
                store.select(clip: id, extend: extend)
            }
            store.selectedTransitionID = nil
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: wasSelected)
        case let .transition(id):
            store.selection = []
            store.selectedTransitionID = id
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: false)
        case let .track(id):
            if let track = model.tracks.first(where: { $0.id == id }) {
                if track.kind == .video { store.targetVideoTrackID = id } else { store.targetAudioTrackID = id }
            }
            startMarquee(at: point, extend: extend)
        case .none:
            startMarquee(at: point, extend: extend)
        }
    }

    private func startMarquee(at point: CGPoint, extend: Bool) {
        if !extend { store.selection = [] }
        store.selectedTransitionID = nil
        drag = .marquee(origin: point, base: store.selection)
    }

    /// The pointer moved past the threshold: start moving or trimming.
    private func startDrag(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, model: TimelineViewModel) {
        switch hit {
        case let .clipBody(id):
            guard store.selection.contains(id), let anchor = model.clip(id: id),
                  let row = model.layout(forTrack: anchor.trackID) else {
                drag = .cancelled
                return
            }
            let ids = Array(store.selection)
            let moving = model.clips.filter { store.selection.contains($0.id) }
            let start = moving.map(\.start).min() ?? anchor.start
            let end = moving.map(\.end).max() ?? anchor.end
            store.engine.beginCoalescing(withKey: "timeline.move")
            drag = .moving(ids: ids, origin: origin, start: start, end: end,
                           excluded: model.expandingLinks(Set(ids)), originKind: row.track.kind,
                           originIndex: row.track.index)
        case let .clipHead(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            store.engine.beginCoalescing(withKey: "timeline.trim")
            drag = .trimmingHead(clip: id, origin: origin, edge: clip.start, excluded: model.expandingLinks([id]))
        case let .clipTail(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            store.engine.beginCoalescing(withKey: "timeline.trim")
            drag = .trimmingTail(clip: id, origin: origin, edge: clip.end, excluded: model.expandingLinks([id]))
        default:
            drag = .cancelled
            return
        }
        store.cancelActiveGesture = {
            store.engine.cancelCoalescing()
            store.snapIndicator = nil
            drag = .cancelled
            store.cancelActiveGesture = nil
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        switch drag {
        case let .pending(hit, _, extend, wasSelected):
            // A plain click on a clip that was part of a multi-selection selects just that clip.
            if case let .clipBody(id) = hit, !extend, wasSelected {
                store.select(clip: id, extend: false)
            }
        case .moving, .trimmingHead, .trimmingTail:
            store.engine.endCoalescing()
        default:
            break
        }
        store.snapIndicator = nil
        store.cancelActiveGesture = nil
        marquee = nil
        drag = .idle
    }

    // MARK: Drop

    private func drop(_ items: [AssetReference], at location: CGPoint) -> Bool {
        let model = store.timelineModel
        guard let item = items.first, let row = model.layout(atY: location.y) else { return false }
        var seconds = model.time(forX: location.x)
        if let snap = model.snap(seconds) { seconds = snap.time }
        let insert = NSEvent.modifierFlags.contains(.command)
        return store.dropAsset(item.assetID, onTrack: row.track.id, at: seconds, overwrite: !insert)
    }
}
