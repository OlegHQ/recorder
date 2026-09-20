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
            Text("Zoom transitions").font(Font(Theme.headingFont(22)))
            TechSegmentedControl(selection: screenBinding, options: [
                (.focused, "Focused"), (.smooth, "Smooth"),
            ])
            Text(animation.screen == .focused ? "Quick, controlled settling." : "Slower settling with a gentle overshoot.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Text("Applies to animated zooms. Instant zooms skip this transition.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Text("Motion blur").font(Font(Theme.headingFont(22)))
            LabeledSlider(title: "Amount", value: fieldBinding(\.animation.motionBlur),
                          range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Motion blur"))
            DisclosureGroup("Blur sources") {
                VStack(alignment: .leading, spacing: 8) {
                    checkbox("Cursor movement", blurCursorBinding)
                    checkbox("Zooming", blurZoomBinding)
                    checkbox("Panning", blurPanBinding)
                }
                .padding(.top, 4)
            }
            .font(Font(Theme.bodyFont))
            .foregroundStyle(Theme.textPrimaryColor)
            Text("Play the recording to judge motion and blur.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private func checkbox(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
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

/// Connect whole-project transition settings to the interval visible in the preview.
struct ZoomTimelineActions: View {
    let model: EditorModel
    private var time: Double { model.timeMap.sourceTime(atOutput: model.playhead) }
    private var activeID: UUID? {
        model.project.zooms.first { time >= $0.start && time < $0.end }
            .flatMap { UUID(uuidString: $0.id) }
    }
    private var canAdd: Bool {
        guard model.playhead < model.timeMap.outputDuration else { return false }
        var trial = model.project
        return trial.addZoom(atSource: time, mode: .manual) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activeID != nil ? "Zoom active at playhead" : "Emphasize a moment")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Button(activeID != nil ? "Edit this zoom" : "Add zoom at playhead") {
                if let id = activeID {
                    model.isPlaying = false
                    model.selectedClips = []
                    model.selection = [id]
                    model.inspectorShowsProject = false
                } else { model.addZoom(atSource: time) }
            }
            .buttonStyle(TechButtonStyle(kind: activeID != nil ? .primary : .secondary, compact: true))
            .disabled(activeID == nil && !canAdd)
        }
    }
}
