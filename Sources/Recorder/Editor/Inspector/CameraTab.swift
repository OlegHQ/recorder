import SwiftUI
import RecorderCore

/// SPEC §6.6 Camera tab: Size, Position (corner), Roundness, Shadow, Mirror, Shrink when zoomed —
/// every `Camera` field — plus "[+ Add fullscreen layout]" (adds a `cameraFull` `Layout` block at
/// the playhead's SOURCE time, via `Project.addLayout`, the same generic block op the layout
/// lane's own empty-lane click uses). Disabled with an empty-state line when the project has no
/// camera track (`source.hasCamera == false`).
struct CameraTab: View {
    let model: EditorModel

    private var camera: Camera { model.project.camera }
    private var hasCamera: Bool { model.project.source.hasCamera }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hasCamera {
                Text("No camera recorded for this project")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondaryColor)
            }

            LabeledSlider(title: "Size", value: fieldBinding(\.camera.size), range: 0.1...0.4,
                          defaultValue: 0.2, onEditingChanged: gesture("Camera size"))

            cornerPicker

            LabeledSlider(title: "Roundness", value: fieldBinding(\.camera.roundness),
                          range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Camera roundness"))
            LabeledSlider(title: "Shadow", value: fieldBinding(\.camera.shadow),
                          range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Camera shadow"))

            Toggle("Mirror", isOn: mirrorBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)

            Toggle("Shrink when zoomed", isOn: shrinkWhenZoomedBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)

            Button(action: addFullscreenLayout) {
                Label("Add fullscreen layout", systemImage: "plus")
            }
        }
        .disabled(!hasCamera)
    }

    /// SPEC §6.6 Camera tab's "[+ Add fullscreen layout]": one `cameraFull` `Layout` block at the
    /// playhead's SOURCE time (`TimeMap`, per CLAUDE.md's "source-time storage" rule), selected
    /// afterwards so its panel shows immediately.
    private func addFullscreenLayout() {
        let sourceTime = model.timeMap.sourceTime(atOutput: model.playhead)
        var newID: UUID?
        model.edit("Add Layout") { newID = $0.addLayout(atSource: sourceTime, kind: .cameraFull) }
        if let newID {
            model.selectedClip = nil
            model.selection = [newID]
        }
    }

    /// Four corner buttons (◰ ◳ ◱ ◲, SPEC §6.6's own glyphs) mirroring `Camera.Corner`'s case order.
    private var cornerPicker: some View {
        HStack(spacing: 8) {
            Text("Position")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondaryColor)
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) {
                cornerButton("◰", .topLeft)
                cornerButton("◳", .topRight)
                cornerButton("◱", .bottomLeft)
                cornerButton("◲", .bottomRight)
            }
        }
    }

    private func cornerButton(_ glyph: String, _ corner: Camera.Corner) -> some View {
        let selected = camera.corner == corner
        return Button {
            model.edit("Camera position") { $0.camera.corner = corner }
        } label: {
            Text(glyph)
                .font(.system(size: 15))
                .frame(width: 28, height: 22)
                .background(selected ? Theme.accentColor : Theme.bgControlColor)
                .foregroundStyle(selected ? Color.white : Theme.textSecondaryColor)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bindings

    private func fieldBinding(_ keyPath: WritableKeyPath<Project, Double>) -> Binding<Double> {
        Binding(get: { model.project[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(get: { camera.mirror }, set: { newValue in model.edit("Camera mirror") { $0.camera.mirror = newValue } })
    }

    private var shrinkWhenZoomedBinding: Binding<Bool> {
        Binding(get: { camera.shrinkWhenZoomed },
                set: { newValue in model.edit("Camera shrink when zoomed") { $0.camera.shrinkWhenZoomed = newValue } })
    }
}
