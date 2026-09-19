import SwiftUI
import RecorderCore

struct CameraTab: View {
    let model: EditorModel
    var layoutID: UUID? = nil

    private var camera: Camera {
        layoutID.flatMap { id in model.project.layouts.first { $0.id == id.uuidString }?.camera } ?? model.project.camera
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.project.source.hasCamera {
                Text("No camera recorded for this project").foregroundStyle(Theme.textSecondaryColor)
            }
            LabeledSlider(title: "Size", value: field(\.size), range: 0.1...1,
                          defaultValue: 0.2, onEditingChanged: gesture("Camera size"))
            Picker("Aspect ratio", selection: Binding(get: { camera.aspect }, set: { value in
                model.edit("Camera aspect ratio") { change(&$0) { $0.aspect = value } }
            })) {
                Text("Square · 1:1").tag(1.0)
                Text("Landscape · 16:9").tag(16.0 / 9)
                Text("Classic · 4:3").tag(4.0 / 3)
                Text("Portrait · 9:16").tag(9.0 / 16)
            }
            PositionGrid(position: position) { point in
                model.edit("Camera position") { change(&$0) { $0.position = point } }
            }
            LabeledSlider(title: "Horizontal", value: positionField(horizontal: true), range: 0...1,
                          defaultValue: 1, onEditingChanged: gesture("Camera position"))
            LabeledSlider(title: "Vertical", value: positionField(horizontal: false), range: 0...1,
                          defaultValue: 1, onEditingChanged: gesture("Camera position"))
            Group {
                LabeledSlider(title: "Roundness", value: field(\.roundness), range: 0...1,
                              defaultValue: 0.5, onEditingChanged: gesture("Camera roundness"))
                LabeledSlider(title: "Shadow", value: field(\.shadow), range: 0...1,
                              defaultValue: 0.5, onEditingChanged: gesture("Camera shadow"))
                Toggle("Mirror", isOn: Binding(get: { camera.mirror }, set: { value in
                    model.edit("Camera mirror") { change(&$0) { $0.mirror = value } }
                }))
                Toggle("Shrink when zoomed", isOn: Binding(get: { camera.shrinkWhenZoomed }, set: { value in
                    model.edit("Camera shrink when zoomed") { change(&$0) { $0.shrinkWhenZoomed = value } }
                }))
            }
            if layoutID == nil {
                Divider()
                Text("Animate on timeline").font(.headline)
                Button("Add size / position change") { addLayout(.bubble) }
                Button("Hide camera") { addLayout(.hidden) }
                Button("Camera fullscreen") { addLayout(.cameraFull) }
                Text("Drag a camera block’s edges to set its duration. Changes ease in and out.")
                    .font(.caption).foregroundStyle(Theme.textSecondaryColor)
            }
        }
        .disabled(!model.project.source.hasCamera)
    }

    private func change(_ project: inout Project, _ update: (inout Camera) -> Void) {
        if let layoutID, let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) {
            var value = project.layouts[i].camera ?? project.camera
            update(&value)
            project.layouts[i].camera = value
        } else { update(&project.camera) }
    }

    private func field(_ keyPath: WritableKeyPath<Camera, Double>) -> Binding<Double> {
        Binding(get: { camera[keyPath: keyPath] }, set: { value in
            model.update { change(&$0) { $0[keyPath: keyPath] = value } }
        })
    }

    private var position: NormPoint {
        camera.position ?? NormPoint(x: camera.corner == .topLeft || camera.corner == .bottomLeft ? 0 : 1,
                                     y: camera.corner == .topLeft || camera.corner == .topRight ? 0 : 1)
    }

    private func positionField(horizontal: Bool) -> Binding<Double> {
        Binding(get: { horizontal ? position.x : position.y }, set: { value in
            var point = position
            if horizontal { point.x = value } else { point.y = value }
            model.update { change(&$0) { $0.position = point } }
        })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private func addLayout(_ kind: RecorderCore.Layout.Kind) {
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        var id: UUID?
        model.edit("Add camera change") { id = $0.addLayout(atSource: time, kind: kind) }
        if let id { model.selectedClip = nil; model.selection = [id] }
    }
}
