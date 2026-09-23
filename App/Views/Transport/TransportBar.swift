import CoreMedia
import SwiftUI
import FramewrightEngine

/// Transport controls under the monitors: program timecode, go to start/end, frame steps,
/// J/K/L shuttle and play/pause (for the focused monitor, see `PlaybackActions`), mute, zoom and
/// the last edit message.
struct TransportBar: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        HStack(spacing: 10) {
            TransportTimecode(playhead: store.playhead, frameDuration: store.frameDuration)
            Text("/ " + Timecode.string(store.sequence.duration, frameDuration: store.frameDuration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            TransportButtons(store: store, playhead: store.playhead, sourcePlayhead: store.sourcePlayhead)
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
            ZoomSlider(store: store, viewport: store.viewport)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The program timecode (observes only the playhead).
private struct TransportTimecode: View {
    @ObservedObject var playhead: PlayheadModel
    let frameDuration: CMTime

    var body: some View {
        Text(Timecode.string(playhead.time, frameDuration: frameDuration))
            .font(.system(.title3, design: .monospaced))
            .accessibilityIdentifier("PlayheadTimecode")
    }
}

private struct TransportButtons: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var playhead: PlayheadModel
    @ObservedObject var sourcePlayhead: PlayheadModel
    @State private var muted = false

    var body: some View {
        let actions = store.playbackActions
        HStack(spacing: 10) {
            Button { actions.goToStart() } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start (Home)")
            Button { actions.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Back one frame (←)")
            Button { actions.shuttleReverse() } label: { Image(systemName: "backward.fill") }
                .help(store.isExporting ? EnginePlaybackActions.exportingMessage
                                        : "Play backwards; repeat to go faster (J)")
                .disabled(store.isExporting)
            Button { actions.togglePlay() } label: {
                Image(systemName: actions.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .help(store.isExporting ? EnginePlaybackActions.exportingMessage : "Play/Pause (Space)")
            .disabled(store.isExporting && !actions.isPlaying)
            .accessibilityIdentifier("PlayPause")
            Button { actions.shuttleForward() } label: { Image(systemName: "forward.fill") }
                .help(store.isExporting ? EnginePlaybackActions.exportingMessage
                                        : "Play forwards; repeat to go faster (L)")
                .disabled(store.isExporting)
            Button { actions.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Forward one frame (→)")
            Button { actions.goToEnd() } label: { Image(systemName: "forward.end.fill") }
                .help("Go to end (End)")
            if actions.isPlaying, abs(currentRate - 1) > 1e-9 {
                Text(String(format: "%gx", currentRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                muted.toggle()
                store.engine.isMuted = muted
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(muted ? "Unmute" : "Mute")
            if !playhead.errorMessage.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(playhead.errorMessage)
            }
        }
        .onAppear { muted = store.engine.isMuted }
    }

    private var currentRate: Double {
        store.focusArea == .sourceMonitor && store.source.assetID != nil ? sourcePlayhead.rate : playhead.rate
    }
}

private struct ZoomSlider: View {
    let store: ProjectStore
    @ObservedObject var viewport: TimelineViewport

    var body: some View {
        Slider(value: Binding(
            get: { log(viewport.pixelsPerSecond) },
            set: { newValue in
                let factor = exp(newValue) / viewport.pixelsPerSecond
                store.zoom(by: factor, anchorX: store.timelineModel.x(forTime: store.playheadTime.secondsOrZero))
            }
        ), in: log(TimelineViewModel.minPixelsPerSecond) ... log(TimelineViewModel.maxPixelsPerSecond))
            .frame(width: 140)
            .controlSize(.small)
            .help("Timeline zoom (⌘= / ⌘-)")
    }
}
