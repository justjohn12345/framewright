import AppKit
import Foundation

/// Editing keys that SwiftUI handles unreliably (bare keys without modifiers, arrows), routed to
/// the store through an application-local key-down monitor.
///
/// Keys go to the focused control instead when one takes keyboard input: a text field being
/// edited, or a focused control that uses the keys itself (a slider, button, table, pop-up; see
/// `shouldHandleKeys(firstResponder:)`). Handled: Space (play/pause), J/K/L (shuttle), ←/→ (one
/// frame), Home/End (start/end), Delete / Forward Delete (delete selection), Shift+Delete
/// (ripple delete), I/O (source in/out), Escape (cancel drag), Command-A (select all clips).
/// Transport keys drive the monitor that has focus (see `PlaybackActions`).
@MainActor
final class KeyboardController {
    enum Action: Equatable {
        case togglePlay, shuttleReverse, shuttleStop, shuttleForward
        case stepBackward, stepForward
        case goToStart, goToEnd
        case delete, rippleDelete
        case markIn, markOut
        case cancel
        case selectAll
    }

    private weak var store: ProjectStore?
    private var monitor: Any?

    init(store: ProjectStore) {
        self.store = store
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let keyEvent = event
            let consumed = MainActor.assumeIsolated { self?.handle(keyEvent) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Maps a key event to an action (nil: not ours). Exposed for tests.
    static func action(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> Action? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if flags == .command, characters.lowercased() == "a" {
            return .selectAll
        }
        switch keyCode {
        case 53: return flags.isEmpty ? .cancel : nil
        case 123: return flags.isEmpty ? .stepBackward : nil
        case 124: return flags.isEmpty ? .stepForward : nil
        case 115: return flags.isEmpty ? .goToStart : nil
        case 119: return flags.isEmpty ? .goToEnd : nil
        case 51, 117:
            if flags.isEmpty { return .delete }
            if flags == .shift { return .rippleDelete }
            return nil
        default:
            break
        }
        guard flags.isEmpty else { return nil }
        switch characters.lowercased() {
        case " ": return .togglePlay
        case "j": return .shuttleReverse
        case "k": return .shuttleStop
        case "l": return .shuttleForward
        case "i": return .markIn
        case "o": return .markOut
        default: return nil
        }
    }

    /// Whether the editor may take bare keys while `firstResponder` has keyboard focus: not while
    /// text is edited, nor while a focused control (slider, button, table, pop-up, stepper...)
    /// would use Space or the arrows itself. Exposed for tests.
    static func shouldHandleKeys(firstResponder: NSResponder?) -> Bool {
        switch firstResponder {
        case is NSText, is NSControl, is NSCollectionView:
            return false
        default:
            return true
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let store, let window = event.window, window.isKeyWindow, window.attachedSheet == nil else {
            return false
        }
        let action = Self.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                 modifiers: event.modifierFlags)
        guard let action else { return false }
        // Escape always reaches a drag in progress; everything else defers to focused controls.
        if action != .cancel || store.cancelActiveGesture == nil,
           !Self.shouldHandleKeys(firstResponder: window.firstResponder) {
            return false
        }
        perform(action, on: store)
        return true
    }

    func perform(_ action: Action, on store: ProjectStore) {
        switch action {
        case .togglePlay: store.playbackActions.togglePlay()
        case .shuttleReverse: store.playbackActions.shuttleReverse()
        case .shuttleStop: store.playbackActions.shuttleStop()
        case .shuttleForward: store.playbackActions.shuttleForward()
        case .stepBackward: store.playbackActions.stepFrames(-1)
        case .stepForward: store.playbackActions.stepFrames(1)
        case .goToStart: store.playbackActions.goToStart()
        case .goToEnd: store.playbackActions.goToEnd()
        case .delete: store.deleteSelection(ripple: false)
        case .rippleDelete: store.deleteSelection(ripple: true)
        case .markIn: store.markSourceIn()
        case .markOut: store.markSourceOut()
        case .cancel: store.cancelActiveGesture?()
        case .selectAll: store.selectAll()
        }
    }
}
