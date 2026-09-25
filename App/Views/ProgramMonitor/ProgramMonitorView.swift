import SwiftUI
import FramewrightEngine

/// Program monitor: the sequence frame at the playhead, letterboxed in black.
///
/// `attach` receives the monitor's `VEPreviewView` when it is created and again whenever
/// `attachID` changes; the app hands it to the engine (`ProjectStore.attachProgramView`), which
/// installs the playback controller's frame source. Pass the identity of the object `attach`
/// talks to (`ObjectIdentifier(store)`) as `attachID`, so a monitor that SwiftUI keeps while the
/// project changes is attached to the new one. `isPlaying` runs the view's display-link render
/// loop (playing or pre-rolling); while stopped the engine renders each new picture itself.
struct ProgramMonitorView: View {
    var isPlaying = false
    var attachID: AnyHashable?
    var attach: (VEPreviewView) -> Void = { _ in }

    var body: some View {
        PreviewViewRepresentable(isPlaying: isPlaying, configurationID: attachID, configure: attach)
            .background(Color.black)
    }
}

/// The program monitor wired to a store: runs while the program plays, shows the debug HUD when
/// enabled, and the Ken Burns editor of the selected Motion span over the picture, inset in its
/// margin (or the readout of a selected Fade or Gain span; see `ProgramMonitorLayout`). The picture
/// view itself observes only the playhead's transport state; the layout around it observes the
/// store for the editor. A click gives the program (timeline) the transport keys and takes keyboard
/// focus back from text fields.
struct ProgramMonitorHost: View {
    let store: ProjectStore
    @ObservedObject var playhead: PlayheadModel
    @AppStorage(PlaybackHUD.defaultsKey) private var showHUD = false

    var body: some View {
        ProgramMonitorLayout(store: store, showsHUD: showHUD) {
            ProgramMonitorView(isPlaying: playhead.isRunning, attachID: ObjectIdentifier(store)) { view in
                store.attachProgramView(view)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusArea = .timeline
            store.reclaimKeyboardFocus()
        }
    }
}
