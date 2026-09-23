import AppKit
import SwiftUI

/// A draggable divider between two panes (a thin line with a wider grab area and a resize
/// cursor). `onDrag` receives the drag's total translation along the divider's axis since the
/// press (positive: right or down), so the owner resizes relative to the size it had then
/// (`onBegin`). A double-click calls `onDoubleClick` (e.g. fit the pane to its content).
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

    @State private var dragging = false
    /// The pointer shape (set, never pushed: see `DividerCursor`).
    @State private var cursor: DividerCursor

    init(orientation: Orientation, onBegin: @escaping () -> Void = {}, onDrag: @escaping (CGFloat) -> Void,
         onDoubleClick: (() -> Void)? = nil) {
        self.orientation = orientation
        self.onBegin = onBegin
        self.onDrag = onDrag
        self.onDoubleClick = onDoubleClick
        _cursor = State(initialValue: DividerCursor(orientation: orientation))
    }

    var body: some View {
        let thickness = WindowLayoutModel.dividerThickness
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: orientation == .vertical ? 1 : nil, height: orientation == .horizontal ? 1 : nil)
        }
        .frame(width: orientation == .vertical ? thickness : nil, height: orientation == .horizontal ? thickness : nil)
        .frame(maxWidth: orientation == .horizontal ? .infinity : nil, maxHeight: orientation == .vertical ? .infinity : nil)
        .contentShape(Rectangle())
        .background(GeometryReader { proxy in
            Color.clear.preference(key: DividerFrameKey.self, value: proxy.frame(in: .global))
        })
        .onPreferenceChange(DividerFrameKey.self) { frame in
            MainActor.assumeIsolated { cursor.frame = frame }
        }
        .onHover { inside in cursor.hover(inside: inside) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        onBegin()
                    }
                    cursor.dragChanged()
                    onDrag(orientation == .vertical ? value.translation.width : value.translation.height)
                }
                .onEnded { value in
                    dragging = false
                    // Hover is not reported during a drag: the pointer may have left the divider
                    // (a pane at its size limit stops following it).
                    cursor.dragEnded(at: value.location)
                }
        )
        .onTapGesture(count: 2) { onDoubleClick?() }
        .onDisappear { cursor.disappeared() }
    }
}

/// The divider's grab area in global coordinates (where a drag's end location is reported).
private struct DividerFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
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
    /// The divider's grab area in the drag's coordinate space (global).
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

    /// A drag of the divider moved.
    func dragChanged() {
        isDragging = true
        set(resize)
    }

    /// The drag ended with the pointer at `location` (global coordinates).
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
