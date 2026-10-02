import AppKit
import FramewrightEngine
import SwiftUI
import UniformTypeIdentifiers

/// The LUTs section of the Colour tab: the input conversion (a .cube LUT applied before the grade: a camera's
/// log to Rec. 709, say) and the look (applied after the grade and the curves, at a strength). Choose… opens a
/// .cube file and sets it on the selected clips (the project keeps a copy, so the file is not needed later);
/// the cross removes it. A file that is not a LUT says why in the status line.
struct LUTSection: View {
    @ObservedObject var tools: GradeToolsModel

    /// The .cube file type (by its extension; no system type declares it).
    static var cubeType: UTType { UTType(filenameExtension: "cube") ?? .data }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LUTs").font(.subheadline.weight(.semibold))
            row("Input", slot: .input, help: "A LUT applied before the grade (a camera's log to Rec. 709)")
            row("Look", slot: .look, help: "A LUT applied after the grade and the curves")
            let strength = tools.lookStrength
            HStack {
                Text("Strength")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { strength.value }, set: { tools.setLookStrength($0) }), in: 0 ... 1,
                       onEditingChanged: { editing in
                           if editing { tools.beginStrengthDrag() } else { tools.endDrag() }
                       })
                       .controlSize(.small)
                       .accessibilityIdentifier("LookStrength")
                Text(strength.mixed ? "Mixed" : "\(Int((strength.value * 100).rounded())) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(tools.lut(.look).id.isEmpty && !tools.lut(.look).mixed)
        }
    }

    private func row(_ title: String, slot: GradeToolsModel.LUTSlot, help: String) -> some View {
        let state = tools.lut(slot)
        return HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(state.mixed ? "Mixed" : tools.lutName(state.id))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            Button("Choose…") { choose(slot) }
                .controlSize(.small)
                .accessibilityIdentifier("ChooseLUT.\(title)")
            Button {
                tools.setLUT("", slot)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(state.id.isEmpty && !state.mixed)
            .help("Remove the \(title.lowercased()) LUT")
            .accessibilityIdentifier("RemoveLUT.\(title)")
        }
    }

    private func choose(_ slot: GradeToolsModel.LUTSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.cubeType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = slot == .input ? "Choose a .cube LUT to apply before the grade"
            : "Choose a .cube LUT to apply as a look"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tools.importLUT(at: url, into: slot)
    }
}
