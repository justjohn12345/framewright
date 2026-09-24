import AppKit
import CoreMedia
import Foundation
import FramewrightEngine

/// The timeline's pointer gestures as a state machine, separate from SwiftUI so it can be
/// driven and tested with synthetic locations.
///
/// A press selects what it hits; moving past `dragThreshold` turns it into a move (clip body),
/// a trim (within `edgeZone` of a clip edge) or a marquee (empty space). Moves and trims are
/// one coalesced engine edit each (every step inside `VEEngine.performInCoalescingGroup`),
/// committed on release (`ended`), reverted by Escape or Cmd+Z (`cancel`) and by a gesture the
/// system abandons without an end (`abandon`). Snapping uses the timeline as it was when the
/// drag started, so the drag's own previewed edits (clips the moved clip overwrote, edges it
/// split) never become snap targets.
///
/// Spans on the lanes under each track: a click selects one (exclusive with the clip selection;
/// the inspector shows it, a Motion span opens the Ken Burns editor); dragging its bar moves it
/// within its clip, dragging an edge trims it, both snapping to the playhead, the cut points and
/// the other spans' edges (`TimelineViewModel.snap(excludingSpans:)`), one undo step each, the
/// status line showing the range (or, refused, the engine's reason and the nearest free range).
/// A transition on lane 0: its edges move independently (the share of each side of the cut; the
/// linked transition follows per the preference), dragging its bar slides the split, dragging a
/// dissolve's end back onto its clip's end makes it a fade out (the status line says so); a fade
/// in keeps its start on its clip's start. A range drag on an empty effect lane over a clip creates
/// a span there (`creation` is drawn meanwhile; nothing under two frames): a Motion span on a video
/// lane (Option: an Opacity span, a fade), a Gain span on an audio lane. Option on a lane means an
/// Opacity span, not the playhead.
///
/// The playhead can be dragged in the track area too, not only in the ruler: press on empty
/// space within `playheadGrabZone` points of the playhead line, or press anywhere but a lane with
/// Option held; the drag then scrubs like the ruler (clip edges and bodies keep their own gestures
/// without Option). Every press also takes keyboard focus back from a text field.
@MainActor
final class TimelineGestureController: ObservableObject {
    enum DragState: Equatable {
        case idle
        /// Pressed, not moved far enough yet.
        case pending(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, wasSelected: Bool, option: Bool)
        case moving(ids: [Int64], origin: CGPoint, start: Double, end: Double, excluded: Set<Int64>,
                    originKind: TimelineViewModel.TrackKind, originIndex: Int)
        case trimmingHead(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case trimmingTail(clip: Int64, origin: CGPoint, edge: Double, excluded: Set<Int64>)
        case marquee(origin: CGPoint, base: Set<Int64>)
        /// Moving an effect span within its clip ([lower, upper]).
        case movingSpan(id: Int64, origin: CGPoint, start: Double, end: Double, lower: Double, upper: Double)
        /// Trimming an effect span's start (`head`) or end, within its clip.
        case trimmingSpan(id: Int64, head: Bool, origin: CGPoint, start: Double, end: Double, lower: Double,
                          upper: Double)
        /// Moving a transition's edge (`head`: its start) or, with `head` nil, the whole transition
        /// (sliding its split). `cut` is its cut, `clipStart` its clip's start.
        case transitionRange(id: Int64, head: Bool?, origin: CGPoint, start: Double, end: Double, cut: Double,
                             clipStart: Double, fadeIn: Bool)
        /// A range drag on an empty effect lane (`creation` has the range).
        case creatingSpan(anchor: Double)
        /// Dragging an audio clip's gain line (`gain`: the value so far; Option drags finely).
        case gain(clip: Int64, lastY: CGFloat, gain: Double)
        /// Dragging the playhead (see the type's comment).
        case scrubbing
        /// Escape pressed: the rest of the gesture is ignored.
        case cancelled
    }

    /// Distance the pointer must travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 3
    /// A press on empty space this close to the playhead line (points) grabs the playhead.
    static let playheadGrabZone: CGFloat = 4
    /// Coalescing group keys of the drags.
    static let moveGroup = "timeline.move"
    static let trimGroup = "timeline.trim"
    static let spanMoveGroup = "timeline.span.move"
    static let spanTrimGroup = "timeline.span.trim"
    static let transitionGroup = "timeline.transition"
    static let gainGroup = "timeline.gain"

    @Published private(set) var drag: DragState = .idle
    @Published private(set) var marquee: CGRect?
    /// The value shown next to the pointer while the gain line is dragged or hovered.
    @Published private(set) var gainTooltip: GainTooltip?
    /// What a transition dragged from the Effects tab would land on.
    @Published private(set) var transitionDrop: TransitionDropTarget?
    /// What an effect (Fade, Gain) dragged from the Effects tab would land on.
    @Published private(set) var effectDrop: EffectDropTarget?
    /// The span a range drag on an empty lane is creating.
    @Published private(set) var creation: SpanCreation?
    /// What the pointer hovers (cursor and gain tooltip).
    @Published private(set) var hover: TimelineViewModel.Hit?

    struct GainTooltip: Equatable {
        let text: String
        let point: CGPoint
    }

    /// Where a transition dragged from the Effects tab goes: across a cut (a cross dissolve or
    /// crossfade), or at a clip's end or start where nothing touches it (a fade out or in).
    enum TransitionPlacement: Equatable {
        case cut(from: Int64, to: Int64)
        case fadeOut(clip: Int64)
        case fadeIn(clip: Int64)
    }

    /// A cut or clip edge a dragged transition would be added to (on lane 0).
    struct TransitionDropTarget: Equatable {
        let kind: TransitionKind
        let trackID: Int64
        let placement: TransitionPlacement
        /// Seconds: the cut, or the clip's edge.
        let cut: Double
        /// The duration it would get (the default, shortened to what fits).
        let frames: Int64
        /// Seconds of the span it would cover (a dissolve centred on the cut).
        let start: Double
        let end: Double
        let allowed: Bool
        /// Why the drop is refused, or what shortens it ("" when neither).
        let message: String

        /// The outgoing clip of a cut, or the clip that fades.
        var fromClipID: Int64 {
            switch placement {
            case let .cut(from, _): return from
            case let .fadeOut(clip): return clip
            case .fadeIn: return 0
            }
        }

        /// The incoming clip of a cut, or the clip that fades in.
        var toClipID: Int64 {
            switch placement {
            case let .cut(_, to): return to
            case .fadeOut: return 0
            case let .fadeIn(clip): return clip
            }
        }

        /// What the drop adds ("Cross Dissolve", "Fade Out", ...).
        var title: String {
            switch placement {
            case .cut: return kind.title
            case .fadeOut: return "Fade Out"
            case .fadeIn: return "Fade In"
            }
        }
    }

    /// Where an effect dragged from the Effects tab would go: a range of a clip on an effect lane.
    struct EffectDropTarget: Equatable {
        let kind: EffectKind
        let trackID: Int64
        let clipID: Int64
        let lane: Int
        /// Seconds.
        let start: Double
        let end: Double
        let allowed: Bool
        /// Why it cannot go there ("" when it can).
        let message: String
    }

    /// The span a range drag on an empty lane creates.
    struct SpanCreation: Equatable {
        let trackID: Int64
        let lane: Int
        let clipID: Int64
        let kind: TimelineViewModel.SpanKind
        /// Seconds, on the frame grid.
        let start: Double
        let end: Double
        /// Why it cannot be created as it is (nil when it can).
        let problem: String?
    }

    /// The pointer shapes the track area uses.
    enum PointerCursor: Equatable {
        case arrow
        case resizeLeftRight
        case resizeUpDown

        var nsCursor: NSCursor {
            switch self {
            case .arrow: return .arrow
            case .resizeLeftRight: return .resizeLeftRight
            case .resizeUpDown: return .resizeUpDown
            }
        }
    }

    /// The cursor hover last set (nil: none since the pointer entered, or since the last drag).
    private(set) var cursor: PointerCursor?
    /// Number of cursor changes hover made (diagnostics and tests).
    private(set) var cursorChanges = 0
    /// Sets the cursor (tests may observe it instead).
    var applyCursor: (PointerCursor) -> Void = { $0.nsCursor.set() }

    unowned let store: ProjectStore
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

    /// The pointer moved (or was pressed: the first event of a gesture). `clickCount` is the
    /// press's click count (2 for a double-click).
    func changed(location: CGPoint, startLocation: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) {
        let model = store.timelineModel
        switch drag {
        case .idle:
            begin(at: startLocation, extend: modifiers.contains(.shift), option: modifiers.contains(.option),
                  clickCount: clickCount, model: model)
            if drag != .idle {
                changed(location: location, startLocation: startLocation, modifiers: modifiers)
            }
        case let .pending(hit, origin, extend, _, option):
            guard hypot(location.x - origin.x, location.y - origin.y) >= Self.dragThreshold else { return }
            startDrag(hit: hit, origin: origin, extend: extend, option: option, model: model)
            if drag != .cancelled {
                changed(location: location, startLocation: startLocation, modifiers: modifiers)
            }
        case let .moving(ids, origin, start, end, excluded, originKind, originIndex):
            move(ids: ids, origin: origin, location: location, start: start, end: end, excluded: excluded,
                 originKind: originKind, originIndex: originIndex, model: model)
        case let .trimmingHead(clip, origin, edge, excluded):
            let time = store.frameTime(trimTime(edge: edge, origin: origin, location: location, excluded: excluded,
                                                model: model))
            store.report(store.engine.performInCoalescingGroup(Self.trimGroup) {
                store.engine.trimClipHead(clip, to: time, clamp: true)
            })
        case let .trimmingTail(clip, origin, edge, excluded):
            let time = store.frameTime(trimTime(edge: edge, origin: origin, location: location, excluded: excluded,
                                                model: model))
            store.report(store.engine.performInCoalescingGroup(Self.trimGroup) {
                store.engine.trimClipTail(clip, to: time, clamp: true)
            })
        case .scrubbing:
            scrub(to: location, model: model)
        case let .movingSpan(id, origin, start, end, lower, upper):
            moveSpan(id, origin: origin, location: location, start: start, end: end, lower: lower, upper: upper,
                     model: model)
        case let .trimmingSpan(id, head, origin, start, end, lower, upper):
            trimSpan(id, head: head, origin: origin, location: location, start: start, end: end, lower: lower,
                     upper: upper, model: model)
        case let .transitionRange(id, head, origin, start, end, cut, clipStart, fadeIn):
            dragTransition(id, head: head, origin: origin, location: location, start: start, end: end, cut: cut,
                           clipStart: clipStart, fadeIn: fadeIn, model: model)
        case let .creatingSpan(anchor):
            extendCreation(anchor: anchor, location: location, model: model)
        case let .gain(clip, lastY, gain):
            dragGain(clip, lastY: lastY, gain: gain, location: location, fine: modifiers.contains(.option), model: model)
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
        case let .pending(hit, _, extend, wasSelected, _):
            switch hit {
            case let .clipBody(id) where !extend && wasSelected:
                // A plain click on a clip that was part of a multi-selection selects just that clip.
                store.select(clip: id, extend: false)
            case .lane:
                // A click on an empty lane deselects everything.
                store.selection = []
                store.selectedSpanID = nil
            default:
                break
            }
        case .moving, .trimmingHead, .trimmingTail, .movingSpan, .trimmingSpan, .transitionRange, .gain:
            endGroup()
        case .creatingSpan:
            commitCreation()
        case .scrubbing:
            store.endScrub()
        default:
            break
        }
        reset()
    }

    /// Ends the drag's coalescing group if it is still open (another edit may have ended it).
    private func endGroup() {
        if let key = store.engine.coalescingKey, Self.dragGroups.contains(key) {
            store.engine.endCoalescing()
        }
    }

    private static let dragGroups: Set<String> = [moveGroup, trimGroup, spanMoveGroup, spanTrimGroup, transitionGroup,
                                                  gainGroup]

    /// Escape / Cmd+Z: reverts the drag's edits; the rest of the gesture is ignored.
    func cancel() {
        switch drag {
        case .moving, .trimmingHead, .trimmingTail, .movingSpan, .trimmingSpan, .transitionRange, .gain:
            if let key = store.engine.coalescingKey, Self.dragGroups.contains(key) {
                store.engine.cancelCoalescing()
            }
            drag = .cancelled
        case .pending, .marquee, .creatingSpan:
            drag = .cancelled
        case .scrubbing:
            store.endScrub()
            drag = .cancelled
        case .idle, .cancelled:
            break
        }
        store.snapIndicator = nil
        store.cancelActiveGesture = nil
        marquee = nil
        creation = nil
        gainTooltip = nil
        snapshot = nil
    }

    /// The system ended the gesture without a release (the view went away, another gesture won):
    /// an unfinished edit is reverted, like Escape, and the state is reset.
    func abandon() {
        guard drag != .idle else { return }
        cancel()
        reset()
    }

    /// Where media dropped at `location` goes: the row under it and the time (snapped like a
    /// clip), overwriting unless `insert`. Nil when the drop is not on a track row.
    func placement(at location: CGPoint, insert: Bool) -> IncomingMedia.Placement? {
        let model = store.timelineModel
        guard let row = model.layout(atY: location.y), location.x >= 0 else { return nil }
        var seconds = model.time(forX: location.x)
        if let snap = model.snap(seconds) { seconds = snap.time }
        return IncomingMedia.Placement(trackID: row.track.id, seconds: max(0, seconds), insert: insert,
                                       changeCount: store.engine.changeCount)
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
        creation = nil
        gainTooltip = nil
        snapshot = nil
        drag = .idle
        cursor = nil // a drag may have changed the cursor: the next hover sets it again
    }

    /// Press: select according to what was hit, or grab the playhead. Option grabs the playhead
    /// anywhere except on a gain line (a fine gain drag) and on a lane (an Opacity span).
    private func begin(at point: CGPoint, extend: Bool, option: Bool, clickCount: Int, model: TimelineViewModel) {
        let hit = model.hitTest(point)
        store.focusArea = .timeline
        store.reclaimKeyboardFocus()
        store.statusMessage = nil
        let onEmptySpace: Bool
        var grabPlayhead = option
        switch hit {
        case .track, .none: onEmptySpace = true
        case .gainLine, .lane:
            onEmptySpace = false
            grabPlayhead = false
        default: onEmptySpace = false
        }
        if grabPlayhead || (onEmptySpace && abs(point.x - model.x(forTime: model.playhead)) <= Self.playheadGrabZone) {
            drag = .scrubbing
            store.cancelActiveGesture = { [weak self] in self?.cancel() }
            scrub(to: point, model: model)
            return
        }
        switch hit {
        case let .clipBody(id), let .clipHead(id), let .clipTail(id), let .gainLine(id):
            let wasSelected = store.selection.contains(id)
            if extend || !wasSelected {
                store.select(clip: id, extend: extend)
            }
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: wasSelected, option: option)
        case let .span(id), let .spanHead(id), let .spanTail(id):
            store.select(span: id)
            if clickCount >= 2, model.span(id: id)?.kind == .transition {
                // Double-click on a transition: edit its duration in the inspector.
                store.requestInspectorFocus(.transitionDuration)
            }
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: true, option: option)
        case .lane:
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: false, option: option)
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
        store.selectedSpanID = nil
        drag = .marquee(origin: point, base: store.selection)
        store.cancelActiveGesture = { [weak self] in self?.cancel() }
    }

    /// The pointer moved past the threshold: start moving or trimming.
    private func startDrag(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, option: Bool,
                           model: TimelineViewModel) {
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
            store.engine.beginCoalescing(withKey: Self.moveGroup)
            drag = .moving(ids: ids, origin: origin, start: start, end: end,
                           excluded: model.expandingLinks(Set(ids)), originKind: row.track.kind,
                           originIndex: row.track.index)
        case let .clipHead(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.trimGroup)
            drag = .trimmingHead(clip: id, origin: origin, edge: clip.start, excluded: model.expandingLinks([id]))
        case let .clipTail(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.trimGroup)
            drag = .trimmingTail(clip: id, origin: origin, edge: clip.end, excluded: model.expandingLinks([id]))
        case let .gainLine(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.gainGroup)
            drag = .gain(clip: id, lastY: origin.y, gain: clip.gainDb)
        case let .span(id), let .spanHead(id), let .spanTail(id):
            guard startSpanDrag(id, hit: hit, origin: origin, model: model) else {
                drag = .cancelled
                store.cancelActiveGesture = nil
                return
            }
        case let .lane(track, lane):
            guard startCreation(track: track, lane: lane, origin: origin, option: option, model: model) else {
                drag = .cancelled
                store.cancelActiveGesture = nil
                return
            }
        default:
            drag = .cancelled
            return
        }
        store.cancelActiveGesture = { [weak self] in self?.cancel() }
    }

    /// Starts dragging a span's bar or edge; false (with the reason in the status line) when it
    /// cannot move that way.
    private func startSpanDrag(_ id: Int64, hit: TimelineViewModel.Hit, origin: CGPoint,
                               model: TimelineViewModel) -> Bool {
        guard let span = model.span(id: id), let clip = model.clip(id: span.clipID) else { return false }
        if let track = model.layout(forTrack: span.trackID)?.track, track.locked {
            store.statusMessage = "Track \(track.name) is locked."
            return false
        }
        var head: Bool?
        switch hit {
        case .spanHead: head = true
        case .spanTail: head = false
        default: head = nil
        }
        snapshot = model
        if span.kind == .transition {
            let fadeIn = span.style == .fadeIn
            if fadeIn, head != false {
                store.statusMessage = "A fade in starts on its clip's start: drag its right edge to change its length."
                return false
            }
            store.engine.beginCoalescing(withKey: Self.transitionGroup)
            drag = .transitionRange(id: id, head: head, origin: origin, start: span.start, end: span.end, cut: span.cut,
                                    clipStart: clip.start, fadeIn: fadeIn)
            return true
        }
        if let head {
            store.engine.beginCoalescing(withKey: Self.spanTrimGroup)
            drag = .trimmingSpan(id: id, head: head, origin: origin, start: span.start, end: span.end, lower: clip.start,
                                 upper: clip.end)
        } else {
            store.engine.beginCoalescing(withKey: Self.spanMoveGroup)
            drag = .movingSpan(id: id, origin: origin, start: span.start, end: span.end, lower: clip.start,
                               upper: clip.end)
        }
        return true
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
        let result = store.engine.performInCoalescingGroup(Self.moveGroup) {
            store.engine.moveClips(ids.map { NSNumber(value: $0) }, by: deltaTime, trackOffset: trackOffset, of: kind)
        }
        store.statusMessage = result.ok ? nil : result.message
    }

    /// Moves the playhead to the pointer (snapping to clip edges, never to itself).
    private func scrub(to location: CGPoint, model: TimelineViewModel) {
        var seconds = model.time(forX: location.x)
        if let snap = model.snap(seconds, excluding: [], includePlayhead: false) {
            seconds = snap.time
        }
        store.scrub(toSeconds: max(0, seconds))
    }

    // MARK: Span drags

    /// A step of a span's body drag: the whole span moves by the pointer's movement (snapped by its
    /// nearer edge, on the frame grid) within its clip.
    private func moveSpan(_ id: Int64, origin: CGPoint, location: CGPoint, start: Double, end: Double, lower: Double,
                          upper: Double, model: TimelineViewModel) {
        var delta = model.time(forX: location.x) - model.time(forX: origin.x)
        let snapped = snapModel.snapMove(start: start, end: end, delta: delta, excluding: [], excludingSpans: [id])
        delta = model.snapToFrame(start + snapped.delta) - start
        delta = min(max(delta, lower - start), upper - end)
        store.snapIndicator = snapped.snap?.time
        applySpanRange(id, start: start + delta, end: end + delta, group: Self.spanMoveGroup)
    }

    /// A step of a span's edge drag: that edge follows the pointer (snapped, on the frame grid)
    /// within its clip, the span at least a frame long.
    private func trimSpan(_ id: Int64, head: Bool, origin: CGPoint, location: CGPoint, start: Double, end: Double,
                          lower: Double, upper: Double, model: TimelineViewModel) {
        let frame = max(model.frameSeconds, 1e-9)
        var time = (head ? start : end) + model.time(forX: location.x) - model.time(forX: origin.x)
        let snap = snapModel.snap(time, excludingSpans: [id])
        if let snap { time = snap.time }
        store.snapIndicator = snap?.time
        time = model.snapToFrame(time)
        if head {
            time = min(max(time, lower), end - frame)
            applySpanRange(id, start: time, end: end, group: Self.spanTrimGroup)
        } else {
            time = max(min(time, upper), start + frame)
            applySpanRange(id, start: start, end: time, group: Self.spanTrimGroup)
        }
    }

    /// Sets a span's range as a step of `group`: the status line shows the range, or the refusal with
    /// the nearest free range of its lane.
    private func applySpanRange(_ id: Int64, start: Double, end: Double, group: String) {
        let range = CMTimeRange(start: store.frameTime(start), end: store.frameTime(end))
        let result = store.engine.performInCoalescingGroup(group) { store.engine.setSpanRange(id, range: range) }
        guard handleStep(result) else {
            if result.errorCode != .busy { store.statusMessage = store.spanRefusalText(result) }
            return
        }
        let title = result.span.map { ProjectStore.title(of: $0, isAudio: false) } ?? "Span"
        store.statusMessage = "\(title): " + store.rangeString(start: range.start, end: CMTimeRangeGetEnd(range))
    }

    /// A step of a transition drag: an edge follows the pointer (a tail transition's start stays at
    /// or before its cut and its end at or after it; a fade in's start stays on its clip's start), or
    /// the whole range slides with it, keeping the cut inside. The engine fits each side to the
    /// clips and says what it changed; the status line shows the shares or the fade.
    private func dragTransition(_ id: Int64, head: Bool?, origin: CGPoint, location: CGPoint, start: Double,
                                end: Double, cut: Double, clipStart: Double, fadeIn: Bool, model: TimelineViewModel) {
        let frame = max(model.frameSeconds, 1e-9)
        let dx = model.time(forX: location.x) - model.time(forX: origin.x)
        var newStart = start
        var newEnd = end
        switch head {
        case true?:
            var time = start + dx
            let snap = snapModel.snap(time, excludingSpans: [id])
            if let snap { time = snap.time }
            store.snapIndicator = snap?.time
            newStart = min(max(model.snapToFrame(time), clipStart), min(cut, end - frame))
        case false?:
            var time = end + dx
            let snap = snapModel.snap(time, excludingSpans: [id])
            if let snap { time = snap.time }
            store.snapIndicator = snap?.time
            let lower = fadeIn ? start + frame : max(cut, start + frame)
            newEnd = max(model.snapToFrame(time), lower)
        case nil:
            let snapped = snapModel.snapMove(start: start, end: end, delta: dx, excluding: [], excludingSpans: [id])
            var delta = model.snapToFrame(start + snapped.delta) - start
            delta = min(max(delta, max(cut - end, clipStart - start)), cut - start)
            store.snapIndicator = snapped.snap?.time
            newStart = start + delta
            newEnd = end + delta
        }
        let result = store.setTransitionRange(id, start: store.frameTime(newStart), end: store.frameTime(newEnd),
                                              group: Self.transitionGroup)
        guard handleStep(result) else { return }
        store.statusMessage = transitionStatus(id, result)
    }

    /// "Cross Dissolve: 21f before / 9f after the cut (70% / 30%)", "Fade Out: 15f", with the
    /// engine's note (a shortening, the change to a fade out).
    private func transitionStatus(_ id: Int64, _ result: VEEditResult) -> String {
        var text: String
        if let span = result.span ?? store.engine.spanInfo(id) {
            let audio = store.clips[span.clipID]?.trackKind == .audio
            let title = ProjectStore.title(of: span, isAudio: audio)
            if span.transitionStyle == .crossDissolve {
                let before = store.frames(span.shareBeforeCut)
                let after = store.frames(span.shareAfterCut)
                let total = max(1, before + after)
                let percent = Int((Double(before) * 100 / Double(total)).rounded())
                text = "\(title): \(store.shortDurationString(frames: before)) before / "
                    + "\(store.shortDurationString(frames: after)) after the cut (\(percent)% / \(100 - percent)%)"
            } else {
                text = "\(title): \(store.durationString(frames: store.frames(span.duration)))"
            }
        } else {
            text = "Transition"
        }
        if !result.note.isEmpty { text += ". " + result.note }
        return text
    }

    // MARK: Creating spans

    /// Starts a range drag on an empty lane: over a clip of the track, on an effect lane (1-3).
    private func startCreation(track: Int64, lane: Int, origin: CGPoint, option: Bool, model: TimelineViewModel) -> Bool {
        guard lane >= 1 else {
            store.statusMessage = "Lane 0 holds transitions: drag one from the Effects tab onto a cut or a clip's end."
            return false
        }
        guard let layout = model.layout(forTrack: track) else { return false }
        if layout.track.locked {
            store.statusMessage = "Track \(layout.track.name) is locked."
            return false
        }
        let pressed = model.time(forX: origin.x)
        guard let clip = model.clip(onTrack: track, at: pressed) else {
            store.statusMessage = "Drag over a clip to create a span on its lane."
            return false
        }
        let kind: TimelineViewModel.SpanKind = layout.track.kind == .audio ? .gain : (option ? .opacity : .motion)
        var anchor = pressed
        if let snap = model.snap(anchor, excludingSpans: []) { anchor = snap.time }
        anchor = min(max(model.snapToFrame(anchor), clip.start), clip.end)
        snapshot = model
        creation = SpanCreation(trackID: track, lane: lane, clipID: clip.id, kind: kind, start: anchor, end: anchor,
                                problem: nil)
        drag = .creatingSpan(anchor: anchor)
        return true
    }

    /// A step of a range drag: the range from the press to the pointer (snapped, on the frame grid)
    /// within the clip, checked against the other spans of the lane.
    private func extendCreation(anchor: Double, location: CGPoint, model: TimelineViewModel) {
        guard let current = creation, let clip = snapModel.clip(id: current.clipID) else { return }
        var time = model.time(forX: location.x)
        let snap = snapModel.snap(time, excludingSpans: [])
        if let snap { time = snap.time }
        store.snapIndicator = snap?.time
        time = min(max(model.snapToFrame(time), clip.start), clip.end)
        let start = min(anchor, time)
        let end = max(anchor, time)
        let frames = Int64(((end - start) / max(model.frameSeconds, 1e-9)).rounded())
        var problem: String?
        if frames < 2 {
            problem = "A span is at least two frames long."
        } else if let other = snapModel.spans(ofClip: clip.id, lane: current.lane)
            .first(where: { $0.start < end - 1e-9 && $0.end > start + 1e-9 }) {
            problem = "Lane \(current.lane) already has a \(other.title) span there."
        }
        creation = SpanCreation(trackID: current.trackID, lane: current.lane, clipID: current.clipID, kind: current.kind,
                                start: start, end: end, problem: problem)
        let name = current.kind == .opacity ? "Fade" : current.kind == .gain ? "Gain" : "Motion"
        store.statusMessage = problem ?? "\(name): " + store.rangeString(start: store.frameTime(start),
                                                                          end: store.frameTime(end))
    }

    /// Release of a range drag: adds the span (its default values, one undo step) and selects it; a
    /// range under two frames creates nothing.
    private func commitCreation() {
        guard let creation else { return }
        let frames = Int64(((creation.end - creation.start) / max(store.frameDuration.secondsOrZero, 1e-9)).rounded())
        guard frames >= 2 else {
            store.statusMessage = "Drag over at least two frames to create a span."
            return
        }
        let kind: VESpanKind
        switch creation.kind {
        case .opacity: kind = .opacity
        case .gain: kind = .gain
        default: kind = .motion
        }
        let range = CMTimeRange(start: store.frameTime(creation.start), end: store.frameTime(creation.end))
        store.cancelActiveGesture = nil // the gesture is over: the add is not refused as "during a drag"
        store.addSpan(kind: kind, lane: creation.lane, clip: creation.clipID, range: range)
    }

    // MARK: Gain

    /// A step of a gain line drag: up raises the gain; Option drags ten times finer.
    private func dragGain(_ id: Int64, lastY: CGFloat, gain: Double, location: CGPoint, fine: Bool,
                          model: TimelineViewModel) {
        guard let clip = snapModel.clip(id: id), let info = store.clips[id] else { return }
        let raw = gain - Double(location.y - lastY) * model.decibelsPerPoint(forClip: clip, fine: fine)
        let clamped = min(TimelineViewModel.gainMaxDb, max(TimelineViewModel.gainMinDb, raw))
        let rounded = (clamped * 10).rounded() / 10
        drag = .gain(clip: id, lastY: location.y, gain: clamped)
        var params = info.audioParams
        guard abs(params.gainDb - rounded) > 1e-9 else {
            gainTooltip = GainTooltip(text: Self.gainText(rounded), point: location)
            return
        }
        params.gainDb = rounded
        let result = store.engine.performInCoalescingGroup(Self.gainGroup) {
            store.engine.setAudioParams(params, forClip: id)
        }
        guard handleStep(result) else { return }
        gainTooltip = GainTooltip(text: Self.gainText(rounded), point: location)
    }

    /// "+3.0 dB", "0.0 dB", "−6.5 dB".
    static func gainText(_ gainDb: Double) -> String {
        let value = (gainDb * 10).rounded() / 10
        if value > 0 { return String(format: "+%.1f dB", value) }
        if value < 0 { return String(format: "−%.1f dB", -value) }
        return "0.0 dB"
    }

    /// Reports a drag step's result; a refusal because another edit ended the drag's group
    /// (VEEditErrorBusy) stops the drag, keeping what it did. Returns whether the step applied.
    private func handleStep(_ result: VEEditResult) -> Bool {
        if result.ok { return true }
        store.statusMessage = result.message
        if result.errorCode == .busy {
            store.statusMessage = "Another edit interrupted the drag; what it did so far is kept."
            drag = .cancelled
            store.cancelActiveGesture = nil
            gainTooltip = nil
            store.snapIndicator = nil
        }
        return false
    }

    // MARK: Hover

    /// The pointer moved over the track area (`nil`: it left). The cursor is set only when the
    /// shape it needs changes (hover fires on every pointer event); leaving the area restores
    /// the arrow if hover had changed it, and otherwise leaves the cursor to whatever the pointer
    /// is over now (a split-view divider sets its own). The gain tooltip follows the gain line.
    func hover(at point: CGPoint?) {
        guard drag == .idle else { return }
        guard let point else {
            if hover != nil { hover = nil }
            if gainTooltip != nil { gainTooltip = nil }
            if let cursor, cursor != .arrow {
                setCursor(.arrow)
            }
            cursor = nil
            return
        }
        let model = store.timelineModel
        let hit = model.hitTest(point)
        if hit != hover { hover = hit }
        var tooltip: GainTooltip?
        let wanted: PointerCursor
        switch hit {
        case .clipHead, .clipTail, .spanTail:
            wanted = .resizeLeftRight
        case let .spanHead(id):
            // A fade in's start stays on its clip's start.
            wanted = model.span(id: id)?.style == .fadeIn && model.span(id: id)?.kind == .transition ? .arrow
                : .resizeLeftRight
        case let .gainLine(id):
            wanted = .resizeUpDown
            if let clip = model.clip(id: id) {
                tooltip = GainTooltip(text: Self.gainText(clip.gainDb), point: point)
            }
        default:
            wanted = .arrow
        }
        if wanted != cursor {
            setCursor(wanted)
        }
        // Republish only when the text changes (not on every pointer move along the line).
        if tooltip?.text != gainTooltip?.text { gainTooltip = tooltip }
    }

    private func setCursor(_ wanted: PointerCursor) {
        cursor = wanted
        cursorChanges += 1
        applyCursor(wanted)
    }

    // MARK: Context menu

    /// The right-click menu at `location` in the track area. What is under the pointer is
    /// selected first (as in Premiere): a transition offers Delete (with its linked transition),
    /// Delete This Transition Only and Transition Duration…; an effect span Set Interpolation, Move
    /// to Lane and Remove; a clip Delete, Ripple Delete, Link/Unlink, Speed/Duration… and, for a
    /// video clip, Add Motion Span at Playhead. Nothing during a drag or over empty space.
    func contextMenuItems(at location: CGPoint) -> [ContextMenuItem] {
        guard drag == .idle, !store.isGestureActive else { return [] }
        let store = self.store
        store.focusArea = .timeline
        store.reclaimKeyboardFocus()
        let model = store.timelineModel
        switch model.hitTest(location) {
        case let .span(id), let .spanHead(id), let .spanTail(id):
            store.select(span: id)
            if model.span(id: id)?.kind == .transition {
                return transitionMenu(id)
            }
            return spanMenu(id)
        case let .clipBody(id), let .clipHead(id), let .clipTail(id), let .gainLine(id):
            if !store.selection.contains(id) {
                store.select(clip: id, extend: false)
            }
            let selected = store.selectedClips
            let canUnlink = !selected.isEmpty && selected.allSatisfy { $0.linkedClipID != 0 }
            var items = [
                ContextMenuItem(title: "Delete") { store.deleteSelection(ripple: false) },
                ContextMenuItem(title: "Ripple Delete") { store.deleteSelection(ripple: true) },
                .separator,
                ContextMenuItem(title: canUnlink ? "Unlink" : "Link", isEnabled: canUnlink || selected.count == 2) {
                    store.linkOrUnlinkSelection()
                },
                ContextMenuItem(title: "Speed/Duration…", isEnabled: selected.contains { !$0.isStill }) {
                    store.showSpeedSheet()
                },
            ]
            if let clip = store.clips[id], clip.trackKind == .video {
                let t = store.playheadTime
                items.append(.separator)
                items.append(ContextMenuItem(title: "Add Motion Span at Playhead",
                                             isEnabled: clip.timelineStart <= t && t < clip.timelineEnd) {
                    store.addMotionSpanAtPlayhead(clip: id)
                })
            }
            return items
        case .lane, .track, .none:
            return []
        }
    }

    private func transitionMenu(_ id: Int64) -> [ContextMenuItem] {
        let store = self.store
        let linked = store.linkedTransition(of: id) != nil
        var items = [ContextMenuItem(title: linked ? "Delete Transitions" : "Delete Transition") {
            store.removeTransition(id, includingLinked: true)
        }]
        if linked {
            items.append(ContextMenuItem(title: "Delete This Transition Only") {
                store.removeTransition(id, includingLinked: false)
            })
        }
        items.append(.separator)
        items.append(ContextMenuItem(title: "Transition Duration…") { store.editTransitionDuration() })
        return items
    }

    private func spanMenu(_ id: Int64) -> [ContextMenuItem] {
        let store = self.store
        guard let span = store.engine.spanInfo(id) else { return [] }
        let interpolations = VEKeyframeInterpolation.choices.map { choice in
            ContextMenuItem(title: choice.title, isChecked: span.interpolation == choice) {
                store.setSpanInterpolation(id, choice)
            }
        }
        let lanes = (1 ... TimelineViewModel.maxEffectLanes).map { lane in
            ContextMenuItem(title: "Lane \(lane)", isEnabled: lane != span.lane, isChecked: lane == span.lane) {
                store.moveSpan(id, toLane: lane)
            }
        }
        return [
            .submenu("Set Interpolation", interpolations),
            .submenu("Move to Lane", lanes),
            .separator,
            ContextMenuItem(title: "Remove") { store.removeSpan(id) },
        ]
    }

    // MARK: Transition drops

    /// A transition from the Effects tab is dragged over `location`: shows lane 0 on the tracks of
    /// its kind, finds where it would land (the nearest cut, or free clip end or start, on that row
    /// within `dropCutDistance` points) and whether it fits.
    @discardableResult
    func transitionDragUpdated(kind: TransitionKind, at location: CGPoint) -> TransitionDropTarget? {
        store.revealTransitionLane(kind.trackKind == .video ? .video : .audio)
        let target = dropTarget(kind: kind, at: location)
        if target != transitionDrop { transitionDrop = target }
        return target
    }

    func transitionDragExited() {
        if transitionDrop != nil { transitionDrop = nil }
        store.revealTransitionLane(nil)
    }

    /// Drops a transition: a cross dissolve / crossfade on the target cut (see
    /// `ProjectStore.addTransition`), a fade on a free clip end or start (`ProjectStore.addFade`); a
    /// refused drop says why in the status line. Returns whether a transition was added (or is
    /// waiting for the linked-crossfade question).
    @discardableResult
    func dropTransition(kind: TransitionKind, at location: CGPoint) -> Bool {
        let target = dropTarget(kind: kind, at: location)
        transitionDrop = nil
        store.revealTransitionLane(nil)
        store.focusArea = .timeline
        guard let target else {
            store.statusMessage = dropMissMessage(kind: kind, at: location)
            return false
        }
        guard target.allowed else {
            store.statusMessage = target.message
            return false
        }
        switch target.placement {
        case let .cut(from, to):
            if store.addTransition(kind, from: from, to: to) {
                return true
            }
            return store.pendingLinkedTransition != nil
        case let .fadeOut(clip):
            return store.addFade(at: .end, of: clip)
        case let .fadeIn(clip):
            return store.addFade(at: .start, of: clip)
        }
    }

    /// Distance (points) from the pointer within which a cut or clip edge takes a dropped transition.
    static let dropCutDistance: CGFloat = 40

    private func dropTarget(kind: TransitionKind, at location: CGPoint) -> TransitionDropTarget? {
        let model = store.timelineModel
        guard let row = model.layout(atY: location.y),
              (row.track.kind == .video) == (kind.trackKind == .video) else { return nil }
        let onTrack = model.clips.filter { $0.trackID == row.track.id }
        var best: (placement: TransitionPlacement, x: Double, distance: CGFloat)?
        func consider(_ placement: TransitionPlacement, at seconds: Double) {
            let distance = abs(model.x(forTime: seconds) - location.x)
            guard distance <= Self.dropCutDistance else { return }
            // A cut wins a tie with a fade (the cut is what a transition usually goes on).
            if let current = best {
                if distance > current.distance { return }
                if distance == current.distance, case .cut = current.placement { return }
            }
            best = (placement, seconds, distance)
        }
        for clip in onTrack {
            let next = onTrack.first { abs($0.start - clip.end) < 1e-9 && $0.id != clip.id }
            let previous = onTrack.first { abs($0.end - clip.start) < 1e-9 && $0.id != clip.id }
            if let next {
                consider(.cut(from: clip.id, to: next.id), at: clip.end)
            } else {
                consider(.fadeOut(clip: clip.id), at: clip.end)
            }
            if previous == nil {
                consider(.fadeIn(clip: clip.id), at: clip.start)
            }
        }
        guard let (placement, cut, _) = best else { return nil }
        let wanted = store.editingPreferences.transitionFrames(frameDuration: store.frameDuration)
        let frameSeconds = model.frameSeconds
        var frames = wanted
        var allowed = !row.track.locked
        var message = row.track.locked ? "Track \(row.track.name) is locked." : ""
        switch placement {
        case let .cut(from, to):
            let limit = store.engine.transitionLimit(fromClip: from, toClip: to)
            frames = min(wanted, limit.maximumFrames)
            if allowed, limit.maximumFrames <= 0 {
                allowed = false
                message = "No transition fits this cut: \(limit.reason)"
            } else if allowed, frames < wanted {
                message = "Shortened to \(store.durationString(frames: frames)): \(limit.reason)"
            }
            let shown = max(frames, 1)
            return TransitionDropTarget(kind: kind, trackID: row.track.id, placement: placement, cut: cut,
                                        frames: frames, start: cut - Double(shown / 2) * frameSeconds,
                                        end: cut + Double(shown - shown / 2) * frameSeconds, allowed: allowed,
                                        message: message)
        case let .fadeOut(id), let .fadeIn(id):
            guard let clip = model.clip(id: id) else { return nil }
            let fadeIn: Bool
            if case .fadeIn = placement { fadeIn = true } else { fadeIn = false }
            let clipFrames = Int64(((clip.end - clip.start) / max(frameSeconds, 1e-9)).rounded())
            let spans = model.spans(ofClip: id, lane: 0)
            let head = spans.first { $0.style == .fadeIn }
            let tail = spans.first { $0.style != .fadeIn }
            // The other fade takes its share of the clip.
            let other = fadeIn ? tail.map { $0.cut - $0.start } ?? 0 : head.map { $0.end - $0.start } ?? 0
            let room = max(0, clipFrames - Int64((other / max(frameSeconds, 1e-9)).rounded()))
            frames = min(wanted, room)
            if allowed, (fadeIn ? head : tail) != nil {
                allowed = false
                message = "“\(clip.name)” already has a \(fadeIn ? "fade in" : "transition at its end")."
            } else if allowed, frames <= 0 {
                allowed = false
                message = "“\(clip.name)” has no room for a fade."
            } else if allowed, frames < wanted {
                message = "Shortened to \(store.durationString(frames: frames)): what “\(clip.name)” has room for."
            }
            let length = Double(max(frames, 1)) * frameSeconds
            return TransitionDropTarget(kind: kind, trackID: row.track.id, placement: placement, cut: cut,
                                        frames: frames, start: fadeIn ? cut : cut - length,
                                        end: fadeIn ? cut + length : cut, allowed: allowed, message: message)
        }
    }

    private func dropMissMessage(kind: TransitionKind, at location: CGPoint) -> String {
        let model = store.timelineModel
        if let row = model.layout(atY: location.y), (row.track.kind == .video) != (kind.trackKind == .video) {
            return "\(kind.title) goes on \(kind.trackKind == .video ? "a video" : "an audio") track."
        }
        return "Drop \(kind.title) on a cut between two clips, or on a clip's start or end to fade."
    }

    // MARK: Effect drops

    /// An effect from the Effects tab is dragged over `location`: the lane and range it would get.
    @discardableResult
    func effectDragUpdated(kind: EffectKind, at location: CGPoint) -> EffectDropTarget? {
        let target = effectTarget(kind: kind, at: location)
        if target != effectDrop { effectDrop = target }
        return target
    }

    func effectDragExited() {
        if effectDrop != nil { effectDrop = nil }
    }

    /// Drops an effect: adds its span with the default values (`ProjectStore.addSpan`, one undo
    /// step) and selects it; a refused drop says why.
    @discardableResult
    func dropEffect(kind: EffectKind, at location: CGPoint) -> Bool {
        let target = effectTarget(kind: kind, at: location)
        effectDrop = nil
        store.focusArea = .timeline
        guard let target else {
            store.statusMessage = "Drop \(kind.title) on a \(kind.trackKind == .video ? "video" : "audio") clip or "
                + "one of its effect lanes."
            return false
        }
        guard target.allowed else {
            store.statusMessage = target.message
            return false
        }
        let range = CMTimeRange(start: store.frameTime(target.start), end: store.frameTime(target.end))
        return store.addSpan(kind: kind.spanKind, lane: target.lane, clip: target.clipID, range: range).ok
    }

    /// Where an effect dropped at `location` goes: on the clip under the pointer, from the drop
    /// point (snapped) for the default transition duration or to the clip's end (a drop near its end
    /// fades out there), on the effect lane under the pointer, or the first lane with room when it is
    /// dropped on the clip or lane 0.
    private func effectTarget(kind: EffectKind, at location: CGPoint) -> EffectDropTarget? {
        let model = store.timelineModel
        guard let row = model.layout(atY: location.y), (row.track.kind == .video) == (kind.trackKind == .video)
        else { return nil }
        var seconds = model.time(forX: location.x)
        guard let clip = model.clip(onTrack: row.track.id, at: seconds) else { return nil }
        if let snap = model.snap(seconds, excludingSpans: []) { seconds = snap.time }
        let frame = max(model.frameSeconds, 1e-9)
        let length = Double(store.editingPreferences.transitionFrames(frameDuration: store.frameDuration)) * frame
        var start = min(max(model.snapToFrame(seconds), clip.start), clip.end)
        if start + length > clip.end { start = max(clip.start, clip.end - length) }
        let end = min(clip.end, start + length)
        let pointed = row.lane(atContentY: location.y + model.scrollY)
        func free(_ lane: Int) -> Bool {
            !model.spans(ofClip: clip.id, lane: lane).contains { $0.start < end - 1e-9 && $0.end > start + 1e-9 }
        }
        var lane = pointed ?? 0
        var allowed = !row.track.locked
        var message = row.track.locked ? "Track \(row.track.name) is locked." : ""
        if lane == 0 {
            if let first = (1 ... TimelineViewModel.maxEffectLanes).first(where: free) {
                lane = first
            } else {
                lane = 1
                if allowed {
                    allowed = false
                    message = "No effect lane of “\(clip.name)” has room there."
                }
            }
        } else if allowed, !free(lane) {
            allowed = false
            message = "Lane \(lane) of “\(clip.name)” already has a span there."
        }
        if allowed, end - start < frame * 1.5 {
            allowed = false
            message = "“\(clip.name)” has no room for a span there."
        }
        return EffectDropTarget(kind: kind, trackID: row.track.id, clipID: clip.id, lane: lane, start: start, end: end,
                                allowed: allowed, message: message)
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
