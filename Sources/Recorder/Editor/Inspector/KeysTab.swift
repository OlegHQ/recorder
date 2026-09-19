import SwiftUI
import RecorderCore

struct KeysTab: View {
    let model: EditorModel
    var layoutID: UUID? = nil

    private var keys: Keys {
        layoutID.flatMap { id in model.project.layouts.first { $0.id == id.uuidString }?.keys } ?? model.project.keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show keystrokes", isOn: field(\.show))
            Toggle("Include all recorded keys", isOn: field(\.allKeys))
            Text("To include typed keys in new recordings, enable Record all keystrokes in Settings. Older recordings contain shortcuts only.")
                .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            LabeledSlider(title: "Size", value: slider(\.size), range: 0.5...3, defaultValue: 1, onEditingChanged: gesture)
            LabeledSlider(title: "Duration", value: slider(\.hold), range: 0.3...5, defaultValue: 1.2, format: { String(format: "%.1f s", $0) }, onEditingChanged: gesture)
            PositionGrid(position: keys.position) { point in
                model.edit("Key position") { change(&$0) { $0.position = point } }
            }
            LabeledSlider(title: "Horizontal", value: slider(\.position.x), range: 0...1, defaultValue: 0.5, onEditingChanged: gesture)
            LabeledSlider(title: "Vertical", value: slider(\.position.y), range: 0...1, defaultValue: 1, onEditingChanged: gesture)
            if layoutID == nil {
                Button("Add keystroke settings clip") {
                    let time = model.timeMap.sourceTime(atOutput: model.playhead)
                    var id: UUID?
                    model.edit("Add keystroke settings") { project in
                        id = project.addLayout(atSource: time, kind: .settings)
                    }
                    if let id { model.selectedClip = nil; model.selection = [id] }
                }
            }
        }
    }

    private func change(_ project: inout Project, _ update: (inout Keys) -> Void) {
        if let layoutID, let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) {
            var value = project.layouts[i].keys ?? project.keys
            update(&value)
            project.layouts[i].keys = value
        } else { update(&project.keys) }
    }

    private func gesture(_ editing: Bool) {
        editing ? model.beginGesture() : model.commitGesture("Keystroke settings")
    }

    private func slider(_ path: WritableKeyPath<Keys, Double>) -> Binding<Double> {
        Binding(get: { keys[keyPath: path] }, set: { value in
            model.update { change(&$0) { $0[keyPath: path] = value } }
        })
    }

    private func field<T>(_ path: WritableKeyPath<Keys, T>) -> Binding<T> {
        Binding(get: { keys[keyPath: path] }, set: { value in
            model.edit("Keystroke settings") { change(&$0) { $0[keyPath: path] = value } }
        })
    }
}

struct PositionGrid: View {
    let position: NormPoint
    let onSelect: (NormPoint) -> Void
    private let names = ["Top left", "Top center", "Top right", "Middle left", "Center", "Middle right", "Bottom left", "Bottom center", "Bottom right"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Position")
            ForEach(0..<3) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3) { column in
                        let point = NormPoint(x: Double(column) / 2, y: Double(row) / 2)
                        Button { onSelect(point) } label: {
                            Image(systemName: position == point ? "circle.inset.filled" : "circle")
                                .frame(width: 30, height: 20)
                        }
                        .accessibilityLabel(names[row * 3 + column])
                        .help(names[row * 3 + column])
                    }
                }
            }
        }
    }
}
