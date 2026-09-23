import Combine
import CoreMedia
import SwiftUI
import FramewrightEngine

/// Which tracks follow a speed change.
enum SpeedRipple: String, CaseIterable, Identifiable {
    /// Later clips on every unlocked track move by the change in duration (falls back to the
    /// synced tracks, with a note, when another track has a clip in the way).
    case allTracks
    /// Only the changed clips' tracks and their linked partners' tracks.
    case syncedTracks
    /// Nothing moves: a slower clip that would run into the next clip is refused.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTracks: return "Ripple all tracks"
        case .syncedTracks: return "Ripple the clips' own tracks"
        case .none: return "Don't ripple (leave a gap or refuse an overlap)"
        }
    }
}

/// The Speed/Duration sheet's logic (Clip > Speed/Duration…, Cmd+R): a speed typed as a
/// percentage or a ratio for the chosen clips, the duration that results, and the ripple choice.
@MainActor
final class SpeedDurationModel: ObservableObject {
    enum Entry: String, CaseIterable, Identifiable {
        case percent
        case ratio

        var id: String { rawValue }
        var title: String { self == .percent ? "Percent" : "Ratio" }
    }

    private unowned let store: ProjectStore
    let clipIDs: [VEClipID]
    @Published var entry: Entry {
        didSet {
            // Show the same speed in the new form.
            if entry != oldValue {
                text = Self.text(for: Self.parse(text, entry: oldValue) ?? firstSpeed, entry: entry)
            }
        }
    }

    @Published var text: String
    @Published var ripple: SpeedRipple
    /// Why the last Apply was refused, or why the text is not a speed; after a successful
    /// Apply, how the typed speed was adjusted to one the engine can store (if it was).
    @Published private(set) var message: String?
    private var preferencesForwarding: AnyCancellable?

    init(store: ProjectStore, clipIDs: [VEClipID]) {
        self.store = store
        self.clipIDs = clipIDs
        ripple = store.engine.rippleScope == .syncedTracks ? .syncedTracks : .allTracks
        let first = clipIDs.lazy.compactMap { store.clips[$0] }.first
        let speed = first.map { SpeedRatio(numerator: $0.speedNumerator, denominator: $0.speedDenominator) }
            ?? SpeedRatio(numerator: 1, denominator: 1)
        let exactPercent = 1000 % max(speed.denominator, 1) == 0
        let initialEntry: Entry = exactPercent ? .percent : .ratio
        entry = initialEntry
        text = Self.text(for: speed, entry: initialEntry)
        // The durations shown follow the duration display preference while the sheet is open.
        preferencesForwarding = store.preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var clips: [VEClipInfo] { clipIDs.compactMap { store.clips[$0] } }

    private var firstSpeed: SpeedRatio {
        clips.first.map { SpeedRatio(numerator: $0.speedNumerator, denominator: $0.speedDenominator) }
            ?? SpeedRatio(numerator: 1, denominator: 1)
    }

    static func text(for speed: SpeedRatio, entry: Entry) -> String {
        switch entry {
        case .percent:
            let percent = speed.percent
            if abs(percent - percent.rounded()) < 1e-9 { return String(format: "%.0f", percent) }
            return String(format: "%.1f", percent)
        case .ratio:
            return SpeedFormat.multiplier(numerator: speed.numerator, denominator: speed.denominator)
        }
    }

    /// The typed speed: in Percent mode a bare number is a percentage, in Ratio mode a
    /// multiplier; "%" and "x" suffixes and fractions ("1/3") work in both.
    var parsedSpeed: SpeedRatio? {
        Self.parse(text, entry: entry)
    }

    static func parse(_ text: String, entry: Entry) -> SpeedRatio? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if entry == .ratio, let value = Double(trimmed) {
            return SpeedRatio.approximating(value)
        }
        return SpeedRatio.parse(trimmed)
    }

    /// The typed speed as a multiplier (nil for a fraction, which is exact).
    static func typedMultiplier(_ text: String, entry: Entry) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if entry == .ratio, let value = Double(trimmed) {
            return value
        }
        return SpeedRatio.typedMultiplier(trimmed)
    }

    /// The first clip's duration now and (approximately: the engine also stops at the end of
    /// the media) at the typed speed, in sequence frames.
    var durations: (before: Int64, after: Int64)? {
        guard let clip = clips.first, let speed = parsedSpeed, speed.value > 0 else { return nil }
        let before = store.frames(clip.duration)
        let current = Double(clip.speedNumerator) / Double(max(clip.speedDenominator, 1))
        let frameSeconds = store.frameDuration.secondsOrZero
        guard frameSeconds > 0 else { return nil }
        let source = clip.duration.secondsOrZero * current
        let after = max(1, Int64((source / speed.value / frameSeconds + 1e-9).rounded(.down)))
        return (before, after)
    }

    var durationText: String {
        guard let durations else { return "—" }
        let after = store.durationString(frames: durations.after)
        let before = store.durationString(frames: durations.before)
        let others = clips.count > 1 ? " (first of \(clips.count) clips)" : ""
        return "\(before) → \(after)\(others)"
    }

    /// Applies the speed to every clip as one undo step. Returns true (and closes the sheet) on
    /// success; a refusal stays in `message`.
    @discardableResult
    func apply() -> Bool {
        guard let speed = parsedSpeed else {
            message = "“\(text)” is not a speed. Type a percentage (50) or a ratio (0.5, 1/3)."
            return false
        }
        guard !store.isGestureActive else {
            message = "Finish the current drag first."
            return false
        }
        let ids = clipIDs.map { NSNumber(value: $0) }
        let result = store.engine.setSpeedNumerator(speed.numerator, denominator: speed.denominator, forClips: ids,
                                                    ripple: ripple != .none,
                                                    scope: ripple == .syncedTracks ? .syncedTracks : .allTracks)
        guard store.report(result) else {
            message = result.message
            return false
        }
        // "33.33" is applied as 1/3: say so (the sheet closes, so in the status line too).
        let adjusted = Self.typedMultiplier(text, entry: entry).flatMap {
            SpeedRatio.adjustmentNote(typed: $0, applied: speed)
        }
        message = adjusted
        if let adjusted {
            store.statusMessage = [adjusted, result.note.isEmpty ? nil : result.note].compactMap { $0 }
                .joined(separator: " ")
        }
        store.speedSheetClipIDs = nil
        return true
    }

    func cancel() {
        store.speedSheetClipIDs = nil
    }
}

/// Clip > Speed/Duration… (Cmd+R).
struct SpeedDurationSheet: View {
    @ObservedObject var model: SpeedDurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.clips.count == 1 ? "Speed/Duration" : "Speed/Duration of \(model.clips.count) Clips")
                .font(.headline)
            Picker("Speed as", selection: $model.entry) {
                ForEach(SpeedDurationModel.Entry.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Speed")
                TextField(model.entry == .percent ? "100" : "1", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit { model.apply() }
                    .accessibilityIdentifier("SpeedField")
                Text(model.entry == .percent ? "%" : "×")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Duration").foregroundStyle(.secondary)
                Text(model.durationText).monospacedDigit()
            }
            .font(.callout)
            Picker("Later clips", selection: $model.ripple) {
                ForEach(SpeedRipple.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { model.apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
