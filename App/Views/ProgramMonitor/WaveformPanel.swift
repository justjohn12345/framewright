import FramewrightEngine
import SwiftUI

/// The luma waveform of the program monitor's picture (View > Show Waveform), beside the program
/// monitor: across, the frame's width; up, luma from 0 to 100 IRE, with the scale on its left. The
/// engine draws it with every frame the program monitor shows (`VEWaveformView`), so it follows the
/// playhead and plays along, showing the graded picture; SwiftUI only lays it out.
struct WaveformPanel: View {
    let store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Waveform")
                    .font(.headline)
                Text("Luma, IRE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.setWaveformVisible(false)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Hide the waveform")
                .accessibilityIdentifier("HideWaveform")
            }
            HStack(alignment: .top, spacing: 3) {
                scale
                WaveformViewRepresentable(attach: { store.attachWaveformView($0) },
                                          detach: { store.detachWaveformView($0) })
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityIdentifier("Waveform")
            }
        }
    }

    /// 100, 50 and 0 IRE beside the graticule's brighter lines.
    private var scale: some View {
        GeometryReader { area in
            ForEach([100, 50, 0], id: \.self) { ire in
                Text("\(ire)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: area.size.width / 2,
                              y: min(max(5, area.size.height * CGFloat(100 - ire) / 100), area.size.height - 5))
            }
        }
        .frame(width: 18)
    }
}
