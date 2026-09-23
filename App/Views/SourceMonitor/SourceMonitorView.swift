import CoreMedia
import SwiftUI
import FramewrightEngine

/// Source monitor: the asset opened from the media bin in the engine's own Metal preview
/// (decoded on the source monitor's lanes, nothing written to disk while scrubbing). Scrub with
/// the slider, play with Space/J/K/L while the monitor has focus (click it), mark in/out
/// (I/O keys or the buttons; snapped to the asset's frames) and place the marked range at the
/// playhead with Insert or Overwrite. Times show at the asset's own frame rate.
struct SourceMonitorView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var playhead: PlayheadModel

    init(store: ProjectStore) {
        self.store = store
        playhead = store.sourcePlayhead
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Source")
                    .font(.headline)
                if let asset = currentAsset {
                    Text(asset.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if store.focusArea == .sourceMonitor, currentAsset != nil {
                    Text("Space/J/K/L play the source")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ZStack {
                PreviewViewRepresentable(isPlaying: playhead.isRunning,
                                         configurationID: ObjectIdentifier(store)) { view in
                    store.attachSourceView(view)
                }
                overlay
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(store.focusArea == .sourceMonitor ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture {
                store.focusArea = .sourceMonitor
                store.reclaimKeyboardFocus()
            }
            scrubber
            controls
        }
        .padding(8)
        .accessibilityIdentifier("SourceMonitor")
    }

    private var currentAsset: VEAssetInfo? {
        store.source.assetID.flatMap { store.asset($0) }
    }

    @ViewBuilder
    private var overlay: some View {
        if let asset = currentAsset {
            if !asset.hasVideo {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }
        } else {
            Text("Double-click media in the bin to open it here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scrubber: some View {
        let duration = max(store.sourceDuration.secondsOrZero, 0.001)
        let binding = Binding<Double>(
            get: { playhead.time.secondsOrZero },
            set: { seconds in
                store.focusArea = .sourceMonitor
                store.scrubSource(to: CMTime(seconds: seconds, preferredTimescale: 600_000))
            }
        )
        return VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    if let inPoint = store.source.inPoint {
                        let start = CGFloat(inPoint.secondsOrZero / duration) * geometry.size.width
                        let end = CGFloat((store.source.outPoint?.secondsOrZero ?? duration) / duration) * geometry.size.width
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: max(1, end - start))
                            .offset(x: start)
                    } else if let outPoint = store.source.outPoint {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: CGFloat(outPoint.secondsOrZero / duration) * geometry.size.width)
                    }
                }
            }
            .frame(height: 4)
            Slider(value: binding, in: 0 ... duration)
                .controlSize(.small)
                .disabled(currentAsset == nil || currentAsset?.isStill == true)
        }
    }

    private var controls: some View {
        let frameDuration = store.sourceFrameDuration
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(Timecode.string(playhead.time, frameDuration: frameDuration))
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                    .accessibilityIdentifier("SourceTimecode")
                Button { store.focusArea = .sourceMonitor; store.playbackActions.togglePlay() } label: {
                    Image(systemName: playhead.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(currentAsset == nil || currentAsset?.isStill == true)
                .help("Play/Pause the source (Space while the source monitor has focus)")
                Spacer(minLength: 4)
                Text("Marked \(markedDuration(frameDuration: frameDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 6) {
                Button("Mark In") { store.markSourceIn() }
                    .help("Mark In (I)")
                    .fixedSize()
                Button("Mark Out") { store.markSourceOut() }
                    .help("Mark Out (O)")
                    .fixedSize()
                Spacer(minLength: 4)
                Button("Insert") { store.placeSource(overwrite: false) }
                    .help("Insert at the playhead on the target tracks, rippling later clips")
                    .fixedSize()
                Button("Overwrite") { store.placeSource(overwrite: true) }
                    .help("Overwrite at the playhead on the target tracks")
                    .fixedSize()
            }
        }
        .controlSize(.small)
        .disabled(currentAsset == nil)
    }

    private func markedDuration(frameDuration: CMTime) -> String {
        let start = store.source.inPoint ?? .zero
        let end = store.source.outPoint ?? store.sourceDuration
        return Timecode.string(CMTimeMaximum(.zero, CMTimeSubtract(end, start)), frameDuration: frameDuration)
    }
}
