import SwiftUI

/// The right-hand panel: the Inspector (the selection's properties) and Effects (the transitions
/// to drag onto a cut or add at the playhead with "+") as two tabs, like Premiere's Effect
/// Controls / Effects pair. The tab is remembered (`WindowLayoutModel.inspectorTab`); asking the
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
/// and added at the cut nearest the playhead with its "+" button.
struct EffectsPanel: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TransitionsPanel(store: store)
                Text("Drag a transition onto a cut between two clips, or press + to add it at the cut nearest the playhead.")
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
