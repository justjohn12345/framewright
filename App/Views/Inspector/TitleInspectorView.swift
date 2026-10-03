import AppKit
import FramewrightEngine
import SwiftUI

/// The inspector's sections for selected titles (Text, Font, Outline, Shadow, Background) and colour mattes (the
/// matte's colour), drawn above the shared Video rows. The logic, units and undo rules are `TitleInspectorModel`'s.
struct TitleInspectorSections: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: TitleInspectorModel

    init(store: ProjectStore) {
        self.store = store
        model = store.titleInspector
    }

    var body: some View {
        if let message = model.message {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    model.clearMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .accessibilityIdentifier("TitleInspector.message")
        }
        if model.showsTitleSections {
            textSection
            fontSection
            toggledSection("Outline", toggle: .outline, rows: [.outlineWidth], colours: [.outlineColour])
            toggledSection("Shadow", toggle: .shadow,
                           rows: [.shadowOpacity, .shadowAngle, .shadowDistance, .shadowBlur], colours: [.shadowColour])
            toggledSection("Background", toggle: .box, rows: [.boxOpacity, .boxPadding, .boxCornerRadius],
                           colours: [.boxColour])
        }
        if model.showsMatteSection {
            matteSection
        }
    }

    private var subtitle: String? {
        let count = model.titleTargets.count
        return count > 1 ? "\(count) titles" : nil
    }

    // MARK: Text

    private var textSection: some View {
        TitleSection(title: "Text", subtitle: subtitle, reset: {
            // Point text and the anchor before the position: turning them back keeps the text where it is, and the
            // position's reset then centres it.
            model.reset([.alignment, .pointText, .anchor, .lineSpacing, .tracking, .positionX, .positionY, .boxWidth])
        }) {
            if model.canEditText {
                TitleTextEditor(text: model.text, modelVersion: store.changeCount,
                                focusSerial: store.inspectorFocusRequest?.field == .titleText
                                    ? store.inspectorFocusRequest?.serial ?? 0 : 0,
                                model: model)
                    .frame(minHeight: 64, maxHeight: 140)
                    .accessibilityIdentifier("TitleText")
            } else {
                Text("Select one title to edit its text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("TitleText.disabled")
            }
            alignmentRow
            textBoxRow
            anchorRow
            ForEach([VETitleParameter.lineSpacing, .tracking, .positionX, .positionY], id: \.self) {
                TitleNumberRow(model: model, parameter: $0)
            }
            // Point text is as wide as its text: it does not wrap.
            TitleNumberRow(model: model, parameter: .boxWidth)
                .disabled(model.pointText == true)
        }
    }

    /// Area text (wraps at the wrap width) or point text (no wrapping: as wide as its text, which grows from its
    /// position as it is typed). Changing it keeps the text where it is.
    private var textBoxRow: some View {
        HStack(spacing: 4) {
            Text("Text Box").foregroundStyle(.secondary)
            if model.isMixed(.pointText) {
                Text("Mixed").foregroundStyle(.tertiary)
            }
            Spacer()
            Picker("Text Box", selection: Binding(get: { model.pointText }, set: { if let on = $0 { model.setPointText(on) } })) {
                Text("Area").tag(Bool?.some(false))
                Text("Point").tag(Bool?.some(true))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Area: the lines wrap inside the wrap width. Point: no wrapping; the text grows from its position as "
                + "you type (from its left edge, centre or right edge, as it is aligned)")
            .accessibilityIdentifier("TitlePointText")
        }
        .font(.caption)
    }

    /// Where the position is on the text block: its top (lines added grow it down), centre or bottom (it grows up).
    private var anchorRow: some View {
        HStack(spacing: 4) {
            Text("Anchor").foregroundStyle(.secondary)
            if model.isMixed(.anchor) {
                Text("Mixed").foregroundStyle(.tertiary)
            }
            Spacer()
            ForEach([(VETitleAnchor.top, "align.vertical.top", "Top: lines added grow the text down"),
                     (.centre, "align.vertical.center", "Centre: lines added grow the text both ways"),
                     (.bottom, "align.vertical.bottom", "Bottom: lines added grow the text up")], id: \.0) { anchor, image, help in
                Button {
                    model.setAnchor(anchor)
                } label: {
                    Image(systemName: image)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(model.anchor == anchor ? Color.accentColor.opacity(0.35) : Color.clear))
                }
                .buttonStyle(.borderless)
                .help(help)
                .accessibilityIdentifier("TitleAnchor.\(anchor.rawValue)")
            }
        }
        .font(.caption)
    }

    private var alignmentRow: some View {
        HStack(spacing: 4) {
            Text("Alignment").foregroundStyle(.secondary)
            if model.isMixed(.alignment) {
                Text("Mixed").foregroundStyle(.tertiary)
            }
            Spacer()
            ForEach([(VETitleAlignment.left, "text.alignleft"), (.centre, "text.aligncenter"), (.right, "text.alignright")],
                    id: \.0) { alignment, image in
                Button {
                    model.setAlignment(alignment)
                } label: {
                    Image(systemName: image)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(model.alignment == alignment ? Color.accentColor.opacity(0.35) : Color.clear))
                }
                .buttonStyle(.borderless)
                .help(alignment == .left ? "Align Left" : alignment == .centre ? "Centre" : "Align Right")
                .accessibilityIdentifier("TitleAlignment.\(alignment.rawValue)")
            }
        }
        .font(.caption)
    }

    // MARK: Font

    private var fontSection: some View {
        TitleSection(title: "Font", subtitle: subtitle, reset: { model.reset([.font, .size, .fillColour]) }) {
            TitleFontRows(model: model)
            TitleNumberRow(model: model, parameter: .size)
            TitleColourRow(model: model, parameter: .fillColour)
        }
    }

    // MARK: Outline, Shadow, Background

    private func toggledSection(_ title: String, toggle: VETitleParameter, rows: [VETitleParameter],
                                colours: [VETitleParameter]) -> some View {
        TitleSection(title: title, subtitle: subtitle, reset: { model.reset([toggle] + colours + rows) }) {
            HStack {
                Toggle(isOn: Binding(get: { model.toggle(toggle) ?? false }, set: { model.setToggle(toggle, $0) })) {
                    Text(VETitleParameterInfo.info(for: toggle).displayName)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("TitleToggle.\(toggle.rawValue)")
                if model.isMixed(toggle) {
                    Text("Mixed").foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .font(.caption)
            ForEach(colours, id: \.self) { TitleColourRow(model: model, parameter: $0) }
            ForEach(rows, id: \.self) { TitleNumberRow(model: model, parameter: $0) }
        }
    }

    // MARK: Matte

    private var matteSection: some View {
        let count = model.matteTargets.count
        return TitleSection(title: "Colour Matte", subtitle: count > 1 ? "\(count) mattes" : nil,
                            reset: { model.setMatteColour(VEColour(red: 0, green: 0, blue: 0)) }) {
            HStack {
                Text("Colour").foregroundStyle(.secondary)
                if model.isMatteColourMixed {
                    Text("Mixed").foregroundStyle(.tertiary)
                }
                Spacer()
                ColorPicker("", selection: Binding(get: { Color(veColour: model.matteColour) },
                                                   set: { model.setMatteColour(VEColour(color: $0)) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityIdentifier("MatteColour")
            }
            .font(.caption)
        }
    }
}

/// A titled section with a Reset button.
private struct TitleSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let reset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset", action: reset)
                    .controlSize(.small)
                    .help("Reset the \(title.lowercased()) settings of the selection")
                    .accessibilityIdentifier("TitleReset.\(title)")
            }
            content
        }
        Divider()
    }
}

/// A number: label, typed field (with nudges), reset and slider, in display units.
private struct TitleNumberRow: View {
    @ObservedObject var model: TitleInspectorModel
    let parameter: VETitleParameter
    @State private var dragging = false

    /// The row's label: the engine's name, but for the text block's centre and wrap width, which would read like
    /// the Video rows' Position X and Y below them.
    static func label(_ parameter: VETitleParameter, _ info: VETitleParameterInfo) -> String {
        switch parameter {
        case .positionX: return "Text Centre X"
        case .positionY: return "Text Centre Y"
        case .boxWidth: return "Wrap Width"
        default: return info.displayName
        }
    }

    var body: some View {
        let info = VETitleParameterInfo.info(for: parameter)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(Self.label(parameter, info)).foregroundStyle(.secondary)
                Spacer()
                NumericField(text: model.text(parameter), placeholder: model.isMixed(parameter) ? "Mixed" : "",
                             commit: { model.commit(parameter, $0) },
                             nudge: { model.nudge(parameter, steps: $0) },
                             accessibilityIdentifier: "TitleParameter.\(info.name)")
                    .frame(width: 104, height: 20)
                Button {
                    model.setNumber(parameter, info.defaultValue * model.displayScale(parameter))
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reset \(info.displayName)")
            }
            .font(.caption)
            Slider(value: Binding(get: { model.value(parameter) ?? info.defaultValue * model.displayScale(parameter) },
                                  set: { model.sliderChanged(parameter, $0) }),
                   in: model.range(parameter)) { editing in
                if editing {
                    model.beginSliderDrag(parameter)
                    dragging = true
                } else {
                    model.endSliderDrag()
                    dragging = false
                }
            }
            .controlSize(.mini)
        }
        .onDisappear {
            if dragging {
                dragging = false
                model.endSliderDrag()
            }
        }
    }
}

/// A colour: label, "Mixed" where the titles differ, and a colour well.
private struct TitleColourRow: View {
    @ObservedObject var model: TitleInspectorModel
    let parameter: VETitleParameter

    var body: some View {
        let info = VETitleParameterInfo.info(for: parameter)
        HStack {
            Text(info.displayName).foregroundStyle(.secondary)
            if model.isMixed(parameter) {
                Text("Mixed").foregroundStyle(.tertiary)
            }
            Spacer()
            ColorPicker("", selection: Binding(get: { Color(veColour: model.colour(parameter) ?? VEColour()) },
                                               set: { model.setColour(parameter, VEColour(color: $0)) }),
                        supportsOpacity: false)
                .labelsHidden()
                .accessibilityIdentifier("TitleColour.\(info.name)")
        }
        .font(.caption)
    }
}

/// The font's family and style popups. The system font is offered by weight (a title stores it by weight, never
/// by a private name); a font this Mac lacks stays listed under its name with a warning (it is drawn in the system
/// font until it is installed).
private struct TitleFontRows: View {
    @ObservedObject var model: TitleInspectorModel
    private static let system = "System"

    var body: some View {
        let font = model.font
        let families = model.families
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Family").foregroundStyle(.secondary)
                Spacer()
                Picker("Family", selection: Binding(get: { familyTag(font) }, set: { chooseFamily($0) })) {
                    if font == nil {
                        Text("Mixed").tag("")
                    }
                    Text(Self.system).tag(Self.system)
                    if let font, !font.isSystem, !families.contains(font.family) {
                        Text("\(font.family.isEmpty ? font.postScriptName : font.family) (missing)").tag(familyTag(font))
                    }
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .accessibilityIdentifier("TitleFontFamily")
            }
            HStack {
                Text("Style").foregroundStyle(.secondary)
                Spacer()
                Picker("Style", selection: Binding(get: { styleTag(font) }, set: { chooseStyle($0, of: font) })) {
                    if let font {
                        if font.isSystem {
                            ForEach(TitleInspectorModel.systemWeights, id: \.weight) { Text($0.name).tag($0.name) }
                        } else {
                            let styles = TitleInspectorModel.styles(ofFamily: font.family)
                            if !styles.contains(where: { $0.postScriptName == font.postScriptName }) {
                                Text(font.style.isEmpty ? font.postScriptName : font.style).tag(font.postScriptName)
                            }
                            ForEach(styles, id: \.postScriptName) { Text($0.style).tag($0.postScriptName) }
                        }
                    } else {
                        Text("Mixed").tag("")
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .disabled(font == nil)
                .accessibilityIdentifier("TitleFontStyle")
            }
            if let font, !font.isAvailable {
                Label("“\(font.displayName)” is not on this Mac: shown in the system font until it is installed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("TitleFontMissing")
            }
        }
        .font(.caption)
    }

    private func familyTag(_ font: VETitleFont?) -> String {
        guard let font else { return "" }
        return font.isSystem ? Self.system : (font.family.isEmpty ? font.postScriptName : font.family)
    }

    private func styleTag(_ font: VETitleFont?) -> String {
        guard let font else { return "" }
        if font.isSystem {
            return TitleInspectorModel.systemWeights.first { $0.weight == font.weight }?.name ?? "Regular"
        }
        return font.postScriptName
    }

    private func chooseFamily(_ family: String) {
        if family == Self.system {
            model.setFont(VETitleFont.system(weight: .semibold))
        } else if let font = TitleInspectorModel.font(forFamily: family) {
            model.setFont(font)
        }
    }

    private func chooseStyle(_ tag: String, of font: VETitleFont?) {
        guard let font else { return }
        if font.isSystem {
            if let weight = TitleInspectorModel.systemWeights.first(where: { $0.name == tag })?.weight {
                model.setFont(VETitleFont.system(weight: weight))
            }
        } else if let style = TitleInspectorModel.styles(ofFamily: font.family).first(where: { $0.postScriptName == tag }) {
            model.setFont(VETitleFont.named(style.postScriptName, family: font.family, style: style.style))
        }
    }
}

/// The title's text area: an AppKit text view (multi-line, plain text) whose every change is a step of the typing
/// run (`TitleInspectorModel.textChanged`) and whose end of editing ends the run. It has no undo of its own
/// (`TitleTextView`), so ⌘Z undoes the run in the engine as one step. A focus request (a title just added) puts the
/// caret in it with all of its text selected, so typing replaces the placeholder.
struct TitleTextEditor: NSViewRepresentable {
    let text: String
    /// The engine's change count: it makes every model change a new value of this view, so SwiftUI updates the
    /// text view even when the model's text is back to what SwiftUI last gave it while the text view shows typed
    /// text (an undo of a typing run SwiftUI never drew in between).
    let modelVersion: UInt64
    let focusSerial: Int
    let model: TitleInspectorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        let textView = TitleTextView()
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("TitleTextView")
        scroll.documentView = textView
        context.coordinator.textView = textView
        focusIfAsked(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // The model's text, unless the user is composing (an input method's marked text) or it is what is shown.
        if textView.string != text, !textView.hasMarkedText() {
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
        }
        focusIfAsked(textView)
    }

    /// Puts the caret in the text view with all of its text selected when a focus request has not been handled.
    private func focusIfAsked(_ textView: NSTextView) {
        guard focusSerial > model.handledTextFocus else { return }
        model.handledTextFocus = focusSerial
        DispatchQueue.main.async {
            guard let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TitleTextEditor
        weak var textView: NSTextView?

        init(_ parent: TitleTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            parent.model.textChanged(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.model.endTyping()
        }
    }
}

/// The title text area's text view: no undo manager, so ⌘Z is never taken by the text view and reaches the
/// engine (which ends the typing run and undoes it as one step).
final class TitleTextView: NSTextView {
    override var undoManager: UndoManager? { nil }
}

extension Color {
    /// An sRGB colour of the engine.
    init(veColour colour: VEColour) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue)
    }
}

extension VEColour {
    /// `color` in sRGB, each component clamped to 0...1 (a colour from a wider gamut is clipped).
    init(color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        func clamp(_ value: CGFloat) -> Double { min(1, max(0, Double(value))) }
        self.init(red: clamp(srgb.redComponent), green: clamp(srgb.greenComponent), blue: clamp(srgb.blueComponent))
    }
}
