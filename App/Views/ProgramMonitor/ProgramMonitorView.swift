import SwiftUI
import VidEditEngine

/// Program monitor: the sequence frame at the playhead, letterboxed in black.
///
/// `attach` receives the monitor's `VEPreviewView` once; the app hands it to the engine
/// (`ProjectStore.attachProgramView`), which installs the still-frame source that shows the frame
/// at the playhead. PLAYBACK INTEGRATION POINT: while playing, the playback controller installs
/// its own frame source on the same view and un-pauses it (`isPlaying`).
struct ProgramMonitorView: View {
    var isPlaying = false
    var attach: (VEPreviewView) -> Void = { _ in }

    var body: some View {
        PreviewViewRepresentable(isPlaying: isPlaying, configure: attach)
            .background(Color.black)
    }
}
