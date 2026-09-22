import AppKit
import SwiftUI

/// Gives SwiftUI content access to its hosting `NSWindow`: keeps the title, represented file and
/// edited dot in sync with the project, and asks before closing a window with unsaved changes.
struct WindowAccessor: NSViewRepresentable {
    var title: String
    var representedURL: URL?
    var isEdited: Bool
    /// Returns whether the window may close (e.g. after a save-or-discard prompt).
    var shouldClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = { window in
            context.coordinator.attach(to: window)
            apply(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        view.onWindow = { window in
            context.coordinator.attach(to: window)
            apply(to: window)
        }
        if let window = view.window {
            context.coordinator.attach(to: window)
            apply(to: window)
        }
    }

    /// Reports the window it is placed in.
    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeCoordinator() -> CloseGuard {
        CloseGuard(shouldClose: shouldClose)
    }

    private func apply(to window: NSWindow) {
        if window.title != title { window.title = title }
        if window.representedURL != representedURL { window.representedURL = representedURL }
        if window.isDocumentEdited != isEdited { window.isDocumentEdited = isEdited }
    }

    /// Window delegate proxy: answers windowShouldClose and forwards everything else to the
    /// delegate SwiftUI installed.
    @MainActor
    final class CloseGuard: NSObject, NSWindowDelegate {
        var shouldClose: @MainActor () -> Bool
        private weak var original: NSWindowDelegate?
        private weak var window: NSWindow?

        init(shouldClose: @escaping @MainActor () -> Bool) {
            self.shouldClose = shouldClose
        }

        func attach(to window: NSWindow) {
            guard self.window !== window || window.delegate !== self else { return }
            if window.delegate !== self {
                original = window.delegate
                window.delegate = self
            }
            self.window = window
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if let original, original.responds(to: selector) {
                return original
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
