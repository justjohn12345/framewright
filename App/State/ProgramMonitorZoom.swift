import CoreGraphics
import Foundation

/// How large the program monitor shows the sequence's frame: Fit (the frame fitted into the monitor, zoomed out
/// just enough to show the Ken Burns editor's boxes when they reach past it, `KenBurnsViewport.editor`) or a fixed
/// percentage, where 100 % is one sequence pixel per screen pixel (Final Cut's viewer zoom, Premiere's Select Zoom
/// Level). A fixed level keeps the frame centred in the monitor; what lies outside the frame is shaded as at Fit,
/// and what does not fit the monitor is cut off.
enum ProgramZoom: Hashable {
    case fit
    case percent(Int)

    /// The fixed levels the control and Command-plus / Command-minus step through.
    static let levels = [25, 50, 75, 100, 200]

    /// The control's label: "Fit" or "50 %".
    var title: String {
        switch self {
        case .fit: return "Fit"
        case let .percent(value): return "\(value) %"
        }
    }
}

/// The program monitor's zoom (`ProjectStore.programZoom`; the control above the monitor, Command-plus and
/// Command-minus while the monitor has the keyboard focus, Shift-Z for Fit). Published on its own so that a
/// change redraws only the monitor's layout. `fitPercent` is what Fit shows now (the layout reports it), so
/// zooming in from Fit goes to the next level above it and zooming out to the next level below, as in Final Cut.
/// Every change is refused while `isFrozen` says a drag on the monitor is in progress (a box would leave the
/// pointer). A fixed level that does not show the Ken Burns editor's boxes gives way to Fit when the editor opens
/// or a drag ends (`keepVisible`).
@MainActor
final class ProgramMonitorZoom: ObservableObject {
    @Published private(set) var zoom: ProgramZoom = .fit
    /// The percentage the frame is shown at while at Fit (one sequence pixel per screen pixel is 100), as last
    /// laid out; 100 until the monitor reports one.
    private(set) var fitPercent: Double = 100
    /// The monitor's area (points), points per screen pixel and the sequence's frame size, as last laid out
    /// (`noteStage`); zero until then.
    private(set) var monitor: CGSize = .zero
    private(set) var pointsPerPixel: CGFloat = 1
    private(set) var sequence: CGSize = .zero
    /// Whether a drag on the monitor is in progress (`ProjectStore.isGestureActive`): the zoom stays as it is.
    var isFrozen: () -> Bool = { false }

    func noteFitPercent(_ percent: Double) {
        if percent.isFinite, percent > 0 { fitPercent = percent }
    }

    /// What the program monitor's layout lays out (it reports a change, `noteStage`).
    struct Stage: Equatable {
        var monitor: CGSize
        var pointsPerPixel: CGFloat
        var sequence: CGSize
    }

    func noteStage(_ stage: Stage) {
        monitor = stage.monitor
        pointsPerPixel = stage.pointsPerPixel > 0 ? stage.pointsPerPixel : 1
        sequence = stage.sequence
    }

    /// A level chosen in the control (refused during a drag).
    func set(_ level: ProgramZoom) {
        guard !isFrozen(), level != zoom else { return }
        zoom = level
    }

    /// The Ken Burns editor opened or a drag in it ended with its boxes in `region` (sequence pixels: the frame and
    /// the boxes): at a fixed level that does not show all of it with the handles' padding, back to Fit, which does.
    func keepVisible(_ region: CGRect) {
        guard case let .percent(level) = zoom, monitor.width > 0, monitor.height > 0, sequence.width > 0 else { return }
        let stage = KenBurnsViewport.stage(zoom: .percent(level), mode: nil, extent: nil, sequence: sequence,
                                           monitor: monitor, pointsPerPixel: pointsPerPixel)
        if !stage.shows(region, padding: KenBurnsViewport.extentPadding) {
            fit()
        }
    }

    /// The level shown now, in percent.
    var currentPercent: Double {
        switch zoom {
        case .fit: return fitPercent
        case let .percent(value): return Double(value)
        }
    }

    /// The next fixed level larger than what is shown (nothing past the largest).
    func zoomIn() {
        let current = currentPercent
        if let next = ProgramZoom.levels.first(where: { Double($0) > current + 1e-6 }) {
            set(.percent(next))
        }
    }

    /// The next fixed level smaller than what is shown (nothing past the smallest).
    func zoomOut() {
        let current = currentPercent
        if let next = ProgramZoom.levels.last(where: { Double($0) < current - 1e-6 }) {
            set(.percent(next))
        }
    }

    func fit() {
        set(.fit)
    }
}

extension KenBurnsViewport {
    /// The program monitor's stage at `zoom`: at Fit, `editor(mode:extent:sequence:monitor:)` (the frame fitted, the
    /// Ken Burns editor's margin and its zoom out to show boxes past it); at a fixed level the frame at that many
    /// percent of its pixels, `pointsPerPixel` points per screen pixel (1 / the display's backing scale), centred in
    /// the monitor.
    static func stage(zoom: ProgramZoom, mode: KenBurnsMode?, extent: CGRect?, sequence: CGSize, monitor: CGSize,
                      pointsPerPixel: CGFloat) -> KenBurnsViewport {
        switch zoom {
        case .fit:
            return editor(mode: mode, extent: extent, sequence: sequence, monitor: monitor)
        case let .percent(value):
            let scale = CGFloat(value) / 100 * (pointsPerPixel > 0 ? pointsPerPixel : 1)
            return KenBurnsViewport(sequence: sequence, monitor: monitor, scale: scale)
        }
    }

    /// The frame at `scale` points per sequence pixel, centred in the monitor.
    init(sequence: CGSize, monitor: CGSize, scale: CGFloat) {
        let points = max(scale, 1e-6)
        self.monitor = monitor
        self.scale = points
        let size = CGSize(width: sequence.width * points, height: sequence.height * points)
        frame = CGRect(x: (monitor.width - size.width) / 2, y: (monitor.height - size.height) / 2, width: size.width,
                       height: size.height)
    }

    /// The percentage of the frame's pixels this shows (100: one sequence pixel per screen pixel).
    func percent(pointsPerPixel: CGFloat) -> Double {
        pointsPerPixel > 0 ? Double(scale / pointsPerPixel) * 100 : Double(scale) * 100
    }
}
