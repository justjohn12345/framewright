import SwiftUI
import FramewrightEngine

/// Preference keys (UserDefaults) and applying them to the engine.
enum Preferences {
    static let preferredBackendKey = "preferredBackend"
    static let frameCacheMegabytesKey = "frameCacheMegabytes"
    static let defaultFrameCacheMegabytes = 512
    /// "all" (every unlocked track, falling back to the synced tracks when another track is in
    /// the way) or "synced" (only the edited clips' tracks and their linked partners').
    static let rippleScopeKey = "rippleScope"

    @MainActor
    static func apply(to engine: VEEngine, defaults: UserDefaults = .standard) {
        let backend = defaults.string(forKey: preferredBackendKey) ?? ""
        engine.preferredBackend = backend.isEmpty ? nil : backend
        let megabytes = defaults.integer(forKey: frameCacheMegabytesKey)
        engine.frameCacheBudgetBytes = UInt(megabytes > 0 ? megabytes : defaultFrameCacheMegabytes) << 20
        engine.rippleScope = defaults.string(forKey: rippleScopeKey) == "synced" ? .syncedTracks : .allTracks
    }
}

/// Settings window: hardware capabilities, decoder backend preference and frame cache size.
struct PreferencesView: View {
    let engine: VEEngine
    @AppStorage(Preferences.preferredBackendKey) private var preferredBackend = ""
    @AppStorage(Preferences.frameCacheMegabytesKey) private var frameCacheMegabytes = Preferences.defaultFrameCacheMegabytes
    @AppStorage(Preferences.rippleScopeKey) private var rippleScope = "all"
    @AppStorage(EditingPreferences.defaultTransitionSecondsKey) private var transitionSeconds =
        EditingPreferences.defaultTransitionSeconds
    @AppStorage(EditingPreferences.linkedCrossfadeKey) private var linkedCrossfade = LinkedCrossfadeMode.always.rawValue
    @AppStorage(EditingPreferences.durationDisplayKey) private var durationDisplay = DurationDisplay.timecode.rawValue
    @AppStorage(LivePhotos.choiceKey) private var livePhotoImport = LivePhotoImportSetting.ask.rawValue

    var body: some View {
        TabView {
            hardwareTab
                .tabItem { Label("Hardware", systemImage: "cpu") }
            mediaTab
                .tabItem { Label("Media", systemImage: "film") }
            editingTab
                .tabItem { Label("Editing", systemImage: "scissors") }
        }
        .frame(width: 560, height: 440)
        .padding()
    }

    private var hardwareTab: some View {
        let caps = engine.hardwareCaps
        return VStack(alignment: .leading, spacing: 8) {
            Text("VideoToolbox capabilities of this Mac")
                .font(.headline)
            Table(caps.codecs.map(CodecRow.init)) {
                TableColumn("Codec") { Text($0.name.uppercased()) }
                TableColumn("Type") { Text($0.codecType).monospaced() }
                TableColumn("HW Decode") { YesNo(value: $0.hardwareDecode) }
                TableColumn("HW Encode") { YesNo(value: $0.hardwareEncode) }
                TableColumn("SW Encode") { YesNo(value: $0.softwareEncode) }
            }
        }
    }

    private var mediaTab: some View {
        Form {
            Picker("Decoder backend", selection: $preferredBackend) {
                Text("Automatic (recommended)").tag("")
                ForEach(engine.backendNames, id: \.self) { name in
                    Text(name == "ffmpeg" ? "Prefer FFmpeg" : "Prefer Apple (AVFoundation/VideoToolbox)").tag(name)
                }
            }
            .onChange(of: preferredBackend) { _, _ in Preferences.apply(to: engine) }
            Text("Applies to media imported or opened after the change.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Frame cache", selection: $frameCacheMegabytes) {
                ForEach([256, 512, 1024, 2048, 4096], id: \.self) { mb in
                    Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                }
            }
            .onChange(of: frameCacheMegabytes) { _, _ in Preferences.apply(to: engine) }
            Text("The audio output stays on for 5 minutes after the last playback, step or scrub (1 minute on "
                + "battery), so Space starts at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Live Photos", selection: $livePhotoImport) {
                ForEach(LivePhotoImportSetting.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .accessibilityIdentifier("LivePhotoImportSetting")
            Text("What to import from a Live Photo dropped from Photos or picked with Import from Photos: the "
                + "question asks each time, and its Remember my choice sets this.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PreferencesView {
    fileprivate var editingTab: some View {
        Form {
            Picker("Ripple edits move", selection: $rippleScope) {
                Text("All tracks (keeps everything in sync)").tag("all")
                Text("Only the edited clips’ tracks").tag("synced")
            }
            .onChange(of: rippleScope) { _, _ in Preferences.apply(to: engine) }
            Text("Ripple delete, speed changes and inserts shift later clips. With All tracks, when another "
                + "track has a clip in the way the edit ripples only the edited clips’ tracks and says so.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Section("Transitions") {
                HStack {
                    TextField("Default duration", value: $transitionSeconds,
                              format: .number.precision(.fractionLength(0 ... 2)))
                        .frame(width: 180)
                    Stepper("", value: $transitionSeconds, in: 0.1 ... 10, step: 0.5)
                        .labelsHidden()
                    Text("seconds")
                }
                Picker("Add the linked audio crossfade", selection: $linkedCrossfade) {
                    ForEach(LinkedCrossfadeMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("New transitions get this duration (rounded to whole frames), shortened when the clips "
                    + "lack media beyond the cut. A video dissolve on linked clips can also add the audio "
                    + "crossfade on their cut, as one undo step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Show durations as", selection: $durationDisplay) {
                ForEach(DurationDisplay.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("Fades and transition durations in the inspector and the timeline. Typed durations accept "
                + "12f, 0.5s or timecode in any mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Row of the capability table.
private struct CodecRow: Identifiable {
    let capability: VECodecCapability
    var id: String { capability.name }
    var name: String { capability.name }
    var codecType: String { capability.codecType }
    var hardwareDecode: Bool { capability.hardwareDecode }
    var hardwareEncode: Bool { capability.hardwareEncode }
    var softwareEncode: Bool { capability.softwareEncode }
}

private struct YesNo: View {
    let value: Bool
    var body: some View {
        Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(value ? .green : .secondary)
    }
}
