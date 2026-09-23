import SwiftUI
import FramewrightEngine

/// SwiftUI host for the engine's Metal preview surface (`VEPreviewView`).
///
/// The view renders on its own thread; SwiftUI owns its lifetime and the paused state.
/// `configure` attaches the view to whoever supplies its frames (the engine's program frame
/// source via `VEEngine.attachProgramView`). It runs when the view is created and again
/// whenever `configurationID` changes, e.g. when the monitor is shown for a different project
/// (closures cannot be compared, so the caller names what the configuration depends on). With
/// the default `nil` it runs once.
struct PreviewViewRepresentable: NSViewRepresentable {
    /// Whether the display-link render loop runs (false while playback is stopped).
    var isPlaying: Bool = false
    /// Identity of what `configure` attaches the view to; a change re-runs `configure`.
    var configurationID: AnyHashable?
    var configure: (VEPreviewView) -> Void = { _ in }

    final class Coordinator {
        var configurationID: AnyHashable?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VEPreviewView {
        let view = VEPreviewView(frame: .zero)
        context.coordinator.configurationID = configurationID
        configure(view)
        view.isPaused = !isPlaying
        return view
    }

    func updateNSView(_ view: VEPreviewView, context: Context) {
        if context.coordinator.configurationID != configurationID {
            context.coordinator.configurationID = configurationID
            configure(view)
        }
        if view.isPaused == isPlaying {
            view.isPaused = !isPlaying
        }
    }
}
