import SwiftUI

/// The right-hand panel: the Inspector (the selection's properties) and Effects (the transitions to
/// drag onto a cut or a clip's free end, or add at the playhead with "+", and the lane effects, Ken
/// Burns, Move, Fade and Gain, to drag onto an effect lane) as two tabs, like Premiere's Effect Controls / Effects pair. The tab is remembered (`WindowLayoutModel.inspectorTab`); asking the
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
/// button; and the lane effects (Ken Burns, Move, Fade on video, Gain on audio), each draggable onto
/// an effect lane of a clip (lanes 1-3), where it becomes a span from the drop point (a Motion span
/// of 5 s, a Fade or Gain of the default transition length); Ken Burns and Move also have a "+" that
/// adds them at the playhead on the selected clip (like Clip > Add Ken Burns… and Add Motion Span).
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
                LaneEffectsPanel(store: store)
                Text("Drag an effect onto an effect lane under a clip (or onto the clip: the first lane with room), "
                    + "or press + to add Ken Burns or a Move at the playhead on the selected clip. Motion spans are "
                    + "also made by dragging across an empty lane of a video track, or with ⌃K.")
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

/// The effects that go on a clip's effect lanes: Ken Burns and Move (Motion spans on video, opened in
/// Ken Burns and Transform mode), Fade (an Opacity span on video) and Gain (an audio span), each a
/// drag source (`EffectReference`); Ken Burns and Move also add at the playhead with "+".
struct LaneEffectsPanel: View {
    @ObservedObject var store: ProjectStore

    private static func color(_ kind: EffectKind) -> Color {
        switch kind.spanKind {
        case .gain: return TimelineRenderer.color(.gain)
        case .motion: return TimelineRenderer.color(.motion)
        default: return TimelineRenderer.color(.opacity)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lane Effects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(EffectKind.allCases) { kind in
                row(kind)
            }
        }
        .padding(8)
        .accessibilityIdentifier("LaneEffectsPanel")
    }

    /// An effect's tile. The drag source is its icon and label only, and Ken Burns' and Move's "+"
    /// sits beside it (as in `TransitionsPanel`), so a click on the button is never taken for a drag.
    private func row(_ kind: EffectKind) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(Self.color(kind))
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.title)
                    Text(kind.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .draggable(EffectReference(kind: kind)) {
                Label(kind.title, systemImage: kind.systemImage)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.3)))
            }
            .help("Drag onto an effect lane of a \(kind.trackKind == .video ? "video" : "audio") clip")
            if let mode = kind.motionMode {
                Button {
                    store.addMotionSpanAtPlayhead(mode: mode)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!store.canAddMotionSpanAtPlayhead)
                .help("Add at the playhead on the selected clip")
                .accessibilityIdentifier("Effect.\(kind.rawValue).add")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
        .accessibilityIdentifier("Effect.\(kind.rawValue)")
    }
}
