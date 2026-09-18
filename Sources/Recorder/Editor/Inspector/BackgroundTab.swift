import AppKit
import SwiftUI
import RecorderCore

/// SPEC §6.6 Background tab: a kind picker, that kind's own controls (wallpaper grid / colour or
/// gradient swatches / image chooser), then the kind-independent Blur/Padding/Corners/Inset/Shadow
/// sliders. Every control writes through `EditorModel.edit`/`update`+`beginGesture`/`commitGesture`
/// so it round-trips (AC-INS-1) and a drag is one undo step (AC-INS-2).
struct BackgroundTab: View {
    let model: EditorModel

    private var background: Background { model.project.background }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: kindBinding) {
                Text("Wallpaper").tag(Background.Kind.wallpaper)
                Text("Gradient").tag(Background.Kind.gradient)
                Text("Color").tag(Background.Kind.color)
                Text("Image").tag(Background.Kind.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch background.kind {
            case .wallpaper:
                WallpaperGrid(model: model)
            case .gradient:
                HStack {
                    ColorPicker("Start", selection: gradientBinding(0))
                    ColorPicker("End", selection: gradientBinding(1))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondaryColor)
            case .color:
                ColorPicker("Color", selection: colorBinding)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondaryColor)
            case .image:
                imageChooser
            }

            Divider().overlay(Theme.strokeColor)

            LabeledSlider(title: "Blur", value: fieldBinding(\.background.blur),
                          range: 0...1, defaultValue: 0, format: { "\(Int(($0 * 100).rounded()))" },
                          onEditingChanged: gesture("Blur"))
            LabeledSlider(title: "Padding", value: fieldBinding(\.frame.padding),
                          range: 0...0.3, defaultValue: 0.08, onEditingChanged: gesture("Padding"))
            LabeledSlider(title: "Corners", value: fieldBinding(\.frame.cornerRadius),
                          range: 0...0.1, defaultValue: 0.02, onEditingChanged: gesture("Corners"))
            LabeledSlider(title: "Inset", value: fieldBinding(\.frame.inset),
                          range: 0...0.05, defaultValue: 0, format: { "\(Int(($0 * 100).rounded()))" },
                          onEditingChanged: gesture("Inset"))
            LabeledSlider(title: "Shadow", value: fieldBinding(\.frame.shadow),
                          range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Shadow"))
        }
    }

    // MARK: - Bindings

    /// A slider bound directly to a `Project` field: drags go through `update` (no snapshot per
    /// tick), `gesture(_:)` below wraps the whole drag in one `beginGesture`/`commitGesture`.
    private func fieldBinding(_ keyPath: WritableKeyPath<Project, Double>) -> Binding<Double> {
        Binding(get: { model.project[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var kindBinding: Binding<Background.Kind> {
        Binding(get: { background.kind },
                set: { newValue in model.edit("Background kind") { $0.background.kind = newValue } })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: background.color)) },
                set: { newValue in model.edit("Background color") { $0.background.color = NSColor(newValue).hexString } })
    }

    private func gradientBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex = background.gradient.indices.contains(index) ? background.gradient[index] : "#5B3DF5"
                return Color(nsColor: NSColor(hex: hex))
            },
            set: { newValue in
                model.edit("Background gradient") { project in
                    var stops = project.background.gradient
                    while stops.count <= index { stops.append("#FFFFFF") }
                    stops[index] = NSColor(newValue).hexString
                    project.background.gradient = stops
                }
            })
    }

    // MARK: - Image

    private var imageChooser: some View {
        HStack {
            Text(background.imagePath.isEmpty ? "No image chosen" : background.imagePath)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: chooseImage)
        }
    }

    /// Copies the chosen file into the package as `background.<ext>` (SPEC §5: media the editor
    /// owns lives beside `project.json`; `imagePath` is relative to the package).
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let name = "background.\(ext)"
        let dest = model.packageURL.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            model.edit("Background image") {
                $0.background.kind = .image
                $0.background.imagePath = name
            }
        } catch {
            // ponytail: no error alert for a failed copy (permissions / disk full) — rare, logged only.
            print("BackgroundTab: failed to copy image: \(error)")
        }
    }
}

/// Bundled `Resources/Wallpapers/01.jpg`…`12.jpg` (T-308) plus the user's own
/// `/System/Library/Desktop Pictures/*.heic`, read-only, listed live (SPEC §6.6).
private struct WallpaperGrid: View {
    let model: EditorModel
    private let bundled = (1...12).map { String(format: "%02d", $0) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(bundled, id: \.self) { id in swatch(id: id) }
            ForEach(systemWallpapers, id: \.path) { url in swatch(id: url.path) }
        }
    }

    private var systemWallpapers: [URL] {
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func swatch(id: String) -> some View {
        let selected = model.project.background.kind == .wallpaper && model.project.background.wallpaper == id
        return Button {
            model.edit("Background wallpaper") {
                $0.background.kind = .wallpaper
                $0.background.wallpaper = id
            }
        } label: {
            ZStack {
                if let image = loadThumbnail(id) {
                    // `.resizable()` is required before `.aspectRatio`/`.frame` affect an `Image`'s
                    // rendered content size — without it the image draws at its native pixel size
                    // (thousands of px for a desktop picture) and blows past the grid cell.
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.bgControlColor
                    Image(systemName: "photo").foregroundStyle(Theme.textSecondaryColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Theme.accentColor : Theme.strokeColor, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func loadThumbnail(_ id: String) -> NSImage? {
        if id.hasPrefix("/") { return NSImage(contentsOfFile: id) }
        guard let url = Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "Wallpapers") else { return nil }
        return NSImage(contentsOf: url)
    }
}
