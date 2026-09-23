import AppKit
import CoreMedia
import Foundation
import VidEditEngine

/// The timeline's pointer gestures as a state machine, separate from SwiftUI so it can be
/// driven and tested with synthetic locations.
///
/// A press selects what it hits; moving past `dragThreshold` turns it into a move (clip body),
/// a trim (within `edgeZone` of a clip edge) or a marquee (empty space). Moves and trims are
/// one coalesced engine edit each, committed on release (`ended`), reverted by Escape or Cmd+Z
/// (`cancel`) and by a gesture the system abandons without an end (`abandon`). Snapping uses
/// the timeline as it was when the drag started, so the drag's own previewed edits (clips the
/// moved clip overwrote, edges it split) never become snap targets.
@MainActor
final class TimelineGestureController: ObservableObject {
    enum DragState: Equatable {
        case idle
        /// Pressed, not moved far enough yet.
        case pending(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, wasSelected: Bool)
        case moving(ids: [Int64], origin: CGPoint, start: Double, end: Double, excluded: Set<Int64>,
                    originKind: TimelineViewModel.TrackKind, originIndex: Int)
        case trimmingHead(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case trimmingTail(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case marquee(origin: CGPoint, base: Set<Int64>)
        /// Escape pressed: the rest of the gesture is ignored.
        case cancelled
    }

    /// Distance the pointer must travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    @Published private(set) var drag: DragState = .idle
    @Published private(set) var marquee: CGRect?

    private unowned let store: ProjectStore
    /// The timeline's content when the drag started (snap candidates).
    private var snapshot: TimelineViewModel?

    init(store: ProjectStore) {
        self.store = store
    }

    /// The pre-gesture content at the current zoom and scroll.
    private var snapModel: TimelineViewModel {
        let live = store.timelineModel
        guard var model = snapshot else { return live }
        model.pixelsPerSecond = live.pixelsPerSecond
        model.scrollX = live.scrollX
        model.scrollY = live.scrollY
        model.playhead = live.playhead
        return model
    }

    // MARK: Events

    /// The pointer moved (or was pressed: the first event of a gesture).
    func changed(location: CGPoint, startLocation: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let model = store.timelineModel
        switch drag {
        case .idle:
            begin(at: startLocation, extend: modifiers.contains(.shift), model: model)
            if drag != .idle {
                changed(location: location, startLocation: startLocation, modifiers: modifiers)
            }
        case let .pending(hit, origin, extend, _):
            guard hypot(location.x - origin.x, location.y - origin.y) >= Self.dragThreshold else { return }
            startDrag(hit: hit, origin: origin, extend: extend, model: model)
            if drag != .cancelled {
                changed(location: location, startLocation: startLocation, modifiers: modifiers)
            }
        case let .moving(ids, origin, start, end, excluded, originKind, originIndex):
            move(ids: ids, origin: origin, location: location, start: start, end: end, excluded: excluded,
                 originKind: originKind, originIndex: originIndex, model: model)
        case let .trimmingHead(clip, origin, edge, excluded):
            let time = trimTime(edge: edge, origin: origin, location: location, excluded: excluded, model: model)
            store.report(store.engine.trimClipHead(clip, to: store.frameTime(time), clamp: true))
        case let .trimmingTail(clip, origin, edge, excluded):
            let time = trimTime(edge: edge, origin: origin, location: location, excluded: excluded, model: model)
            store.report(store.engine.trimClipTail(clip, to: store.frameTime(time), clamp: true))
        case let .marquee(origin, base):
            let rect = CGRect(x: origin.x, y: origin.y, width: location.x - origin.x,
                              height: location.y - origin.y).standardized
            marquee = rect
            let hit = base.union(model.expandingLinks(model.clipIDs(intersecting: rect)))
            if hit != store.selection { store.selection = hit }
        case .cancelled:
            break
        }
    }

    /// The pointer was released.
    func ended() {
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
        reset()
    }

    /// Escape / Cmd+Z: reverts the drag's edits; the rest of the gesture is ignored.
    func cancel() {
        switch drag {
        case .moving, .trimmingHead, .trimmingTail:
            store.engine.cancelCoalescing()
            drag = .cancelled
        case .pending, .marquee:
            drag = .cancelled
        case .idle, .cancelled:
            break
        }
        store.snapIndicator = nil
        store.cancelActiveGesture = nil
        marquee = nil
        snapshot = nil
    }

    /// The system ended the gesture without a release (the view went away, another gesture won):
    /// an unfinished edit is reverted, like Escape, and the state is reset.
    func abandon() {
        guard drag != .idle else { return }
        cancel()
        reset()
    }

    /// Media dropped from the bin: lands at the drop position and row (overwrite; `insert`
    /// ripples instead). False when the drop is not on a track row.
    @discardableResult
    func drop(assetID: VEAssetID, at location: CGPoint, insert: Bool) -> Bool {
        let model = store.timelineModel
        guard let row = model.layout(atY: location.y), location.x >= 0 else { return false }
        var seconds = model.time(forX: location.x)
        if let snap = model.snap(seconds) { seconds = snap.time }
        return store.dropAsset(assetID, onTrack: row.track.id, at: seconds, overwrite: !insert)
    }

    // MARK: Steps

    private func reset() {
        store.snapIndicator = nil
        store.cancelActiveGesture = nil
        marquee = nil
        snapshot = nil
        drag = .idle
    }

    /// Press: select according to what was hit.
    private func begin(at point: CGPoint, extend: Bool, model: TimelineViewModel) {
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
        store.cancelActiveGesture = { [weak self] in self?.cancel() }
    }

    /// The pointer moved past the threshold: start moving or trimming.
    private func startDrag(hit: TimelineViewModel.Hit, origin: CGPoint, extend _: Bool, model: TimelineViewModel) {
        switch hit {
        case let .clipBody(id):
            guard store.selection.contains(id), let anchor = model.clip(id: id),
                  let row = model.layout(forTrack: anchor.trackID) else {
                drag = .cancelled
                return
            }
            let ids = Array(store.selection).sorted()
            let moving = model.clips.filter { store.selection.contains($0.id) }
            let start = moving.map(\.start).min() ?? anchor.start
            let end = moving.map(\.end).max() ?? anchor.end
            snapshot = model
            store.engine.beginCoalescing(withKey: "timeline.move")
            drag = .moving(ids: ids, origin: origin, start: start, end: end,
                           excluded: model.expandingLinks(Set(ids)), originKind: row.track.kind,
                           originIndex: row.track.index)
        case let .clipHead(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: "timeline.trim")
            drag = .trimmingHead(clip: id, origin: origin, edge: clip.start, excluded: model.expandingLinks([id]))
        case let .clipTail(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: "timeline.trim")
            drag = .trimmingTail(clip: id, origin: origin, edge: clip.end, excluded: model.expandingLinks([id]))
        default:
            drag = .cancelled
            return
        }
        store.cancelActiveGesture = { [weak self] in self?.cancel() }
    }

    private func move(ids: [Int64], origin: CGPoint, location: CGPoint, start: Double, end: Double,
                      excluded: Set<Int64>, originKind: TimelineViewModel.TrackKind, originIndex: Int,
                      model: TimelineViewModel) {
        let snapping = snapModel
        var delta = model.time(forX: location.x) - model.time(forX: origin.x)
        let snapped = snapping.snapMove(start: start, end: end, delta: delta, excluding: excluded)
        delta = snapped.delta
        delta = model.snapToFrame(start + delta) - start
        if start + delta < 0 { delta = -start }
        var trackOffset = 0
        if let row = snapping.layout(atY: location.y), row.track.kind == originKind {
            trackOffset = row.track.index - originIndex
        }
        store.snapIndicator = snapped.snap?.time
        let frames = Int64((delta / max(model.frameSeconds, 1e-9)).rounded())
        let deltaTime = CMTimeMultiply(store.frameDuration, multiplier: Int32(clamping: frames))
        // Only clips of the dragged row's kind change tracks (selected audio stays on its tracks
        // when the drag moves between video rows).
        let kind: VETrackKind = originKind == .video ? .video : .audio
        let result = store.engine.moveClips(ids.map { NSNumber(value: $0) }, by: deltaTime, trackOffset: trackOffset,
                                            of: kind)
        store.statusMessage = result.ok ? nil : result.message
    }

    private func trimTime(edge: Double, origin: CGPoint, location: CGPoint, excluded: Set<Int64>,
                          model: TimelineViewModel) -> Double {
        var time = edge + model.time(forX: location.x) - model.time(forX: origin.x)
        let snap = snapModel.snap(time, excluding: excluded)
        if let snap { time = snap.time }
        store.snapIndicator = snap?.time
        return max(0, time)
    }
}
