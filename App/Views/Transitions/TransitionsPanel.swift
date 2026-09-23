import SwiftUI
import VidEditEngine

/// The transitions of the MVP, to drag onto a cut between two adjacent clips in the timeline:
/// Cross Dissolve (video tracks) and Constant Power (audio crossfade). The "+" button next to a
/// transition (or its context menu) adds it at the cut nearest the playhead, like Shift+Cmd+D
/// and Option+Shift+Cmd+D; so does a double-click on the row outside its label. New transitions
/// get the default duration (Settings > Editing, shown below the list and re-formatted when the
/// duration display changes), shortened to what the cut's media allows.
///
/// The drag source is the transition's icon and label only, and the button sits beside it, so
/// adding at the playhead never depends on SwiftUI arbitrating a drag against a double-click
/// on the same view.
struct TransitionsPanel: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transitions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(TransitionKind.allCases) { kind in
                row(kind)
            }
            Text("New transitions: \(store.durationString(frames: defaultFrames))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("TransitionsPanel.defaultDuration")
        }
        .padding(8)
        .accessibilityIdentifier("TransitionsPanel")
    }

    private var defaultFrames: Int64 {
        store.editingPreferences.transitionFrames(frameDuration: store.frameDuration)
    }

    private func row(_ kind: TransitionKind) -> some View {
        HStack(spacing: 8) {
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
            }
            .contentShape(Rectangle())
            .draggable(TransitionReference(kind: kind)) {
                Label(kind.title, systemImage: kind.systemImage)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.3)))
            }
            .help("Drag onto a cut between two clips on a \(kind.trackKind == .video ? "video" : "audio") track")
            Spacer(minLength: 4)
            Button {
                store.addTransitionAtPlayhead(kind)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Add at the cut nearest the playhead")
            .accessibilityIdentifier("Transition.\(kind.rawValue).add")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.addTransitionAtPlayhead(kind) }
        .contextMenu {
            Button("Add at Playhead") { store.addTransitionAtPlayhead(kind) }
        }
        .accessibilityIdentifier("Transition.\(kind.rawValue)")
    }
}
