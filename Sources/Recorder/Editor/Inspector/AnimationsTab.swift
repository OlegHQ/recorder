import SwiftUI
import RecorderCore

/// SPEC §6.6 Animations tab: Motion blur amount, an Advanced fold of per-source blur toggles
/// (Cursor/Zoom/Pan), and the zoom spring preset (Focused/Smooth) — every `Animation` field. The
/// cursor Movement (smoothing) picker stays on the Cursor tab (plan T-501 note).
struct AnimationsTab: View {
    let model: EditorModel

    // `RecorderCore.Animation` because SwiftUI has its own `Animation` type in scope.
    private var animation: RecorderCore.Animation { model.project.animation }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledSlider(title: "Motion blur", value: fieldBinding(\.animation.motionBlur),
                          range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Motion blur"))

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    checkbox("Cursor", blurCursorBinding)
                    checkbox("Zoom", blurZoomBinding)
                    checkbox("Pan", blurPanBinding)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimaryColor)

            HStack(spacing: 8) {
                Text("Screen")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondaryColor)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: screenBinding) {
                    Text("Focused").tag(RecorderCore.Animation.Screen.focused)
                    Text("Smooth").tag(RecorderCore.Animation.Screen.smooth)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
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

    private var blurCursorBinding: Binding<Bool> {
        Binding(get: { animation.blurCursor },
                set: { newValue in model.edit("Motion blur cursor") { $0.animation.blurCursor = newValue } })
    }

    private var blurZoomBinding: Binding<Bool> {
        Binding(get: { animation.blurZoom },
                set: { newValue in model.edit("Motion blur zoom") { $0.animation.blurZoom = newValue } })
    }

    private var blurPanBinding: Binding<Bool> {
        Binding(get: { animation.blurPan },
                set: { newValue in model.edit("Motion blur pan") { $0.animation.blurPan = newValue } })
    }

    private var screenBinding: Binding<RecorderCore.Animation.Screen> {
        Binding(get: { animation.screen }, set: { newValue in model.edit("Zoom spring") { $0.animation.screen = newValue } })
    }
}
