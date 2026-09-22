import SwiftUI
import VidEditEngine

/// SwiftUI host for the engine's Metal preview surface (`VEPreviewView`).
///
/// The view renders on its own thread; SwiftUI only owns its lifetime and the paused state.
/// `configure` runs once when the view is created, so the caller can attach a frame source
/// (the engine's program frame source via `VEEngine.attachProgramView`).
struct PreviewViewRepresentable: NSViewRepresentable {
    /// Whether the display-link render loop runs (false while playback is stopped).
    var isPlaying: Bool = false
    var configure: (VEPreviewView) -> Void = { _ in }

    func makeNSView(context: Context) -> VEPreviewView {
        let view = VEPreviewView(frame: .zero)
        configure(view)
        view.isPaused = !isPlaying
        return view
    }

    func updateNSView(_ view: VEPreviewView, context: Context) {
        if view.isPaused == isPlaying {
            view.isPaused = !isPlaying
        }
    }
}
