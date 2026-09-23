import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VidEditEngine

/// The project's media: a grid of assets with thumbnails, name, duration and a codec/backend/
/// hardware badge. Import with the button, File > Import Media… or by dropping files from the
/// Finder. Drag an asset to the timeline; double-click to open it in the source monitor.
struct MediaBinView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var thumbnails: ThumbnailCache
    @State private var isDropTargeted = false

    init(store: ProjectStore) {
        self.store = store
        thumbnails = store.thumbnails
    }

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if store.assets.isEmpty {
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
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                store.importMedia(files)
                return !files.isEmpty
            } isTargeted: { isDropTargeted = $0 }
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
            Text("Drop media files here\nor click Import.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
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
struct AssetTileView: View {
    let asset: VEAssetInfo
    @ObservedObject var thumbnails: ThumbnailCache
    var isSelected: Bool

    static let thumbnailSize = 320

    var body: some View {
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
