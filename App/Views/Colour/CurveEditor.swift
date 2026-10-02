import FramewrightEngine
import SwiftUI

/// The Colour tab's curve editor: a curve drawn over a square with its points. A tone curve (Luma, Red,
/// Green, Blue): input across and output up, both 0 to 100 %. A hue curve (Hue vs Saturation, Hue vs Hue, Hue
/// vs Luma): hue across (a band of the hues along the bottom, as a vectorscope orders them), the change up with
/// no change at the middle line; it joins itself at the edges. Click empty space to add a point there (and keep dragging
/// it), drag a point to move it (it stays between its neighbours), drag it out of the square to remove it,
/// or select it (click) and press Delete. Each gesture is one undo step (`GradeToolsModel`). Where the
/// selected clips' curves differ, the first clip's is drawn faded with "Mixed"; editing gives them all the new
/// curve.
struct CurveEditor: View {
    @ObservedObject var tools: GradeToolsModel
    let points: [CGPoint]
    let mixed: Bool

    /// The point being dragged (its index in the editable points), and whether it is out of the square.
    @State private var dragging: Int?
    @State private var draggedOut = false
    @State private var selected: Int?
    /// The editable points as the drag left them (the model follows a step behind).
    @State private var working: [CGPoint]?

    private var curve: CurveChannel { tools.curveChannel }
    private var periodic: Bool { curve.isHue }

    /// The hue at fraction `x` of the circle (Cb across, Cr up, as the grade and a vectorscope measure it).
    static func hueColour(_ x: Double) -> Color {
        let angle = x * 2 * .pi
        let rgb = ColourWheelSurface.rgbOf(cb: cos(angle) * 0.3, cr: sin(angle) * 0.3, luma: 0.55)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func colour(of curve: CurveChannel) -> Color {
        switch curve {
        case .red: return Color(red: 1, green: 0.3, blue: 0.3)
        case .green: return Color(red: 0.3, green: 0.9, blue: 0.35)
        case .blue: return Color(red: 0.35, green: 0.55, blue: 1)
        default: return Color(white: 0.92)
        }
    }

    var body: some View {
        GeometryReader { area in
            let side = min(area.size.width, area.size.height)
            let shown = working ?? CurveEditing.editable(points, periodic: periodic)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.12))
                if periodic {
                    Rectangle()
                        .fill(LinearGradient(colors: (0 ... 12).map { Self.hueColour(Double($0) / 12) },
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: side, height: 8)
                        .offset(y: side - 8)
                }
                grid(side: side)
                curvePath(shown, side: side)
                    .stroke(Self.colour(of: curve).opacity(mixed && working == nil ? 0.4 : 1), lineWidth: 1.5)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, point in
                    if !(draggedOut && dragging == index) {
                        Circle()
                            .fill(index == selected ? Self.colour(of: curve) : Color(white: 0.12))
                            .overlay(Circle().strokeBorder(Self.colour(of: curve), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(CurveEditing.viewPoint(point, side: side))
                    }
                }
                if mixed && working == nil {
                    Text("Mixed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .gesture(drag(side: side))
            .focusable()
            .onDeleteCommand {
                guard let selected else { return }
                tools.setCurve(curve, CurveEditing.removing(selected, from: points, periodic: periodic))
                self.selected = nil
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: tools.curveChannel) { _, _ in selected = nil }
        .accessibilityIdentifier("CurveEditor")
    }

    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    let base = CurveEditing.editable(points, periodic: periodic)
                    if let hit = CurveEditing.hit(value.startLocation, in: base, side: side, periodic: periodic) {
                        dragging = hit
                        working = base
                    } else if let added = CurveEditing.adding(CurveEditing.curvePoint(value.startLocation, side: side),
                                                              to: base, periodic: periodic) {
                        dragging = added.index
                        working = added.points
                    } else {
                        return
                    }
                    selected = dragging
                    tools.beginCurveDrag(curve)
                    if let working, working != base {
                        tools.setCurve(curve, working)
                    }
                }
                guard let index = dragging, let current = working else { return }
                draggedOut = CurveEditing.isDraggedOut(value.location, side: side) && (periodic || current.count > 2)
                if draggedOut {
                    tools.setCurve(curve, CurveEditing.removing(index, from: current, periodic: periodic))
                } else {
                    let moved = CurveEditing.moving(index, to: CurveEditing.curvePoint(value.location, side: side),
                                                    in: current, periodic: periodic)
                    working = moved
                    tools.setCurve(curve, moved)
                }
            }
            .onEnded { _ in
                if draggedOut {
                    selected = nil
                }
                dragging = nil
                draggedOut = false
                working = nil
                tools.endDrag()
            }
    }

    /// Quarter lines and the identity: the diagonal of a tone curve, the middle line of a hue curve.
    private func grid(side: CGFloat) -> some View {
        Path { path in
            for step in 1 ..< 4 {
                let t = side * CGFloat(step) / 4
                path.move(to: CGPoint(x: t, y: 0))
                path.addLine(to: CGPoint(x: t, y: side))
                path.move(to: CGPoint(x: 0, y: t))
                path.addLine(to: CGPoint(x: side, y: t))
            }
            if !periodic {
                path.move(to: CGPoint(x: 0, y: side))
                path.addLine(to: CGPoint(x: side, y: 0))
            }
        }
        .stroke(Color(white: 0.3), lineWidth: 0.5)
    }

    /// The curve through `points`, sampled as the renderer applies it (one more sample for a hue curve, so it
    /// reaches the right edge where it joins itself).
    private func curvePath(_ points: [CGPoint], side: CGFloat) -> Path {
        let count = max(2, Int(side))
        var samples = [Double](repeating: 0, count: count)
        let values = points.map { NSValue(point: $0) }
        if periodic {
            VEGradeCurveInfo.sampleHue(values, into: &samples, count: count)
            samples.append(samples[0])
        } else {
            VEGradeCurveInfo.sample(values, into: &samples, count: count)
        }
        let last = Double(samples.count - 1)
        return Path { path in
            for (i, y) in samples.enumerated() {
                let p = CurveEditing.viewPoint(CGPoint(x: Double(i) / last, y: y), side: side)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }
}

/// The Curves section of the Colour tab: the channel, the editor, the resets.
struct CurvesSection: View {
    @ObservedObject var tools: GradeToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Curves").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { tools.resetCurve(tools.curveChannel) }
                    .controlSize(.small)
                    .help("Reset this curve of the selection")
                    .accessibilityIdentifier("ResetCurve")
                Button("Reset All") { tools.resetCurves() }
                    .controlSize(.small)
                    .disabled(!tools.anyCurveSet)
                    .help("Reset every curve of the selection (tone and hue)")
                    .accessibilityIdentifier("ResetCurves")
            }
            Picker("Curve", selection: $tools.curveChannel) {
                ForEach(CurveChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("CurveChannel")
            let state = tools.curve(tools.curveChannel)
            CurveEditor(tools: tools, points: state.points, mixed: state.mixed)
            Text(tools.curveChannel.isHue
                ? "Hue across, the change up (none at the middle line). Click to add a point, drag to move it, drag "
                + "it out of the square (or select it and press Delete) to remove it."
                : "Click to add a point, drag to move it, drag it out of the square (or select it and press Delete) "
                + "to remove it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
