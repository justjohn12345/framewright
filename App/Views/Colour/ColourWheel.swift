import AppKit
import FramewrightEngine
import SwiftUI

/// One colour wheel of the Colour tab (lift, gamma or gain): the wheel, whose puck is the wheel's colour
/// (the point (cb, cr) in the disk, placed as a vectorscope places colours: red up and to the left, blue to
/// the right), and the level slider under it. Dragging the puck moves the colour relative to where the drag
/// began (Option: a quarter as fast, for fine changes); the colour stays in the disk. Each drag, and each
/// slider drag, is one undo step (`GradeToolsModel`). Where the selected clips differ, the puck is hidden
/// ("Mixed") or the level says "Mixed"; moving it gives them all the new colour or level.
struct ColourWheelControl: View {
    let wheel: VEGradeWheel
    let tools: GradeToolsModel
    let value: VEGradeWheelValue
    let colourMixed: Bool
    let levelMixed: Bool

    private var info: VEGradeWheelInfo? { VEGradeWheelInfo.info(for: wheel) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(info?.displayName ?? "")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    tools.reset(wheel)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Reset \(info?.displayName ?? "the wheel")")
                .accessibilityIdentifier("ResetWheel.\(info?.name ?? "")")
            }
            ColourWheelSurface(colour: colourMixed ? nil : CGPoint(x: value.cb, y: value.cr),
                               onBegin: { tools.beginDrag(wheel, part: "colour") },
                               onChange: { tools.setColour(wheel, cb: Double($0.x), cr: Double($0.y)) },
                               onEnd: { tools.endDrag() })
                .aspectRatio(1, contentMode: .fit)
                .help("\(info?.displayName ?? "") moves the \(info?.tonalRange ?? "picture"): drag the centre toward a colour "
                    + "(Option: finer)")
                .accessibilityIdentifier("Wheel.\(info?.name ?? "")")
            Slider(value: Binding(get: { value.level }, set: { tools.setLevel(wheel, $0) }), in: -1 ... 1,
                   onEditingChanged: { editing in
                       if editing {
                           tools.beginDrag(wheel, part: "level")
                       } else {
                           tools.endDrag()
                       }
                   })
                   .controlSize(.mini)
                   .accessibilityIdentifier("WheelLevel.\(info?.name ?? "")")
            Text(levelMixed ? "Mixed" : Self.levelText(value.level))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// A level as the control shows it: signed, two decimals ("+0.25", "0.00").
    static func levelText(_ level: Double) -> String {
        level == 0 ? "0.00" : String(format: "%+.2f", level)
    }
}

/// The wheel itself, drawn as a grading wheel is (DaVinci Resolve's, Lightroom's): a disc of hues placed as a
/// vectorscope places them (the colour at each direction is the BT.709 chroma of that direction, at its full
/// saturation), strongest at the rim, where a thin ring shows each hue at full strength, and fading to a neutral
/// grey at the centre (no change); with a puck at `colour` (cb across, cr up; nil hides it: the clips differ).
/// The puck sits over the colour it adds.
struct ColourWheelSurface: View {
    let colour: CGPoint?
    var onBegin: () -> Void
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void

    @State private var dragStart: CGPoint?

    /// The grey of the wheel's centre (no change).
    static let neutral = Color(white: 0.45)

    /// The hues around the wheel, every 5 degrees from 3 o'clock clockwise (SwiftUI's angular order on screen,
    /// y down), each the colour of the direction (cb, cr) = (cos a, -sin a) at its full saturation.
    static let hues: [Color] = (0 ... 72).map { step in
        let angle = Double(step) / 72 * 2 * .pi
        let rgb = saturatedRGBOf(cb: cos(angle), cr: -sin(angle))
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// BT.709 Y'CbCr to R'G'B', limited to [0, 1].
    static func rgbOf(cb: Double, cr: Double, luma: Double) -> (r: Double, g: Double, b: Double) {
        let r = luma + 1.5748 * cr
        let g = luma - 0.1873 * cb - 0.4681 * cr
        let b = luma + 1.8556 * cb
        return (min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
    }

    /// The hue of the chroma direction (cb, cr) at its full saturation: the BT.709 R'G'B' of that chroma,
    /// stretched so that its strongest channel is 1 and its weakest 0 (adding grey and scaling keep the hue).
    /// Grey for no direction.
    static func saturatedRGBOf(cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        let r = 1.5748 * cr
        let g = -0.1873 * cb - 0.4681 * cr
        let b = 1.8556 * cb
        let low = min(r, g, b)
        let span = max(r, g, b) - low
        guard span > 1e-9, span.isFinite else { return (0.5, 0.5, 0.5) }
        return ((r - low) / span, (g - low) / span, (b - low) / span)
    }

    /// The point of the view for the wheel's (cb, cr) in a square of `side` points.
    static func position(of colour: CGPoint, side: CGFloat) -> CGPoint {
        let radius = side / 2
        return CGPoint(x: radius + colour.x * radius, y: radius - colour.y * radius)
    }

    /// The width of the hue ring at the rim of a wheel `side` points wide.
    static func ringWidth(side: CGFloat) -> CGFloat {
        max(2.5, side * 0.035)
    }

    var body: some View {
        GeometryReader { area in
            let side = min(area.size.width, area.size.height)
            let ring = Self.ringWidth(side: side)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.hues, center: .center))
                // Neutral at the centre, the hues at full strength from just inside the ring.
                Circle()
                    .fill(RadialGradient(stops: [.init(color: Self.neutral, location: 0),
                                                 .init(color: Self.neutral.opacity(0.85), location: 0.15),
                                                 .init(color: Self.neutral.opacity(0.45), location: 0.5),
                                                 .init(color: Self.neutral.opacity(0), location: 0.95)],
                                         center: .center, startRadius: 0, endRadius: side / 2 - ring))
                Circle()
                    .strokeBorder(AngularGradient(colors: Self.hues, center: .center), lineWidth: ring)
                Circle()
                    .stroke(Color.black.opacity(0.45), lineWidth: 0.75)
                    .padding(ring)
                Circle()
                    .strokeBorder(Color.black.opacity(0.6), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: side / 2 - 4, y: side / 2))
                    path.addLine(to: CGPoint(x: side / 2 + 4, y: side / 2))
                    path.move(to: CGPoint(x: side / 2, y: side / 2 - 4))
                    path.addLine(to: CGPoint(x: side / 2, y: side / 2 + 4))
                }
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                if let colour {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(Circle().fill(Color.black.opacity(0.25)))
                        .frame(width: 11, height: 11)
                        .position(Self.position(of: colour, side: side))
                } else {
                    Text("Mixed")
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start: CGPoint
                    if let dragStart {
                        start = dragStart
                    } else {
                        start = colour ?? .zero
                        dragStart = start
                        onBegin()
                    }
                    let scale = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                    let radius = max(side / 2, 1)
                    onChange(CGPoint(x: start.x + drag.translation.width / radius * scale,
                                     y: start.y - drag.translation.height / radius * scale))
                }
                .onEnded { _ in
                    dragStart = nil
                    onEnd()
                })
        }
    }
}
