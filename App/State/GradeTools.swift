import Combine
import FramewrightEngine
import Foundation

/// The editing logic of the Colour tab's slice 2 tools (the colour wheels, the curves and the LUTs), over
/// the selection's video clips, as `InspectorModel` is for the inspector's rows: the values shown (agreeing or "mixed" across the
/// clips), and the edits, each one undo step: a wheel's colour or level dragged (a coalescing group from the
/// press to the release), a reset. Moving a wheel's colour over several clips keeps each clip's level and
/// the rest of its grade; moving its level keeps each colour (the engine's NaN fields).
///
/// The values it shows are read from the store's clips and selection, so a change of either (an edit made
/// here or anywhere else, an undo, another clip selected) is announced as a change of this model: the views
/// that observe only it (the curves, the LUTs) then show the clips as they now are, not as they were when the
/// view last drew.
@MainActor
final class GradeToolsModel: ObservableObject {
    private unowned let store: ProjectStore
    private var engine: VEEngine { store.engine }
    /// The coalescing group of the drag in progress, if any.
    private(set) var dragGroup: String?
    /// Announces the store's clips and selection changing as this model's change.
    private var storeForwarding: AnyCancellable?

    init(store: ProjectStore) {
        self.store = store
        storeForwarding = store.$clips.dropFirst().map { _ in () }
            .merge(with: store.$selection.dropFirst().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
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

    /// The curve the curve editor shows (per session).
    @Published var curveChannel: CurveChannel = .luma

    private func points(of clip: VEClipInfo, _ channel: CurveChannel) -> [CGPoint] {
        if let tone = channel.toneCurve {
            return clip.gradeCurvePoints(tone).map(\.pointValue)
        }
        if let hue = channel.hueCurve {
            return clip.gradeHueCurvePoints(hue).map(\.pointValue)
        }
        return []
    }

    /// `channel` as the clips have it: the first clip's points (what the editor shows) and whether the clips
    /// differ.
    func curve(_ channel: CurveChannel) -> (points: [CGPoint], mixed: Bool) {
        let targets = videoTargets
        guard let first = targets.first else { return ([], false) }
        let shown = points(of: first, channel)
        let mixed = targets.dropFirst().contains { points(of: $0, channel) != shown }
        return (shown, mixed)
    }

    /// Whether any target has a curve (tone or hue) that is not the identity.
    var anyCurveSet: Bool {
        videoTargets.contains { clip in CurveChannel.allCases.contains { !points(of: clip, $0).isEmpty } }
    }

    /// Starts a drag in the curve editor (a point moved, added or dragged out): one undo step.
    func beginCurveDrag(_ channel: CurveChannel) {
        openDragGroup("colour.curve.\(channel.rawValue)")
    }

    /// Sets `channel` to `points` on every target (inside the drag's group when one is open).
    func setCurve(_ channel: CurveChannel, _ points: [CGPoint]) {
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        let values = points.map { NSValue(point: $0) }
        let edit: () -> VEEditResult = {
            if let tone = channel.toneCurve {
                return self.engine.setGradeCurve(values, for: tone, clips: clips)
            }
            return self.engine.setGradeHueCurve(values, for: channel.hueCurve ?? .saturation, clips: clips)
        }
        if let group = dragGroup {
            report(engine.performInCoalescingGroup(group) { edit() })
        } else {
            report(edit())
        }
    }

    /// `channel` back to the identity on every target.
    func resetCurve(_ channel: CurveChannel) {
        endDrag()
        setCurve(channel, [])
    }

    /// Every curve (tone and hue) back to the identity on every target (one undo step, "Reset Curves").
    func resetCurves() {
        endDrag()
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        report(engine.resetGradeCurves(ofClips: clips))
    }

    // MARK: LUTs

    /// A LUT slot: the input conversion (before the grade) or the look (after it).
    enum LUTSlot {
        case input
        case look
    }

    /// The slot's LUT as the clips have it: the first clip's id ("" for none) and whether the clips differ.
    func lut(_ slot: LUTSlot) -> (id: String, mixed: Bool) {
        let ids = videoTargets.map { slot == .input ? $0.gradeInputLUTID : $0.gradeLookLUTID }
        guard let first = ids.first else { return ("", false) }
        return (first, ids.contains { $0 != first })
    }

    /// What to call the LUT of `id` ("None" for ""): the name of the file the user chose, without its extension
    /// (a .cube file's TITLE is often the name of the tool that wrote it, not of the LUT), else the engine's name
    /// for it (its TITLE) where the file's name is unknown.
    func lutName(_ id: String) -> String {
        guard !id.isEmpty else { return "None" }
        guard let info = engine.lut(withID: id) else { return "Unknown LUT" }
        let stem = (info.fileName as NSString).deletingPathExtension
        return stem.isEmpty ? info.displayName : stem
    }

    /// The look's strength as the clips with a look have it (the first's, 1 when none has a look), and
    /// whether they differ.
    var lookStrength: (value: Double, mixed: Bool) {
        let strengths = videoTargets.filter { !$0.gradeLookLUTID.isEmpty }.map(\.gradeLookStrength)
        guard let first = strengths.first else { return (1, false) }
        return (first, strengths.contains { $0 != first })
    }

    /// Imports the .cube file at `url` and sets it in `slot` on every target (one undo step). A file that
    /// cannot be read or is not a LUT says why in the status line and changes nothing; returns whether it was
    /// set.
    @discardableResult
    func importLUT(at url: URL, into slot: LUTSlot) -> Bool {
        endDrag()
        let info: VELUTInfo
        do {
            info = try engine.importLUT(at: url)
        } catch {
            store.statusMessage = error.localizedDescription
            return false
        }
        return setLUT(info.lutID, slot)
    }

    /// Sets `id` ("" removes) in `slot` on every target (one undo step).
    @discardableResult
    func setLUT(_ id: String, _ slot: LUTSlot) -> Bool {
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return false }
        let result = slot == .input ? engine.setGradeInputLUT(id, clips: clips) : engine.setGradeLook(id, clips: clips)
        report(result)
        return result.ok
    }

    /// Starts a drag of the look's strength slider (one undo step).
    func beginStrengthDrag() {
        openDragGroup("colour.lookStrength")
    }

    /// Sets the look's strength (0 to 1) on every target with a look.
    func setLookStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        let clips = videoTargets.map { NSNumber(value: $0.clipID) }
        guard !clips.isEmpty else { return }
        let value = min(1, max(0, strength))
        if let group = dragGroup {
            report(engine.performInCoalescingGroup(group) { self.engine.setGradeLookStrength(value, clips: clips) })
        } else {
            report(engine.setGradeLookStrength(value, clips: clips))
        }
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
