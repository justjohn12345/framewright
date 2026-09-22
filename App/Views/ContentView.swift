import SwiftUI
import VidEditEngine

struct ContentView: View {
    /// Version line shown under the title, e.g. "Engine 0.1.0 · FFmpeg 7.1.5".
    static var versionText: String {
        "Engine \(VEEngine.engineVersion) · FFmpeg \(VEEngine.ffmpegVersion)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("VidEdit")
                .font(.largeTitle)
            Text(Self.versionText)
                .font(.callout)
                .foregroundStyle(.secondary)
            ProgramMonitorView()
                .frame(minHeight: 240)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
    }
}
