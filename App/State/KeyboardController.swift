import AppKit
import Foundation

/// Editing keys that SwiftUI handles unreliably (bare keys without modifiers, arrows), routed to
/// the store through an application-local key-down monitor.
///
/// Only key presses in the editor window (`ProjectStore.editorWindow`) and the program output
/// window on a second display (`OutputDisplayController.window`) are handled; the Settings window,
/// panels and alerts keep their keys. The output window takes only the transport keys (Space, J/K/L,
/// ←/→, Home/End) and Escape (`isTransportOrCancel`): the user is looking at the picture there, not
/// at the timeline, so Delete, I/O, zoom, gain and Command-A do nothing (the output window closes on
/// Escape unless a drag is in progress). Keys go to the focused control instead when one takes
/// keyboard input: a text field being edited, or a focused control that uses the keys
/// itself (a slider, button, table, pop-up; see `shouldHandleKeys(firstResponder:)`); a click
/// in the timeline, a monitor or the bin takes that focus back (`ProjectStore.reclaimKeyboardFocus`).
/// Handled: Space (play/pause), J/K/L (shuttle), ←/→ (one frame), Home/End (start/end), Delete /
/// Forward Delete (delete in the focused panel; a transition goes with its linked one),
/// Option+Delete (only the selected transition), Shift+Delete (ripple delete), I/O (source
/// in/out), = or + / - (zoom the timeline, like Command-= / Command--), ] / [ (gain of the selected
/// audio clips ±1 dB, with Shift ±10 dB; a burst is one undo step), Escape (cancel the drag in
/// progress, a Ken Burns rectangle drag too; else close the Ken Burns editor; passed on when there is
/// neither), Command-A (select all clips), Control-K (Add Motion
/// Span at Playhead: a Motion span on the selected clip from the playhead, 5 s or to the clip's
/// end, which opens the Ken Burns editor; only the selected clip, or the selected span's clip, never
/// another clip under the playhead: with none selected, or its track locked, it only says why in the
/// status line). Auto-repeat of Space, J/K/L and Control-K is ignored (holding L does not race to
/// 8x, holding Space does not toggle, holding Control-K adds one span). Transport keys drive the
/// monitor that has focus (see `PlaybackActions`).
@MainActor
final class KeyboardController {
    enum Action: Equatable {
        case togglePlay, shuttleReverse, shuttleStop, shuttleForward
        case stepBackward, stepForward
        case goToStart, goToEnd
        case delete, rippleDelete
        /// Option-Delete: the selected transition without its linked one.
        case deleteTransitionOnly
        case markIn, markOut
        case zoomIn, zoomOut
        case cancel
        case selectAll
        /// `]` / `[`: gain of the selected audio clips ±1 dB (with Shift, `}` / `{`: ±10 dB).
        case gainUp(big: Bool), gainDown(big: Bool)
        /// Control-K: Add Motion Span at Playhead on the selected clip (Final Cut Pro's Add Keyframe
        /// key; `ProjectStore.motionSpanTarget`).
        case addMotionSpan

        /// The keys the program output window takes: the transport (play, shuttle, step, start/end)
        /// and Escape. Everything else edits or navigates the timeline.
        var isTransportOrCancel: Bool {
            switch self {
            case .togglePlay, .shuttleReverse, .shuttleStop, .shuttleForward, .stepBackward, .stepForward,
                 .goToStart, .goToEnd, .cancel:
                return true
            default:
                return false
            }
        }

        /// Keys whose auto-repeat is ignored: discrete transport commands, and Control-K (holding it
        /// would try to add a span over and over, each an undo step or a refusal).
        var ignoresRepeat: Bool {
            switch self {
            case .togglePlay, .shuttleReverse, .shuttleStop, .shuttleForward, .addMotionSpan: return true
            default: return false
            }
        }
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
        if flags == .control, characters.lowercased() == "k" {
            return .addMotionSpan
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
            if flags == .option { return .deleteTransitionOnly }
            return nil
        default:
            break
        }
        // "+" is Shift+= on most layouts: accept it with or without Shift.
        if characters == "+", flags.isEmpty || flags == .shift {
            return .zoomIn
        }
        if flags.isEmpty || flags == .shift {
            switch characters {
            case "]": return .gainUp(big: flags == .shift)
            case "[": return .gainDown(big: flags == .shift)
            case "}": return .gainUp(big: true)
            case "{": return .gainDown(big: true)
            default: break
            }
        }
        guard flags.isEmpty else { return nil }
        switch characters.lowercased() {
        case " ": return .togglePlay
        case "j": return .shuttleReverse
        case "k": return .shuttleStop
        case "l": return .shuttleForward
        case "i": return .markIn
        case "o": return .markOut
        case "=": return .zoomIn
        case "-": return .zoomOut
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

    /// Handles a key-down event sent to `window` (the event's window; tests pass one). Returns
    /// whether it was consumed.
    func handle(_ event: NSEvent, window: NSWindow?) -> Bool {
        guard let store, let window, window.attachedSheet == nil else { return false }
        let fromOutput = window === store.outputDisplay.window
        guard window === store.editorWindow || fromOutput else { return false }
        let action = Self.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                 modifiers: event.modifierFlags)
        guard let action else { return false }
        // The output window shows the picture only: no editing from it (the key is not ours, so
        // it goes on to the window, which ignores it).
        if fromOutput, !action.isTransportOrCancel { return false }
        if action == .cancel {
            // Escape cancels a drag in progress (whatever has focus); otherwise it closes the Ken
            // Burns editor (not from the output window, and not while a text field has the key).
            if let cancel = store.cancelActiveGesture {
                cancel()
                return true
            }
            guard !fromOutput, store.kenBurns != nil,
                  Self.shouldHandleKeys(firstResponder: window.firstResponder) else { return false }
            store.closeKenBurns()
            return true
        }
        guard Self.shouldHandleKeys(firstResponder: window.firstResponder) else { return false }
        if event.isARepeat, action.ignoresRepeat {
            return true // swallowed: a held key is one command
        }
        perform(action, on: store)
        return true
    }

    private func handle(_ event: NSEvent) -> Bool {
        handle(event, window: event.window)
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
        case .deleteTransitionOnly: store.deleteSelectedTransitionOnly()
        case .markIn: store.markSourceIn()
        case .markOut: store.markSourceOut()
        case .zoomIn: store.zoomIn()
        case .zoomOut: store.zoomOut()
        case .cancel:
            if let cancel = store.cancelActiveGesture { cancel() } else { store.closeKenBurns() }
        case .selectAll: store.selectAll()
        case let .gainUp(big): store.nudgeGain(big ? InspectorModel.bigStep : 1)
        case let .gainDown(big): store.nudgeGain(big ? -InspectorModel.bigStep : -1)
        case .addMotionSpan: store.addMotionSpanAtPlayhead()
        }
    }
}
