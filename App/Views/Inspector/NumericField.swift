import AppKit
import SwiftUI

/// A text field for a numeric inspector value, backed by `NSTextField` so the keys that matter
/// are handled reliably by AppKit's field editor:
/// - Return (or leaving the field with Tab or a click) commits the typed text;
/// - Up/Down arrow nudge by +1/-1 and Shift+Up/Down by +10/-10 (`nudge`), showing the new
///   value at once;
/// - Escape reverts to the current value.
/// While the field is not being edited it shows `text` (the model's value). `focusSerial`
/// focuses the field whenever it changes (a double-click on a transition focuses its duration).
struct NumericField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let commit: (String) -> Void
    let nudge: (Double) -> Void
    var focusSerial: Int = 0
    var accessibilityIdentifier: String = ""
    var isEnabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.toolTip = "Type a value (units optional); ↑/↓ nudge by 1, ⇧↑/⇧↓ by 10"
        context.coordinator.lastFocusSerial = focusSerial
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        let editing = field.currentEditor() != nil
        if !editing || coordinator.showModelValue {
            if field.stringValue != text {
                field.stringValue = text
            }
            if editing, let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (text as NSString).length)
            }
            coordinator.showModelValue = false
            coordinator.edited = false
        }
        if focusSerial != coordinator.lastFocusSerial {
            coordinator.lastFocusSerial = focusSerial
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumericField
        var lastFocusSerial = 0
        /// The user typed since the field last showed the model's value.
        var edited = false
        /// Show the model's value on the next update even while editing (after a nudge).
        var showModelValue = false

        init(_ parent: NumericField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            edited = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if edited {
                edited = false
                parent.commit(field.stringValue)
            }
            field.stringValue = parent.text
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if edited {
                    edited = false
                    parent.commit(textView.string)
                }
                showModelValue = true
                textView.string = parent.text
                textView.selectAll(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                applyNudge(1, textView: textView)
                return true
            case #selector(NSResponder.moveDown(_:)):
                applyNudge(-1, textView: textView)
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                applyNudge(InspectorModel.bigStep, textView: textView)
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                applyNudge(-InspectorModel.bigStep, textView: textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                edited = false
                textView.string = parent.text
                textView.selectAll(nil)
                return true
            default:
                return false
            }
        }

        private func applyNudge(_ steps: Double, textView: NSTextView) {
            // Typed text not yet committed would be lost: commit it first, then nudge from it.
            if edited {
                edited = false
                parent.commit(textView.string)
            }
            showModelValue = true
            parent.nudge(steps)
        }
    }
}
