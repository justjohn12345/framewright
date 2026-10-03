import FramewrightEngine
import SwiftUI

/// The Colour tab of the right-hand panel: the grading tools for the selected video clips (titles and colour
/// mattes are not graded: the tab says so when they are selected and leaves them out). The basic grade
/// (the inspector's Colour rows, the same `ParameterSection`, so both places edit the one grade), the
/// colour wheels (lift, gamma, gain), the curves (luma, red, green, blue) and the LUTs (input, look).
///
/// Why a tab: three wheels with their level sliders need the panel's whole width and more height than the
/// inspector's sections leave beside Video, Audio and Speed (the curves and LUTs of later slices too). The
/// basic rows stay in the inspector as well, where the user found them in slice 1.
struct ColourPanel: View {
    @ObservedObject var store: ProjectStore
    let tools: GradeToolsModel

    init(store: ProjectStore) {
        self.store = store
        tools = store.gradeTools
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if tools.ungradedGenerated > 0 {
                    Label(tools.isAvailable ? "Titles and colour mattes are not graded: the selected ones are left out."
                        : "Titles and colour mattes are not graded.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ColourPanel.generatedNote")
                }
                if tools.isAvailable {
                    gradeHeader
                    ParameterSection(store: store, inspector: store.inspector, section: .colour, subtitle: nil)
                    wheels
                    Divider()
                    CurvesSection(tools: tools)
                    Divider()
                    LUTSection(tools: tools)
                } else if tools.ungradedGenerated == 0 {
                    Text("Select a video clip to grade it.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ColourPanel")
        .onDisappear { tools.endDrag() }
    }

    private var gradeHeader: some View {
        HStack {
            let count = tools.videoTargets.count
            Text(count == 1 ? "1 video clip" : "\(count) video clips")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") { store.copyGrade() }
                .disabled(!store.canCopyGrade)
                .help("Copy the grade of the selected clip, or the grade the selected clips share (⌥⌘C)")
            Button("Paste") { store.pasteGrade() }
                .disabled(!store.canPasteGrade)
                .help("Give the selected clips the copied grade (⌥⌘V)")
        }
        .controlSize(.small)
    }

    private var wheels: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wheels").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { tools.resetWheels() }
                    .controlSize(.small)
                    .disabled(!tools.anyWheelSet)
                    .help("Reset the lift, gamma and gain wheels of the selection")
                    .accessibilityIdentifier("ResetWheels")
            }
            // Always three across, as a grading panel has them (the wheels shrink with the panel).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach([VEGradeWheel.lift, .gamma, .gain], id: \.rawValue) { wheel in
                    let state = tools.wheel(wheel)
                    ColourWheelControl(wheel: wheel, tools: tools, value: state.value, colourMixed: state.colourMixed,
                                       levelMixed: state.levelMixed)
                }
            }
            Text("Lift moves the shadows, gamma the midtones, gain the highlights: drag a wheel's centre toward a "
                + "colour, its slider for brightness.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
