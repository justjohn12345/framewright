import FramewrightEngine
import SwiftUI

/// SwiftUI host for the engine's luma waveform surface (`VEWaveformView`). `attach` hands the view to
/// the engine when it is created; `detach` runs when SwiftUI removes it (the panel is hidden), so the
/// engine stops drawing into it.
struct WaveformViewRepresentable: NSViewRepresentable {
    var attach: (VEWaveformView) -> Void
    var detach: (VEWaveformView) -> Void

    final class Coordinator {
        var detach: (VEWaveformView) -> Void
        init(detach: @escaping (VEWaveformView) -> Void) {
            self.detach = detach
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(detach: detach)
    }

    func makeNSView(context: Context) -> VEWaveformView {
        let view = VEWaveformView(frame: .zero)
        attach(view)
        return view
    }

    func updateNSView(_ view: VEWaveformView, context: Context) {
        context.coordinator.detach = detach
    }

    static func dismantleNSView(_ view: VEWaveformView, coordinator: Coordinator) {
        coordinator.detach(view)
    }
}
