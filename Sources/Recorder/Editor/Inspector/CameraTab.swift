import SwiftUI
import RecorderCore

struct CameraTab: View {
    let model: EditorModel
    var layoutID: UUID? = nil
    var spatialControls = true
    var showsTimelineActions = true

    private var camera: Camera {
        layoutID.flatMap { id in model.project.layouts.first { $0.id == id.uuidString }?.camera } ?? model.project.camera
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spatialControls ? 8 : 12) {
            if !model.project.source.hasCamera {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No camera track")
                        .font(Font(Theme.headingFont(18)))
                    Text("Camera controls appear here when the recording includes a camera source.")
                        .foregroundStyle(Theme.textSecondaryColor)
                }
                .padding(.vertical, 4)
            } else {
                LabeledSlider(title: "Size", value: field(\.size), range: 0.1...1,
                              defaultValue: 0.2, onEditingChanged: gesture("Camera size"))
                    .modifier(InspectorReveal(identity: layoutID?.uuidString ?? "camera", order: 0))
                Picker("Aspect ratio", selection: Binding(get: { camera.aspect }, set: { value in
                    model.edit("Camera aspect ratio") { change(&$0) { $0.aspect = value } }
                })) {
                    Text("Square · 1:1").tag(1.0)
                    Text("Landscape · 16:9").tag(16.0 / 9)
                    Text("Classic · 4:3").tag(4.0 / 3)
                    Text("Portrait · 9:16").tag(9.0 / 16)
                }
                .modifier(InspectorReveal(identity: layoutID?.uuidString ?? "camera", order: 1))
                if spatialControls {
                    PlacementPad(position: position, onChange: { point in
                        model.update { change(&$0) { $0.position = point } }
                    }, onEditingChanged: gesture("Camera position"), onCancel: { model.cancelGesture() })
                    .modifier(InspectorReveal(identity: layoutID?.uuidString ?? "camera", order: 2))
                    DisclosureGroup("Precise coordinates") {
                        coordinates
                    }
                    .modifier(InspectorReveal(identity: layoutID?.uuidString ?? "camera", order: 3))
                } else {
                    PositionGrid(position: position) { point in
                        model.edit("Camera position") { change(&$0) { $0.position = point } }
                    }
                    coordinates
                }
                if spatialControls {
                    DisclosureGroup("Shape & finish") { finish }
                        .modifier(InspectorReveal(identity: layoutID?.uuidString ?? "camera", order: 3))
                } else { finish }
                if layoutID == nil && showsTimelineActions {
                    Divider()
                    CameraTimelineActions(model: model)
                }
            }
        }
    }

    private var coordinates: some View {
        VStack(spacing: 8) {
            LabeledSlider(title: "Horizontal", value: positionField(horizontal: true), range: 0...1,
                          defaultValue: 1, onEditingChanged: gesture("Camera position"))
            LabeledSlider(title: "Vertical", value: positionField(horizontal: false), range: 0...1,
                          defaultValue: 1, onEditingChanged: gesture("Camera position"))
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 8) {
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

}

/// Shared by the standard form and the prototype's persistent footer.
struct CameraTimelineActions: View {
    let model: EditorModel
    private var canAdd: Bool {
        model.project.source.hasCamera && model.project.previewLayoutPlacement(
            atSource: model.timeMap.sourceTime(atOutput: model.playhead)) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(canAdd ? "Change at playhead" : "No free layout interval here")
                Spacer(minLength: 0)
                Text(String(format: "%.1f s", model.playhead)).font(Font(Theme.timecodeFont(10)))
            }.font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            HStack(spacing: 4) {
                Button("Position / size") { addLayout(.bubble) }
                    .help("Create a timed camera appearance override at the playhead")
                Button("Hide") { addLayout(.hidden) }
                    .help("Hide the camera for a new timeline interval")
                Button("Fullscreen") { addLayout(.cameraFull) }
                    .help("Make the camera fullscreen for a new timeline interval")
            }
            .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            .disabled(!canAdd)
        }
    }

    private func addLayout(_ kind: RecorderCore.Layout.Kind) {
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        var id: UUID?
        model.edit("Add camera change") { id = $0.addLayout(atSource: time, kind: kind) }
        if let id { model.selectedClip = nil; model.selection = [id] }
    }
}
