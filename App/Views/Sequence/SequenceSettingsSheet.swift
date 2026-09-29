import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import FramewrightEngine

/// The Sequence Settings sheet's logic (Sequence > Sequence Settings…): the frame size (common presets
/// or a custom even size), the frame rate (the engine's standard list), the audio sample rate, the
/// project's "Sharpen scaled-down sources" (VEEngine.sharpenScaledDownSources), what
/// applying them does to the clips (the engine's preview, re-read as the values change), the
/// confirmation before a change of size or frame rate is applied to a sequence with clips, and Apply
/// (one undo step).
@MainActor
final class SequenceSettingsModel: ObservableObject {
    struct SizePreset: Equatable {
        let title: String
        let width: Int
        let height: Int
    }

    /// The frame sizes offered, largest first; any other even size is typed as Custom.
    static let sizePresets: [SizePreset] = [
        SizePreset(title: "3840 × 2160 (4K UHD)", width: 3840, height: 2160),
        SizePreset(title: "2560 × 1440 (QHD)", width: 2560, height: 1440),
        SizePreset(title: "1920 × 1080 (Full HD)", width: 1920, height: 1080),
        SizePreset(title: "1280 × 720 (HD)", width: 1280, height: 720),
        SizePreset(title: "1080 × 1920 (vertical)", width: 1080, height: 1920),
        SizePreset(title: "1080 × 1080 (square)", width: 1080, height: 1080),
    ]
    static let standardSampleRates = [44100, 48000]
    /// What "Sharpen scaled-down sources" does (the sheet's and the export sheet's help).
    static let sharpenHelp = "A picture drawn smaller than 3/4 of its size (a 4K recording in a 1080p "
        + "sequence or export, any picture in a small monitor) gets a light unsharp mask after it is scaled "
        + "down, so fine text stays crisp. Monitors and export alike."

    /// The Frame size picker's value: a preset (index into sizePresets) or the custom fields.
    enum SizeChoice: Hashable {
        case preset(Int)
        case custom
    }

    private unowned let store: ProjectStore
    /// The frame rates offered: the engine's standard list, plus the sequence's own when it is none of
    /// them (a project made elsewhere), so the picker always shows a selection.
    let frameDurations: [CMTime]
    /// The sample rates offered, likewise.
    let sampleRates: [Int]

    @Published var sizeChoice: SizeChoice { didSet { refresh() } }
    @Published var widthText: String { didSet { refresh() } }
    @Published var heightText: String { didSet { refresh() } }
    /// Index into `frameDurations`.
    @Published var frameRateIndex: Int { didSet { refresh() } }
    @Published var audioSampleRate: Int { didSet { refresh() } }
    @Published var sharpenScaledDownSources: Bool { didSet { refresh() } }
    /// What applying the current values would do (nil while a custom side is not a number).
    @Published private(set) var preview: VESequenceSettingsPreview?
    /// The confirmation is up (Apply was pressed for a change that needs one).
    @Published var confirming = false
    /// Why the last Apply was refused.
    @Published private(set) var refusal: String?

    init(store: ProjectStore) {
        self.store = store
        let current = store.engine.sequenceSettings
        let standard = VEEngine.standardSequenceFrameDurations.map(\.timeValue)
        var durations = standard
        if !standard.contains(where: { CMTimeCompare($0, current.frameDuration) == 0 }) {
            durations.append(current.frameDuration)
        }
        frameDurations = durations
        sampleRates = Self.standardSampleRates.contains(current.audioSampleRate)
            ? Self.standardSampleRates
            : (Self.standardSampleRates + [current.audioSampleRate]).sorted()
        let presetIndex = Self.sizePresets.firstIndex {
            $0.width == current.width && $0.height == current.height
        }
        sizeChoice = presetIndex.map { .preset($0) } ?? .custom
        widthText = String(current.width)
        heightText = String(current.height)
        frameRateIndex = durations.firstIndex { CMTimeCompare($0, current.frameDuration) == 0 } ?? 0
        audioSampleRate = current.audioSampleRate
        sharpenScaledDownSources = current.sharpenScaledDownSources
        refresh()
    }

    // MARK: Values

    /// "29.97 fps", "Custom 15 fps" for a rate outside the standard list.
    func frameRateTitle(at index: Int) -> String {
        let name = VEEngine.name(for: frameDurations[index]) + " fps"
        let standard = VEEngine.standardSequenceFrameDurations.map(\.timeValue)
        return standard.contains { CMTimeCompare($0, frameDurations[index]) == 0 } ? name : "Custom " + name
    }

    static func sampleRateTitle(_ rate: Int) -> String {
        let kilohertz = Double(rate) / 1000
        return (kilohertz == kilohertz.rounded() ? String(format: "%.0f", kilohertz) : String(format: "%g", kilohertz))
            + " kHz"
    }

    /// The width and height the values ask for (nil while a custom side is not a whole number).
    var size: (width: Int, height: Int)? {
        switch sizeChoice {
        case let .preset(index):
            let preset = Self.sizePresets[index]
            return (preset.width, preset.height)
        case .custom:
            guard let width = Int(widthText.trimmingCharacters(in: .whitespaces)),
                  let height = Int(heightText.trimmingCharacters(in: .whitespaces)) else { return nil }
            return (width, height)
        }
    }

    var settings: VESequenceSettings? {
        guard let size else { return nil }
        return VESequenceSettings(width: size.width, height: size.height, frameDuration: frameDurations[frameRateIndex],
                                  audioSampleRate: audioSampleRate,
                                  sharpenScaledDownSources: sharpenScaledDownSources)
    }

    /// Why the values cannot be applied, or nil.
    var validationMessage: String? {
        guard settings != nil else { return "Type the width and height in pixels." }
        return preview?.refusal
    }

    /// The sentences naming what changes (empty when nothing does).
    var changes: [String] { preview?.changes ?? [] }

    var canApply: Bool {
        validationMessage == nil && (preview?.changesSettings ?? false) && !store.isGestureActive
    }

    /// The confirmation's text: every change, one per line.
    var confirmationMessage: String { changes.joined(separator: "\n") }

    private func refresh() {
        refusal = nil
        preview = settings.map { store.engine.previewSequenceSettings($0) }
    }

    // MARK: Actions

    /// Apply: asks first when the size or frame rate changes for a sequence with clips (the
    /// confirmation's Apply calls `confirm`), else applies. Returns whether the settings were applied.
    @discardableResult
    func apply() -> Bool {
        guard canApply else {
            refusal = store.isGestureActive ? "Finish the current drag first." : validationMessage
            return false
        }
        if preview?.needsConfirmation ?? false {
            confirming = true
            return false
        }
        return commit()
    }

    /// The confirmation's Apply.
    @discardableResult
    func confirm() -> Bool {
        confirming = false
        return commit()
    }

    private func commit() -> Bool {
        guard let settings else { return false }
        let result = store.engine.applySequenceSettings(settings)
        guard store.report(result) else {
            refusal = result.message
            return false
        }
        store.statusMessage = "Sequence settings: \(settings.width)×\(settings.height), "
            + "\(VEEngine.name(for: settings.frameDuration)) fps, \(Self.sampleRateTitle(settings.audioSampleRate))."
        store.sequenceSettingsModel = nil
        return true
    }

    func cancel() {
        store.sequenceSettingsModel = nil
    }
}

/// Sequence > Sequence Settings….
struct SequenceSettingsSheet: View {
    @ObservedObject var model: SequenceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sequence Settings").font(.headline)
            Form {
                Picker("Frame size", selection: $model.sizeChoice) {
                    ForEach(SequenceSettingsModel.sizePresets.indices, id: \.self) { index in
                        Text(SequenceSettingsModel.sizePresets[index].title).tag(SequenceSettingsModel.SizeChoice.preset(index))
                    }
                    Text("Custom").tag(SequenceSettingsModel.SizeChoice.custom)
                }
                .accessibilityIdentifier("SequenceFrameSize")
                if model.sizeChoice == .custom {
                    HStack {
                        TextField("Width", text: $model.widthText).frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $model.heightText).frame(width: 80)
                        Text("pixels (even numbers)").foregroundStyle(.secondary)
                    }
                }
                Picker("Frame rate", selection: $model.frameRateIndex) {
                    ForEach(model.frameDurations.indices, id: \.self) { Text(model.frameRateTitle(at: $0)).tag($0) }
                }
                .accessibilityIdentifier("SequenceFrameRate")
                Picker("Audio sample rate", selection: $model.audioSampleRate) {
                    ForEach(model.sampleRates, id: \.self) { Text(SequenceSettingsModel.sampleRateTitle($0)).tag($0) }
                }
                Toggle("Sharpen scaled-down sources", isOn: $model.sharpenScaledDownSources)
                    .help(SequenceSettingsModel.sharpenHelp)
                    .accessibilityIdentifier("SequenceSharpen")
            }
            if !model.changes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applying changes:").font(.callout).foregroundStyle(.secondary)
                    ForEach(model.changes, id: \.self) { change in
                        Text("• " + change)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("SequenceSettingsChanges")
            }
            if let message = model.refusal ?? model.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Change the sequence's clips?", isPresented: $model.confirming) {
            Button("Cancel", role: .cancel) { model.confirming = false }
            Button("Apply") { model.confirm() }
        } message: {
            Text(model.confirmationMessage)
        }
    }
}
