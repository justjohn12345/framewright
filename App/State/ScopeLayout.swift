import CoreGraphics
import FramewrightEngine
import Foundation

/// The scope the scope panel shows (View > Scope; remembered by the window layout).
enum ScopeMode: String, CaseIterable, Identifiable {
    case waveform
    case histogram
    case vectorscope

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waveform: return "Waveform"
        case .histogram: return "Histogram"
        case .vectorscope: return "Vectorscope"
        }
    }

    var engineMode: VEScopeMode {
        switch self {
        case .waveform: return .waveform
        case .histogram: return .histogram
        case .vectorscope: return .vectorscope
        }
    }
}

/// How the histogram is drawn (remembered by the window layout).
enum HistogramStyleChoice: String, CaseIterable, Identifiable {
    case rgbAndLuma
    case luma
    case parade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgbAndLuma: return "RGB + Luma"
        case .luma: return "Luma"
        case .parade: return "RGB Parade"
        }
    }

    var engineStyle: VEHistogramStyle {
        switch self {
        case .rgbAndLuma: return .rgbAndLuma
        case .luma: return .luma
        case .parade: return .parade
        }
    }
}

/// Where the scope panel sits: beside the program monitor (right of it), below it, or wherever the picture
/// stays larger (the default).
enum ScopePlacement: String, CaseIterable, Identifiable {
    case automatic
    case beside
    case below

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .beside: return "Beside the Monitor"
        case .below: return "Below the Monitor"
        }
    }
}

/// Where the program monitor, the divider and the scope panel go in the monitor area (all in its
/// coordinates, origin top left).
struct ScopeArrangement: Equatable {
    /// Whether the panel is beside the monitor (else below it).
    var beside: Bool
    var monitor: CGRect
    var divider: CGRect
    /// The whole panel: its header and, below it, the scale column and the scope.
    var panel: CGRect
    /// The scope view inside the panel: the picture's aspect, `scopeWidth` wide.
    var scopeSize: CGSize
}

/// The scope panel's geometry (`ScopePanel`, laid out by `ContentView`).
///
/// The panel is wide and short: its scope has the picture's aspect, so a waveform column is a picture
/// column (and the scope view draws one waveform column per pixel column). Its width is the user's
/// (`WindowLayoutModel.scopeWidth`, dragged on the divider), kept within what the area allows while the
/// monitor keeps `minimumMonitor`. Placed beside the monitor it uses the width the picture leaves when the
/// monitor is limited by its height (the usual case on a wide window); below, the height the picture leaves
/// when it is limited by its width. Automatic takes whichever leaves the picture larger (beside on a tie),
/// which keeps the program monitor as large as it can be.
@MainActor
enum ScopeLayout {
    /// The panel's header (the mode menu, the clipping indicator, the buttons).
    static let headerHeight: CGFloat = 26
    /// The scale column left of the scope (the waveform's IRE figures).
    static let scaleWidth: CGFloat = 22
    /// The narrowest scope the panel shows (while the area allows it).
    static let minimumScopeWidth: CGFloat = 300
    /// What the program monitor keeps at least beside or above the panel.
    static let minimumMonitor = CGSize(width: 240, height: 135)

    /// The panel's whole size for a scope `width` wide at `aspect`.
    static func panelSize(scopeWidth width: CGFloat, aspect: CGFloat) -> CGSize {
        CGSize(width: scaleWidth + width, height: headerHeight + width / aspect)
    }

    /// The largest rectangle of `aspect` inside `size` (the picture the monitor shows).
    static func pictureSize(in size: CGSize, aspect: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// The arrangement of a monitor area `area` for a picture of `aspect` (width over height), a scope the
    /// user made `scopeWidth` wide, in `placement`.
    static func arrange(area: CGSize, aspect rawAspect: CGFloat, placement: ScopePlacement,
                        scopeWidth: CGFloat) -> ScopeArrangement {
        let aspect = rawAspect.isFinite && rawAspect > 0 ? rawAspect : 16.0 / 9.0
        switch placement {
        case .beside:
            return besideArrangement(area: area, aspect: aspect, scopeWidth: scopeWidth)
        case .below:
            return belowArrangement(area: area, aspect: aspect, scopeWidth: scopeWidth)
        case .automatic:
            let beside = besideArrangement(area: area, aspect: aspect, scopeWidth: scopeWidth)
            let below = belowArrangement(area: area, aspect: aspect, scopeWidth: scopeWidth)
            let besidePicture = pictureSize(in: beside.monitor.size, aspect: aspect)
            let belowPicture = pictureSize(in: below.monitor.size, aspect: aspect)
            return belowPicture.width > besidePicture.width + 0.5 ? below : beside
        }
    }

    /// `width` within [min(minimum, upper), upper], and never negative.
    private static func limit(_ width: CGFloat, upper: CGFloat) -> CGFloat {
        let upper = max(0, upper)
        let finite = width.isFinite ? width : minimumScopeWidth
        return min(upper, max(min(minimumScopeWidth, upper), finite))
    }

    private static func besideArrangement(area: CGSize, aspect: CGFloat, scopeWidth: CGFloat) -> ScopeArrangement {
        let thickness = WindowLayoutModel.dividerThickness
        let byWidth = area.width - minimumMonitor.width - thickness - scaleWidth
        let byHeight = (area.height - headerHeight) * aspect
        let width = limit(scopeWidth, upper: min(byWidth, byHeight))
        let panel = panelSize(scopeWidth: width, aspect: aspect)
        let monitorWidth = max(0, area.width - thickness - panel.width)
        return ScopeArrangement(
            beside: true,
            monitor: CGRect(x: 0, y: 0, width: monitorWidth, height: area.height),
            divider: CGRect(x: monitorWidth, y: 0, width: thickness, height: area.height),
            panel: CGRect(x: monitorWidth + thickness, y: max(0, (area.height - panel.height) / 2),
                          width: panel.width, height: panel.height),
            scopeSize: CGSize(width: width, height: width / aspect))
    }

    private static func belowArrangement(area: CGSize, aspect: CGFloat, scopeWidth: CGFloat) -> ScopeArrangement {
        let thickness = WindowLayoutModel.dividerThickness
        let byWidth = area.width - scaleWidth
        let byHeight = (area.height - minimumMonitor.height - thickness - headerHeight) * aspect
        let width = limit(scopeWidth, upper: min(byWidth, byHeight))
        let panel = panelSize(scopeWidth: width, aspect: aspect)
        let monitorHeight = max(0, area.height - thickness - panel.height)
        return ScopeArrangement(
            beside: false,
            monitor: CGRect(x: 0, y: 0, width: area.width, height: monitorHeight),
            divider: CGRect(x: 0, y: monitorHeight, width: area.width, height: thickness),
            panel: CGRect(x: max(0, (area.width - panel.width) / 2), y: monitorHeight + thickness,
                          width: panel.width, height: panel.height),
            scopeSize: CGSize(width: width, height: width / aspect))
    }

    /// The scope width a drag on the divider gives: `translation` points (positive: right or down) from a
    /// scope `startWidth` wide. Beside the monitor, dragging left widens it; below, dragging up makes it
    /// taller, and its width follows the picture's aspect.
    static func draggedWidth(from startWidth: CGFloat, translation: CGFloat, beside: Bool, aspect: CGFloat) -> CGFloat {
        guard translation.isFinite else { return startWidth }
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        return beside ? startWidth - translation : startWidth - translation * aspect
    }

    /// A clipped share for the indicator: "0 %", "<0.1 %", or one decimal ("2.3 %").
    static func clippingText(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0 %" }
        if fraction < 0.0005 { return "<0.1 %" }
        return String(format: "%.1f %%", min(1, fraction) * 100)
    }
}
