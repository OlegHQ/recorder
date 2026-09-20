import SwiftUI
import RecorderCore

/// SPEC §6.6 "Mask selected" / §7.1 — replaces the tabs in `InspectorView` while a mask block is
/// selected: kind (Mask/Highlight) + Opacity + Remove, same pattern as `ZoomPanel`/`LayoutPanel`.
/// The mask RECT is edited in the preview (`MaskRectOverlay`/`SelectionRectView`), not here.
struct MaskPanel: View {
    let model: EditorModel
    let maskID: UUID

    private var index: Int? { model.project.masks.firstIndex { $0.id == maskID.uuidString } }
    private var mask: Mask? { index.map { model.project.masks[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Mask") { deselect() }

            if let mask {
                EffectPreviewControls(model: model, start: mask.start, end: mask.end, editsRegion: true,
                                      regionHint: "Mask hidden; preview unzoomed for positioning.")
                Divider().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Kind")
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .frame(width: 60, alignment: .leading)
                    TechSegmentedControl(selection: kindBinding, options: [
                        (.mask, "Cover"), (.blur, "Blur"), (.highlight, "Highlight"),
                    ])
                }

                Text(model.previewShowsResult ? "Switch to Edit region to resize the rectangle." : "Drag the rectangle in the preview to resize")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)

                LabeledSlider(title: "Opacity", value: fieldBinding(\.opacity), range: 0...1, defaultValue: 0.8,
                              format: { String(format: "%.0f%%", $0 * 100) }, onEditingChanged: gesture("Mask opacity"))

                Divider().padding(.vertical, 4)
                Toggle("Smooth transition", isOn: Binding(
                    get: { mask.transition > 0 },
                    set: { enabled in edit { $0.transition = enabled ? 0.25 : 0 } }))
                if mask.transition > 0 {
                    LabeledSlider(title: "Fade", value: fieldBinding(\.transition), range: 0.05...1, defaultValue: 0.25,
                                  format: { String(format: "%.2f s", $0) }, onEditingChanged: gesture("Mask transition"))
                }
                if mask.kind != .highlight {
                    Text("For complete redaction, choose Cover at 100% opacity with transitions off.")
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                }

                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(TechButtonStyle(kind: .danger, compact: true))
            }
        }
    }

    // MARK: - Bindings

    /// A slider bound to one field of the selected mask, found by id each time (its index can
    /// shift as other masks are added/removed). Drags go through `update` (no snapshot per tick);
    /// `gesture(_:)` wraps the whole drag in one `beginGesture`/`commitGesture` (AC-INS-2).
    private func fieldBinding(_ keyPath: WritableKeyPath<Mask, Double>) -> Binding<Double> {
        Binding(
            get: { mask?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                model.update { project in
                    guard let i = project.masks.firstIndex(where: { $0.id == maskID.uuidString }) else { return }
                    project.masks[i][keyPath: keyPath] = newValue
                }
            })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var kindBinding: Binding<Mask.Kind> {
        Binding(get: { mask?.kind ?? .mask }, set: { newValue in edit { $0.kind = newValue } })
    }

    private func remove() {
        model.edit("Remove mask") { $0.removeBlock(maskID) }
        deselect()
    }

    private func edit(_ change: @escaping (inout Mask) -> Void) {
        model.edit("Mask") { project in
            guard let i = project.masks.firstIndex(where: { $0.id == maskID.uuidString }) else { return }
            change(&project.masks[i])
        }
    }

    private func deselect() {
        model.selection = []
    }
}
