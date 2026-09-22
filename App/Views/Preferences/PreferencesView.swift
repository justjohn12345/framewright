import SwiftUI
import VidEditEngine

/// Preference keys (UserDefaults) and applying them to the engine.
enum Preferences {
    static let preferredBackendKey = "preferredBackend"
    static let frameCacheMegabytesKey = "frameCacheMegabytes"
    static let defaultFrameCacheMegabytes = 512

    @MainActor
    static func apply(to engine: VEEngine, defaults: UserDefaults = .standard) {
        let backend = defaults.string(forKey: preferredBackendKey) ?? ""
        engine.preferredBackend = backend.isEmpty ? nil : backend
        let megabytes = defaults.integer(forKey: frameCacheMegabytesKey)
        engine.frameCacheBudgetBytes = UInt(megabytes > 0 ? megabytes : defaultFrameCacheMegabytes) << 20
    }
}

/// Settings window: hardware capabilities, decoder backend preference and frame cache size.
struct PreferencesView: View {
    let engine: VEEngine
    @AppStorage(Preferences.preferredBackendKey) private var preferredBackend = ""
    @AppStorage(Preferences.frameCacheMegabytesKey) private var frameCacheMegabytes = Preferences.defaultFrameCacheMegabytes

    var body: some View {
        TabView {
            hardwareTab
                .tabItem { Label("Hardware", systemImage: "cpu") }
            mediaTab
                .tabItem { Label("Media", systemImage: "film") }
        }
        .frame(width: 560, height: 360)
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
