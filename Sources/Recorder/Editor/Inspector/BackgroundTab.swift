import AppKit
import SwiftUI
import RecorderCore

/// SPEC §6.6 Background tab: a kind picker, that kind's own controls (wallpaper grid / colour or
/// gradient swatches / image chooser), then the kind-independent Blur/Padding/Corners/Inset/Shadow
/// sliders. Every control writes through `EditorModel.edit`/`update`+`beginGesture`/`commitGesture`
/// so it round-trips (AC-INS-1) and a drag is one undo step (AC-INS-2).
struct BackgroundTab: View {
    let model: EditorModel
    @State private var colorCommit: DispatchWorkItem?

    private var background: Background { model.project.background }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output shape").font(Font(Theme.headingFont(22)))
                Spacer()
                Button("Crop source…") {
                    if let window = NSApp.keyWindow { CropSheet.present(for: model, on: window) }
                }.buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            }
            HStack(spacing: 4) {
                ForEach([Output.Aspect.auto, .r16x9, .r9x16, .r1x1, .r4x3, .r16x10], id: \.self) { aspect in
                    shapeButton(aspect)
                }
            }
            Divider().padding(.vertical, 4)
            Toggle("Background and frame", isOn: Binding(
                get: { model.project.framingEnabled },
                set: { enabled in model.edit("Background and frame") { $0.frame.enabled = enabled } }
            ))

            if model.project.framingEnabled {
                LabeledSlider(title: "Padding", value: fieldBinding(\.frame.padding),
                              range: 0...0.3, defaultValue: 0.08, onEditingChanged: gesture("Padding"))
                DisclosureGroup("Corners, inset & shadow") {
                    VStack(spacing: 8) {
                LabeledSlider(title: "Corners", value: fieldBinding(\.frame.cornerRadius),
                              range: 0...0.1, defaultValue: 0.02, onEditingChanged: gesture("Corners"))
                LabeledSlider(title: "Inset", value: fieldBinding(\.frame.inset),
                              range: 0...0.05, defaultValue: 0, format: { "\(Int(($0 * 100).rounded()))" },
                              onEditingChanged: gesture("Inset"))
                LabeledSlider(title: "Shadow", value: fieldBinding(\.frame.shadow),
                              range: 0...1, defaultValue: 0.5, onEditingChanged: gesture("Shadow"))

                    }.padding(.top, 4)
                }

                Divider().overlay(Theme.strokeColor)
                Text("Backdrop")
                    .font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: kindBinding, options: [
                    (.wallpaper, "Wallpaper"), (.gradient, "Gradient"),
                    (.color, "Color"), (.image, "Image"),
                ])

                switch background.kind {
                case .wallpaper:
                    WallpaperGrid(model: model)
                case .gradient:
                    HStack {
                        ColorPicker("Start", selection: gradientBinding(0))
                        ColorPicker("End", selection: gradientBinding(1))
                    }
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                    LabeledSlider(title: "Angle", value: fieldBinding(\.background.gradientAngle),
                                  range: 0...360, defaultValue: 45, format: { "\(Int($0.rounded()))°" },
                                  onEditingChanged: gesture("Gradient angle"))
                    presetRow(Self.gradientPresets) { stops in
                        model.edit("Gradient preset") { $0.background.gradient = stops }
                    } selected: { background.gradient == $0 } fill: {
                        LinearGradient(colors: $0.map { Color(nsColor: NSColor(hex: $0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                case .color:
                    ColorPicker("Color", selection: colorBinding)
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                    presetRow(Self.colorPresets.map { [$0] }) { hexes in
                        model.edit("Color preset") { $0.background.color = hexes[0] }
                    } selected: { background.color.caseInsensitiveCompare($0[0]) == .orderedSame } fill: {
                        LinearGradient(colors: [Color(nsColor: NSColor(hex: $0[0]))], startPoint: .top, endPoint: .bottom)
                    }
                case .image:
                    imageChooser
                }

                if background.kind != .color {
                LabeledSlider(title: "Blur", value: fieldBinding(\.background.blur),
                              range: 0...1, defaultValue: 0, format: { "\(Int(($0 * 100).rounded()))" },
                              onEditingChanged: gesture("Blur"))
                }
            } else {
                Text("Edge to edge. Enable background and frame to add padding, corners, and shadow.")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
        }
    }

    // Cool slate / blue / frost.
    static let gradientPresets: [[String]] = [
        ["#1B2230", "#2F3E57"], ["#0F2A4A", "#2A5C9A"], ["#2A5C9A", "#8FB8E8"], ["#2B3340", "#6B7C93"],
        ["#3A4A63", "#9DB4D3"], ["#8FA6C4", "#DCE6F2"], ["#17304F", "#4F86C6"], ["#6B7C93", "#E4EBF3"],
    ]
    static let colorPresets = ["#111827", "#1B2230", "#2F3E57", "#2A5C9A", "#4F86C6", "#8FA6C4", "#BCCFE6", "#E4EBF3"]

    /// One row of 8 preset tiles (colour stops); `apply` is what a click writes, `fill` how the tile looks.
    private func presetRow(_ items: [[String]], apply: @escaping ([String]) -> Void,
                           selected: @escaping ([String]) -> Bool, fill: @escaping ([String]) -> some View) -> some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { apply(items[i]) } label: { fill(items[i]).frame(maxWidth: .infinity).frame(height: 22) }
                    .buttonStyle(TechSelectableTileStyle(selected: selected(items[i])))
            }
        }
    }

    private func shapeButton(_ aspect: Output.Aspect) -> some View {
        let selected = model.project.output.aspect == aspect
        let ratio: CGFloat = switch aspect {
        case .auto: CGFloat(model.project.source.pixelWidth) * model.project.crop.w / max(1, CGFloat(model.project.source.pixelHeight) * model.project.crop.h)
        case .r16x9: 16.0 / 9
        case .r9x16: 9.0 / 16
        case .r1x1: 1
        case .r4x3: 4.0 / 3
        case .r16x10: 16.0 / 10
        }
        return Button {
            guard !selected else { return }
            model.edit("Output shape") { $0.output.aspect = aspect }
        } label: {
            VStack(spacing: 4) {
                Rectangle().strokeBorder(lineWidth: 1)
                    .frame(width: min(28, 20 * ratio), height: min(20, 28 / ratio))
                    .frame(height: 22)
                Text(aspect == .auto ? "Source" : aspect.rawValue)
                    .font(Font(Theme.timecodeFont(10)))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? Theme.bgWindowColor : Theme.textPrimaryColor)
            .background(selected ? Theme.accentColor : Theme.bgControlColor)
            .overlay(Rectangle().strokeBorder(selected ? Theme.accentColor : Theme.strokeColor))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(aspect == .auto ? "Match the cropped recording" : "Set output shape to " + aspect.rawValue)
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

    /// `ColorPicker` has no begin/end callbacks, so one drag through the wheel = one gesture that commits once
    /// the colour has been still for 0.5 s. // ponytail: a different edit inside that window joins the gesture.
    private func colorEdit(_ name: String, _ change: @escaping (inout Project) -> Void) {
        if colorCommit == nil { model.beginGesture() }
        model.update(change)
        colorCommit?.cancel()
        let work = DispatchWorkItem { [model] in model.commitGesture(name); colorCommit = nil }
        colorCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: background.color)) },
                set: { newValue in colorEdit("Background color") { $0.background.color = NSColor(newValue).hexString } })
    }

    private func gradientBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex = background.gradient.indices.contains(index) ? background.gradient[index] : "#5B3DF5"
                return Color(nsColor: NSColor(hex: hex))
            },
            set: { newValue in
                colorEdit("Background gradient") { project in
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
                .font(Font(Theme.bodyFont))
                .foregroundStyle(Theme.textSecondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: chooseImage)
                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
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
    private let bundled = (1...16).map { String(format: "%02d", $0) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(bundled, id: \.self) { id in swatch(id: id) }
            ForEach(systemWallpapers, id: \.path) { url in swatch(id: url.path) }
        }
    }

    // Static: `body` re-runs on every project change, and listing the folder + decoding every
    // full-size HEIC each time froze the inspector on every click.
    private var systemWallpapers: [URL] { Self.systemWallpaperURLs }
    private static let systemWallpaperURLs: [URL] = {
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

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
        }
        .buttonStyle(TechSelectableTileStyle(selected: selected))
    }

    // ponytail: first display still decodes every thumbnail synchronously on the main thread
    // (ImageIO downscales while decoding, so it's ms each); move to a background load if the
    // wallpaper folder ever gets big.
    private static var thumbnails: [String: NSImage] = [:]

    private func loadThumbnail(_ id: String) -> NSImage? {
        if let cached = Self.thumbnails[id] { return cached }
        let url = id.hasPrefix("/") ? URL(fileURLWithPath: id)
            : Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "Wallpapers")
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        Self.thumbnails[id] = image
        return image
    }
}
