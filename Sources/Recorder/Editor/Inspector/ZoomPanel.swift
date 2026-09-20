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
                EffectPreviewControls(model: model, start: zoom.start, end: zoom.end, editsRegion: zoom.mode == .manual)
                    .modifier(InspectorReveal(identity: zoomID.uuidString, order: 0))
                Divider().padding(.vertical, 4)
                LabeledSlider(title: "Level", value: fieldBinding(\.scale), range: 1.2...5, defaultValue: 2,
                              format: { String(format: "%.1f×", $0) }, onEditingChanged: gesture("Zoom level"))
                    .modifier(InspectorReveal(identity: zoomID.uuidString, order: 1))

                HStack(spacing: 8) {
                    Text("Mode")
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .frame(width: 60, alignment: .leading)
                    TechSegmentedControl(selection: modeBinding, options: [
                        (.auto, "Auto"), (.manual, "Manual"),
                    ])
                }
                .modifier(InspectorReveal(identity: zoomID.uuidString, order: 2))

                if zoom.mode == .manual && !model.previewShowsResult {
                    Text("Drag the preview frame to set the target.")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                }

                Toggle("Instant (no animation)", isOn: instantBinding)
                    .modifier(InspectorReveal(identity: zoomID.uuidString, order: 3))

                HStack {
                    Button(zoom.enabled ? "Disable" : "Enable", action: toggleEnabled)
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                    Button("Remove", role: .destructive, action: remove)
                        .buttonStyle(TechButtonStyle(kind: .danger, compact: true))
                }
                .modifier(InspectorReveal(identity: zoomID.uuidString, order: 3))
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
