import AppKit
import SwiftUI

/// Delivers scroll-wheel and trackpad scroll events over its area to `onScroll`.
///
/// SwiftUI has no scroll-wheel modifier on macOS 14. This transparent background view installs
/// an application-local event monitor while it is in a window and consumes scroll events whose
/// location falls inside its bounds (other events and other windows are untouched). It never
/// takes part in hit testing, so gestures on the views above it keep working.
struct ScrollWheelCatcher: NSViewRepresentable {
    struct Scroll {
        /// Scroll distance in points (positive: content moves right/down, like AppKit's deltas).
        var deltaX: CGFloat
        var deltaY: CGFloat
        /// Pointer location in this view's coordinates, origin top-left.
        var location: CGPoint
        var modifiers: NSEvent.ModifierFlags
        /// A trackpad or another device with precise deltas (not a notched mouse wheel, whose
        /// deltas are multiplied by 10 here).
        var isPrecise: Bool = false
    }

    var onScroll: (Scroll) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((Scroll) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                self.onScroll?(Scroll(deltaX: event.scrollingDeltaX * scale, deltaY: event.scrollingDeltaY * scale,
                                      location: point, modifiers: event.modifierFlags,
                                      isPrecise: event.hasPreciseScrollingDeltas))
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}
