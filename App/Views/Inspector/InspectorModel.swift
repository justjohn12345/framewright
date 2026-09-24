import CoreMedia
import Foundation
import FramewrightEngine

/// A section of the inspector.
enum InspectorSection: String, CaseIterable {
    case video
    case audio
    case speed
    case transition

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .speed: return "Speed"
        case .transition: return "Transition"
        }
    }
}

/// An editable parameter of the inspector, in display units: pixels (position), percent
/// (scale, opacity, speed), degrees (rotation), decibels (gain) and sequence frames (fades,
/// transition duration; shown per the duration preference).
enum InspectorParameter: String, CaseIterable, Identifiable {
    case positionX, positionY, scale, rotation, opacity
    case gain, fadeIn, fadeOut
    case speed
    case transitionDuration

    var id: String { rawValue }

    var section: InspectorSection {
        switch self {
        case .positionX, .positionY, .scale, .rotation, .opacity: return .video
        case .gain, .fadeIn, .fadeOut: return .audio
        case .speed: return .speed
        case .transitionDuration: return .transition
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
        case .fadeIn: return "Fade In"
        case .fadeOut: return "Fade Out"
        case .speed: return "Speed"
        case .transitionDuration: return "Duration"
        }
    }

    /// Unit shown after the number (durations use the duration preference instead).
    var unit: String {
        switch self {
        case .positionX, .positionY: return "px"
        case .scale, .opacity, .speed: return "%"
        case .rotation: return "°"
        case .gain: return "dB"
        case .fadeIn, .fadeOut, .transitionDuration: return ""
        }
    }

    /// Units accepted when typed (lowercased), besides none.
    var acceptedUnits: Set<String> {
        switch self {
        case .positionX, .positionY: return ["px", "pixel", "pixels"]
        case .scale, .opacity: return ["%"]
        case .rotation: return ["°", "deg", "degree", "degrees"]
        case .gain: return ["db"]
        case .speed, .fadeIn, .fadeOut, .transitionDuration: return []
        }
    }

    var isDuration: Bool {
        self == .fadeIn || self == .fadeOut || self == .transitionDuration
    }

    /// The engine's Motion parameter of a Video parameter (nil for the others).
    var motionParameter: VEMotionParameter? {
        switch self {
        case .positionX: return .positionX
        case .positionY: return .positionY
        case .scale: return .scale
        case .rotation: return .rotation
        case .opacity: return .opacity
        case .gain, .fadeIn, .fadeOut, .speed, .transitionDuration: return nil
        }
    }

    /// Display units per engine unit (scale and opacity are shown in percent).
    var displayFactor: Double {
        self == .scale || self == .opacity ? 100 : 1
    }

    /// The value a reset restores (transition duration: the default duration preference).
    var defaultValue: Double {
        switch self {
        case .scale, .opacity, .speed: return 100
        case .positionX, .positionY, .rotation, .gain, .fadeIn, .fadeOut, .transitionDuration: return 0
        }
    }

    /// The parameters of a section, in display order.
    static func parameters(in section: InspectorSection) -> [InspectorParameter] {
        allCases.filter { $0.section == section }
    }
}

/// The interpolations the inspector offers for a keyframe's segment (Custom, the part of an eased
/// segment that a split or a keyframe added inside it leaves, is shown but cannot be chosen).
extension VEKeyframeInterpolation {
    static let choices: [VEKeyframeInterpolation] = [.linear, .hold, .easeOut, .easeIn, .easeInOut]

    var title: String {
        switch self {
        case .hold: return "Hold"
        case .linear: return "Linear"
        case .easeOut: return "Ease Out"
        case .easeIn: return "Ease In"
        case .easeInOut: return "Ease In and Out"
        case .custom: return "Custom"
        @unknown default: return "Linear"
        }
    }

    /// What it does, for help tags (Premiere and FCP naming: out of a keyframe, into the next).
    var explanation: String {
        switch self {
        case .hold: return "The value stays until the next keyframe, then jumps."
        case .linear: return "Constant rate to the next keyframe."
        case .easeOut: return "Leaves this keyframe slowly, then speeds up."
        case .easeIn: return "Slows down to arrive at the next keyframe."
        case .easeInOut: return "Leaves slowly and arrives slowly."
        case .custom: return "The part of an eased move left when a keyframe was added inside it or the clip was split."
        @unknown default: return ""
        }
    }
}

/// What a Video parameter's keyframe controls show, derived from the model. `KeyframeControls` draws
/// only from this value (a stored, Equatable property), so SwiftUI redraws the controls whenever it
/// changes: a view that kept only a reference to `InspectorModel` would compare equal after every
/// edit and keep showing the old diamond and interpolation.
struct KeyframeControlState: Equatable {
    /// The frame under the playhead shows a keyframe of the parameter.
    var hasKeyframeAtPlayhead = false
    /// That keyframe's interpolation.
    var interpolation: VEKeyframeInterpolation?
    /// The parameter has keyframes.
    var isAnimated = false
    var hasPrevious = false
    var hasNext = false
}

/// The inspector's editing logic, separate from SwiftUI so it can be tested.
///
/// Targets: video parameters apply to every selected clip on a video track, audio parameters to
/// every selected clip on an audio track, each change as one undoable batch
/// (`VEEngine.applyClipParams`). Keyframed Motion: with a single video clip (`motionTarget`) the
/// Video values are the ones the picture has at the playhead, and a change goes through
/// `VEEngine.setMotionValue`: an animated parameter changes the keyframe under the playhead (or
/// gets a new one there, as in Premiere), a static one its static value. Several clips at once
/// can change only parameters none of them animates. Each Video parameter has a keyframe toggle,
/// previous/next keyframe navigation and the interpolation of the keyframe under the playhead.
/// Speed applies to a single clip (or linked pair); the Speed/Duration sheet handles several. The
/// transition section edits the selected transition.
///
/// Edits: a typed value (with or without its unit) is clamped to the parameter's range and
/// applied as one undo step; a slider drag is one coalesced step (Replace group, ended on
/// release or when the inspector goes away); keyboard nudges (Up/Down ±1, Shift ±10 in a
/// field, and `[`/`]` for gain) open an Accumulate group so a burst is one undo step, closed
/// after `burstIdleSeconds` without nudges (or by any other edit, which commits it first). Every
/// refusal, including VEEditErrorBusy when another edit ended a group, is shown in `message`.
@MainActor
final class InspectorModel: ObservableObject {
    /// Seconds without a nudge after which the burst's undo step is closed.
    static var burstIdleSeconds: TimeInterval = 1.0
    static let bigStep = 10.0

    private unowned let store: ProjectStore
    /// Last refusal or note of an inspector edit (non-modal; cleared by the next success).
    @Published private(set) var message: String?
    /// The coalescing group of the slider drag in progress.
    private(set) var sliderGroup: String?
    /// A slider drag whose group another edit ended: its remaining steps are ignored.
    private var sliderInterrupted = false
    private var burstEnd: DispatchWorkItem?

    init(store: ProjectStore) {
        self.store = store
    }

    private var engine: VEEngine { store.engine }

    // MARK: Targets

    var videoTargets: [VEClipInfo] { store.selectedClips.filter { $0.trackKind == .video } }
    /// The clip whose Motion keyframes the inspector shows: the only selected video clip.
    var motionTarget: VEClipInfo? {
        let targets = videoTargets
        return targets.count == 1 ? targets[0] : nil
    }
    var audioTargets: [VEClipInfo] { store.selectedClips.filter { $0.trackKind == .audio } }

    /// The clip whose speed the inspector edits: the only selected clip, or the video clip of a
    /// selected linked pair (never a still).
    var speedTarget: VEClipInfo? {
        let selected = store.selectedClips
        let clip: VEClipInfo?
        if selected.count == 1 {
            clip = selected[0]
        } else if selected.count == 2, selected[0].linkedClipID == selected[1].clipID {
            clip = selected.first { $0.trackKind == .video } ?? selected[0]
        } else {
            clip = nil
        }
        return clip.flatMap { $0.isStill ? nil : $0 }
    }

    /// The selected transition (shown when no clip is selected).
    var transition: VETransitionInfo? {
        guard store.selection.isEmpty, let id = store.selectedTransitionID else { return nil }
        return engine.transitionInfo(id)
    }

    var transitionKind: TransitionKind? {
        guard let transition, let track = store.track(transition.trackID) else { return nil }
        return TransitionKind.forTrack(track.kind)
    }

    /// The selected transition's linked transition (the crossfade under a dissolve), if any.
    var linkedTransition: VETransitionID? {
        transition.flatMap { store.linkedTransition(of: $0.transitionID) }
    }

    /// Where the selected transition sits on its cut (the cut is the outgoing clip's end).
    var transitionTiming: TransitionTiming? {
        guard let transition else { return nil }
        let cut = store.clips[transition.fromClipID]?.timelineEnd
            ?? CMTimeMultiplyByRatio(CMTimeAdd(transition.start, transition.end), multiplier: 1, divisor: 2)
        return TransitionTiming(start: transition.start, end: transition.end, cut: cut,
                                frameDuration: store.frameDuration)
    }

    func isAvailable(_ parameter: InspectorParameter) -> Bool {
        switch parameter.section {
        case .video: return !videoTargets.isEmpty
        case .audio: return !audioTargets.isEmpty
        case .speed: return speedTarget != nil
        case .transition: return transition != nil
        }
    }

    // MARK: Values

    /// The parameter's value on the first target (display units), or nil when unavailable.
    func value(_ parameter: InspectorParameter) -> Double? {
        switch parameter.section {
        case .video: return videoTargets.first.map { value(parameter, of: $0) }
        case .audio: return audioTargets.first.map { value(parameter, of: $0) }
        case .speed: return speedTarget.map { value(parameter, of: $0) }
        case .transition: return transition.map { Double(store.frames($0.duration)) }
        }
    }

    /// True when the targets have different values.
    func isMixed(_ parameter: InspectorParameter) -> Bool {
        let clips: [VEClipInfo]
        switch parameter.section {
        case .video: clips = videoTargets
        case .audio: clips = audioTargets
        case .speed, .transition: return false
        }
        guard let first = clips.first.map({ value(parameter, of: $0) }) else { return false }
        return clips.dropFirst().contains { abs(value(parameter, of: $0) - first) > 1e-9 }
    }

    /// The value `clip` shows (display units): for Motion, at the playhead.
    func value(_ parameter: InspectorParameter, of clip: VEClipInfo) -> Double {
        let video = clip.videoParams
        let audio = clip.audioParams
        let motion = parameter.motionParameter != nil && clip.hasKeyframes
            ? clip.motion(at: store.playheadTime) : video
        switch parameter {
        case .positionX: return motion.x
        case .positionY: return motion.y
        case .scale: return motion.scale * 100
        case .rotation: return motion.rotationDegrees
        case .opacity: return motion.opacity * 100
        case .gain: return audio.gainDb
        case .fadeIn: return Double(store.frames(audio.fadeInDuration))
        case .fadeOut: return Double(store.frames(audio.fadeOutDuration))
        case .speed: return Double(clip.speedNumerator) / Double(max(clip.speedDenominator, 1)) * 100
        case .transitionDuration: return 0
        }
    }

    /// Values a typed entry is clamped to.
    func range(_ parameter: InspectorParameter) -> ClosedRange<Double> {
        switch parameter {
        case .positionX, .positionY: return -10000 ... 10000
        case .scale: return 0 ... 10000
        case .rotation: return -3600 ... 3600
        case .opacity: return 0 ... 100
        case .gain: return -96 ... 24
        case .fadeIn, .fadeOut:
            let clip = audioTargets.first
            let length = clip.map { Double(store.frames($0.duration)) } ?? 0
            let other = clip.map { value(parameter == .fadeIn ? .fadeOut : .fadeIn, of: $0) } ?? 0
            return 0 ... max(0, length - other)
        case .speed: return 1 ... 10000
        case .transitionDuration:
            return 1 ... Double(max(1, transitionLimit?.maximumFrames ?? 1))
        }
    }

    /// The slider's span (typed values may go beyond it).
    func sliderRange(_ parameter: InspectorParameter) -> ClosedRange<Double> {
        switch parameter {
        case .positionX: return -Double(max(store.sequence.width, 1)) ... Double(max(store.sequence.width, 1))
        case .positionY: return -Double(max(store.sequence.height, 1)) ... Double(max(store.sequence.height, 1))
        case .scale: return 0 ... 400
        case .rotation: return -180 ... 180
        case .opacity: return 0 ... 100
        case .gain: return -60 ... 24
        case .fadeIn, .fadeOut:
            let length = audioTargets.first.map { Double(store.frames($0.duration)) } ?? 1
            return 0 ... max(1, length)
        case .speed: return 10 ... 400
        case .transitionDuration:
            return 1 ... Double(max(2, transitionLimit?.maximumFrames ?? 2))
        }
    }

    var transitionLimit: VETransitionLimit? {
        transition.map { engine.transitionLimit(forTransition: $0.transitionID) }
    }

    // MARK: Text

    /// The value as shown in the field ("" when mixed or unavailable: the field shows its
    /// placeholder).
    func text(_ parameter: InspectorParameter) -> String {
        guard let value = value(parameter), !isMixed(parameter) else { return "" }
        return format(parameter, value)
    }

    func format(_ parameter: InspectorParameter, _ value: Double) -> String {
        if parameter.isDuration {
            return store.durationString(frames: Int64(value.rounded()))
        }
        if parameter == .speed, let clip = speedTarget {
            let exact = SpeedRatio(numerator: clip.speedNumerator, denominator: clip.speedDenominator)
            if abs(exact.percent - value) < 1e-9, 1000 % max(clip.speedDenominator, 1) != 0 {
                return "\(clip.speedNumerator)/\(clip.speedDenominator)"
            }
        }
        let number: String
        if abs(value - value.rounded()) < 1e-9 {
            number = String(format: "%.0f", value)
        } else if abs(value * 10 - (value * 10).rounded()) < 1e-6 {
            number = String(format: "%.1f", value)
        } else {
            number = String(format: "%.2f", value)
        }
        return parameter.unit.isEmpty ? number : number + " " + parameter.unit
    }

    /// Parses typed text in display units: a number with or without the parameter's unit
    /// ("50", "50 %", "-6dB", "12px", "45°"); durations as "12f", "0.5s", timecode or a bare
    /// number in the preferred unit; speed as a percentage or a multiplier ("0.5x", "1/3").
    func parse(_ parameter: InspectorParameter, _ text: String) -> Double? {
        if parameter.isDuration {
            return DurationFormat.parseFrames(text, frameDuration: store.frameDuration,
                                              display: store.editingPreferences.durationDisplay).map(Double.init)
        }
        if parameter == .speed {
            return SpeedRatio.parse(text)?.percent
        }
        let (number, unit) = DurationFormat.splitNumber(text.replacingOccurrences(of: ",", with: "."))
        guard let value = Double(number), value.isFinite else { return nil }
        guard unit.isEmpty || parameter.acceptedUnits.contains(unit) else { return nil }
        return value
    }

    // MARK: Edits

    /// Applies typed text: parsed, clamped to the range, one undo step. Invalid text is refused
    /// with a message.
    func commitText(_ parameter: InspectorParameter, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if parameter == .speed, let ratio = SpeedRatio.parse(trimmed) {
            // "33.33" cannot be stored exactly: say what was applied instead.
            let adjusted = SpeedRatio.typedMultiplier(trimmed).flatMap {
                SpeedRatio.adjustmentNote(typed: $0, applied: ratio)
            }
            applySpeed(ratio, mode: .single, clampNote: adjusted)
            return
        }
        guard let value = parse(parameter, trimmed) else {
            message = "“\(trimmed)” is not a valid \(parameter.label.lowercased())"
                + (parameter.isDuration ? " (use frames like 12f, seconds like 0.5s, or timecode)."
                                        : parameter.unit.isEmpty ? "." : " in \(parameter.unit).")
            return
        }
        setValue(parameter, value)
    }

    /// Sets the parameter on every target, clamped to its range, as one undo step.
    func setValue(_ parameter: InspectorParameter, _ value: Double) {
        guard canEdit() else { return }
        endNudgeBurst()
        apply(parameter, mode: .single) { _ in value }
    }

    /// A keyboard nudge by `steps` units (±1, ±10 with Shift). Consecutive nudges of the same
    /// parameter and targets merge into one undo step.
    func nudge(_ parameter: InspectorParameter, steps: Double) {
        guard canEdit(), isAvailable(parameter) else { return }
        let group = "inspector.nudge.\(parameter.rawValue).\(targetKey(parameter))"
        if engine.coalescingKey != group {
            endNudgeBurst()
            engine.beginCoalescing(withKey: group, mode: .accumulate)
            store.nudgeGroup = group
        }
        apply(parameter, mode: .burst(group)) { $0 + steps }
        scheduleBurstEnd(group)
    }

    /// Closes the nudge burst's undo step (also done after `burstIdleSeconds`).
    func endNudgeBurst() {
        burstEnd?.cancel()
        burstEnd = nil
        if let group = store.nudgeGroup, engine.coalescingKey == group {
            engine.endCoalescing()
        }
        store.nudgeGroup = nil
    }

    func beginSliderDrag(_ parameter: InspectorParameter) {
        guard canEdit(), isAvailable(parameter) else { return }
        endNudgeBurst()
        let group = "inspector.slider.\(parameter.rawValue).\(targetKey(parameter))"
        engine.beginCoalescing(withKey: group)
        sliderGroup = group
        sliderInterrupted = false
    }

    /// A slider value: a step of the drag in progress, or (the slider moved by its keys, with
    /// no drag) a nudge-like edit that joins the current burst.
    func sliderChanged(_ parameter: InspectorParameter, _ value: Double) {
        if let group = sliderGroup {
            apply(parameter, mode: .slider(group)) { _ in value }
        } else if !sliderInterrupted, canEdit(), isAvailable(parameter) {
            let group = "inspector.nudge.\(parameter.rawValue).\(targetKey(parameter))"
            if engine.coalescingKey != group {
                endNudgeBurst()
                engine.beginCoalescing(withKey: group, mode: .accumulate)
                store.nudgeGroup = group
            }
            apply(parameter, mode: .burst(group)) { _ in value }
            scheduleBurstEnd(group)
        }
    }

    /// Ends the slider drag (release, or the inspector going away mid-drag: what the drag did
    /// is kept as its undo step).
    func endSliderDrag() {
        if let group = sliderGroup, engine.coalescingKey == group {
            engine.endCoalescing()
        }
        sliderGroup = nil
        sliderInterrupted = false
    }

    /// Resets one parameter on every target.
    func reset(_ parameter: InspectorParameter) {
        guard isAvailable(parameter) else { return }
        if parameter == .transitionDuration {
            setValue(parameter, Double(store.editingPreferences.transitionFrames(frameDuration: store.frameDuration)))
        } else {
            setValue(parameter, parameter.defaultValue)
        }
    }

    /// Resets a whole section on every target (one undo step); a Video reset also removes the
    /// clips' Motion keyframes.
    func reset(_ section: InspectorSection) {
        guard canEdit() else { return }
        endNudgeBurst()
        switch section {
        case .video:
            let batch = VEClipParamsBatch()
            for clip in videoTargets {
                batch.setVideoParams(VEVideoParamsIdentity(), clearingKeyframesForClip: clip.clipID)
            }
            guard batch.count > 0 else { return }
            handle(engine.applyClipParams(batch), mode: .single, clampNote: nil)
        case .audio:
            let batch = VEClipParamsBatch()
            for clip in audioTargets { batch.setAudioParams(VEAudioParamsDefault(), forClip: clip.clipID) }
            guard batch.count > 0 else { return }
            handle(engine.applyClipParams(batch), mode: .single, clampNote: nil)
        case .speed:
            reset(InspectorParameter.speed)
        case .transition:
            reset(.transitionDuration)
        }
    }

    func clearMessage() {
        message = nil
    }

    // MARK: Keyframes

    /// Whether the Motion keyframe controls apply to `parameter` (a Video parameter with a single
    /// video clip selected).
    func hasKeyframeControls(_ parameter: InspectorParameter) -> Bool {
        parameter.motionParameter != nil && motionTarget != nil
    }

    /// Whether the single video clip animates `parameter`.
    func isAnimated(_ parameter: InspectorParameter) -> Bool {
        guard let motion = parameter.motionParameter, let clip = motionTarget else { return false }
        return clip.isAnimated(motion)
    }

    /// The keyframe of `parameter` the frame under the playhead shows, if any.
    func keyframeAtPlayhead(_ parameter: InspectorParameter) -> VEKeyframe? {
        guard let motion = parameter.motionParameter, let clip = motionTarget else { return nil }
        return clip.keyframe(for: motion, at: store.playheadTime)
    }

    /// Whether the playhead is over the single video clip (keyframes are set on its frames).
    var playheadIsOverMotionTarget: Bool {
        guard let clip = motionTarget else { return false }
        let t = store.playheadTime
        return clip.timelineStart <= t && t < clip.timelineEnd
    }

    /// The frames (timeline times) of `parameter`'s keyframes that the clip shows, in order.
    func keyframeFrames(_ parameter: InspectorParameter) -> [CMTime] {
        guard let motion = parameter.motionParameter, let clip = motionTarget else { return [] }
        return clip.keyframes(for: motion).filter(\.isInsideClip).map(\.frameTime)
    }

    /// The nearest keyframe frame before the playhead's frame, or nil.
    func previousKeyframeTime(_ parameter: InspectorParameter) -> CMTime? {
        let playhead = store.frameTime(store.playheadTime.secondsOrZero)
        return keyframeFrames(parameter).last { $0 < playhead }
    }

    /// The nearest keyframe frame after the playhead's frame, or nil.
    func nextKeyframeTime(_ parameter: InspectorParameter) -> CMTime? {
        let playhead = store.frameTime(store.playheadTime.secondsOrZero)
        return keyframeFrames(parameter).first { $0 > playhead }
    }

    /// Moves the playhead to the previous (`forward` false) or next keyframe of `parameter`.
    func goToKeyframe(_ parameter: InspectorParameter, forward: Bool) {
        guard let time = forward ? nextKeyframeTime(parameter) : previousKeyframeTime(parameter) else { return }
        store.playheadTime = time
    }

    /// The keyframe toggle: removes the keyframe under the playhead, or adds one there with the
    /// value the parameter has (the picture does not change). One undo step.
    func toggleKeyframe(_ parameter: InspectorParameter) {
        guard canEdit(), let motion = parameter.motionParameter, let clip = motionTarget else { return }
        endNudgeBurst()
        let time = store.playheadTime
        let result = keyframeAtPlayhead(parameter) != nil
            ? engine.removeKeyframe(clip: clip.clipID, parameter: motion, at: time)
            : engine.addKeyframe(clip: clip.clipID, parameter: motion, at: time)
        handle(result, mode: .single, clampNote: nil)
    }

    /// Everything the keyframe controls of `parameter` show (nil when it has none: not a Video
    /// parameter, or not a single video clip).
    func keyframeControlState(_ parameter: InspectorParameter) -> KeyframeControlState? {
        guard hasKeyframeControls(parameter) else { return nil }
        let keyframe = keyframeAtPlayhead(parameter)
        return KeyframeControlState(hasKeyframeAtPlayhead: keyframe != nil, interpolation: keyframe?.interpolation,
                                    isAnimated: isAnimated(parameter),
                                    hasPrevious: previousKeyframeTime(parameter) != nil,
                                    hasNext: nextKeyframeTime(parameter) != nil)
    }

    /// The interpolation of the keyframe under the playhead (nil when there is none).
    func interpolation(_ parameter: InspectorParameter) -> VEKeyframeInterpolation? {
        keyframeAtPlayhead(parameter)?.interpolation
    }

    /// Sets the interpolation of the keyframe under the playhead. One undo step.
    func setInterpolation(_ interpolation: VEKeyframeInterpolation, for parameter: InspectorParameter) {
        guard canEdit(), let motion = parameter.motionParameter, let clip = motionTarget else { return }
        endNudgeBurst()
        handle(engine.setKeyframeInterpolation(interpolation, parameter: motion, clip: clip.clipID,
                                               at: store.playheadTime),
               mode: .single, clampNote: nil)
    }

    /// Removes every keyframe of `parameter` (Premiere's stopwatch off): it keeps the value it has
    /// at the playhead. One undo step.
    func removeAnimation(_ parameter: InspectorParameter) {
        guard canEdit(), let motion = parameter.motionParameter, let clip = motionTarget else { return }
        endNudgeBurst()
        handle(engine.removeAnimation(clip: clip.clipID, parameter: motion, at: store.playheadTime),
               mode: .single, clampNote: nil)
    }

    // MARK: Neighbours

    /// The clip touching the single video clip at `edge` on its track (the previous one ending where
    /// it starts, the next one starting where it ends), or nil.
    func adjacentClip(_ edge: VEClipEdge) -> VEClipInfo? {
        motionTarget.flatMap { store.adjacentClip(to: $0.clipID, at: edge) }
    }

    /// Whether "Match Previous Clip's End" (`.start`) or "Match Next Clip's Start" (`.end`) applies.
    func canMatch(_ edge: VEClipEdge) -> Bool {
        adjacentClip(edge) != nil
    }

    /// Copies the touching neighbour's position, scale, rotation and opacity at the cut (as its
    /// boundary frame shows them) onto the single video clip's first (`.start`) or last (`.end`)
    /// frame: a keyframe there for what the clip animates, its static value for the rest (the note
    /// says which). One undo step; refused during a gesture.
    func matchAdjacent(_ edge: VEClipEdge) {
        guard let clip = motionTarget else { return }
        guard !store.isGestureActive else {
            message = "Finish the current drag first."
            store.statusMessage = message
            return
        }
        endNudgeBurst()
        handle(engine.matchMotion(clip: clip.clipID, toAdjacentAt: edge), mode: .single, clampNote: nil)
    }

    /// The Transition section's Delete buttons: remove the selected transition (with its linked
    /// transition unless `includingLinked` is false) whichever panel has the focus (Delete in the
    /// media bin removes an asset instead).
    func deleteTransition(includingLinked: Bool = true) {
        guard let transition else { return }
        endNudgeBurst()
        if !store.removeTransition(transition.transitionID, includingLinked: includingLinked) {
            message = store.statusMessage
        }
    }

    // MARK: Implementation

    enum Mode: Equatable {
        case single
        case burst(String)
        case slider(String)
    }

    /// Edits are refused while a timeline drag or another inspector drag is in progress.
    private func canEdit() -> Bool {
        if store.cancelActiveGesture != nil {
            message = "Finish the timeline drag first."
            return false
        }
        return true
    }

    private func targetKey(_ parameter: InspectorParameter) -> String {
        switch parameter.section {
        case .video: return videoTargets.map { String($0.clipID) }.joined(separator: ",")
        case .audio: return audioTargets.map { String($0.clipID) }.joined(separator: ",")
        case .speed: return speedTarget.map { String($0.clipID) } ?? ""
        case .transition: return transition.map { String($0.transitionID) } ?? ""
        }
    }

    private func scheduleBurstEnd(_ group: String) {
        burstEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.store.nudgeGroup == group else { return }
                self.endNudgeBurst()
            }
        }
        burstEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstIdleSeconds, execute: work)
    }

    /// Applies `transform` (current value -> new value, display units) to every target.
    private func apply(_ parameter: InspectorParameter, mode: Mode, transform: (Double) -> Double) {
        switch parameter.section {
        case .video, .audio:
            applyClipParameter(parameter, mode: mode, transform: transform)
        case .speed:
            guard let clip = speedTarget else { return }
            let bounds = range(.speed)
            let requested = transform(value(.speed, of: clip))
            let percent = min(bounds.upperBound, max(bounds.lowerBound, requested))
            guard let ratio = SpeedRatio.approximating(percent / 100) else { return }
            applySpeed(ratio, mode: mode, clampNote: percent != requested ? limitNote(.speed, bounds) : nil)
        case .transition:
            applyTransitionDuration(mode: mode, transform: transform)
        }
    }

    private func applyClipParameter(_ parameter: InspectorParameter, mode: Mode, transform: (Double) -> Double) {
        if let motion = parameter.motionParameter {
            let targets = videoTargets
            if let clip = motionTarget {
                applyMotion(parameter, motion, clip: clip, mode: mode, transform: transform)
                return
            }
            if targets.contains(where: { $0.isAnimated(motion) }) {
                message = "\(parameter.label) is animated on a selected clip: select that clip alone to change its keyframes."
                store.statusMessage = message
                return
            }
        }
        let batch = VEClipParamsBatch()
        var clamped = false
        let targets = parameter.section == .video ? videoTargets : audioTargets
        for clip in targets {
            let requested = transform(value(parameter, of: clip))
            var bounds = range(parameter)
            if parameter == .fadeIn || parameter == .fadeOut {
                // Each clip's own room: fadeIn + fadeOut <= duration.
                let other = value(parameter == .fadeIn ? .fadeOut : .fadeIn, of: clip)
                bounds = 0 ... max(0, Double(store.frames(clip.duration)) - other)
            }
            let newValue = min(bounds.upperBound, max(bounds.lowerBound, requested))
            if abs(newValue - requested) > 1e-9 { clamped = true }
            if parameter.section == .video {
                var params = clip.videoParams
                switch parameter {
                case .positionX: params.x = newValue
                case .positionY: params.y = newValue
                case .scale: params.scale = newValue / 100
                case .rotation: params.rotationDegrees = newValue
                case .opacity: params.opacity = newValue / 100
                default: break
                }
                batch.setVideoParams(params, forClip: clip.clipID)
            } else {
                var params = clip.audioParams
                switch parameter {
                case .gain: params.gainDb = newValue
                case .fadeIn: params.fadeInDuration = store.time(frames: Int64(newValue.rounded()))
                case .fadeOut: params.fadeOutDuration = store.time(frames: Int64(newValue.rounded()))
                default: break
                }
                batch.setAudioParams(params, forClip: clip.clipID)
            }
        }
        guard batch.count > 0 else { return }
        let note = clamped ? limitNote(parameter, range(parameter)) : nil
        handle(perform(mode) { self.engine.applyClipParams(batch) }, mode: mode, clampNote: note)
    }

    /// A Video value of the single video clip: its keyframe under the playhead (or a new one) when
    /// the parameter is animated, else its static value.
    private func applyMotion(_ parameter: InspectorParameter, _ motion: VEMotionParameter, clip: VEClipInfo,
                             mode: Mode, transform: (Double) -> Double) {
        let requested = transform(value(parameter, of: clip))
        let bounds = range(parameter)
        let newValue = min(bounds.upperBound, max(bounds.lowerBound, requested))
        let note = abs(newValue - requested) > 1e-9 ? limitNote(parameter, bounds) : nil
        let engineValue = newValue / parameter.displayFactor
        let time = store.playheadTime
        let id = clip.clipID
        handle(perform(mode) { self.engine.setMotionValue(engineValue, parameter: motion, clip: id, at: time) },
               mode: mode, clampNote: note)
    }

    private func applySpeed(_ ratio: SpeedRatio, mode: Mode, clampNote: String? = nil) {
        guard let clip = speedTarget else { return }
        if mode == .single { endNudgeBurst() }
        let scope = engine.rippleScope
        let result = perform(mode) {
            self.engine.setSpeedNumerator(ratio.numerator, denominator: ratio.denominator,
                                          forClips: [NSNumber(value: clip.clipID)], ripple: true, scope: scope)
        }
        handle(result, mode: mode, clampNote: clampNote)
    }

    private func applyTransitionDuration(mode: Mode, transform: (Double) -> Double) {
        guard let transition, let limit = transitionLimit else { return }
        let requested = transform(Double(store.frames(transition.duration))).rounded()
        var frames = Int64(max(1, min(requested, Double(Int32.max))))
        var note: String?
        if requested < 1 {
            note = "A transition is at least one frame long."
        }
        if frames > limit.maximumFrames, limit.maximumFrames > 0 {
            frames = limit.maximumFrames
            note = "Limited to \(store.durationString(frames: frames)): \(limit.reason)"
        }
        let length = store.time(frames: frames)
        let id = transition.transitionID
        // "Also change the linked transition" (remembered; on by default).
        let includingLinked = store.resizesLinkedTransitions
        handle(perform(mode) { self.engine.setDuration(length, forTransition: id, includingLinked: includingLinked) },
               mode: mode, clampNote: note)
    }

    private func perform(_ mode: Mode, _ edit: @escaping () -> VEEditResult) -> VEEditResult {
        switch mode {
        case .single:
            return edit()
        case let .burst(group), let .slider(group):
            return engine.performInCoalescingGroup(group) { edit() }
        }
    }

    /// Shows the outcome: a refusal or note in `message` and the status line. A plain success
    /// clears the inspector's own message but leaves the status line alone (it may show another
    /// component's message, such as a timeline drag's).
    private func handle(_ result: VEEditResult, mode: Mode, clampNote: String?) {
        if result.ok {
            let note = [clampNote, result.note.isEmpty ? nil : result.note].compactMap { $0 }.joined(separator: " ")
            message = note.isEmpty ? nil : note
            if let message {
                store.statusMessage = message
            }
            return
        }
        if result.errorCode == .busy {
            // Another edit ended this change's group (committing what it did): stop the gesture.
            switch mode {
            case .slider:
                sliderGroup = nil
                sliderInterrupted = true
            case .burst:
                store.nudgeGroup = nil
                burstEnd?.cancel()
                burstEnd = nil
            case .single:
                break
            }
            message = "Another edit interrupted this change (what it did so far is kept as its own undo step)."
        } else {
            message = result.message
        }
        store.statusMessage = message
    }

    private func limitNote(_ parameter: InspectorParameter, _ bounds: ClosedRange<Double>) -> String {
        if parameter.isDuration {
            return "\(parameter.label) is limited to \(format(parameter, bounds.lowerBound))–\(format(parameter, bounds.upperBound))."
        }
        return "\(parameter.label) is limited to \(format(parameter, bounds.lowerBound)) to \(format(parameter, bounds.upperBound))."
    }
}
