import SwiftUI
import RecorderCore

/// SPEC §6.6 Cursor tab: Hide, Size, Movement, Hide when idle, Loop cursor position, and the
/// Advanced fold (Always use arrow / Rotate while moving / Remove cursor shakes) — all backed by
/// `CursorStyle` fields, all wired through `EditorModel.edit` (T-604 UI half; the `CursorPath`
/// behaviour they drive is core work already merged, see plan Log).
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

            checkbox("Loop cursor position", loopBinding)

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    checkbox("Always use arrow", alwaysArrowBinding)
                    checkbox("Rotate while moving", rotateBinding)
                    checkbox("Remove cursor shakes", removeShakesBinding)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimaryColor)
        }
    }

    private func checkbox(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimaryColor)
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

    private var loopBinding: Binding<Bool> {
        Binding(get: { cursor.loop }, set: { newValue in model.edit("Loop cursor position") { $0.cursor.loop = newValue } })
    }

    private var alwaysArrowBinding: Binding<Bool> {
        Binding(get: { cursor.alwaysArrow },
                set: { newValue in model.edit("Always use arrow") { $0.cursor.alwaysArrow = newValue } })
    }

    private var rotateBinding: Binding<Bool> {
        Binding(get: { cursor.rotate }, set: { newValue in model.edit("Rotate while moving") { $0.cursor.rotate = newValue } })
    }

    private var removeShakesBinding: Binding<Bool> {
        Binding(get: { cursor.removeShakes },
                set: { newValue in model.edit("Remove cursor shakes") { $0.cursor.removeShakes = newValue } })
    }
}
