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
    var onBegin: () -> Void = {}
    var onDrag: (CGFloat) -> Void
    var onDoubleClick: (() -> Void)?

    @State private var dragging = false
    @State private var cursorPushed = false

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
        .onHover { inside in
            if inside, !cursorPushed {
                (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                cursorPushed = true
            } else if !inside, cursorPushed, !dragging {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        onBegin()
                    }
                    onDrag(orientation == .vertical ? value.translation.width : value.translation.height)
                }
                .onEnded { _ in
                    dragging = false
                }
        )
        .onTapGesture(count: 2) { onDoubleClick?() }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }
}
