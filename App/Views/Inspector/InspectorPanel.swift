import SwiftUI

/// The right-hand panel: the Inspector (the selection's properties) and Effects (the transitions to
/// drag onto a cut or a clip's free end, or add at the playhead with "+", and the Fade and Gain
/// effects to drag onto an effect lane) as two tabs, like Premiere's Effect Controls / Effects pair. The tab is remembered (`WindowLayoutModel.inspectorTab`); asking the
/// inspector to focus a field (double-clicking a transition) switches to the Inspector tab.
struct InspectorPanel: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var layout: WindowLayoutModel

    init(store: ProjectStore) {
        self.store = store
        layout = store.layout
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $layout.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .accessibilityIdentifier("InspectorTabs")
            Divider()
            switch layout.inspectorTab {
            case .inspector:
                InspectorView(store: store)
            case .effects:
                EffectsPanel(store: store)
            }
        }
    }
}

/// The Effects tab: the transitions (Cross Dissolve, Constant Power), each draggable onto a cut
/// (or a clip's free start or end: a fade) and added at the cut nearest the playhead with its "+"
/// button; and the lane effects (Fade on video, Gain on audio), each draggable onto an effect lane
/// of a clip (lanes 1-3), where it becomes a span of the default transition length from the drop
/// point.
struct EffectsPanel: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TransitionsPanel(store: store)
                Text("Drag a transition onto a cut between two clips (or a clip's free start or end to fade), or press "
                    + "+ to add it at the cut nearest the playhead. It goes on the track's lane 0.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                LaneEffectsPanel()
                Text("Drag an effect onto an effect lane under a clip (or onto the clip: the first lane with room). "
                    + "Motion spans are made by dragging across an empty lane of a video track, or with ⌃K.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("EffectsPanel")
    }
}

/// The effects that go on a clip's effect lanes: Fade (an Opacity span on video) and Gain (an audio
/// span), each a drag source (`EffectReference`).
struct LaneEffectsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lane Effects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(EffectKind.allCases) { kind in
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .frame(width: 18)
                        .foregroundStyle(TimelineRenderer.color(kind.spanKind == .gain ? .gain : .opacity))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title)
                        Text(kind.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                .contentShape(Rectangle())
                .draggable(EffectReference(kind: kind)) {
                    Label(kind.title, systemImage: kind.systemImage)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.3)))
                }
                .help("Drag onto an effect lane of a \(kind.trackKind == .video ? "video" : "audio") clip")
                .accessibilityIdentifier("Effect.\(kind.rawValue)")
            }
        }
        .padding(8)
        .accessibilityIdentifier("LaneEffectsPanel")
    }
}
