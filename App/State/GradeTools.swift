import FramewrightEngine
import Foundation

/// The editing logic of the Colour tab's slice 2 tools (the colour wheels and the curves), over the
/// selection's video clips, as `InspectorModel` is for the inspector's rows: the values shown (agreeing or "mixed" across the
/// clips), and the edits, each one undo step: a wheel's colour or level dragged (a coalescing group from the
/// press to the release), a reset. Moving a wheel's colour over several clips keeps each clip's level and
/// the rest of its grade; moving its level keeps each colour (the engine's NaN fields).
@MainActor
final class GradeToolsModel: ObservableObject {
    private unowned let store: ProjectStore
    private var engine: VEEngine { store.engine }
    /// The coalescing group of the drag in progress, if any.
    private(set) var dragGroup: String?

    init(store: ProjectStore) {
        self.store = store
    }

    /// The clips the tools edit: the selection's clips on video tracks.
    var videoTargets: [VEClipInfo] { store.selectedClips.filter { $0.trackKind == .video } }

    /// Whether there is anything to grade.
    var isAvailable: Bool { !videoTargets.isEmpty }

    // MARK: Wheels

    /// `wheel` as the clips have it: the first clip's setting (what the control shows), and whether its
    /// colour and its level differ between the clips.
    func wheel(_ wheel: VEGradeWheel) -> (value: VEGradeWheelValue, colourMixed: Bool, levelMixed: Bool) {
        let targets = videoTargets
        guard let first = targets.first?.gradeWheel(wheel) else {
            return (VEGradeWheelValueNeutral(), false, false)
        }
        var colourMixed = false
        var levelMixed = false
        for clip in targets.dropFirst() {
            let value = clip.gradeWheel(wheel)
            colourMixed = colourMixed || value.cb != first.cb || value.cr != first.cr
            levelMixed = levelMixed || value.level != first.level
        }
        return (first, colourMixed, levelMixed)
    }

    /// The wheel's colour point (cb, cr) limited to the disk.
    static func limitedColour(cb: Double, cr: Double) -> (cb: Double, cr: Double) {
        guard cb.isFinite, cr.isFinite else { return (0, 0) }
        let radius = (cb * cb + cr * cr).squareRoot()
        guard radius > 1 else { return (cb, cr) }
        return (cb / radius, cr / radius)
    }

    /// Starts a drag of `wheel`'s colour or level: its steps make one undo step.
    func beginDrag(_ wheel: VEGradeWheel, part: String) {
        openDragGroup("colour.wheel.\(wheel.rawValue).\(part)")
    }

    /// Opens a coalescing group for a drag over the targets (refused while a timeline drag is in progress).
    private func openDragGroup(_ name: String) {
        guard isAvailable else { return }
        guard store.cancelActiveGesture == nil else {
            store.statusMessage = "Finish the timeline drag first."
            return
        }
        endDrag()
        let group = "\(name).\(videoTargets.map { String($0.clipID) }.joined(separator: ","))"
        engine.beginCoalescing(withKey: group)
        dragGroup = group
    }

    /// Ends the drag (what it did is its undo step).
    func endDrag() {
        if let group = dragGroup, engine.coalescingKey == group {
            engine.endCoalescing()
        }
        dragGroup = nil
    }

    /// Sets `wheel`'s colour on every target (inside the drag's group when one is open), keeping levels.
    func setColour(_ wheel: VEGradeWheel, cb: Double, cr: Double) {
        let colour = Self.limitedColour(cb: cb, cr: cr)
        apply(VEGradeWheelValue(level: .nan, cb: colour.cb, cr: colour.cr), wheel)
    }

    /// Sets `wheel`'s level on every target, keeping colours.
    func setLevel(_ wheel: VEGradeWheel, _ level: Double) {
        guard level.isFinite else { return }
        apply(VEGradeWheelValue(level: min(1, max(-1, level)), cb: .nan, cr: .nan), wheel)
    }

    /// Sets `wheel` neutral on every target (one undo step).
    func reset(_ wheel: VEGradeWheel) {
        endDrag()
        apply(VEGradeWheelValueNeutral(), wheel)
    }

    /// Every wheel neutral on every target (one undo step, "Reset Wheels").
    func resetWheels() {
        endDrag()
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        report(engine.resetGradeWheels(ofClips: clips))
    }

    /// Whether any target has a wheel set.
    var anyWheelSet: Bool {
        videoTargets.contains { clip in
            [VEGradeWheel.lift, .gamma, .gain].contains { wheel in
                let value = clip.gradeWheel(wheel)
                return value.level != 0 || value.cb != 0 || value.cr != 0
            }
        }
    }

    // MARK: Curves

    /// The curve the curve editor shows (Luma, Red, Green, Blue; per session).
    @Published var curveChannel: VEGradeCurve = .luma

    /// `curve` as the clips have it: the first clip's points (what the editor shows) and whether the clips
    /// differ.
    func curve(_ curve: VEGradeCurve) -> (points: [CGPoint], mixed: Bool) {
        let targets = videoTargets
        guard let first = targets.first else { return ([], false) }
        let points = first.gradeCurvePoints(curve).map(\.pointValue)
        let mixed = targets.dropFirst().contains { $0.gradeCurvePoints(curve).map(\.pointValue) != points }
        return (points, mixed)
    }

    /// Whether any target has a curve that is not the identity.
    var anyCurveSet: Bool {
        videoTargets.contains { clip in
            [VEGradeCurve.luma, .red, .green, .blue].contains { !clip.gradeCurvePoints($0).isEmpty }
        }
    }

    /// Starts a drag in the curve editor (a point moved, added or dragged out): one undo step.
    func beginCurveDrag(_ curve: VEGradeCurve) {
        openDragGroup("colour.curve.\(curve.rawValue)")
    }

    /// Sets `curve` to `points` on every target (inside the drag's group when one is open).
    func setCurve(_ curve: VEGradeCurve, _ points: [CGPoint]) {
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        let values = points.map { NSValue(point: $0) }
        if let group = dragGroup {
            report(engine.performInCoalescingGroup(group) { self.engine.setGradeCurve(values, for: curve, clips: clips) })
        } else {
            report(engine.setGradeCurve(values, for: curve, clips: clips))
        }
    }

    /// `curve` back to the identity on every target.
    func resetCurve(_ curve: VEGradeCurve) {
        endDrag()
        setCurve(curve, [])
    }

    /// Every curve back to the identity on every target (one undo step, "Reset Curves").
    func resetCurves() {
        endDrag()
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        report(engine.resetGradeCurves(ofClips: clips))
    }

    private func apply(_ value: VEGradeWheelValue, _ wheel: VEGradeWheel) {
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        let result: VEEditResult
        if let group = dragGroup {
            result = engine.performInCoalescingGroup(group) { self.engine.setGradeWheel(value, for: wheel, clips: clips) }
        } else {
            result = engine.setGradeWheel(value, for: wheel, clips: clips)
        }
        report(result)
    }

    private func report(_ result: VEEditResult) {
        if !result.ok {
            if result.errorCode == .busy {
                dragGroup = nil
                store.statusMessage = "Another edit interrupted this change (what it did so far is kept as its own undo step)."
            } else {
                store.statusMessage = result.message
            }
        }
    }
}
