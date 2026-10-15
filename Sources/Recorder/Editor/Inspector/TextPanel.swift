import SwiftUI
import RecorderCore

/// Inspector panel while a Text-lane block is selected (SPEC "Editor roadmap" Text): text, style, size,
/// 3x3 position, Remove. Same recipe as `MaskPanel`.
struct TextPanel: View {
    let model: EditorModel
    let textID: UUID
    @FocusState private var typing: Bool

    private var text: TextBlock? { model.project.texts.first { $0.id == textID.uuidString } }
    private static let xs = [0.2, 0.5, 0.8], ys = [0.15, 0.5, 0.8]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Text") { model.selection = [] }
            if let text {
                TextField("Text", text: Binding(get: { text.text }, set: { new in change { $0.setText(new) } }), axis: .vertical)
                    .focused($typing)
                    .onChange(of: typing) { _, now in
                        if now { model.beginGesture() } else { model.commitGesture("Edit text") }
                    }
                HStack(spacing: 8) {
                    Text("Style").font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor).frame(width: 60, alignment: .leading)
                    TechSegmentedControl(selection: Binding(get: { text.style }, set: { new in edit { $0.style = new } }), options: [
                        (.caption, "Caption"), (.title, "Title"), (.label, "Label"),
                    ])
                }
                LabeledSlider(title: "Size", value: Binding(get: { text.size }, set: { new in change { $0.size = new } }), range: 16...120,
                              defaultValue: 48, format: { String(format: "%.0f", $0) },
                              onEditingChanged: { $0 ? model.beginGesture() : model.commitGesture("Text size") })
                VStack(alignment: .leading, spacing: 4) {
                    Text("Position").font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                    ForEach(Self.ys, id: \.self) { y in
                        HStack(spacing: 4) {
                            ForEach(Self.xs, id: \.self) { x in
                                let here = abs(text.position.x - x) < 0.01 && abs(text.position.y - y) < 0.01
                                Button { edit { $0.position = NormPoint(x: x, y: y) } } label: { Text(here ? "●" : "○").frame(maxWidth: .infinity) }
                                    .buttonStyle(TechButtonStyle(kind: here ? .primary : .quiet, compact: true))
                            }
                        }
                    }
                }
                Button("Remove", role: .destructive) {
                    model.edit("Remove text") { $0.removeBlock(textID) }
                    model.selection = []
                }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
                Divider().padding(.vertical, 4)
            }
            AddTextButton(model: model)
        }
    }

    /// Live change inside a gesture (slider / text field).
    private func change(_ body: (inout TextBlock) -> Void) {
        model.update { if let i = $0.texts.firstIndex(where: { $0.id == textID.uuidString }) { body(&$0.texts[i]) } }
    }

    /// One-shot change = one undo step.
    private func edit(_ body: @escaping (inout TextBlock) -> Void) {
        model.edit("Text") { if let i = $0.texts.firstIndex(where: { $0.id == textID.uuidString }) { body(&$0.texts[i]) } }
    }
}

/// Pinned "Add text at playhead" action (also the `T` key on the timeline).
struct AddTextButton: View {
    let model: EditorModel
    var body: some View {
        Button("Add text at playhead") { model.addText(atSource: model.timeMap.sourceTime(atOutput: model.playhead)) }
            .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
    }
}
