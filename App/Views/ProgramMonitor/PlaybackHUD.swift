import SwiftUI
import VidEditEngine

/// Debug HUD over the program monitor (View > Show Playback HUD): the playback controller's
/// counters (`VEPlaybackStats`) and the preview view's render state, refreshed four times a
/// second.
struct PlaybackHUD: View {
    /// UserDefaults key of the View menu toggle.
    static let defaultsKey = "showPlaybackHUD"

    let engine: VEEngine

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(Self.lines(stats: engine.playbackStats, status: engine.playbackStatus, view: engine.programView))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
                .accessibilityIdentifier("PlaybackHUD")
        }
        .allowsHitTesting(false)
    }

    /// The HUD text (also used by tests).
    static func lines(stats: VEPlaybackStats, status: VEPlaybackStatus, view: VEPreviewView?) -> String {
        var lines: [String] = []
        let state: String
        switch status.state {
        case .stopped: state = "stopped"
        case .prerolling: state = "pre-rolling"
        case .playing: state = "playing"
        case .scrubbing: state = "scrubbing"
        @unknown default: state = "?"
        }
        let clock: String
        switch stats.clockMode {
        case .stopped: clock = "stopped"
        case .audioSamples: clock = "audio"
        case .hostTime: clock = "host"
        @unknown default: clock = "?"
        }
        lines.append(String(format: "%@ %gx  t %.3f s  clock %@  %.1f fps", state, status.rate,
                            status.time.secondsOrZero, clock, stats.fps))
        lines.append("frames \(stats.presentedFrames)  dropped \(stats.droppedFrames)  late \(stats.lateFrames)"
            + "  holds \(stats.monotonicHolds)")
        lines.append(String(format: "cache hit %.0f%%  %.0f MB  queue %ld  map failures %llu", stats.cacheHitRate * 100,
                            Double(stats.cacheBytes) / 1_048_576, stats.decodeQueueDepth, stats.mapFailures))
        lines.append(String(format: "audio %@ %@  latency %.1f ms  underruns %llu (%llu frames)",
                            stats.audioOutputKind, stats.outputRunning ? "running" : "stopped",
                            stats.outputLatency * 1000, stats.audioUnderruns, stats.audioUnderrunFrames))
        for clip in stats.activeClips {
            let backend = clip.backendName.isEmpty ? "-" : clip.backendName
            lines.append("\(clip.isAudio ? "A" : "V") clip \(clip.clipID) asset \(clip.assetID): \(backend)"
                + (clip.isAudio ? "" : clip.hardware ? " hw" : " sw") + (clip.failed ? " FAILED" : ""))
        }
        if let view {
            lines.append("view: missing layers \(view.missingLayerCount)  skipped \(view.skippedLayerCount)"
                + "  rendered \(view.renderCount)")
            if let error = view.lastError {
                lines.append("view error: \(error.localizedDescription)")
            }
        }
        if !stats.errorMessage.isEmpty {
            lines.append("audio error: \(stats.errorMessage)")
        }
        return lines.joined(separator: "\n")
    }
}
