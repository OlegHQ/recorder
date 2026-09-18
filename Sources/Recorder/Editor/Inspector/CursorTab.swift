import SwiftUI
import RecorderCore

/// SPEC §6.6 Cursor tab — basic controls only (T-414 scope, per the plan): Hide, Size, Movement,
/// Hide when idle. Loop and the Advanced fold (Always use arrow / Rotate while moving / Remove
/// cursor shakes) are shown disabled and tagged "M6" — their `CursorStyle` fields already exist,
/// but wiring them up (and the `CursorPath` behaviour they drive) is later work.
struct CursorTab: View {
    let model: EditorModel

    private var cursor: CursorStyle { model.project.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Hide cursor", isOn: hiddenBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)

            LabeledSlider(title: "Size", value: fieldBinding(\.cursor.size), range: 0.5...4,
                          defaultValue: 1.5, format: { String(format: "%.1f×", $0) },
                          onEditingChanged: gesture("Cursor size"))

            Picker("Movement", selection: styleBinding) {
                Text("Smooth").tag(CursorStyle.Style.smooth)
                Text("Medium").tag(CursorStyle.Style.medium)
                Text("Rapid").tag(CursorStyle.Style.rapid)
                Text("None").tag(CursorStyle.Style.none)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondaryColor)

            Toggle("Hide when idle", isOn: hideWhenIdleBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)

            Divider().overlay(Theme.strokeColor)

            futureToggle("Loop cursor position")
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    futureToggle("Always use arrow")
                    futureToggle("Rotate while moving")
                    futureToggle("Remove cursor shakes")
                }
                .padding(.top, 4)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimaryColor)
        }
    }

    /// A disabled checkbox row tagged "M6" — SPEC's Advanced fold controls, not in this task's scope.
    private func futureToggle(_ title: String) -> some View {
        HStack {
            Toggle(title, isOn: .constant(false))
                .toggleStyle(.checkbox)
            Spacer()
            Text("M6")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondaryColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.bgControlColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .disabled(true)
        .font(.system(size: 13))
        .foregroundStyle(Theme.textSecondaryColor)
    }

    // MARK: - Bindings

    private func fieldBinding(_ keyPath: WritableKeyPath<Project, Double>) -> Binding<Double> {
        Binding(get: { model.project[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(get: { cursor.hidden }, set: { newValue in model.edit("Hide cursor") { $0.cursor.hidden = newValue } })
    }

    private var hideWhenIdleBinding: Binding<Bool> {
        Binding(get: { cursor.hideWhenIdle },
                set: { newValue in model.edit("Hide cursor when idle") { $0.cursor.hideWhenIdle = newValue } })
    }

    private var styleBinding: Binding<CursorStyle.Style> {
        Binding(get: { cursor.style }, set: { newValue in model.edit("Cursor movement") { $0.cursor.style = newValue } })
    }
}
