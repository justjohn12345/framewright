import AppKit
import SwiftUI

/// A draggable divider between two panes (a thin line with a wider grab area and a resize
/// cursor). `onDrag` receives the drag's total translation along the divider's axis since the
/// press (positive: right or down), so the owner resizes relative to the size it had then
/// (`onBegin`). A double-click calls `onDoubleClick` (e.g. fit the pane to its content).
///
/// The line and the grip are SwiftUI; the grab area is an AppKit view (`DividerHandleView`) that
/// takes the press, the drag, the double-click, the hover and the pointer shape itself. As a SwiftUI
/// `DragGesture` with `onHover` and `NSCursor.set()`, the divider between the monitors could not be
/// grabbed while the source monitor played. The divider itself was neither re-rendered nor
/// replaced then, but the source monitor beside it (its scrubber, timecode and play button follow
/// its playhead) and the transport re-render at the display rate inside the same hosting view, and
/// the press, the drag and the pointer shape all went through SwiftUI's event and hover handling of
/// that hosting view. AppKit delivers a press, its drags and its release to the view that took the
/// press whatever SwiftUI redraws meanwhile, and asks that view for the pointer shape
/// (`cursorUpdate`) whenever the pointer is over it, so neither monitor's playback reaches the
/// divider.
struct PaneDivider: View {
    enum Orientation {
        /// Between two columns: drags left and right.
        case vertical
        /// Between two rows: drags up and down.
        case horizontal
    }

    let orientation: Orientation
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDoubleClick: (() -> Void)?
    /// Draws a grip in the middle while the pointer is over the divider or drags it (review D2: the
    /// split above the timeline is the user's, so its handle shows).
    var showsGrip = false
    /// The divider's tooltip.
    var help: String?

    @State private var dragging = false
    @State private var hovering = false

    init(orientation: Orientation, onBegin: @escaping () -> Void = {}, onDrag: @escaping (CGFloat) -> Void,
         onDoubleClick: (() -> Void)? = nil, showsGrip: Bool = false, help: String? = nil) {
        self.orientation = orientation
        self.onBegin = onBegin
        self.onDrag = onDrag
        self.onDoubleClick = onDoubleClick
        self.showsGrip = showsGrip
        self.help = help
    }

    /// The grip's size (along the divider, across it).
    static let gripSize = CGSize(width: 36, height: 3)

    var body: some View {
        let thickness = WindowLayoutModel.dividerThickness
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: orientation == .vertical ? 1 : nil, height: orientation == .horizontal ? 1 : nil)
            if showsGrip, hovering || dragging {
                Capsule()
                    .fill(Color.secondary.opacity(0.8))
                    .frame(width: orientation == .horizontal ? Self.gripSize.width : Self.gripSize.height,
                           height: orientation == .horizontal ? Self.gripSize.height : Self.gripSize.width)
                    .accessibilityIdentifier("PaneDividerGrip")
            }
        }
        .frame(width: orientation == .vertical ? thickness : nil, height: orientation == .horizontal ? thickness : nil)
        .frame(maxWidth: orientation == .horizontal ? .infinity : nil, maxHeight: orientation == .vertical ? .infinity : nil)
        .overlay(
            DividerHandle(orientation: orientation, help: help, onBegin: onBegin, onDrag: onDrag,
                          onDoubleClick: onDoubleClick,
                          onHover: { inside in if hovering != inside { hovering = inside } },
                          onDragging: { active in if dragging != active { dragging = active } })
        )
    }
}

/// The divider's grab area: a `DividerHandleView` over the line, fed the current closures on every
/// update (they capture the owner's sizes, so they change with the layout).
private struct DividerHandle: NSViewRepresentable {
    let orientation: PaneDivider.Orientation
    let help: String?
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDoubleClick: (() -> Void)?
    let onHover: (Bool) -> Void
    let onDragging: (Bool) -> Void

    func makeNSView(context: Context) -> DividerHandleView {
        let view = DividerHandleView(orientation: orientation)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DividerHandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.onDragging = onDragging
        if view.toolTip != help { view.toolTip = help }
    }

    static func dismantleNSView(_ view: DividerHandleView, coordinator: ()) {
        view.cancelDrag()
    }
}

/// The AppKit grab area of a `PaneDivider`: a press and its drags move the divider (the
/// translation along its axis since the press, positive right or down; the drag starts after a
/// point of movement, as SwiftUI's `DragGesture(minimumDistance: 1)` did), a double-click fits,
/// and the pointer shows the resize cursor over it and while dragging (`DividerCursor`, told by a
/// tracking area and AppKit's `cursorUpdate`). It takes the first click of an inactive window, as a
/// split view's divider does.
@MainActor
final class DividerHandleView: NSView {
    let orientation: PaneDivider.Orientation
    let cursor: DividerCursor
    var onBegin: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDoubleClick: (() -> Void)?
    var onHover: (Bool) -> Void = { _ in }
    var onDragging: (Bool) -> Void = { _ in }

    /// Where the press was, in window coordinates (nil: no press in progress).
    private var pressLocation: NSPoint?
    /// The press has moved a point or more: the divider is being dragged.
    private(set) var isDragging = false
    /// Drags reported (diagnostics and tests).
    private(set) var dragSteps = 0
    private var trackingArea: NSTrackingArea?

    init(orientation: PaneDivider.Orientation) {
        self.orientation = orientation
        cursor = DividerCursor(orientation: orientation)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp,
                                                         .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cursor.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursor.frame = bounds
        if window == nil {
            cancelDrag()
            cursor.disappeared()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
        cursor.hover(inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
        cursor.hover(inside: false)
    }

    /// AppKit asks for the pointer shape over the divider (the pointer came in, or something reset
    /// the cursor meanwhile).
    override func cursorUpdate(with event: NSEvent) {
        cursor.cursorUpdate()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pressLocation = nil
            onDoubleClick?()
            return
        }
        pressLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressLocation else { return }
        let location = event.locationInWindow
        // Window coordinates grow upwards: a drag down is a positive translation.
        let translation = orientation == .vertical ? location.x - press.x : press.y - location.y
        if !isDragging {
            guard hypot(location.x - press.x, location.y - press.y) >= 1 else { return }
            isDragging = true
            onDragging(true)
            onBegin()
        }
        cursor.dragChanged()
        dragSteps += 1
        onDrag(translation)
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        guard isDragging else { return }
        isDragging = false
        onDragging(false)
        cursor.dragEnded(at: convert(event.locationInWindow, from: nil))
    }

    /// The divider went away mid-drag (out of the window, or dismantled by SwiftUI): the drag ends
    /// where it is. Nothing is reported, since its owner is going away with it (and SwiftUI may be
    /// in the middle of an update).
    func cancelDrag() {
        pressLocation = nil
        isDragging = false
    }
}

/// The pointer shape over a divider, handled like the timeline's (`TimelineGestureController`):
/// set with `NSCursor.set()` (a push/pop stack mixed with other views' `set()` can restore the
/// wrong cursor, and a pop skipped at the end of a drag left the resize cursor up), and only when
/// the shape changes. The resize cursor shows while the pointer is over the divider or drags it;
/// when the pointer leaves (not during a drag), or a drag ends outside the divider, the arrow is
/// set if this divider had changed the cursor, and the divider forgets it (the next hover sets it
/// again, whatever other views did meanwhile).
@MainActor
final class DividerCursor {
    typealias Shape = TimelineGestureController.PointerCursor

    /// The shape shown over the divider.
    let resize: Shape
    /// The shape this divider set last (nil: none, or it gave the cursor back).
    private(set) var current: Shape?
    /// Number of cursor changes it made (tests).
    private(set) var changes = 0
    private(set) var isDragging = false
    /// The divider's grab area in the coordinates a drag's end is reported in (the handle view's
    /// own bounds).
    var frame: CGRect = .zero
    /// Sets the cursor (tests observe it instead).
    var apply: (Shape) -> Void = { $0.nsCursor.set() }

    init(orientation: PaneDivider.Orientation) {
        resize = orientation == .vertical ? .resizeLeftRight : .resizeUpDown
    }

    /// The pointer entered (true) or left (false) the divider.
    func hover(inside: Bool) {
        if inside {
            set(resize)
        } else if !isDragging {
            release()
        }
    }

    /// AppKit asks for the pointer shape over the divider (`cursorUpdate`): the resize cursor is
    /// set even when this divider set it last, since another view may have changed the cursor
    /// since (a view that re-renders every frame resets it).
    func cursorUpdate() {
        current = resize
        changes += 1
        apply(resize)
    }

    /// A drag of the divider moved.
    func dragChanged() {
        isDragging = true
        set(resize)
    }

    /// The drag ended with the pointer at `location` (in `frame`'s coordinates).
    func dragEnded(at location: CGPoint) {
        isDragging = false
        if frame.contains(location) {
            set(resize)
        } else {
            release()
        }
    }

    /// The divider went away.
    func disappeared() {
        isDragging = false
        release()
    }

    private func set(_ shape: Shape) {
        guard shape != current else { return }
        current = shape
        changes += 1
        apply(shape)
    }

    private func release() {
        if let current, current != .arrow {
            set(.arrow)
        }
        current = nil
    }
}
