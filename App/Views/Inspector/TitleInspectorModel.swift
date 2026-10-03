import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI

/// The inspector's editing logic for titles and colour mattes (titles design sections 9 and 10; slice 1): the
/// selected titles' text, font, outline, shadow and background, and the selected mattes' colour.
///
/// - Several titles: each control shows the value they agree on, or "Mixed" where they differ, and setting it sets
///   that parameter on all of them, keeping what differs (the grade's rule, `VEEngine.setTitle…`). The text can be
///   edited only with one title selected.
/// - Every control edit is one undo step. A slider drag is one coalescing group; a burst of keyboard nudges, or of
///   colour changes from the colour panel (which sends one per pointer movement), is one step, closed after
///   `InspectorModel.burstIdleSeconds` without another or by any other edit (`ProjectStore.nudgeGroup`, like the
///   inspector's nudges).
/// - A typing run is one undo step (`VECoalescingModeReplace`: every keystroke sets the whole text). It ends when
///   the text area loses the focus, the selection changes or another edit is made (the engine then ends its
///   group, and the next keystroke opens a new one). Undo during a run takes the run back as one step: the text
///   area has no undo of its own (`TitleTextView`), so ⌘Z reaches the engine, which ends the run first.
/// - Numbers are shown in the units an editor thinks in: sizes in sequence pixels (the engine stores fractions of
///   the frame, so a title looks the same in another sequence size), opacities in percent, the angle in degrees.
@MainActor
final class TitleInspectorModel: ObservableObject {
    /// Last refusal of a title edit (cleared by the next success).
    @Published private(set) var message: String?

    private unowned let store: ProjectStore
    /// The coalescing group of the slider drag in progress.
    private(set) var sliderGroup: String?
    private var sliderInterrupted = false
    private var burstEnd: DispatchWorkItem?
    /// The selection's titles and mattes, read from the engine once per model change and selection.
    private var selectionCache: (change: UInt64, ids: [VEClipID], selection: VETitleSelection)?

    /// The last text focus request (`InspectorFocusRequest.titleText`) the text area acted on.
    var handledTextFocus = 0
    /// The families of the installed fonts (the font popup), read again when the Mac's fonts change.
    @Published private(set) var families: [String] = []
    private var fontObserver: NSObjectProtocol?

    init(store: ProjectStore) {
        self.store = store
        families = Self.installedFamilies()
        fontObserver = NotificationCenter.default.addObserver(forName: .VEEngineTitleFontsDidChange, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.families = Self.installedFamilies()
                self.selectionCache = nil
            }
        }
    }

    deinit {
        if let fontObserver {
            NotificationCenter.default.removeObserver(fontObserver)
        }
    }

    private var engine: VEEngine { store.engine }

    // MARK: Targets

    /// The selected title clips, in timeline order.
    var titleTargets: [VEClipInfo] { store.selectedClips.filter { $0.generatorKind == .title } }
    /// The selected colour matte clips, in timeline order.
    var matteTargets: [VEClipInfo] { store.selectedClips.filter { $0.generatorKind == .colourMatte } }

    /// The title sections show when every selected video clip is a title (sound may be selected with them); with
    /// a title and another picture selected only the shared rows (Video) show.
    var showsTitleSections: Bool {
        let video = store.selectedClips.filter { $0.trackKind == .video }
        return !video.isEmpty && video.allSatisfy { $0.generatorKind == .title }
    }

    /// The matte's colour row shows when every selected video clip is a colour matte.
    var showsMatteSection: Bool {
        let video = store.selectedClips.filter { $0.trackKind == .video }
        return !video.isEmpty && video.allSatisfy { $0.generatorKind == .colourMatte }
    }

    private var titleIDs: [NSNumber] { titleTargets.map { NSNumber(value: $0.clipID) } }
    private var matteIDs: [NSNumber] { matteTargets.map { NSNumber(value: $0.clipID) } }
    private var targetKey: String { (titleTargets + matteTargets).map { String($0.clipID) }.joined(separator: ",") }

    /// What the selected titles and mattes have.
    var selection: VETitleSelection {
        let ids = (titleTargets + matteTargets).map(\.clipID)
        if let cached = selectionCache, cached.change == store.changeCount, cached.ids == ids {
            return cached.selection
        }
        let selection = engine.title(ofClips: ids.map { NSNumber(value: $0) })
        selectionCache = (store.changeCount, ids, selection)
        return selection
    }

    // MARK: Text

    /// The text can be edited with exactly one title selected.
    var canEditText: Bool { titleTargets.count == 1 }

    /// The selected title's text ("" with several).
    var text: String { canEditText ? (selection.firstTitle?.text ?? "") : "" }

    /// The typing run's coalescing group while one is open.
    private var typingGroup: String? {
        get { store.titleTypingGroup }
        set { store.titleTypingGroup = newValue }
    }

    /// A keystroke (or paste) in the text area: sets the whole text of the selected title, as a step of the typing
    /// run (one undo step for the run).
    func textChanged(_ text: String) {
        guard canEditText, text != self.text, canEdit() else { return }
        let ids = titleIDs
        let group = "title.text.\(ids.map(\.stringValue).joined(separator: ","))"
        func step() -> VEEditResult {
            if engine.coalescingKey != group {
                endBurst()
                endTyping()
                engine.beginCoalescing(withKey: group, mode: .replace)
                typingGroup = group
            }
            return engine.performInCoalescingGroup(group) { self.engine.setTitleText(text, clips: ids) }
        }
        var result = step()
        if result.errorCode == .busy {
            // Another edit ended the run (committing it as its own step): this keystroke starts a new run.
            typingGroup = nil
            result = step()
        }
        handle(result)
    }

    /// Ends the typing run (the text area lost the focus, the selection changed, or another control is used).
    func endTyping() {
        if let group = typingGroup, engine.coalescingKey == group {
            engine.endCoalescing()
        }
        typingGroup = nil
    }

    // MARK: Numbers

    static func info(_ parameter: VETitleParameter) -> VETitleParameterInfo {
        VETitleParameterInfo.info(for: parameter)
    }

    /// How many display units one engine unit is (sizes in sequence pixels, fractions in percent).
    func displayScale(_ parameter: VETitleParameter) -> Double {
        switch Self.info(parameter).unit {
        case .frameHeight: return Double(max(1, store.sequence.height))
        case .frameWidth: return Double(max(1, store.sequence.width))
        case .fraction: return 100
        default: return 1
        }
    }

    static func unitSuffix(_ parameter: VETitleParameter) -> String {
        switch info(parameter).unit {
        case .frameHeight, .frameWidth: return "px"
        case .fraction: return "%"
        case .degrees: return "°"
        case .multiple: return "×"
        default: return ""
        }
    }

    /// One keyboard nudge, in display units.
    static func nudgeStep(_ parameter: VETitleParameter) -> Double {
        info(parameter).unit == .multiple ? 0.05 : 1
    }

    /// The first selected title's value in display units (nil without titles).
    func value(_ parameter: VETitleParameter) -> Double? {
        guard let title = selection.firstTitle else { return nil }
        return title.number(parameter) * displayScale(parameter)
    }

    func isMixed(_ parameter: VETitleParameter) -> Bool { selection.isMixed(parameter) }

    /// The range of `parameter` in display units.
    func range(_ parameter: VETitleParameter) -> ClosedRange<Double> {
        let info = Self.info(parameter)
        let scale = displayScale(parameter)
        return info.minimum * scale ... info.maximum * scale
    }

    /// The field's text: the value with its unit, or "" where the titles differ (the field then shows "Mixed").
    func text(_ parameter: VETitleParameter) -> String {
        guard !isMixed(parameter), let value = value(parameter) else { return "" }
        return Self.format(parameter, value)
    }

    static func format(_ parameter: VETitleParameter, _ value: Double) -> String {
        let decimals = info(parameter).unit == .multiple ? 2 : 1
        var number = String(format: "%.\(decimals)f", value)
        while number.contains("."), number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        if number == "-0" { number = "0" }
        let suffix = unitSuffix(parameter)
        return suffix.isEmpty ? number : suffix == "°" ? number + suffix : "\(number) \(suffix)"
    }

    /// A typed value, with or without its unit, in display units; nil when it is not a number.
    static func parse(_ parameter: VETitleParameter, _ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        let suffix = unitSuffix(parameter)
        if !suffix.isEmpty, trimmed.hasSuffix(suffix) { trimmed.removeLast(suffix.count) }
        return Double(trimmed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// Typed text: parsed, clamped to the range, one undo step; invalid text is refused with a message.
    func commit(_ parameter: VETitleParameter, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let value = Self.parse(parameter, trimmed) else {
            let info = Self.info(parameter)
            message = "“\(trimmed)” is not a valid \(info.displayName.lowercased())"
                + (Self.unitSuffix(parameter).isEmpty ? "." : " in \(Self.unitSuffix(parameter)).")
            return
        }
        setNumber(parameter, value)
    }

    /// Sets `value` (display units, clamped) on every selected title, as one undo step.
    func setNumber(_ parameter: VETitleParameter, _ value: Double) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        handle(applyNumber(parameter, value))
    }

    /// A keyboard nudge by `steps` steps; a burst of them is one undo step.
    func nudge(_ parameter: VETitleParameter, steps: Double) {
        guard canEdit(), let current = value(parameter) else { return }
        let group = "title.nudge.\(parameter.rawValue).\(targetKey)"
        joinBurst(group)
        handle(engine.performInCoalescingGroup(group) {
            self.applyNumber(parameter, current + steps * Self.nudgeStep(parameter))
        })
        scheduleBurstEnd(group)
    }

    func beginSliderDrag(_ parameter: VETitleParameter) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        let group = "title.slider.\(parameter.rawValue).\(targetKey)"
        engine.beginCoalescing(withKey: group)
        sliderGroup = group
        sliderInterrupted = false
    }

    /// A slider value: a step of the drag in progress, or (the slider moved by its keys) a nudge-like edit.
    func sliderChanged(_ parameter: VETitleParameter, _ value: Double) {
        if let group = sliderGroup {
            handle(engine.performInCoalescingGroup(group) { self.applyNumber(parameter, value) })
        } else if !sliderInterrupted, canEdit() {
            let group = "title.nudge.\(parameter.rawValue).\(targetKey)"
            joinBurst(group)
            handle(engine.performInCoalescingGroup(group) { self.applyNumber(parameter, value) })
            scheduleBurstEnd(group)
        }
    }

    /// Ends the slider drag (release, or the inspector going away mid-drag: what the drag did is kept).
    func endSliderDrag() {
        if let group = sliderGroup, engine.coalescingKey == group {
            engine.endCoalescing()
        }
        sliderGroup = nil
        sliderInterrupted = false
    }

    private func applyNumber(_ parameter: VETitleParameter, _ display: Double) -> VEEditResult {
        let bounds = range(parameter)
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, display))
        return engine.setTitleNumber(clamped / displayScale(parameter), for: parameter, clips: titleIDs)
    }

    // MARK: Colours, toggles, alignment, font

    /// The first selected title's colour (nil without titles).
    func colour(_ parameter: VETitleParameter) -> VEColour? { selection.firstTitle?.colour(parameter) }

    /// A colour from the colour well: changes from the colour panel arrive one per pointer movement, so a run of
    /// them is one undo step.
    func setColour(_ parameter: VETitleParameter, _ colour: VEColour) {
        guard canEdit() else { return }
        let group = "title.colour.\(parameter.rawValue).\(targetKey)"
        joinBurst(group, mode: .replace)
        handle(engine.performInCoalescingGroup(group) {
            self.engine.setTitleColour(colour, for: parameter, clips: self.titleIDs)
        })
        scheduleBurstEnd(group)
    }

    /// The first selected title's toggle (nil without titles).
    func toggle(_ parameter: VETitleParameter) -> Bool? { selection.firstTitle?.toggle(parameter) }

    func setToggle(_ parameter: VETitleParameter, _ on: Bool) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        handle(engine.setTitleToggle(on, for: parameter, clips: titleIDs))
    }

    /// The titles' alignment (nil when they differ or there are none).
    var alignment: VETitleAlignment? {
        isMixed(.alignment) ? nil : selection.firstTitle?.alignment
    }

    func setAlignment(_ alignment: VETitleAlignment) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        handle(engine.setTitleAlignment(alignment, clips: titleIDs))
    }

    /// The titles' font (nil when they differ or there are none).
    var font: VETitleFont? {
        isMixed(.font) ? nil : selection.firstTitle?.font
    }

    func setFont(_ font: VETitleFont) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        handle(engine.setTitleFont(font, clips: titleIDs))
    }

    /// Sets every parameter of `section` back to its default on the selected titles, as one undo step.
    func reset(_ parameters: [VETitleParameter]) {
        guard canEdit() else { return }
        endBurst()
        endTyping()
        let ids = titleIDs
        guard !ids.isEmpty else { return }
        let group = "title.reset.\(targetKey)"
        engine.beginCoalescing(withKey: group, mode: .accumulate)
        var failure: VEEditResult?
        for parameter in parameters {
            let info = Self.info(parameter)
            let result = engine.performInCoalescingGroup(group) {
                switch info.type {
                case .number: return self.engine.setTitleNumber(info.defaultValue, for: parameter, clips: ids)
                case .toggle: return self.engine.setTitleToggle(info.defaultValue != 0, for: parameter, clips: ids)
                case .colour: return self.engine.setTitleColour(Self.defaultColour(parameter), for: parameter, clips: ids)
                case .choice: return self.engine.setTitleAlignment(.centre, clips: ids)
                case .font: return self.engine.setTitleFont(VETitleFont.system(weight: .semibold), clips: ids)
                default: return VEEditResult.success()
                }
            }
            if !result.ok, failure == nil { failure = result }
        }
        if engine.coalescingKey == group { engine.endCoalescing() }
        handle(failure ?? VEEditResult.success())
    }

    /// A colour parameter's default (the engine's TitleContent defaults: white text, black outline, shadow and box).
    static func defaultColour(_ parameter: VETitleParameter) -> VEColour {
        parameter == .fillColour ? VEColour(red: 1, green: 1, blue: 1) : VEColour(red: 0, green: 0, blue: 0)
    }

    // MARK: Matte

    /// The first selected matte's colour, and whether the mattes differ.
    var matteColour: VEColour { selection.matteColour }
    var isMatteColourMixed: Bool { selection.isMatteColourMixed }

    func setMatteColour(_ colour: VEColour) {
        guard canEdit() else { return }
        let group = "title.matte.\(targetKey)"
        joinBurst(group, mode: .replace)
        handle(engine.performInCoalescingGroup(group) { self.engine.setMatteColour(colour, clips: self.matteIDs) })
        scheduleBurstEnd(group)
    }

    // MARK: Fonts

    /// The families of the fonts installed on this Mac, sorted, for the font popup (System comes first there).
    static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// A family's styles: (PostScript name, style name), in the family's order.
    static func styles(ofFamily family: String) -> [(postScriptName: String, style: String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard member.count >= 2, let name = member[0] as? String, let style = member[1] as? String else { return nil }
            return (name, style)
        }
    }

    /// The font a family popup choice gives: the family's Regular style (or its first).
    static func font(forFamily family: String) -> VETitleFont? {
        let styles = styles(ofFamily: family)
        guard let chosen = styles.first(where: { $0.style == "Regular" }) ?? styles.first else { return nil }
        return VETitleFont.named(chosen.postScriptName, family: family, style: chosen.style)
    }

    static let systemWeights: [(weight: VESystemFontWeight, name: String)] = [
        (.ultraLight, "Ultralight"), (.thin, "Thin"), (.light, "Light"), (.regular, "Regular"), (.medium, "Medium"),
        (.semibold, "Semibold"), (.bold, "Bold"), (.heavy, "Heavy"), (.black, "Black"),
    ]

    // MARK: Messages

    func clearMessage() {
        message = nil
    }

    // MARK: Implementation

    /// Edits wait while a timeline drag is in progress.
    private func canEdit() -> Bool {
        if store.cancelActiveGesture != nil {
            message = "Finish the timeline drag first."
            return false
        }
        return true
    }

    /// Opens (or keeps) the burst `group`, ending another burst, the typing run and an inspector nudge burst first.
    private func joinBurst(_ group: String, mode: VECoalescingMode = .replace) {
        guard engine.coalescingKey != group else { return }
        endBurst()
        endTyping()
        store.inspector.endNudgeBurst()
        engine.beginCoalescing(withKey: group, mode: mode)
        store.nudgeGroup = group
    }

    private func scheduleBurstEnd(_ group: String) {
        burstEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.store.nudgeGroup == group else { return }
                self.endBurst()
            }
        }
        burstEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InspectorModel.burstIdleSeconds, execute: work)
    }

    /// Closes a burst of nudges or colour changes as its undo step.
    func endBurst() {
        burstEnd?.cancel()
        burstEnd = nil
        if let group = store.nudgeGroup, group.hasPrefix("title."), engine.coalescingKey == group {
            engine.endCoalescing()
            store.nudgeGroup = nil
        }
    }

    private func handle(_ result: VEEditResult) {
        if result.ok {
            message = nil
            return
        }
        if result.errorCode == .busy {
            if sliderGroup != nil {
                sliderGroup = nil
                sliderInterrupted = true
            }
            message = "Another edit interrupted this change (what it did so far is kept as its own undo step)."
        } else {
            message = result.message
        }
        store.statusMessage = message
    }
}
