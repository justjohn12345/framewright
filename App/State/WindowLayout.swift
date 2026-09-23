import CoreGraphics
import Foundation

/// Which page the right-hand panel shows: the selection's properties or the effects to add.
enum InspectorTab: String, CaseIterable, Identifiable {
    case inspector
    case effects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspector: return "Inspector"
        case .effects: return "Effects"
        }
    }
}

/// The editor window's layout: which optional panels are shown, the right panel's tab and the
/// split positions, persisted in `defaults` so they survive relaunches (as Premiere's and
/// Resolve's workspaces do).
///
/// Layout (see `ContentView`): the media bin (left), the monitors and the transport bar (centre),
/// the inspector with its Inspector/Effects tabs (right), and the timeline below them. The program
/// monitor takes the whole centre unless the source monitor is shown (View > Show Source Monitor,
/// Shift+Cmd+2; hidden until media is opened in it). The timeline's height fits its tracks (rows +
/// ruler + scroll bar, between `minimumTimelineHeight` and `maximumTimelineShare` of the window)
/// until the user drags the divider above it; from then on the dragged height is kept (a double-click
/// on the divider returns to fitting). Widths and the dragged height are clamped whenever they are
/// used, so a height saved on a larger screen still leaves the monitors room on a smaller one.
@MainActor
final class WindowLayoutModel: ObservableObject {
    static let sourceMonitorKey = "layout.showsSourceMonitor"
    static let inspectorTabKey = "layout.inspectorTab"
    static let mediaBinWidthKey = "layout.mediaBinWidth"
    static let inspectorWidthKey = "layout.inspectorWidth"
    static let sourceFractionKey = "layout.sourceMonitorFraction"
    static let timelineHeightKey = "layout.timelineHeight"

    static let defaultMediaBinWidth: CGFloat = 240
    static let mediaBinWidths: ClosedRange<CGFloat> = 180 ... 480
    static let defaultInspectorWidth: CGFloat = 280
    static let inspectorWidths: ClosedRange<CGFloat> = 240 ... 460
    /// Share of the monitor area the source monitor takes when shown.
    static let defaultSourceFraction = 0.42
    static let sourceFractions: ClosedRange<Double> = 0.25 ... 0.6
    static let minimumTimelineHeight: CGFloat = 140
    /// The timeline never takes more than this share of the window's height (the monitors keep the rest).
    static let maximumTimelineShare: CGFloat = 0.6
    /// Height the monitors and transport bar keep at least.
    static let minimumMonitorHeight: CGFloat = 240
    /// Thickness of a divider (the drag handle between panes).
    static let dividerThickness: CGFloat = 5

    @Published var showsSourceMonitor: Bool {
        didSet { if showsSourceMonitor != oldValue { defaults?.set(showsSourceMonitor, forKey: Self.sourceMonitorKey) } }
    }

    @Published var inspectorTab: InspectorTab {
        didSet { if inspectorTab != oldValue { defaults?.set(inspectorTab.rawValue, forKey: Self.inspectorTabKey) } }
    }

    @Published private(set) var mediaBinWidth: CGFloat
    @Published private(set) var inspectorWidth: CGFloat
    @Published private(set) var sourceMonitorFraction: Double
    /// The height the user dragged the timeline to; nil while it fits its content.
    @Published private(set) var timelineHeight: CGFloat?

    /// Where the layout is saved; nil keeps it in memory only (a store made for tests).
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        showsSourceMonitor = defaults?.object(forKey: Self.sourceMonitorKey) as? Bool ?? false
        inspectorTab = defaults?.string(forKey: Self.inspectorTabKey).flatMap(InspectorTab.init(rawValue:)) ?? .inspector
        mediaBinWidth = Self.stored(defaults, Self.mediaBinWidthKey).map { Self.clamp($0, Self.mediaBinWidths) }
            ?? Self.defaultMediaBinWidth
        inspectorWidth = Self.stored(defaults, Self.inspectorWidthKey).map { Self.clamp($0, Self.inspectorWidths) }
            ?? Self.defaultInspectorWidth
        let fraction = defaults?.object(forKey: Self.sourceFractionKey) as? Double
        sourceMonitorFraction = fraction.map { min(Self.sourceFractions.upperBound, max(Self.sourceFractions.lowerBound, $0)) }
            ?? Self.defaultSourceFraction
        timelineHeight = Self.stored(defaults, Self.timelineHeightKey).map { max(Self.minimumTimelineHeight, $0) }
    }

    // MARK: Setters (clamped, persisted)

    func setMediaBinWidth(_ width: CGFloat) {
        let clamped = Self.clamp(width, Self.mediaBinWidths)
        guard clamped != mediaBinWidth else { return }
        mediaBinWidth = clamped
        defaults?.set(Double(clamped), forKey: Self.mediaBinWidthKey)
    }

    func setInspectorWidth(_ width: CGFloat) {
        let clamped = Self.clamp(width, Self.inspectorWidths)
        guard clamped != inspectorWidth else { return }
        inspectorWidth = clamped
        defaults?.set(Double(clamped), forKey: Self.inspectorWidthKey)
    }

    func setSourceMonitorFraction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let clamped = min(Self.sourceFractions.upperBound, max(Self.sourceFractions.lowerBound, fraction))
        guard clamped != sourceMonitorFraction else { return }
        sourceMonitorFraction = clamped
        defaults?.set(clamped, forKey: Self.sourceFractionKey)
    }

    /// The divider above the timeline was dragged to give it `height` in a window content of
    /// `windowHeight` points.
    func setTimelineHeight(_ height: CGFloat, windowHeight: CGFloat) {
        guard height.isFinite else { return }
        let clamped = Self.clamp(height, Self.timelineHeights(windowHeight: windowHeight))
        guard clamped != timelineHeight else { return }
        timelineHeight = clamped
        defaults?.set(Double(clamped), forKey: Self.timelineHeightKey)
    }

    /// Back to fitting the timeline to its tracks (double-click on the divider).
    func fitTimelineToContent() {
        guard timelineHeight != nil else { return }
        timelineHeight = nil
        defaults?.removeObject(forKey: Self.timelineHeightKey)
    }

    /// Restores every default (panels, tab and splits).
    func resetToDefaults() {
        showsSourceMonitor = false
        inspectorTab = .inspector
        mediaBinWidth = Self.defaultMediaBinWidth
        inspectorWidth = Self.defaultInspectorWidth
        sourceMonitorFraction = Self.defaultSourceFraction
        timelineHeight = nil
        for key in [Self.sourceMonitorKey, Self.inspectorTabKey, Self.mediaBinWidthKey, Self.inspectorWidthKey,
                    Self.sourceFractionKey, Self.timelineHeightKey] {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: Sizing

    /// The heights the timeline may have in a window content `windowHeight` points tall.
    static func timelineHeights(windowHeight: CGFloat) -> ClosedRange<CGFloat> {
        let byShare = windowHeight * maximumTimelineShare
        let byMonitors = windowHeight - minimumMonitorHeight - dividerThickness
        let upper = max(minimumTimelineHeight, min(byShare, byMonitors))
        return minimumTimelineHeight ... upper
    }

    /// The height a timeline showing `contentHeight` points of rows needs: the rows, the ruler,
    /// the scroll bar and the dividers between them.
    static func fittedTimelineHeight(contentHeight: CGFloat) -> CGFloat {
        contentHeight + TimelineView.rulerHeight + TimelineView.scrollBarHeight + 1 + 2
    }

    /// The timeline's height in a window content `windowHeight` points tall: the dragged height,
    /// else the fitted one, within `timelineHeights(windowHeight:)`.
    func timelineHeight(contentHeight: CGFloat, windowHeight: CGFloat) -> CGFloat {
        let wanted = timelineHeight ?? Self.fittedTimelineHeight(contentHeight: contentHeight)
        return Self.clamp(wanted, Self.timelineHeights(windowHeight: windowHeight))
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func stored(_ defaults: UserDefaults?, _ key: String) -> CGFloat? {
        guard let value = defaults?.object(forKey: key) as? Double, value.isFinite else { return nil }
        return CGFloat(value)
    }
}
