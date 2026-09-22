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
        .background(
            WindowAccessor(title: store.projectName, representedURL: store.projectURL, isEdited: store.isDirty,
                           shouldClose: { documents.confirmDiscardingChanges() })
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
            ProgramMonitorView { view in
                store.attachProgramView(view)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityIdentifier("ProgramMonitor")
        }
        .padding(8)
    }
}
