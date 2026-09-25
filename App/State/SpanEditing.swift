import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// A parameter of an effect span as the inspector and the monitor readout show it: absolute (what
/// the picture or the sound has at the span's edge), in display units (pixels, percent, degrees,
/// decibels).
///
/// Span values are relative and cumulative (see `VEEffectSpan`): the span's own value applies on
/// top of what the rest of the clip composes to at that edge (`VEClipInfo.getBaseValues`), adding
/// for Position X/Y, Rotation and Gain and multiplying for Scale and Opacity. `SpanValueMath` turns
/// one into the other.
enum SpanParameter: String, CaseIterable, Identifiable {
    case positionX, positionY, scale, rotation, opacity, gain

    var id: String { rawValue }

    var engineParameter: VESpanParameter {
        switch self {
        case .positionX: return .positionX
        case .positionY: return .positionY
        case .scale: return .scale
        case .rotation: return .rotation
        case .opacity: return .opacity
        case .gain: return .gain
        }
    }

    var label: String {
        switch self {
        case .positionX: return "Position X"
        case .positionY: return "Position Y"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        case .gain: return "Gain"
        }
    }

    var unit: String {
        switch self {
        case .positionX, .positionY: return "px"
        case .scale, .opacity: return "%"
        case .rotation: return "°"
        case .gain: return "dB"
        }
    }

    /// Units accepted when typed (lowercased), besides none.
    var acceptedUnits: Set<String> {
        switch self {
        case .positionX, .positionY: return ["px", "pixel", "pixels"]
        case .scale, .opacity: return ["%"]
        case .rotation: return ["°", "deg", "degree", "degrees"]
        case .gain: return ["db"]
        }
    }

    /// Display units per engine unit (scale and opacity are shown in percent).
    var displayFactor: Double {
        self == .scale || self == .opacity ? 100 : 1
    }

    /// The span's value multiplies what it applies onto (else it adds to it).
    var isFactor: Bool {
        self == .scale || self == .opacity
    }

    /// The parameters a span of `kind` animates, in display order.
    static func parameters(for kind: VESpanKind) -> [SpanParameter] {
        switch kind {
        case .motion: return [.positionX, .positionY, .scale, .rotation]
        case .opacity: return [.opacity]
        case .gain: return [.gain]
        default: return []
        }
    }

    /// The parameter's field of `values`.
    func value(in values: VESpanValues) -> Double {
        switch self {
        case .positionX: return values.x
        case .positionY: return values.y
        case .scale: return values.scale
        case .rotation: return values.rotationDegrees
        case .opacity: return values.opacity
        case .gain: return values.gainDb
        }
    }

    /// Sets the parameter's field of `values`.
    func set(_ value: Double, in values: inout VESpanValues) {
        switch self {
        case .positionX: values.x = value
        case .positionY: values.y = value
        case .scale: values.scale = value
        case .rotation: values.rotationDegrees = value
        case .opacity: values.opacity = value
        case .gain: values.gainDb = value
        }
    }
}

/// The conversion between a span's relative value and the absolute value its edge shows, given the
/// base (what the rest of the clip composes to there): absolute = base + relative for the additive
/// parameters, base x relative for the factors; and back. Exact inverses (up to rounding) whenever
/// the base of a factor is not 0.
enum SpanValueMath {
    static func absolute(_ parameter: SpanParameter, base: Double, relative: Double) -> Double {
        parameter.isFactor ? base * relative : base + relative
    }

    /// The relative value that shows `absolute` on `base`; nil when a factor's base is 0 (nothing
    /// multiplied onto it can show anything but 0).
    static func relative(_ parameter: SpanParameter, base: Double, absolute: Double) -> Double? {
        if parameter.isFactor {
            guard base != 0, base.isFinite else { return nil }
            return absolute / base
        }
        return absolute - base
    }
}

/// An edge of a span as the inspector shows it: the base under it and the span's own value there.
struct SpanEdge {
    let base: VESpanValues
    let relative: VESpanValues

    /// What the edge shows for `parameter` (absolute, engine units).
    func absolute(_ parameter: SpanParameter) -> Double {
        SpanValueMath.absolute(parameter, base: parameter.value(in: base), relative: parameter.value(in: relative))
    }
}

/// Span editing in the store: selection, adding spans with their default values (one undo step),
/// Add Motion Span at Playhead (Control-K), range changes limited to the clip and to the free space
/// of the lane, absolute values written back as relative ones, interpolation, lanes, matching a
/// neighbour, fades from the Effects tab. Every command is refused while a gesture is in progress
/// (`isGestureActive`); a refusal is reported in the status line (with the engine's nearest free
/// range for an overlap).
extension ProjectStore {
    /// How long a Motion span added at the playhead is (or to its clip's end, if shorter).
    static let motionSpanSeconds = 5.0
    /// The fraction of its start framing a new Motion span's end framing shows (the Ken Burns push in).
    static let defaultPushInFraction = 0.8

    // MARK: Selection

    /// Selects a span (a transition too); the clips are deselected (the two are exclusive).
    func select(span id: VESpanID) {
        focusArea = .timeline
        if selectedSpanID != id {
            selectedSpanID = id
        }
    }

    /// The selected span as the engine has it now (nil when none).
    var selectedSpan: VEEffectSpan? {
        selectedSpanID.flatMap { engine.spanInfo($0) }
    }

    /// The selected span when it is an effect span (lanes 1-3; not a transition).
    var selectedEffectSpan: VEEffectSpan? {
        selectedSpan.flatMap { $0.kind == .transition ? nil : $0 }
    }

    // MARK: Text

    /// A timeline time as the user's duration format shows it (the frame from zero).
    func timelineTimeString(_ time: CMTime) -> String {
        durationString(frames: frames(time))
    }

    /// "00:00:01:00 – 00:00:03:00".
    func rangeString(start: CMTime, end: CMTime) -> String {
        "\(timelineTimeString(start)) – \(timelineTimeString(end))"
    }

    /// A refused span edit's message, with the nearest free range of the lane for an overlap.
    func spanRefusalText(_ result: VEEditResult) -> String {
        guard result.errorCode == .overlap, result.freeRange.isValid, result.freeRange.duration > .zero else {
            return result.message
        }
        let range = result.freeRange
        return result.message + " The nearest free range is "
            + rangeString(start: range.start, end: CMTimeAdd(range.start, range.duration)) + "."
    }

    /// The title of a span kind ("Motion", "Fade", "Gain"; transitions by their style).
    static func title(of span: VEEffectSpan, isAudio: Bool) -> String {
        switch span.kind {
        case .motion: return "Motion"
        case .opacity: return "Fade"
        case .gain: return "Gain"
        case .transition:
            switch span.transitionStyle {
            case .fadeIn: return "Fade In"
            case .fadeOut: return "Fade Out"
            default: return isAudio ? "Crossfade" : "Cross Dissolve"
            }
        @unknown default: return "Span"
        }
    }

    // MARK: Adding

    /// Adds a span of `kind` (Motion or Opacity on a video clip, Gain on an audio clip) over `range`
    /// (timeline, whole frames) on `lane`, or on the first effect lane with room when `lane` is nil,
    /// with its default values, as one undo step ("Add ... Span"), and selects it. Defaults: a Motion
    /// span is the Ken Burns push in: it starts on the framing the clip has there (no jump) and ends
    /// on `defaultPushInFraction` of it around the same point (scale x 1.25), eased in and out. An
    /// Opacity span fades: 1 -> 0 when it touches the clip's end, 0 -> 1 at its start, else 1 -> 1.
    /// A Gain span is 0 -> 0 dB. A refusal is reported (with the free range for an overlap) and
    /// changes nothing.
    @discardableResult
    func addSpan(kind: VESpanKind, lane: Int?, clip id: VEClipID, range: CMTimeRange) -> VEEditResult {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return VEEditResult.failure(with: .busy, message: "Finish the current drag first.")
        }
        inspector.endNudgeBurst()
        let key = "span.add"
        engine.beginCoalescing(withKey: key, mode: .accumulate)
        var added = VEEditResult.failure(withMessage: "")
        for candidate in lane.map({ [$0] }) ?? [1, 2, 3] {
            added = engine.performInCoalescingGroup(key) { self.engine.addSpan(kind: kind, lane: candidate, clip: id,
                                                                                 range: range) }
            if added.ok || added.errorCode != .overlap { break }
        }
        guard added.ok, let span = added.span else {
            engine.cancelCoalescing()
            if lane == nil, added.errorCode == .overlap {
                let name = clips[id]?.name ?? "the clip"
                statusMessage = "No effect lane of “\(name)” has room there: " + spanRefusalText(added)
            } else {
                statusMessage = spanRefusalText(added)
            }
            return added
        }
        let defaults = applyDefaults(to: span, key: key)
        guard defaults.ok else {
            engine.cancelCoalescing()
            statusMessage = defaults.message
            return defaults
        }
        engine.endCoalescing()
        statusMessage = nil
        select(span: span.spanID)
        return VEEditResult.success(withCreatedIDs: [NSNumber(value: span.spanID)])
    }

    /// Sets a new span's default values inside the adding group (see `addSpan`).
    private func applyDefaults(to span: VEEffectSpan, key: String) -> VEEditResult {
        guard let clip = engine.clipInfo(span.clipID) else { return .success() }
        switch span.kind {
        case .opacity:
            let touchesEnd = span.end == clip.timelineEnd
            let touchesStart = span.start == clip.timelineStart
            var start = VESpanValuesUnchanged()
            var end = VESpanValuesUnchanged()
            start.opacity = touchesEnd ? 1 : (touchesStart ? 0 : 1)
            end.opacity = touchesEnd ? 0 : 1
            guard start.opacity != 1 || end.opacity != 1 else { return .success() }
            return engine.performInCoalescingGroup(key) { self.engine.setSpanValues(span.spanID, start: start, end: end) }
        case .motion:
            // The Ken Burns default: from the framing the clip has there to a gentle push in on it (the
            // end 1 / defaultPushInFraction larger, around the same point), easing in and out.
            var end = VESpanValuesUnchanged()
            end.scale = 1 / Self.defaultPushInFraction
            let values = engine.performInCoalescingGroup(key) {
                self.engine.setSpanValues(span.spanID, start: VESpanValuesUnchanged(), end: end)
            }
            guard values.ok else { return values }
            return engine.performInCoalescingGroup(key) {
                self.engine.setSpanInterpolation(span.spanID, interpolation: .easeInOut)
            }
        default:
            return .success()
        }
    }

    /// Frames of `clip` under a cross dissolve or crossfade coming into it (the previous clip's tail
    /// transition's share after the cut); 0 when none comes in.
    func incomingTransitionFrames(of clip: VEClipInfo) -> Int64 {
        for other in clips.values where other.trackID == clip.trackID && other.clipID != clip.clipID {
            if let span = other.spans.first(where: {
                $0.kind == .transition && $0.transitionStyle == .crossDissolve && $0.partnerClipID == clip.clipID
            }) {
                return frames(span.shareAfterCut)
            }
        }
        return 0
    }

    /// The relative Motion values that show `framing` (position and scale) over `base`; nil when
    /// the base's scale is 0.
    static func relativeFraming(_ framing: VEMotionFraming, base: VESpanValues) -> VESpanValues? {
        guard let scale = SpanValueMath.relative(.scale, base: base.scale, absolute: framing.scale) else { return nil }
        var values = VESpanValuesUnchanged()
        values.x = framing.x - base.x
        values.y = framing.y - base.y
        values.scale = scale
        return values
    }

    /// The clip Add Motion Span at Playhead works on: the selected video clip (a linked pair counts
    /// as its video clip) or the selected span's clip; with nothing selected, the top-most video
    /// clip under the playhead on a track that is neither locked nor hidden (review L6). Nil when
    /// there is none.
    func motionSpanClip() -> VEClipInfo? {
        let video = selectedClips.filter { $0.trackKind == .video }
        if video.count == 1 { return video[0] }
        if !selection.isEmpty { return nil }
        if let span = selectedSpan, let clip = clips[span.clipID], clip.trackKind == .video { return clip }
        let t = playheadTime
        for trackID in sequence.videoTrackIDs.map(\.int64Value).reversed() {
            guard let track = track(trackID), !track.locked, !track.muted else { continue }
            if let clip = clips.values.first(where: {
                $0.trackID == trackID && $0.timelineStart <= t && t < $0.timelineEnd
            }) {
                return clip
            }
        }
        return nil
    }

    /// Control-K, Clip > Add Motion Span at Playhead, and the clip's context menu (`clip`): a Motion
    /// span from the frame under the playhead, 5 s long or to the clip's end if shorter, on the first
    /// effect lane with room, with the default values (see `addSpan`); it is selected, which opens the
    /// Ken Burns editor. Refused with the reason: during a gesture, without a video clip, with the
    /// playhead off the clip or on its last frame, or when no lane has room.
    func addMotionSpanAtPlayhead(clip id: VEClipID? = nil) {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return
        }
        guard let clip = id.flatMap({ clips[$0] }) ?? motionSpanClip(), clip.trackKind == .video else {
            let selectedVideo = selectedClips.filter { $0.trackKind == .video }.count
            statusMessage = selectedVideo > 1
                ? "Select one video clip to add a Motion span (\(selectedVideo) are selected)."
                : "Select a video clip, or move the playhead over one, to add a Motion span."
            return
        }
        let start = frameTime(playheadTime.secondsOrZero)
        guard clip.timelineStart <= start, start < clip.timelineEnd else {
            statusMessage = "Move the playhead over “\(clip.name)” to add a Motion span there."
            return
        }
        // Pressed again on the same frame: the span it added is selected, not a second push in on
        // top of it (review L6: repeated presses stacked 1.25 x 1.25 x 1.25).
        if let existing = clip.spans.first(where: { $0.kind == .motion && $0.start == start }) {
            select(span: existing.spanID)
            statusMessage = "“\(clip.name)” already has a Motion span starting here: it is selected (drag on an empty "
                + "lane to add another)."
            return
        }
        let length = CMTime.onFrameGrid(seconds: Self.motionSpanSeconds, frameDuration: frameDuration)
        let end = CMTimeMinimum(CMTimeAdd(start, length), clip.timelineEnd)
        guard frames(CMTimeSubtract(end, start)) >= 2 else {
            statusMessage = "Less than two frames of “\(clip.name)” are left after the playhead: a Motion span "
                + "needs at least two."
            return
        }
        addSpan(kind: .motion, lane: nil, clip: clip.clipID, range: CMTimeRange(start: start, end: end))
    }

    // MARK: Changing

    /// Removes an effect span (Delete, the context menu, the inspector); a transition goes through
    /// `removeTransition` (with its linked one). One undo step; refused during a gesture.
    @discardableResult
    func removeSpan(_ id: VESpanID) -> Bool {
        guard !isGestureActive else { return false }
        if engine.transitionInfo(id) != nil {
            return removeTransition(id, includingLinked: true)
        }
        inspector.endNudgeBurst()
        guard report(engine.removeSpan(id)) else { return false }
        if selectedSpanID == id { selectedSpanID = nil }
        return true
    }

    /// Moves an effect span to lane 1-3 of its clip (one undo step; an overlap there is refused
    /// with the free range).
    @discardableResult
    func moveSpan(_ id: VESpanID, toLane lane: Int) -> Bool {
        guard !isGestureActive else { return false }
        inspector.endNudgeBurst()
        let result = engine.moveSpan(id, toLane: lane)
        guard result.ok else {
            statusMessage = spanRefusalText(result)
            return false
        }
        return report(result)
    }

    /// Sets how the span moves from its start to its end values (one undo step).
    @discardableResult
    func setSpanInterpolation(_ id: VESpanID, _ interpolation: VEKeyframeInterpolation) -> Bool {
        guard !isGestureActive else { return false }
        inspector.endNudgeBurst()
        guard engine.spanInfo(id)?.interpolation != interpolation else { return true }
        return report(engine.setSpanInterpolation(id, interpolation: interpolation))
    }

    /// Where an effect span's edges may go: within its clip and the free space of its lane around
    /// it (from the end of the span before it on the lane to the start of the one after it).
    func spanLimits(_ span: VEEffectSpan) -> (lower: CMTime, upper: CMTime)? {
        guard let clip = clips[span.clipID] else { return nil }
        var lower = clip.timelineStart
        var upper = clip.timelineEnd
        for other in engine.spans(forClip: span.clipID) where other.lane == span.lane && other.spanID != span.spanID {
            if other.end <= span.start { lower = CMTimeMaximum(lower, other.end) }
            if other.start >= span.end { upper = CMTimeMinimum(upper, other.start) }
        }
        return (lower, upper)
    }

    /// Moves an effect span's edges to [start, end) (timeline times, whole frames: the Start, End
    /// and Duration fields), limited to its clip and to the free space of its lane around it, at
    /// least a frame long: when the range would be shorter, the edge that was typed (`typed`: its
    /// start or its end; nil for both) gives way to the other, which stays. Returns the note saying
    /// what was limited (nil when taken as asked), or the refusal. One undo step (none when nothing
    /// changes).
    @discardableResult
    func setSpanRange(_ id: VESpanID, start: CMTime, end: CMTime, typed: VEClipEdge? = nil) -> (ok: Bool, note: String?) {
        guard !isGestureActive else { return (false, "Finish the current drag first.") }
        guard let span = engine.spanInfo(id), span.kind != .transition, let limits = spanLimits(span) else {
            return (false, "The span no longer exists.")
        }
        let frame = frameDuration
        var from = frameTime(start.secondsOrZero)
        var to = frameTime(end.secondsOrZero)
        var notes: [String] = []
        if from < limits.lower || to > limits.upper || from >= limits.upper || to <= limits.lower {
            let clip = clips[span.clipID]
            let byClip = limits.lower == clip?.timelineStart && limits.upper == clip?.timelineEnd
            from = CMTimeMinimum(CMTimeMaximum(from, limits.lower), limits.upper)
            to = CMTimeMaximum(CMTimeMinimum(to, limits.upper), limits.lower)
            notes.append((byClip ? "Limited to the clip, " : "Limited to the free space on lane \(span.lane), ")
                + rangeString(start: limits.lower, end: limits.upper) + ".")
        }
        if CMTimeSubtract(to, from) < frame {
            if typed == .start {
                from = CMTimeMaximum(limits.lower, CMTimeSubtract(to, frame))
                to = CMTimeMinimum(limits.upper, CMTimeAdd(from, frame))
                notes.append("A span is at least a frame long: the start is \(timelineTimeString(from)), a frame "
                    + "before the end.")
            } else {
                to = CMTimeMinimum(limits.upper, CMTimeAdd(from, frame))
                from = CMTimeMaximum(limits.lower, CMTimeSubtract(to, frame))
                notes.append("A span is at least a frame long: the end is \(timelineTimeString(to)), a frame "
                    + "after the start.")
            }
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        guard from != span.start || to != span.end else { return (true, note) }
        inspector.endNudgeBurst()
        let result = engine.setSpanRange(id, range: CMTimeRange(start: from, end: to))
        guard result.ok else {
            let text = spanRefusalText(result)
            statusMessage = text
            return (false, text)
        }
        report(result)
        if let note { statusMessage = note }
        return (true, note)
    }

    // MARK: Values

    /// An edge of an effect span: its base and its own value (nil for a transition or an unknown
    /// span). Read from the clip as it is now, never cached: an edit of an earlier span changes the
    /// base of every later one.
    func spanEdge(_ span: VEEffectSpan, atEnd: Bool) -> SpanEdge? {
        guard span.kind != .transition, let clip = clips[span.clipID] ?? engine.clipInfo(span.clipID) else { return nil }
        var base = VESpanValuesUnchanged()
        guard clip.getBaseValues(&base, underSpan: span.spanID, atEnd: atEnd, frameDuration: frameDuration) else {
            return nil
        }
        return SpanEdge(base: base, relative: atEnd ? span.endValues : span.startValues)
    }

    /// The relative values that show `absolute` (engine units) for `parameter` at an edge of `span`,
    /// with the note saying what was limited (a factor above what it applies onto, a negative scale)
    /// or, when nothing can show it, the refusal as `error`.
    func relativeValue(_ parameter: SpanParameter, absolute: Double, of span: VEEffectSpan,
                       atEnd: Bool) -> (value: Double?, note: String?) {
        guard let edge = spanEdge(span, atEnd: atEnd) else { return (nil, "The span no longer exists.") }
        let base = parameter.value(in: edge.base)
        var wanted = absolute
        var note: String?
        if parameter.isFactor, wanted < 0 {
            wanted = 0
            note = "\(parameter.label) is at least 0 %."
        }
        if parameter == .opacity, wanted > base {
            // An Opacity span is a factor of 0...1 on what it applies onto: it can only lower it.
            wanted = base
            note = "Limited to \(Self.percentText(base)): the opacity the rest of the clip has here (a fade "
                + "can only lower it)."
        }
        guard let relative = SpanValueMath.relative(parameter, base: base, absolute: wanted) else {
            return (nil, "The rest of the clip has \(parameter.label.lowercased()) 0 here, so the span cannot "
                + "change what it shows.")
        }
        return (relative, note)
    }

    /// "80 %".
    static func percentText(_ factor: Double) -> String {
        let percent = factor * 100
        return abs(percent - percent.rounded()) < 1e-9 ? String(format: "%.0f %%", percent)
            : String(format: "%.1f %%", percent)
    }

    /// Sets what an edge of an effect span shows for `parameter` (absolute, engine units), written
    /// back as the span's relative value (`relativeValue`). Inside `group` (a nudge burst) the edit
    /// joins it; otherwise it is one undo step. Returns the result and the limiting note.
    func setSpanValue(_ parameter: SpanParameter, absolute: Double, of span: VEEffectSpan, atEnd: Bool,
                      group: String? = nil) -> (result: VEEditResult, note: String?) {
        let (relative, note) = relativeValue(parameter, absolute: absolute, of: span, atEnd: atEnd)
        guard let relative else {
            return (VEEditResult.failure(with: .invalidArgument, message: note ?? ""), nil)
        }
        var values = VESpanValuesUnchanged()
        parameter.set(relative, in: &values)
        let unchanged = VESpanValuesUnchanged()
        let id = span.spanID
        let edit = { self.engine.setSpanValues(id, start: atEnd ? unchanged : values, end: atEnd ? values : unchanged) }
        let result = group.map { key in engine.performInCoalescingGroup(key) { edit() } } ?? edit()
        return (result, note)
    }

    /// Matches the span's edge to the touching clip at `edge` (`VEEngine.matchSpanEdge`): its start
    /// continues the previous clip's last frame, its end leads into the next clip's first frame.
    /// One undo step (none when it already matches); refused during a gesture.
    @discardableResult
    func matchSpanEdge(_ id: VESpanID, _ edge: VEClipEdge) -> VEEditResult {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return VEEditResult.failure(with: .busy, message: "Finish the current drag first.")
        }
        inspector.endNudgeBurst()
        let result = engine.matchSpanEdge(id, toAdjacentClipAt: edge)
        report(result)
        return result
    }

    /// Whether matching the span's `edge` applies: a clip touches that edge of its clip, and for the
    /// start the span starts on its clip's first frame (the engine refuses a later one).
    func canMatchSpan(_ span: VEEffectSpan, _ edge: VEClipEdge) -> Bool {
        guard span.kind != .transition, let clip = clips[span.clipID], adjacentClip(to: clip.clipID, at: edge) != nil
        else { return false }
        return edge == .end || span.start == clip.timelineStart
    }

    // MARK: Transitions

    /// Sets a transition's range (timeline, whole frames): its edges independently (asymmetric
    /// shares of the cut) or the whole span (sliding the split); the linked transition follows per
    /// the linked-transitions preference (`resizesLinkedTransitions`). One undo step (a drag passes
    /// `group`). The engine fits each side to the handles and says so in its note; a range that no
    /// longer reaches past the cut becomes a fade out (and the note says so).
    func setTransitionRange(_ id: VETransitionID, start: CMTime, end: CMTime, group: String? = nil) -> VEEditResult {
        let includingLinked = resizesLinkedTransitions
        let range = CMTimeRange(start: frameTime(start.secondsOrZero), end: frameTime(end.secondsOrZero))
        let edit = { self.engine.setTransitionRange(id, range: range, includingLinked: includingLinked) }
        return group.map { key in engine.performInCoalescingGroup(key) { edit() } } ?? edit()
    }

    /// Adds a fade from or to black / silence (a lane-0 transition span) at `edge` of `clip` with
    /// `frames` (the default transition duration when nil), shortened to what the clip allows, and
    /// selects it. Only this clip (not its linked partner). One undo step.
    @discardableResult
    func addFade(at edge: VEClipEdge, of clip: VEClipID, frames: Int64? = nil) -> Bool {
        guard !isGestureActive else { return false }
        inspector.endNudgeBurst()
        let length = frames ?? editingPreferences.transitionFrames(frameDuration: frameDuration)
        let result = engine.addTransition(at: edge, of: clip, duration: time(frames: length), options: [.fitToCut])
        guard report(result), let id = result.createdIDs.first?.int64Value else { return false }
        select(span: id)
        return true
    }
}
