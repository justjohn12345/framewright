import FramewrightEngine
import SwiftUI

/// SwiftUI host for the engine's scope surface (`VEWaveformView`: the waveform or the histogram). `attach`
/// hands the view to the engine when it is created; `detach` runs when SwiftUI removes it (the panel is
/// hidden), so the engine stops drawing into it. The mode and the histogram style are set on the view
/// whenever SwiftUI updates it (the view asks the program monitor for a frame when they change), and
/// `onClipping` hears the clipped shares the view publishes (on the main thread, at most ten times a
/// second).
struct WaveformViewRepresentable: NSViewRepresentable {
    var attach: (VEWaveformView) -> Void
    var detach: (VEWaveformView) -> Void
    var mode: VEScopeMode = .waveform
    var histogramStyle: VEHistogramStyle = .rgbAndLuma
    var onClipping: ((Double, Double) -> Void)?

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
        view.mode = mode
        view.histogramStyle = histogramStyle
        view.clippingHandler = onClipping
        attach(view)
        return view
    }

    func updateNSView(_ view: VEWaveformView, context: Context) {
        context.coordinator.detach = detach
        if view.mode != mode { view.mode = mode }
        if view.histogramStyle != histogramStyle { view.histogramStyle = histogramStyle }
        view.clippingHandler = onClipping
    }

    static func dismantleNSView(_ view: VEWaveformView, coordinator: Coordinator) {
        view.clippingHandler = nil
        coordinator.detach(view)
    }
}
