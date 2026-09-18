import SwiftUI
import RecorderCore

/// SPEC §6.6 "Zoom selected": replaces the tabs in `InspectorView` while a zoom block is selected.
/// Level/Mode/Instant edit the `Zoom` in place (plain field writes through `model.edit`/`update`,
/// same pattern as `BackgroundTab` — none of these touch the start/end invariants); Remove goes
/// through the shared `Project.removeBlock` op (`TimelineOps.swift`).
struct ZoomPanel: View {
    let model: EditorModel
    let zoomID: UUID

    private var index: Int? { model.project.zooms.firstIndex { $0.id == zoomID.uuidString } }
    private var zoom: Zoom? { index.map { model.project.zooms[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Zoom") { deselect() }

            if let zoom {
                LabeledSlider(title: "Level", value: fieldBinding(\.scale), range: 1.2...5, defaultValue: 2,
                              format: { String(format: "%.1f×", $0) }, onEditingChanged: gesture("Zoom level"))

                HStack(spacing: 8) {
                    Text("Mode")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: modeBinding) {
                        Text("Auto").tag(Zoom.Mode.auto)
                        Text("Manual").tag(Zoom.Mode.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if zoom.mode == .manual {
                    Text("Drag the frame in the preview to set the target")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondaryColor)
                }

                Toggle("Instant (no animation)", isOn: instantBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimaryColor)

                HStack {
                    Button(zoom.enabled ? "Disable" : "Enable", action: toggleEnabled)
                    Button("Remove", role: .destructive, action: remove)
                }
            }
        }
    }

    // MARK: - Bindings

    /// A slider bound to one field of the selected zoom, found by id each time (its index can
    /// shift as other zooms are added/removed). Drags go through `update` (no snapshot per tick);
    /// `gesture(_:)` wraps the whole drag in one `beginGesture`/`commitGesture` (AC-INS-2).
    private func fieldBinding(_ keyPath: WritableKeyPath<Zoom, Double>) -> Binding<Double> {
        Binding(
            get: { zoom?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                model.update { project in
                    guard let i = project.zooms.firstIndex(where: { $0.id == zoomID.uuidString }) else { return }
                    project.zooms[i][keyPath: keyPath] = newValue
                }
            })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var modeBinding: Binding<Zoom.Mode> {
        Binding(get: { zoom?.mode ?? .manual }, set: { newValue in edit { $0.mode = newValue } })
    }

    private var instantBinding: Binding<Bool> {
        Binding(get: { zoom?.instant ?? false }, set: { newValue in edit { $0.instant = newValue } })
    }

    private func toggleEnabled() {
        edit { $0.enabled.toggle() }
    }

    private func remove() {
        model.edit("Remove zoom") { $0.removeBlock(zoomID) }
        deselect()
    }

    private func edit(_ change: @escaping (inout Zoom) -> Void) {
        model.edit("Zoom") { project in
            guard let i = project.zooms.firstIndex(where: { $0.id == zoomID.uuidString }) else { return }
            change(&project.zooms[i])
        }
    }

    private func deselect() {
        model.selection = []
    }
}
