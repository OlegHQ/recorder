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
            InspectorSelectionHeader(title: "Overlay settings") { deselect() }

            if let layout {
                VStack(alignment: .leading, spacing: 6) {
                    kindRow("Keystrokes only", .settings, current: layout.kind)
                    kindRow("Camera visible / size / position", .bubble, current: layout.kind)
                    kindRow("Camera fullscreen", .cameraFull, current: layout.kind)
                    kindRow("Camera hidden", .hidden, current: layout.kind)
                }

                if layout.kind == .bubble { CameraTab(model: model, layoutID: layoutID) }
                LabeledSlider(title: "Transition seconds", value: Binding(get: { layout.transition }, set: { value in
                    model.update { project in
                        guard let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) else { return }
                        project.layouts[i].transition = value
                    }
                }), range: 0...2, defaultValue: 0.3, format: { String(format: "%.1f s", $0) },
                onEditingChanged: { $0 ? model.beginGesture() : model.commitGesture("Overlay transition") })
                Divider()
                Toggle("Override keystroke settings", isOn: Binding(get: { layout.keys != nil }, set: { enabled in
                    edit { $0.keys = enabled ? model.project.keys : nil }
                }))
                if layout.keys != nil { KeysTab(model: model, layoutID: layoutID) }

                Button("Preview change") { previewChange() }
                Button("Remove", role: .destructive, action: remove)
            }
        }
    }

    private func kindRow(_ title: String, _ kind: RecorderCore.Layout.Kind, current: RecorderCore.Layout.Kind) -> some View {
        Button { setKind(kind) } label: {
            HStack(spacing: 8) {
                Image(systemName: current == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(current == kind ? Theme.accentColor : Theme.textSecondaryColor)
                Text(title).foregroundStyle(Theme.textPrimaryColor)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    // MARK: - Actions

    private func previewChange() {
        guard let layout else { return }
        for clip in model.project.clips {
            let start = max(layout.start, clip.sourceStart), end = min(layout.end, clip.sourceEnd)
            if end > start, let output = model.timeMap.outputTime(atSource: (start + end) / 2) {
                model.isPlaying = false
                model.playhead = output
                return
            }
        }
    }

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
