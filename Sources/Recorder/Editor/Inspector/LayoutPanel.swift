import SwiftUI
import RecorderCore

/// Edits the camera treatment for a selected timeline interval.
struct LayoutPanel: View {
    let model: EditorModel
    let layoutID: UUID

    private var index: Int? { model.project.layouts.firstIndex { $0.id == layoutID.uuidString } }
    private var layout: RecorderCore.Layout? { index.map { model.project.layouts[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: layout?.kind == .settings ? "Keystroke clip" : "Camera layout") { deselect() }

            if let layout {
                EffectPreviewControls(model: model, start: layout.start, end: layout.end)
                if layout.kind != .settings {
                    TechSegmentedControl(selection: Binding(get: { layout.kind }, set: setKind), options: [
                        (.bubble, "Bubble"), (.cameraFull, "Fullscreen"), (.hidden, "Hidden"),
                    ])

                }
                if layout.kind == .bubble { CameraTab(model: model, layoutID: layoutID) }
                Divider().padding(.vertical, 4)
                LabeledSlider(title: "Transition", value: Binding(get: { layout.transition }, set: { value in
                    model.update { project in
                        guard let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) else { return }
                        project.layouts[i].transition = value
                    }
                }), range: 0...2, defaultValue: 0.3, format: { String(format: "%.1f s", $0) },
                onEditingChanged: { $0 ? model.beginGesture() : model.commitGesture("Overlay transition") })
                Divider()
                if layout.kind == .settings {
                Toggle("Override keystroke settings", isOn: Binding(get: { layout.keys != nil }, set: { enabled in
                    edit { $0.keys = enabled ? model.project.keys : nil }
                }))
                if layout.keys != nil { KeysTab(model: model, layoutID: layoutID) }
                }

                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(TechButtonStyle(kind: .danger, compact: true))
            }
        }
    }

    // MARK: - Actions

    private func setKind(_ kind: RecorderCore.Layout.Kind) {
        edit { $0.kind = kind }
    }

    private func remove() {
        model.edit("Remove layout") { $0.removeBlock(layoutID) }
        deselect()
    }

    private func edit(_ change: @escaping (inout RecorderCore.Layout) -> Void) {
        model.edit("Layout") { project in
            guard let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) else { return }
            change(&project.layouts[i])
        }
    }

    private func deselect() {
        model.selection = []
    }
}
