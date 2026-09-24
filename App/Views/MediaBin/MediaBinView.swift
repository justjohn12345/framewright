import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FramewrightEngine

/// The project's media: a grid of assets with thumbnails, name, duration and a codec/backend/
/// hardware badge. Import with the button, File > Import Media…, File > Import from Photos…, or by
/// dropping files from the Finder or photos and videos from Photos (file promises: received into
/// the project's Media folder, listed at the top while they arrive, each with Cancel). Drag an
/// asset to the timeline; double-click to open it in the source monitor.
struct MediaBinView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var thumbnails: ThumbnailCache
    @ObservedObject var incoming: IncomingMedia
    @State private var isDropTargeted = false

    init(store: ProjectStore) {
        self.store = store
        thumbnails = store.thumbnails
        incoming = store.incoming
    }

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !incoming.items.isEmpty {
                IncomingMediaList(incoming: incoming)
                Divider()
            }
            ScrollView {
                if store.assets.isEmpty && incoming.items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.assets, id: \.assetID) { asset in
                            AssetTileView(asset: asset, thumbnails: thumbnails,
                                          isSelected: store.selectedAssetID == asset.assetID)
                                .onTapGesture(count: 2) { store.showInSourceMonitor(asset.assetID) }
                                .onTapGesture {
                                    store.selectedAssetID = asset.assetID
                                    store.focusArea = .mediaBin
                                    store.reclaimKeyboardFocus()
                                }
                                .draggable(AssetReference(assetID: asset.assetID)) {
                                    AssetTileView(asset: asset, thumbnails: thumbnails, isSelected: true)
                                        .frame(width: 140)
                                }
                                .contextMenu {
                                    Button("Open in Source Monitor") { store.showInSourceMonitor(asset.assetID) }
                                    Divider()
                                    Button("Remove from Project") { store.removeAsset(asset.assetID) }
                                }
                        }
                    }
                    .padding(10)
                }
            }
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .onDrop(of: MediaDrop.types, delegate: MediaBinDropDelegate(store: store, isTargeted: $isDropTargeted))
        }
        .accessibilityIdentifier("MediaBin")
    }

    private var header: some View {
        HStack {
            Text("Media")
                .font(.headline)
            if store.isImporting {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                presentImportPanel(store: store)
            } label: {
                Label("Import", systemImage: "plus")
            }
            .help("Import media files (⌘I)")
            Button {
                if let id = store.selectedAssetID { store.removeAsset(id) }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(store.selectedAssetID == nil)
            .help("Remove the selected media from the project")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Drop media files or photos here\nor click Import.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// Drops on the media bin: files from the Finder and file promises from Photos (see `MediaDrop`).
/// The `handle...` methods take any `TimelineDropInfo`, so they are tested with a double.
@MainActor
struct MediaBinDropDelegate: DropDelegate {
    let store: ProjectStore
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool { handleValidate(info) }
    func dropEntered(info: DropInfo) { handleEntered(info) }
    func dropExited(info: DropInfo) { handleExited(info) }
    func performDrop(info: DropInfo) -> Bool {
        handlePerform(info, pasteboardPromises: { PasteboardFilePromise.fromDragPasteboard() })
    }

    func handleValidate(_ info: some TimelineDropInfo) -> Bool {
        MediaDrop.accepts(info)
    }

    func handleEntered(_ info: some TimelineDropInfo) {
        isTargeted = MediaDrop.accepts(info)
    }

    func handleExited(_ info: some TimelineDropInfo) {
        isTargeted = false
    }

    func handlePerform(_ info: some TimelineDropInfo, pasteboardPromises: () -> [PromisedFile] = { [] }) -> Bool {
        isTargeted = false
        return MediaDrop.perform(info, store: store, placement: nil, pasteboardPromises: pasteboardPromises)
    }
}

/// Media arriving from Photos: one row per item (name, progress or a spinner while the source
/// does not report it, the state, Cancel) and Cancel All.
struct IncomingMediaList: View {
    @ObservedObject var incoming: IncomingMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Receiving from Photos")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Cancel All") { incoming.cancelAll() }
                    .controlSize(.small)
                    .disabled(!incoming.items.contains { $0.state == .receiving })
                    .accessibilityIdentifier("CancelAllIncoming")
            }
            ForEach(incoming.items) { item in
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    switch item.state {
                    case .receiving:
                        if let fraction = item.fraction {
                            ProgressView(value: fraction)
                                .frame(width: 60)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Button {
                            incoming.cancel(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop waiting for “\(item.name)”")
                    case .received:
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .help("Received; imported with the rest of its batch")
                    case let .failed(reason):
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(reason)
                    case .cancelled:
                        Text("Cancelled").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("IncomingMedia")
    }
}

/// Shows the Open panel for media and imports the chosen files.
@MainActor
func presentImportPanel(store: ProjectStore) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.movie, .audio, .image, .audiovisualContent]
    panel.message = "Choose media to import"
    panel.prompt = "Import"
    if panel.runModal() == .OK {
        store.importMedia(panel.urls)
    }
}

/// One asset in the bin.
/// Redraw counters of the media bin (tests measure redraw budgets with them).
enum MediaBinDiagnostics {
    /// `AssetTileView` body evaluations.
    static var tileBodies = 0
}

struct AssetTileView: View {
    let asset: VEAssetInfo
    @ObservedObject var thumbnails: ThumbnailCache
    var isSelected: Bool

    static let thumbnailSize = 320

    var body: some View {
        let _ = MediaBinDiagnostics.tileBodies += 1
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.85))
                if asset.isMissing {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                } else if asset.hasVideo {
                    let _ = thumbnails.version
                    if let image = thumbnails.image(asset: asset.assetID, seconds: 0, maxDimension: Self.thumbnailSize) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundStyle(.green)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if !asset.isStill {
                    Text(Timecode.duration(asset.duration))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            Text(asset.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            badge
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .help(asset.routingReason.isEmpty ? asset.path : "\(asset.path)\n\(asset.routingReason)")
    }

    private var badge: some View {
        HStack(spacing: 4) {
            if !asset.codecName.isEmpty {
                Text(asset.codecName)
            }
            if !asset.backendName.isEmpty {
                Text(asset.backendName == "ffmpeg" ? "FFmpeg" : "Apple")
            }
            if asset.hasVideo, !asset.isStill {
                Text(asset.hardwareDecode ? "HW" : "SW")
                    .foregroundStyle(asset.hardwareDecode ? .green : .orange)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
