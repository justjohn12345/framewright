import SwiftUI
import VidEditEngine

/// The editor window: media bin (left), source and program monitors with the transport bar
/// (top centre), inspector (right) and the timeline (bottom).
struct ContentView: View {
    /// Version line, e.g. "Engine 0.1.0 · FFmpeg 7.1.5".
    static var versionText: String {
        "Engine \(VEEngine.engineVersion) · FFmpeg \(VEEngine.ffmpegVersion)"
    }

    @ObservedObject var store: ProjectStore
    @ObservedObject var documents: DocumentController

    var body: some View {
        VSplitView {
            HSplitView {
                VStack(spacing: 0) {
                    MediaBinView(store: store)
                    Divider()
                    TransitionsPanel(store: store)
                    Text(Self.versionText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(4)
                }
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)
                VStack(spacing: 0) {
                    HSplitView {
                        SourceMonitorView(store: store)
                            .frame(minWidth: 260, idealWidth: 420)
                        programMonitor
                            .frame(minWidth: 300, idealWidth: 480)
                    }
                    Divider()
                    TransportBar(store: store)
                }
                .frame(minWidth: 560)
                InspectorView(store: store)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
            }
            .frame(minHeight: 280, idealHeight: 420)
            TimelineView(store: store)
                .frame(minHeight: 200, idealHeight: 320)
        }
        .frame(minWidth: 1100, minHeight: 640)
        .sheet(isPresented: Binding(get: { store.speedSheetClipIDs != nil },
                                    set: { if !$0 { store.speedSheetClipIDs = nil } })) {
            if let ids = store.speedSheetClipIDs {
                SpeedDurationSheet(model: SpeedDurationModel(store: store, clipIDs: ids))
            }
        }
        .sheet(isPresented: Binding(get: { store.exportModel != nil },
                                    set: { presented in
                                        // The sheet only goes away when its model allows it (not
                                        // while exporting).
                                        if !presented, store.exportModel?.isExporting == false {
                                            store.exportModel = nil
                                        }
                                    })) {
            if let model = store.exportModel {
                ExportSheet(model: model)
                    .interactiveDismissDisabled(model.isExporting)
            }
        }
        .confirmationDialog("Also add a crossfade to the linked audio?",
                            isPresented: Binding(get: { store.pendingLinkedTransition != nil },
                                                 set: { presented in
                                                     // Dismissed without a choice (Escape, a click
                                                     // outside): cancel, after any button action.
                                                     guard !presented else { return }
                                                     DispatchQueue.main.async {
                                                         store.resolvePendingTransition(includeLinked: nil)
                                                     }
                                                 }),
                            titleVisibility: .visible) {
            Button("Add Dissolve and Crossfade") { store.resolvePendingTransition(includeLinked: true) }
            Button("Video Only") { store.resolvePendingTransition(includeLinked: false) }
            Button("Cancel", role: .cancel) { store.resolvePendingTransition(includeLinked: nil) }
        } message: {
            Text("The clips' linked audio also meets at this cut. Both transitions are added as one undo step. "
                + "(Settings > Editing decides whether to ask.)")
        }
        .background(
            WindowAccessor(title: store.projectName, representedURL: store.projectURL, isEdited: store.isDirty,
                           shouldClose: { documents.confirmClosingWindow() },
                           onWindow: { [weak store] window in store?.editorWindow = window })
        )
    }

    private var programMonitor: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Program")
                    .font(.headline)
                Text(store.sequence.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.sequence.width)×\(store.sequence.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgramMonitorHost(store: store, playhead: store.playhead)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityIdentifier("ProgramMonitor")
        }
        .padding(8)
    }
}
