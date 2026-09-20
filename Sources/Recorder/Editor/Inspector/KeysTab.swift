import SwiftUI
import RecorderCore

struct KeysTab: View {
    let model: EditorModel
    var layoutID: UUID? = nil
    var showsTimelineActions = true

    private var keys: Keys {
        layoutID.flatMap { id in model.project.keystrokeClips.first { $0.id == id.uuidString }?.keys } ?? model.project.keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show keystrokes", isOn: field(\.show))
            Divider().padding(.vertical, 4)
            LabeledSlider(title: "Size", value: slider(\.size), range: 0.5...3, defaultValue: 1, onEditingChanged: gesture)
            LabeledSlider(title: "Duration", value: slider(\.hold), range: 0.3...5, defaultValue: 1.2, format: { String(format: "%.1f s", $0) }, onEditingChanged: gesture)
            PositionGrid(position: keys.position) { point in
                model.edit("Key position") { change(&$0) { $0.position = point } }
            }
            DisclosureGroup("Precise coordinates") {
                LabeledSlider(title: "Horizontal", value: slider(\.position.x), range: 0...1, defaultValue: 0.5, onEditingChanged: gesture)
                LabeledSlider(title: "Vertical", value: slider(\.position.y), range: 0...1, defaultValue: 1, onEditingChanged: gesture)
            }
            DisclosureGroup("Recorded keys") {
                Toggle("Include all recorded keys", isOn: field(\.allKeys))
                Text("This control only displays keys captured during recording. Enable Record all keystrokes in Settings for future recordings to include typed keys.")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if layoutID == nil && showsTimelineActions { KeysTimelineActions(model: model) }
        }
    }

    private func change(_ project: inout Project, _ update: (inout Keys) -> Void) {
        if let layoutID, let i = project.keystrokeClips.firstIndex(where: { $0.id == layoutID.uuidString }) {
            var value = project.keystrokeClips[i].keys ?? project.keys
            update(&value)
            project.keystrokeClips[i].keys = value
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Position").font(Font(Theme.headingFont(22)))
                Text("Anchor in frame")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ForEach(0..<3) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<3) { column in
                            let point = NormPoint(x: Double(column) / 2, y: Double(row) / 2)
                            let selected = position == point
                            Button { onSelect(point) } label: {
                                ZStack {
                                    Rectangle().fill(selected ? Theme.accentColor : .clear)
                                    Circle().fill(selected ? Theme.bgWindowColor : Theme.textSecondaryColor)
                                        .frame(width: selected ? 6 : 3, height: selected ? 6 : 3)
                                }.frame(width: 32, height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(names[row * 3 + column])
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help(names[row * 3 + column])
                        }
                    }
                }
            }
            .padding(4)
            .background(Theme.bgControlColor)
            .overlay(Rectangle().strokeBorder(Theme.strokeStrongColor))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: position)
        }.padding(.vertical, 8)
    }
}

struct KeysTimelineActions: View {
    let model: EditorModel
    private var time: Double { model.timeMap.sourceTime(atOutput: model.playhead) }
    private var activeID: UUID? {
        model.project.keystrokeClips.first { time >= $0.start && time < $0.end }
            .flatMap { UUID(uuidString: $0.id) }
    }
    private var canAdd: Bool {
        var trial = model.project
        return trial.addLayout(atSource: time, kind: .settings) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activeID != nil ? "Timed keystroke settings active" : "Change at playhead")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Button(activeID != nil ? "Edit this timed interval" : "Add timed keystroke settings") {
                var id = activeID
                if id == nil { model.edit("Add keystroke settings") { id = $0.addLayout(atSource: time, kind: .settings) } }
                if let id {
                    model.selectedClips = []
                    model.selection = [id]
                    model.inspectorShowsProject = false
                }
            }
            .buttonStyle(TechButtonStyle(kind: activeID != nil ? .primary : .secondary, compact: true))
            .disabled(activeID == nil && !canAdd)
        }
    }
}
