import FramewrightEngine
import SwiftUI

/// The Colour tab's curve editor: a curve (Luma, Red, Green, Blue) drawn over a square of input across and
/// output up, both 0 to 100 %, with its points. Click empty space to add a point there (and keep dragging
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

    private var curve: VEGradeCurve { tools.curveChannel }

    static func colour(of curve: VEGradeCurve) -> Color {
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
            let shown = working ?? CurveEditing.editable(points)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.12))
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
                tools.setCurve(curve, CurveEditing.removing(selected, from: points))
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
                    let base = CurveEditing.editable(points)
                    if let hit = CurveEditing.hit(value.startLocation, in: base, side: side) {
                        dragging = hit
                        working = base
                    } else if let added = CurveEditing.adding(CurveEditing.curvePoint(value.startLocation, side: side),
                                                              to: base) {
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
                draggedOut = CurveEditing.isDraggedOut(value.location, side: side) && current.count > 2
                if draggedOut {
                    tools.setCurve(curve, CurveEditing.removing(index, from: current))
                } else {
                    let moved = CurveEditing.moving(index, to: CurveEditing.curvePoint(value.location, side: side),
                                                    in: current)
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

    /// Quarter lines and the diagonal (the identity).
    private func grid(side: CGFloat) -> some View {
        Path { path in
            for step in 1 ..< 4 {
                let t = side * CGFloat(step) / 4
                path.move(to: CGPoint(x: t, y: 0))
                path.addLine(to: CGPoint(x: t, y: side))
                path.move(to: CGPoint(x: 0, y: t))
                path.addLine(to: CGPoint(x: side, y: t))
            }
            path.move(to: CGPoint(x: 0, y: side))
            path.addLine(to: CGPoint(x: side, y: 0))
        }
        .stroke(Color(white: 0.3), lineWidth: 0.5)
    }

    /// The curve through `points`, sampled as the renderer applies it.
    private func curvePath(_ points: [CGPoint], side: CGFloat) -> Path {
        let count = max(2, Int(side))
        var samples = [Double](repeating: 0, count: count)
        VEGradeCurveInfo.sample(points.map { NSValue(point: $0) }, into: &samples, count: count)
        return Path { path in
            for (i, y) in samples.enumerated() {
                let p = CurveEditing.viewPoint(CGPoint(x: Double(i) / Double(count - 1), y: y), side: side)
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
                    .help("Reset the luma, red, green and blue curves of the selection")
                    .accessibilityIdentifier("ResetCurves")
            }
            Picker("Curve", selection: $tools.curveChannel) {
                Text("Luma").tag(VEGradeCurve.luma)
                Text("Red").tag(VEGradeCurve.red)
                Text("Green").tag(VEGradeCurve.green)
                Text("Blue").tag(VEGradeCurve.blue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("CurveChannel")
            let state = tools.curve(tools.curveChannel)
            CurveEditor(tools: tools, points: state.points, mixed: state.mixed)
            Text("Click to add a point, drag to move it, drag it out of the square (or select it and press Delete) "
                + "to remove it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
