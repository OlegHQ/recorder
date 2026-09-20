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
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                    .contentShape(Rectangle())
                    .onTapGesture { resetIfOption() }
                Spacer(minLength: 8)
                if isTyping {
                    TextField("", text: $typedText, onCommit: commitTyped)
                        .accessibilityLabel("\(title), numeric value")
                        .textFieldStyle(TechFieldStyle())
                        .font(Font(Theme.timecodeFont(11)))
                        .frame(width: 64)
                        .onExitCommand { isTyping = false }
                } else {
                    Text(format(value))
                        .font(Font(Theme.timecodeFont(12)))
                        .foregroundStyle(Theme.textPrimaryColor)
                        .frame(minWidth: 48, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { startTyping() }
                        .onTapGesture(count: 1) { resetIfOption() }
                        .help("Double-click to enter a value · Option-click to reset")
                }
            }.frame(minHeight: 22)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
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
