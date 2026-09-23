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
        /// Shows the menu for the event (tests replace it: the real one tracks the menu modally).
        var popUp: @MainActor (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }

        private var monitor: Any?

        /// The application-local event monitor is installed: exactly while the view is in a window.
        var isMonitoring: Bool { monitor != nil }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            let presses: NSEvent.EventTypeMask = [.rightMouseDown, .leftMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let pressed = event
                let passOn = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return true }
                    return self.handle(pressed, window: pressed.window) != nil
                }
                return passOn ? event : nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        /// A press that asks for a context menu: the right button, or Control with the left one.
        static func isContextClick(type: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags) -> Bool {
            type == .rightMouseDown || (type == .leftMouseDown && modifierFlags.contains(.control))
        }

        /// Handles a press sent to `window` (the event's window; tests pass one): shows the menu
        /// for a context click inside this view and consumes the event (nil); passes anything else
        /// on. Every left click in the app goes through here, so it is filtered on the button and
        /// the Control key before any coordinate conversion or hit testing.
        func handle(_ event: NSEvent, window eventWindow: NSWindow?) -> NSEvent? {
            guard Self.isContextClick(type: event.type, modifierFlags: event.modifierFlags) else { return event }
            guard let window, eventWindow === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            let items = itemsAt?(point) ?? []
            guard !items.isEmpty else { return event }
            popUp(Self.menu(items), event, self)
            return nil
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
