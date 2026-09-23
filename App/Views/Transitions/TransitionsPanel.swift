import SwiftUI
import VidEditEngine

/// The transitions of the MVP, to drag onto a cut between two adjacent clips in the timeline:
/// Cross Dissolve (video tracks) and Constant Power (audio crossfade). A double-click (or the
/// context menu) adds the transition at the cut nearest the playhead, like Shift+Cmd+D and
/// Option+Shift+Cmd+D. New transitions get the default duration (Settings > Editing), shortened
/// to what the cut's media allows.
struct TransitionsPanel: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transitions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(TransitionKind.allCases) { kind in
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .frame(width: 18)
                        .foregroundStyle(Color.purple)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title)
                        Text(kind.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                .contentShape(Rectangle())
                .draggable(TransitionReference(kind: kind)) {
                    Label(kind.title, systemImage: kind.systemImage)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.3)))
                }
                .onTapGesture(count: 2) { store.addTransitionAtPlayhead(kind) }
                .contextMenu {
                    Button("Add at Playhead") { store.addTransitionAtPlayhead(kind) }
                }
                .help("Drag onto a cut between two clips on a \(kind.trackKind == .video ? "video" : "audio") track")
                .accessibilityIdentifier("Transition.\(kind.rawValue)")
            }
        }
        .padding(8)
        .accessibilityIdentifier("TransitionsPanel")
    }
}
