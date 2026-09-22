import CoreMedia
import SwiftUI
import VidEditEngine

/// Source monitor: scrub the asset opened from the media bin, mark in/out (I/O keys or the
/// buttons) and place it at the playhead with Insert or Overwrite.
///
/// The picture is a thumbnail at the scrub time sized to the monitor (good enough until the
/// playback phase gives the source monitor its own frame source).
struct SourceMonitorView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var thumbnails: ThumbnailCache

    init(store: ProjectStore) {
        self.store = store
        thumbnails = store.thumbnails
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
            }
            GeometryReader { geometry in
                picture(size: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            scrubber
            controls
        }
        .padding(8)
        .accessibilityIdentifier("SourceMonitor")
    }

    private var currentAsset: VEAssetInfo? {
        store.source.assetID.flatMap { store.asset($0) }
    }

    /// Scrub times are quantized to the asset's frames (or 1/30 s) so repeated scrubbing hits
    /// the cache.
    private var frameSeconds: Double {
        let fd = currentAsset?.frameDuration.secondsOrZero ?? 0
        return fd > 0 ? fd : 1.0 / 30.0
    }

    @ViewBuilder
    private func picture(size: CGSize) -> some View {
        if let asset = currentAsset {
            if asset.hasVideo {
                let _ = thumbnails.version
                let maxDimension = min(1920, max(64, Int(max(size.width, size.height) * 2)))
                let seconds = asset.isStill ? 0 : (store.source.time.secondsOrZero / frameSeconds).rounded() * frameSeconds
                if let image = thumbnails.image(asset: asset.assetID, seconds: seconds, maxDimension: maxDimension)
                    ?? thumbnails.anyImage(asset: asset.assetID, maxDimension: maxDimension) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            } else {
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
            get: { store.source.time.secondsOrZero },
            set: { store.source.time = CMTime(seconds: $0, preferredTimescale: 600) }
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
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(Timecode.string(store.source.time, frameDuration: store.frameDuration))
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                Spacer(minLength: 4)
                Text("Marked \(markedDuration)")
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

    private var markedDuration: String {
        let start = store.source.inPoint?.secondsOrZero ?? 0
        let end = store.source.outPoint?.secondsOrZero ?? store.sourceDuration.secondsOrZero
        return Timecode.duration(CMTime(seconds: max(0, end - start), preferredTimescale: 600))
    }
}
