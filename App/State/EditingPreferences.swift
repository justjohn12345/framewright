import CoreMedia
import Foundation

/// How durations are shown in the inspector, the timeline and the Speed/Duration sheet.
enum DurationDisplay: String, CaseIterable, Identifiable {
    /// "00:00:01:05" (non-drop-frame timecode).
    case timecode
    /// "35f".
    case frames
    /// "1.17 s".
    case seconds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timecode: return "Timecode (HH:MM:SS:FF)"
        case .frames: return "Frames"
        case .seconds: return "Seconds"
        }
    }
}

/// Whether adding a video dissolve also adds the crossfade on the linked audio's cut.
enum LinkedCrossfadeMode: String, CaseIterable, Identifiable {
    case always
    case never
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always"
        case .never: return "Never"
        case .ask: return "Ask each time"
        }
    }
}

/// The Editing preferences (Settings > Editing): a snapshot of their values.
struct EditingPreferences: Equatable {
    static let defaultTransitionSecondsKey = "defaultTransitionSeconds"
    static let linkedCrossfadeKey = "linkedCrossfade"
    static let durationDisplayKey = "durationDisplay"
    static let defaultTransitionSeconds = 1.0

    /// Default length of new transitions in seconds (the Transitions panel, Add Cross Dissolve).
    var transitionSeconds = Self.defaultTransitionSeconds
    var linkedCrossfade = LinkedCrossfadeMode.always
    var durationDisplay = DurationDisplay.timecode

    init() {}

    /// The values stored in `defaults` (a missing or invalid value reads as its default).
    init(defaults: UserDefaults) {
        let seconds = defaults.double(forKey: Self.defaultTransitionSecondsKey)
        transitionSeconds = seconds > 0 && seconds.isFinite ? seconds : Self.defaultTransitionSeconds
        linkedCrossfade = defaults.string(forKey: Self.linkedCrossfadeKey).flatMap(LinkedCrossfadeMode.init(rawValue:))
            ?? .always
        durationDisplay = defaults.string(forKey: Self.durationDisplayKey).flatMap(DurationDisplay.init(rawValue:))
            ?? .timecode
    }

    /// The default transition length in whole frames of `frameDuration` (at least one).
    func transitionFrames(frameDuration: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 30 }
        return max(1, Int64((transitionSeconds / frame).rounded()))
    }
}

/// The Editing preferences as observable state, so open views re-format when they change.
///
/// Mirrors the three keys of `defaults` in `current`, re-read whenever any user default changes
/// in this process (`UserDefaults.didChangeNotification`: the Settings window's `@AppStorage`
/// writes, or a test writing its own suite); a change posted on the main thread is applied before
/// the write returns. `revision` changes with every change of `current` (a redraw token for
/// canvases). Owned by `ProjectStore`, which forwards the changes to its own observers.
@MainActor
final class EditingPreferencesModel: ObservableObject {
    @Published private(set) var current: EditingPreferences
    @Published private(set) var revision = 0
    /// Where the preferences are read from (tests use their own suite); replacing it re-reads.
    var defaults: UserDefaults {
        didSet {
            if defaults !== oldValue { reload() }
        }
    }

    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = EditingPreferences(defaults: defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: nil) { [weak self] _ in
            // Delivered on the thread that wrote the default.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.reload() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reload() }
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-reads the preferences; publishes only when a value changed.
    func reload() {
        let fresh = EditingPreferences(defaults: defaults)
        guard fresh != current else { return }
        current = fresh
        revision &+= 1
    }
}

/// Durations as frame counts on a frame grid: display in the user's preferred form and parsing
/// of typed text with units.
enum DurationFormat {
    /// `frames` shown per `display`: "00:00:01:05", "35f" or "1.17 s".
    static func string(frames: Int64, frameDuration: CMTime, display: DurationDisplay) -> String {
        switch display {
        case .timecode:
            return Timecode.string(CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frames)),
                                   frameDuration: frameDuration)
        case .frames:
            return "\(frames)f"
        case .seconds:
            return String(format: "%.2f s", Double(frames) * frameDuration.secondsOrZero)
        }
    }

    /// A compact label for the timeline ("1:05", "35f", "1.17s").
    static func shortString(frames: Int64, frameDuration: CMTime, display: DurationDisplay) -> String {
        switch display {
        case .timecode:
            let fps = Int64(Timecode.framesPerSecond(frameDuration))
            let seconds = frames / fps
            let rest = frames % fps
            return seconds > 0 ? String(format: "%lld:%02lld", seconds, rest) : "\(rest)f"
        case .frames:
            return "\(frames)f"
        case .seconds:
            return String(format: "%.2fs", Double(frames) * frameDuration.secondsOrZero)
        }
    }

    /// Parses a typed duration into whole frames (seconds round to the nearest frame):
    /// "35f", "35 frames", "1.5s", "1.5 sec", timecode "00:00:01:05" or "1:05" (the last field is
    /// frames), or a bare number in the display's unit (frames for timecode and frames, seconds
    /// for seconds). Nil for text that is not a duration or is negative.
    static func parseFrames(_ text: String, frameDuration: CMTime, display: DurationDisplay) -> Int64? {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") || trimmed.contains(";") {
            let fields = trimmed.split(separator: ":", omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: ";", omittingEmptySubsequences: false) }
            guard fields.count >= 2, fields.count <= 4 else { return nil }
            var values: [Int64] = []
            for field in fields {
                guard let value = Int64(field.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
                values.append(value)
            }
            let fps = Int64(Timecode.framesPerSecond(frameDuration))
            let framesField = values.removeLast()
            var seconds: Int64 = 0
            for value in values { seconds = seconds * 60 + value }
            let (product, overflow) = seconds.multipliedReportingOverflow(by: fps)
            guard !overflow else { return nil }
            return product + framesField
        }
        let (number, unit) = splitNumber(trimmed)
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let inSeconds: Bool
        switch unit {
        case "":
            inSeconds = display == .seconds
        case "f", "fr", "frame", "frames":
            inSeconds = false
        case "s", "sec", "secs", "second", "seconds":
            inSeconds = true
        default:
            return nil
        }
        let frames = inSeconds ? value / frame : value
        guard frames < Double(Int32.max) else { return nil }
        return Int64(frames.rounded())
    }

    /// "12.5 dB" -> ("12.5", "db"): the leading number and the (lowercased, trimmed) rest.
    static func splitNumber(_ text: String) -> (number: String, unit: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var end = trimmed.startIndex
        for index in trimmed.indices {
            let character = trimmed[index]
            let isSign = (character == "-" || character == "+" || character == "−") && index == trimmed.startIndex
            if character.isNumber || character == "." || isSign {
                end = trimmed.index(after: index)
            } else {
                break
            }
        }
        let number = String(trimmed[trimmed.startIndex ..< end]).replacingOccurrences(of: "−", with: "-")
        let unit = trimmed[end...].trimmingCharacters(in: .whitespaces).lowercased()
        return (number, unit)
    }
}

/// An exact speed as a fraction (what the engine stores).
struct SpeedRatio: Equatable {
    var numerator: Int64
    var denominator: Int64

    var value: Double { Double(numerator) / Double(max(denominator, 1)) }
    var percent: Double { value * 100 }

    /// The best approximation of `value` with a denominator of at most `maxDenominator`
    /// (continued fractions), reduced. Nil for non-positive or non-finite values.
    static func approximating(_ value: Double, maxDenominator: Int64 = 1000) -> SpeedRatio? {
        guard value.isFinite, value > 0, value < 1e6 else { return nil }
        var (h0, h1): (Int64, Int64) = (0, 1)
        var (k0, k1): (Int64, Int64) = (1, 0)
        var x = value
        for _ in 0 ..< 64 {
            guard x < 1e15 else { break }
            let a = Int64(x.rounded(.down))
            let (ah, overflowH) = a.multipliedReportingOverflow(by: h1)
            let (ak, overflowK) = a.multipliedReportingOverflow(by: k1)
            guard !overflowH, !overflowK else { break }
            let (h2, overflowH2) = ah.addingReportingOverflow(h0)
            let (k2, overflowK2) = ak.addingReportingOverflow(k0)
            guard !overflowH2, !overflowK2, k2 <= maxDenominator else { break }
            (h0, h1) = (h1, h2)
            (k0, k1) = (k1, k2)
            let fraction = x - Double(a)
            if fraction < 1e-12 { break }
            x = 1 / fraction
        }
        guard h1 > 0, k1 > 0 else { return nil }
        return SpeedRatio(numerator: h1, denominator: k1).reduced
    }

    var reduced: SpeedRatio {
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }
        let divisor = max(1, gcd(abs(numerator), abs(denominator)))
        return SpeedRatio(numerator: numerator / divisor, denominator: denominator / divisor)
    }

    /// Parses a speed typed as a percentage ("50", "50%", "33.3 %") or a multiplier ("0.5x",
    /// "2×", "1/3"). Nil when not a positive number.
    static func parse(_ text: String) -> SpeedRatio? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let n = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                  let d = Int64(parts[1].trimmingCharacters(in: .whitespaces)), n > 0, d > 0 else { return nil }
            return SpeedRatio(numerator: n, denominator: d).reduced
        }
        let (number, unit) = DurationFormat.splitNumber(trimmed)
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        switch unit {
        case "", "%":
            // Exact for percentages with up to one decimal (denominator 1000).
            let tenths = (value * 10).rounded()
            if abs(tenths - value * 10) < 1e-9, tenths < Double(Int32.max) {
                return SpeedRatio(numerator: Int64(tenths), denominator: 1000).reduced
            }
            return approximating(value / 100)
        case "x", "×":
            return approximating(value)
        default:
            return nil
        }
    }

    /// The speed typed for `parse`, as a multiplier ("33.33" or "33.33 %" -> 0.3333, "0.5x" ->
    /// 0.5). Nil for a fraction ("1/3", exact by construction) and for text that is not a speed.
    static func typedMultiplier(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.contains("/") else { return nil }
        let (number, unit) = DurationFormat.splitNumber(trimmed)
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        switch unit {
        case "", "%": return value / 100
        case "x", "×": return value
        default: return nil
        }
    }

    /// Why an applied speed is not exactly the typed one (the engine stores fractions with a
    /// denominator of at most 1000): "Applied as 1/3 (33.33 %)". Nil when they agree.
    static func adjustmentNote(typed: Double, applied: SpeedRatio) -> String? {
        guard abs(applied.value - typed) > 1e-9 else { return nil }
        return String(format: "Applied as %lld/%lld (%.2f %%)", applied.numerator, applied.denominator, applied.percent)
    }
}
