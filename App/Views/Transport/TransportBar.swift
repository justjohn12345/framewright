import SwiftUI
import VidEditEngine

/// Transport controls under the monitors: timecode, play/pause and frame steps, zoom, and the
/// last edit message.
///
/// Play/pause and shuttle go through `ProjectStore.playbackActions`, a no-op placeholder until
/// the playback controller is wired in (see `PlaybackActions`).
struct TransportBar: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        HStack(spacing: 10) {
            Text(Timecode.string(store.playheadTime, frameDuration: store.frameDuration))
                .font(.system(.title3, design: .monospaced))
                .accessibilityIdentifier("PlayheadTimecode")
            Text("/ " + Timecode.string(store.sequence.duration, frameDuration: store.frameDuration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Back one frame (←)")
            Button { store.playbackActions.togglePlay() } label: {
                Image(systemName: store.playbackActions.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play/Pause (Space). Playback arrives with the playback engine.")
            Button { store.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Forward one frame (→)")
            Spacer()
            if let message = store.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .help(message)
            }
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: zoomBinding, in: log(TimelineViewModel.minPixelsPerSecond) ... log(TimelineViewModel.maxPixelsPerSecond))
                .frame(width: 140)
                .controlSize(.small)
                .help("Timeline zoom (⌘= / ⌘-)")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(store.pixelsPerSecond) },
            set: { newValue in
                let factor = exp(newValue) / store.pixelsPerSecond
                store.zoom(by: factor, anchorX: store.timelineModel.x(forTime: store.playheadTime.secondsOrZero))
            }
        )
    }
}
