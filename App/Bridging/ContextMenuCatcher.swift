import AppKit
import SwiftUI

/// One item of a context menu built for a point (see `ContextMenuCatcher`).
struct ContextMenuItem {
    var title: String
    var isEnabled = true
    var action: @MainActor () -> Void

    /// A separator line.
    static var separator: ContextMenuItem {
        ContextMenuItem(title: "", isEnabled: false, action: {})
    }

    var isSeparator: Bool { title.isEmpty }
}

/// Shows a context menu for the point clicked with the right mouse button (or Control-click)
/// inside its bounds. `itemsAt` receives the point in this view's coordinates (origin top-left)
/// and returns the items (it may select what is under the pointer first, as Premiere does); no
/// items, no menu. Like `ScrollWheelCatcher` it is a transparent background that never takes part
/// in hit testing: an application-local event monitor sees the press before SwiftUI does.
struct ContextMenuCatcher: NSViewRepresentable {
    var itemsAt: @MainActor (CGPoint) -> [ContextMenuItem]

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.itemsAt = itemsAt
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.itemsAt = itemsAt
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var itemsAt: (@MainActor (CGPoint) -> [ContextMenuItem])?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let controlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
                guard event.type == .rightMouseDown || controlClick else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let items = MainActor.assumeIsolated { self.itemsAt?(point) ?? [] }
                guard !items.isEmpty else { return event }
                NSMenu.popUpContextMenu(Self.menu(items), with: event, for: self)
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

        static func menu(_ items: [ContextMenuItem]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: #selector(MenuActionTarget.run(_:)),
                                          keyEquivalent: "")
                menuItem.target = MenuActionTarget.shared
                menuItem.representedObject = MenuAction(item.action)
                menuItem.isEnabled = item.isEnabled
                menu.addItem(menuItem)
            }
            return menu
        }
    }
}

/// The closure a context menu item runs (its `representedObject`).
final class MenuAction: NSObject {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// The target of every context menu item: runs the item's `MenuAction`.
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func run(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        MainActor.assumeIsolated { action.run() }
    }
}
