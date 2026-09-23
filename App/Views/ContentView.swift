import SwiftUI
import FramewrightEngine

/// The editor window, laid out so the program monitor dominates (see `WindowLayoutModel`): the
/// media bin (left), the program monitor with the transport bar and, when shown, the source
/// monitor beside it (centre), the Inspector/Effects panel (right), and the timeline below, sized
/// to its tracks. The dividers between them can be dragged (the positions are remembered); a
/// double-click on the one above the timeline fits it to its tracks again.
struct ContentView: View {
    /// Version line, e.g. "Engine 0.1.0 · FFmpeg 7.1.5".
    static var versionText: String {
        "Engine \(VEEngine.engineVersion) · FFmpeg \(VEEngine.ffmpegVersion)"
    }

    /// The monitors keep at least this width between the side panels.
    static let minimumCentreWidth: CGFloat = 420

    @ObservedObject var store: ProjectStore
    @ObservedObject var documents: DocumentController
    @ObservedObject var layout: WindowLayoutModel

    /// Sizes when a divider drag began (drags are relative to them).
    @State private var dragStartBinWidth: CGFloat = 0
    @State private var dragStartInspectorWidth: CGFloat = 0
    @State private var dragStartTimelineHeight: CGFloat = 0
    @State private var dragStartSourceFraction: Double = 0

    init(store: ProjectStore, documents: DocumentController) {
        self.store = store
        self.documents = documents
        layout = store.layout
    }

    var body: some View {
        GeometryReader { window in
            let timelineHeight = layout.timelineHeight(contentHeight: store.timelineContentHeight,
                                                       windowHeight: window.size.height)
            let sides = sideWidths(windowWidth: window.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    mediaColumn
                        .frame(width: sides.bin)
                    PaneDivider(orientation: .vertical, onBegin: { dragStartBinWidth = sides.bin },
                                onDrag: { layout.setMediaBinWidth(dragStartBinWidth + $0) })
                    monitorColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    PaneDivider(orientation: .vertical, onBegin: { dragStartInspectorWidth = sides.inspector },
                                onDrag: { layout.setInspectorWidth(dragStartInspectorWidth - $0) })
                    InspectorPanel(store: store)
                        .frame(width: sides.inspector)
                }
                .frame(maxHeight: .infinity)
                PaneDivider(orientation: .horizontal, onBegin: { dragStartTimelineHeight = timelineHeight },
                            onDrag: { layout.setTimelineHeight(dragStartTimelineHeight - $0,
                                                               windowHeight: window.size.height) },
                            onDoubleClick: { layout.fitTimelineToContent() })
                    .help("Drag to resize the timeline; double-click to fit it to its tracks")
                TimelineView(store: store)
                    .frame(height: timelineHeight)
            }
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

    /// The bin and inspector widths, narrowed (inspector first, then the bin) when the window is
    /// too narrow to leave the monitors `minimumCentreWidth`.
    private func sideWidths(windowWidth: CGFloat) -> (bin: CGFloat, inspector: CGFloat) {
        let dividers = 2 * WindowLayoutModel.dividerThickness
        var bin = layout.mediaBinWidth
        var inspector = layout.inspectorWidth
        var excess = bin + inspector + dividers + Self.minimumCentreWidth - windowWidth
        if excess > 0 {
            let cut = min(excess, inspector - WindowLayoutModel.inspectorWidths.lowerBound)
            inspector -= cut
            excess -= cut
        }
        if excess > 0 {
            bin -= min(excess, bin - WindowLayoutModel.mediaBinWidths.lowerBound)
        }
        return (bin, inspector)
    }

    private var mediaColumn: some View {
        VStack(spacing: 0) {
            MediaBinView(store: store)
            Text(Self.versionText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(4)
        }
    }

    /// The program monitor (the full width while the source monitor is hidden) and the transport.
    private var monitorColumn: some View {
        VStack(spacing: 0) {
            GeometryReader { area in
                let sourceWidth = area.size.width * CGFloat(layout.sourceMonitorFraction)
                HStack(spacing: 0) {
                    if layout.showsSourceMonitor {
                        SourceMonitorView(store: store)
                            .frame(width: sourceWidth)
                        PaneDivider(orientation: .vertical,
                                    onBegin: { dragStartSourceFraction = layout.sourceMonitorFraction },
                                    onDrag: { dx in
                                        guard area.size.width > 0 else { return }
                                        layout.setSourceMonitorFraction(dragStartSourceFraction + Double(dx / area.size.width))
                                    })
                    }
                    programMonitor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            TransportBar(store: store)
        }
    }

    private var programMonitor: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Program")
                    .font(.headline)
                Text(store.sequence.name)
                    .foregroundStyle(.secondary)
                Spacer()
                if !layout.showsSourceMonitor {
                    Button {
                        store.setSourceMonitorVisible(true)
                    } label: {
                        Label("Source", systemImage: "rectangle.lefthalf.inset.filled")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Show the source monitor (⇧⌘2)")
                    .accessibilityIdentifier("ShowSourceMonitor")
                }
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
