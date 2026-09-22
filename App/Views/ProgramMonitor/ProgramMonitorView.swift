import SwiftUI
import VidEditEngine

/// Program monitor: the sequence frame at the playhead, letterboxed in black.
struct ProgramMonitorView: View {
    /// Called once with the monitor's surface so the owner can attach a frame source.
    var attach: (VEPreviewView) -> Void = { _ in }

    var body: some View {
        PreviewViewRepresentable(isPlaying: false, configure: attach)
            .background(Color.black)
    }
}
