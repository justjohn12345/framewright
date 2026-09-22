import SwiftUI
import VidEditEngine

/// Program monitor: the sequence frame at the playhead, letterboxed in black.
///
/// PLACEHOLDER CONTENT: until the engine facade wires playback (phase 5), the monitor shows a
/// synthetic test pattern (two generated burn-in frames at 50 % opacity, the top one rotating
/// while "Animate" is on) so the Metal pipeline is visibly working end to end.
struct ProgramMonitorView: View {
    @State private var animate = true

    var body: some View {
        VStack(spacing: 6) {
            PreviewViewRepresentable(isPlaying: animate) { view in
                view.installPlaceholderTestSource()
            }
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                Text("Placeholder test pattern — real playback arrives with the engine facade")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            Toggle("Animate", isOn: $animate)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

#Preview {
    ProgramMonitorView()
        .frame(width: 640, height: 400)
}
