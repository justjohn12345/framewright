import SwiftUI
import VidEditEngine

/// Program monitor: the sequence frame at the playhead, letterboxed in black.
///
/// `attach` receives the monitor's `VEPreviewView` when it is created and again whenever
/// `attachID` changes; the app hands it to the engine (`ProjectStore.attachProgramView`), which
/// installs the still-frame source that shows the frame at the playhead. Pass the identity of
/// the object `attach` talks to (e.g. `ObjectIdentifier(store)`) as `attachID`, so a monitor
/// that SwiftUI keeps while the project changes is attached to the new one. PLAYBACK
/// INTEGRATION POINT: while playing, the playback controller installs its own frame source on
/// the same view and un-pauses it (`isPlaying`).
struct ProgramMonitorView: View {
    var isPlaying = false
    var attachID: AnyHashable?
    var attach: (VEPreviewView) -> Void = { _ in }

    var body: some View {
        PreviewViewRepresentable(isPlaying: isPlaying, configurationID: attachID, configure: attach)
            .background(Color.black)
    }
}
