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
/// The playhead can be dragged in the track area too, not only in the ruler: press on empty
/// space within `playheadGrabZone` points of the playhead line, or press anywhere with Option
/// held; the drag then scrubs like the ruler (clip edges and bodies keep their own gestures
/// without Option). Every press also takes keyboard focus back from a text field.
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
        /// Dragging an edge of a transition band: the duration changes by twice the edge's
        /// movement (the transition stays centred on its cut), in whole frames within
        /// [1, maxFrames] (`limit` says what stops it at the top).
        case resizingTransition(id: Int64, tail: Bool, origin: CGPoint, frames: Int64, maxFrames: Int64,
                                limit: String)
        /// Dragging an audio clip's fade handle.
        case fading(clip: Int64, fadeIn: Bool)
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
    static let transitionGroup = "timeline.transition"
    static let fadeGroup = "timeline.fade"
    static let gainGroup = "timeline.gain"

    @Published private(set) var drag: DragState = .idle
    @Published private(set) var marquee: CGRect?
    /// The value shown next to the pointer while the gain line is dragged or hovered.
    @Published private(set) var gainTooltip: GainTooltip?
    /// What a transition dragged from the Transitions panel would land on.
    @Published private(set) var transitionDrop: TransitionDropTarget?
    /// What the pointer hovers (cursor and gain tooltip).
    @Published private(set) var hover: TimelineViewModel.Hit?

    struct GainTooltip: Equatable {
        let text: String
        let point: CGPoint
    }

    /// A cut a dragged transition would be added to.
    struct TransitionDropTarget: Equatable {
        let kind: TransitionKind
        let trackID: Int64
        let fromClipID: Int64
        let toClipID: Int64
        /// Seconds.
        let cut: Double
        /// The duration it would get (the default, shortened to what the cut allows).
        let frames: Int64
        /// Seconds of the band it would cover (centred on the cut).
        let start: Double
        let end: Double
        let allowed: Bool
        /// Why the drop is refused, or what shortens it ("" when neither).
        let message: String
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
        case let .resizingTransition(id, tail, origin, frames, maxFrames, limit):
            resizeTransition(id, tail: tail, origin: origin, location: location, frames: frames, maxFrames: maxFrames,
                             limit: limit, model: model)
        case let .fading(clip, fadeIn):
            fade(clip, fadeIn: fadeIn, location: location, model: model)
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
        case let .pending(hit, _, extend, wasSelected):
            // A plain click on a clip that was part of a multi-selection selects just that clip.
            if case let .clipBody(id) = hit, !extend, wasSelected {
                store.select(clip: id, extend: false)
            }
            // A click on a keyframe marker moves the playhead to the frame that shows it.
            if case let .keyframe(id, seconds) = hit {
                if !extend, wasSelected { store.select(clip: id, extend: false) }
                store.setPlayhead(seconds: seconds)
            }
        case .moving, .trimmingHead, .trimmingTail, .resizingTransition, .fading, .gain:
            endGroup()
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

    private static let dragGroups: Set<String> = [moveGroup, trimGroup, transitionGroup, fadeGroup, gainGroup]

    /// Escape / Cmd+Z: reverts the drag's edits; the rest of the gesture is ignored.
    func cancel() {
        switch drag {
        case .moving, .trimmingHead, .trimmingTail, .resizingTransition, .fading, .gain:
            if let key = store.engine.coalescingKey, Self.dragGroups.contains(key) {
                store.engine.cancelCoalescing()
            }
            drag = .cancelled
        case .pending, .marquee:
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
        gainTooltip = nil
        snapshot = nil
        drag = .idle
        cursor = nil // a drag may have changed the cursor: the next hover sets it again
    }

    /// Press: select according to what was hit, or grab the playhead. Option grabs the playhead
    /// anywhere except on a gain line (where it means a fine gain drag).
    private func begin(at point: CGPoint, extend: Bool, option: Bool, clickCount: Int, model: TimelineViewModel) {
        let hit = model.hitTest(point)
        store.focusArea = .timeline
        store.reclaimKeyboardFocus()
        store.statusMessage = nil
        let onEmptySpace: Bool
        var grabPlayhead = option
        switch hit {
        case .track, .none: onEmptySpace = true
        case .gainLine:
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
        case let .clipBody(id), let .clipHead(id), let .clipTail(id), let .fadeIn(id), let .fadeOut(id),
             let .gainLine(id), let .keyframe(id, _):
            let wasSelected = store.selection.contains(id)
            if extend || !wasSelected {
                store.select(clip: id, extend: extend)
            }
            store.selectedTransitionID = nil
            drag = .pending(hit: hit, origin: point, extend: extend, wasSelected: wasSelected)
        case let .transition(id), let .transitionHead(id), let .transitionTail(id):
            store.selection = []
            store.selectedTransitionID = id
            if clickCount >= 2 {
                // Double-click: edit the duration in the inspector.
                store.requestInspectorFocus(.transitionDuration)
            }
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
    private func startDrag(hit: TimelineViewModel.Hit, origin: CGPoint, extend: Bool, model: TimelineViewModel) {
        switch hit {
        case let .keyframe(id, _):
            // Dragging from a keyframe marker moves the clip, like dragging its body.
            startDrag(hit: .clipBody(id), origin: origin, extend: extend, model: model)
            return
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
        case let .transitionHead(id), let .transitionTail(id):
            guard let info = store.engine.transitionInfo(id) else { drag = .cancelled; return }
            let limit = store.engine.transitionLimit(forTransition: id)
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.transitionGroup)
            var tail = false
            if case .transitionTail = hit { tail = true }
            drag = .resizingTransition(id: id, tail: tail, origin: origin, frames: store.frames(info.duration),
                                       maxFrames: max(1, limit.maximumFrames), limit: limit.reason)
        case let .fadeIn(id), let .fadeOut(id):
            guard model.clip(id: id) != nil else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.fadeGroup)
            var fadeIn = false
            if case .fadeIn = hit { fadeIn = true }
            drag = .fading(clip: id, fadeIn: fadeIn)
        case let .gainLine(id):
            guard let clip = model.clip(id: id) else { drag = .cancelled; return }
            snapshot = model
            store.engine.beginCoalescing(withKey: Self.gainGroup)
            drag = .gain(clip: id, lastY: origin.y, gain: clip.gainDb)
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

    /// A step of a transition edge drag.
    private func resizeTransition(_ id: Int64, tail: Bool, origin: CGPoint, location: CGPoint, frames: Int64,
                                  maxFrames: Int64, limit: String, model: TimelineViewModel) {
        let dx = model.time(forX: location.x) - model.time(forX: origin.x)
        let requested = Int64((Double(frames) + (tail ? 2 : -2) * dx / max(model.frameSeconds, 1e-9)).rounded())
        let length = min(maxFrames, max(1, requested))
        let duration = store.time(frames: length)
        // The linked transition follows unless the Transition inspector's "Also change the linked
        // transition" is off.
        let includingLinked = store.resizesLinkedTransitions
        let result = store.engine.performInCoalescingGroup(Self.transitionGroup) {
            store.engine.setDuration(duration, forTransition: id, includingLinked: includingLinked)
        }
        guard handleStep(result) else { return }
        let linkedNote = result.note.isEmpty ? "" : " " + result.note
        if requested > maxFrames {
            store.statusMessage = "Limited to \(store.durationString(frames: maxFrames)): \(limit)" + linkedNote
        } else if requested < 1 {
            store.statusMessage = "A transition is at least one frame long."
        } else {
            store.statusMessage = "Transition: \(store.durationString(frames: length))" + linkedNote
        }
    }

    /// A step of a fade handle drag: the fade ends at the pointer, on the frame grid, within
    /// the clip and never overlapping the other fade.
    private func fade(_ id: Int64, fadeIn: Bool, location: CGPoint, model: TimelineViewModel) {
        guard let clip = snapModel.clip(id: id), let info = store.clips[id] else { return }
        let frameSeconds = max(model.frameSeconds, 1e-9)
        let pointer = model.time(forX: location.x)
        let requested = Int64(((fadeIn ? pointer - clip.start : clip.end - pointer) / frameSeconds).rounded())
        let clipFrames = store.frames(info.duration)
        let other = store.frames(fadeIn ? info.audioParams.fadeOutDuration : info.audioParams.fadeInDuration)
        let room = max(0, clipFrames - other)
        let frames = min(room, max(0, requested))
        var params = info.audioParams
        if fadeIn {
            params.fadeInDuration = store.time(frames: frames)
        } else {
            params.fadeOutDuration = store.time(frames: frames)
        }
        let result = store.engine.performInCoalescingGroup(Self.fadeGroup) {
            store.engine.setAudioParams(params, forClip: id)
        }
        guard handleStep(result) else { return }
        let name = fadeIn ? "Fade in" : "Fade out"
        if requested > room {
            store.statusMessage = other > 0
                ? "\(name) limited to \(store.durationString(frames: room)): the fades cannot overlap."
                : "\(name) limited to the clip's length."
        } else {
            store.statusMessage = "\(name): \(store.durationString(frames: frames))"
        }
    }

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

    /// The pointer hovers `point` (nil: it left the track area): updates the cursor and the gain
    /// tooltip. Publishes only when what is hovered changes.
    /// The pointer moved over the track area (`nil`: it left). The cursor is set only when the
    /// shape it needs changes (hover fires on every pointer event); leaving the area restores
    /// the arrow if hover had changed it, and otherwise leaves the cursor to whatever the pointer
    /// is over now (a split-view divider sets its own).
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
        case .clipHead, .clipTail, .transitionHead, .transitionTail, .fadeIn, .fadeOut:
            wanted = .resizeLeftRight
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
    /// Delete This Transition Only and Transition Duration…; a clip offers Delete, Ripple Delete,
    /// Link/Unlink and Speed/Duration…. Nothing during a drag or over empty space.
    func contextMenuItems(at location: CGPoint) -> [ContextMenuItem] {
        guard drag == .idle, !store.isGestureActive else { return [] }
        let store = self.store
        store.focusArea = .timeline
        store.reclaimKeyboardFocus()
        switch store.timelineModel.hitTest(location) {
        case let .transition(id), let .transitionHead(id), let .transitionTail(id):
            store.selection = []
            store.selectedTransitionID = id
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
        case let .clipBody(id), let .clipHead(id), let .clipTail(id), let .fadeIn(id), let .fadeOut(id),
             let .gainLine(id), let .keyframe(id, _):
            if !store.selection.contains(id) {
                store.select(clip: id, extend: false)
            }
            store.selectedTransitionID = nil
            let selected = store.selectedClips
            let canUnlink = !selected.isEmpty && selected.allSatisfy { $0.linkedClipID != 0 }
            return [
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
        case .track, .none:
            return []
        }
    }

    // MARK: Transition drops

    /// A transition from the Transitions panel is dragged over `location`: finds the cut it would
    /// land on (the nearest cut on that row within `dropCutDistance` points) and whether it fits.
    @discardableResult
    func transitionDragUpdated(kind: TransitionKind, at location: CGPoint) -> TransitionDropTarget? {
        let target = dropTarget(kind: kind, at: location)
        if target != transitionDrop { transitionDrop = target }
        return target
    }

    func transitionDragExited() {
        if transitionDrop != nil { transitionDrop = nil }
    }

    /// Drops a transition: added on the target cut (see `ProjectStore.addTransition`); a refused
    /// drop says why in the status line. Returns whether a transition was added (or is waiting
    /// for the linked-crossfade question).
    @discardableResult
    func dropTransition(kind: TransitionKind, at location: CGPoint) -> Bool {
        let target = dropTarget(kind: kind, at: location)
        transitionDrop = nil
        store.focusArea = .timeline
        guard let target else {
            store.statusMessage = dropMissMessage(kind: kind, at: location)
            return false
        }
        guard target.allowed else {
            store.statusMessage = target.message
            return false
        }
        if store.addTransition(kind, from: target.fromClipID, to: target.toClipID) {
            return true
        }
        return store.pendingLinkedTransition != nil
    }

    /// Distance (points) from the pointer within which a cut takes a dropped transition.
    static let dropCutDistance: CGFloat = 40

    private func dropTarget(kind: TransitionKind, at location: CGPoint) -> TransitionDropTarget? {
        let model = store.timelineModel
        guard let row = model.layout(atY: location.y),
              (row.track.kind == .video) == (kind.trackKind == .video) else { return nil }
        let onTrack = model.clips.filter { $0.trackID == row.track.id }
        var best: (from: TimelineViewModel.Clip, to: TimelineViewModel.Clip, distance: CGFloat)?
        for (from, to) in zip(onTrack, onTrack.dropFirst()) where abs(from.end - to.start) < 1e-9 {
            let distance = abs(model.x(forTime: from.end) - location.x)
            if distance <= Self.dropCutDistance, best.map({ distance < $0.distance }) ?? true {
                best = (from, to, distance)
            }
        }
        guard let (from, to, _) = best else { return nil }
        let limit = store.engine.transitionLimit(fromClip: from.id, toClip: to.id)
        let wanted = store.editingPreferences.transitionFrames(frameDuration: store.frameDuration)
        let frames = min(wanted, limit.maximumFrames)
        let allowed = limit.maximumFrames > 0 && !row.track.locked
        var message = ""
        if row.track.locked {
            message = "Track \(row.track.name) is locked."
        } else if !allowed {
            message = "No transition fits this cut: \(limit.reason)"
        } else if frames < wanted {
            message = "Shortened to \(store.durationString(frames: frames)): \(limit.reason)"
        }
        let shown = max(frames, 1)
        let frameSeconds = model.frameSeconds
        let start = from.end - Double(shown / 2) * frameSeconds
        let end = from.end + Double(shown - shown / 2) * frameSeconds
        return TransitionDropTarget(kind: kind, trackID: row.track.id, fromClipID: from.id, toClipID: to.id,
                                    cut: from.end, frames: frames, start: start, end: end, allowed: allowed,
                                    message: message)
    }

    private func dropMissMessage(kind: TransitionKind, at location: CGPoint) -> String {
        let model = store.timelineModel
        if let row = model.layout(atY: location.y), (row.track.kind == .video) != (kind.trackKind == .video) {
            return "\(kind.title) goes on \(kind.trackKind == .video ? "a video" : "an audio") track."
        }
        return "Drop \(kind.title) on a cut between two adjacent clips."
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
