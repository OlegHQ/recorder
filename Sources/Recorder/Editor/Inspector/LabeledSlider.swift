import AppKit
import SwiftUI

/// SPEC §6.6: "label left, value right (double-click to type), ⌥-click resets to default." The
/// only slider component in the inspector — every tab uses this, never a bare `Slider`.
///
/// `value` is a plain `Binding<Double>`; the caller's setter is expected to write through
/// `EditorModel.update` (no snapshot) and `onEditingChanged` to wrap `beginGesture`/`commitGesture`
/// around the drag — see `BackgroundTab.fieldBinding`/`gesture`. That way one drag (or one typed
/// value, or one ⌥-click reset) is exactly one undo step (AC-INS-2).
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isTyping = false
    @State private var typedText = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondaryColor)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { resetIfOption() }

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)

            if isTyping {
                TextField("", text: $typedText, onCommit: commitTyped)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 52)
                    .onExitCommand { isTyping = false }
            } else {
                Text(format(value))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.textPrimaryColor)
                    .frame(width: 52, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startTyping() }
                    .onTapGesture(count: 1) { resetIfOption() }
            }
        }
    }

    private func startTyping() {
        typedText = String(value)
        isTyping = true
    }

    private func commitTyped() {
        if let typed = Double(typedText) {
            let clamped = min(max(typed, range.lowerBound), range.upperBound)
            onEditingChanged(true)
            value = clamped
            onEditingChanged(false)
        }
        isTyping = false
    }

    /// ⌥-click resets to `defaultValue`; a plain click here does nothing (the slider itself owns drag).
    private func resetIfOption() {
        guard NSEvent.modifierFlags.contains(.option) else { return }
        onEditingChanged(true)
        value = defaultValue
        onEditingChanged(false)
    }
}
