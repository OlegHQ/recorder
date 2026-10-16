import SwiftUI
@preconcurrency import AVFoundation
import ImageIO
import RecorderCore

struct LayerPanel: View {
    let model: EditorModel
    let layerID: UUID
    @State private var thumbnail: CGImage?
    @State private var loading = true
    @State private var freeRect: NormRect?

    var layer: LayerBlock? { model.project.layers.first { $0.id == layerID.uuidString } }
    private var aspect: Double? { thumbnail.map { Double($0.width) / Double($0.height) } }
    private var placement: LayerPlacement {
        guard let layer else { return .free }
        if freeRect == layer.rect { return .free }
        return model.layerPlacement(layer, aspect: aspect)
    }
    private var corner: NormPoint {
        guard let rect = layer?.rect else { return NormPoint(x: 1, y: 1) }
        return NormPoint(x: (rect.x / max(0.001, 1 - rect.w) * 2).rounded() / 2,
                         y: (rect.y / max(0.001, 1 - rect.h) * 2).rounded() / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: layer?.kind == .video ? "Video layer" : "Image layer") { model.selection = [] }
            if let layer {
                Button {
                    if let time = model.timeMap.outputTime(atSource: layer.start) {
                        model.isPlaying = false; model.playhead = time + min(0.5, (layer.end - layer.start) / 2)
                    }
                } label: {
                    ZStack {
                        Theme.bgWindowColor
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                        } else {
                            Label(loading ? "Loading media…" : "Missing media", systemImage: loading ? "photo" : "exclamationmark.triangle")
                                .foregroundStyle(Theme.textSecondaryColor)
                        }
                    }.frame(height: 112).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("Show layer in preview")
                HStack {
                    Text(URL(fileURLWithPath: layer.file).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    Spacer(minLength: 0)
                    Button("Replace…") { model.chooseMedia(in: NSApp.keyWindow, replacing: layerID) }
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        .disabled(model.mediaImportStatus != nil)
                }
                EffectPreviewControls(model: model, start: layer.start, end: layer.end, connected: true, editsRegion: true,
                                      regionHint: "Edit the final rectangle; View result restores fades and motion.")
                Text("Placement").font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: Binding(get: { placement }, set: { value in
                    freeRect = value == .free ? layer.rect : nil
                    model.setLayerPlacement(layerID, placement: value, aspect: aspect, position: corner)
                }), options: LayerPlacement.allCases.map { ($0, $0.rawValue.capitalized) })
                if placement == .corner {
                    PositionGrid(position: corner) { position in
                        model.setLayerPlacement(layerID, placement: .corner, aspect: aspect, position: position)
                    }
                }
                Text("Drag the preview handles to place freely. ⌘ bypasses snapping.")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Divider()
                Text("Backdrop").font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: Binding(get: { layer.backdrop }, set: { value in
                    model.changeLayer(layerID, name: "Layer Backdrop") { $0.backdrop = value }
                }), options: [(.none, "None"), (.dim, "Dim"), (.blur, "Blur")])
                Text("Motion").font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: Binding(get: { layer.motion }, set: { value in
                    model.changeLayer(layerID, name: "Layer Motion") { $0.motion = value }
                }), options: [(.fade, "Fade"), (.scale, "Scale"), (.slide, "Slide")])
                ForEach([true, false], id: \.self) { incoming in
                    LabeledSlider(title: incoming ? "Fade in" : "Fade out", value: fadeBinding(incoming: incoming), range: 0...3,
                                  defaultValue: 0.3, format: { $0 == 0 ? "Off" : String(format: "%.1f s", $0) },
                                  onEditingChanged: { editing in editing ? model.beginGesture() : model.commitGesture("Layer Fade") })
                }
                Toggle("In front of camera", isOn: Binding(get: { layer.aboveCamera }, set: { value in
                    model.changeLayer(layerID, name: "Layer Order") { $0.aboveCamera = value }
                }))
                if layer.kind == .video {
                    Divider()
                    Text(model.layerSoundDescription(layer)).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    Button(model.linkedLayerSound(layer).isEmpty ? "Link Back" : "Detach Audio") { model.toggleLayerSound(layerID) }
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        .disabled(model.linkedLayerSound(layer).isEmpty && model.detachedLayerSound(layer).isEmpty)
                    Text("Link Back needs detached sound from this file overlapping the layer.")
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                }
                Button("Remove layer", role: .destructive) {
                    model.edit("Remove Layer") { $0.removeBlock(layerID) }; model.selection = []
                }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
            }
        }
        .task(id: layer?.file) {
            thumbnail = nil; loading = true
            let image = if let layer { await model.layerThumbnail(layer) } else { nil as CGImage? }
            guard !Task.isCancelled else { return }
            thumbnail = image
            loading = false
        }
    }

    func fadeBinding(incoming: Bool) -> Binding<Double> {
        Binding(get: { (incoming ? layer?.fadeIn : layer?.fadeOut) ?? 0 }, set: { value in
            guard value.isFinite else { return }
            model.update { project in
                guard let index = project.layers.firstIndex(where: { $0.id == layerID.uuidString }) else { return }
                let seconds = min(3, max(0, (value * 10).rounded() / 10))
                if incoming { project.layers[index].fadeIn = seconds > 0 ? seconds : nil }
                else { project.layers[index].fadeOut = seconds > 0 ? seconds : nil }
            }
        })
    }
}

extension EditorModel {
    var layerCanvas: CGSize {
        outputSize(aspect: project.output.aspect, croppedSource: CGSize(width: Double(project.source.pixelWidth) * project.crop.w,
                                                                     height: Double(project.source.pixelHeight) * project.crop.h), longEdge: 1000)
    }

    func changeLayer(_ id: UUID, name: String, _ change: (inout LayerBlock) -> Void) {
        guard let index = project.layers.firstIndex(where: { $0.id == id.uuidString }) else { return }
        var value = project.layers[index]; change(&value)
        guard value != project.layers[index] else { return }
        edit(name) { $0.layers[index] = value }
    }

    func layerPlacement(_ layer: LayerBlock, aspect: Double?) -> LayerPlacement {
        if layer.rect == NormRect() { return .full }
        guard let aspect else { return .free }
        func matches(_ rect: NormRect?) -> Bool {
            guard let rect else { return false }
            return abs(rect.x - layer.rect.x) + abs(rect.y - layer.rect.y) + abs(rect.w - layer.rect.w) + abs(rect.h - layer.rect.h) < 0.004
        }
        if matches(layerPlacementRect(.card, aspect: aspect, canvas: layerCanvas)) { return .card }
        for horizontal in [0.0, 0.5, 1] {
            for vertical in [0.0, 0.5, 1] where matches(layerPlacementRect(.corner, aspect: aspect, canvas: layerCanvas, position: NormPoint(x: horizontal, y: vertical))) { return .corner }
        }
        return .free
    }

    func setLayerPlacement(_ id: UUID, placement: LayerPlacement, aspect: Double?, position: NormPoint = NormPoint(x: 1, y: 1)) {
        layerPlacementTask?.cancel()
        guard placement != .free else { return }
        if placement == .full { changeLayer(id, name: "Layer Placement") { $0.rect = NormRect() }; return }
        guard let aspect else {
            layerPlacementTask = Task {
                guard let layer = project.layers.first(where: { $0.id == id.uuidString }), let image = await layerThumbnail(layer),
                      !Task.isCancelled, project.layers.first(where: { $0.id == layer.id }) == layer,
                      let rect = layerPlacementRect(placement, aspect: Double(image.width) / Double(image.height), canvas: layerCanvas, position: position) else { return }
                changeLayer(id, name: "Layer Placement") { $0.rect = rect }
            }
            return
        }
        guard let rect = layerPlacementRect(placement, aspect: aspect, canvas: layerCanvas, position: position) else { return }
        changeLayer(id, name: "Layer Placement") { $0.rect = rect }
    }

    func linkedLayerSound(_ layer: LayerBlock) -> [AudioClip] { project.audioClips.filter { $0.link == .layer && $0.layer == layer.id } }

    func detachedLayerSound(_ layer: LayerBlock) -> [AudioClip] {
        guard let start = timeMap.outputTime(atSource: layer.start) else { return [] }
        return project.audioClips.filter { audio in
            guard audio.link == nil, audio.file == layer.file, let output = timeMap.outputTime(atSource: audio.start) else { return false }
            return output < start + layer.end - layer.start && output + audio.end - audio.start > start
        }
    }

    func layerSoundDescription(_ layer: LayerBlock) -> String {
        let tracks = Set(linkedLayerSound(layer).map { project.audioTracks[$0.track].name }).sorted()
        return tracks.isEmpty ? "Sound: detached or unavailable" : "Sound: linked on " + tracks.joined(separator: ", ")
    }

    func toggleLayerSound(_ id: UUID) {
        guard let layer = project.layers.first(where: { $0.id == id.uuidString && $0.kind == .video }) else { return }
        let linked = linkedLayerSound(layer)
        let sound = linked.isEmpty ? detachedLayerSound(layer) : linked
        guard !sound.isEmpty else { return }
        var trial = project
        for audio in sound {
            guard let audioID = UUID(uuidString: audio.id) else { continue }
            if linked.isEmpty { _ = trial.linkAudio(audioID, to: .layer, layer: layer.id) }
            else { _ = trial.unlinkAudio(audioID) }
        }
        if trial != project { edit(linked.isEmpty ? "Link Layer Audio" : "Detach Layer Audio") { $0 = trial } }
    }

    func layerThumbnail(_ layer: LayerBlock) async -> CGImage? {
        guard let url = Waveform.audioURL(in: packageURL, file: layer.file) else { return nil }
        return await Task.detached(priority: .utility) {
            if layer.kind == .image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
            return try? await generator.image(at: CMTime(seconds: layer.mediaStart, preferredTimescale: 600)).image
        }.value
    }
}

extension LayerPanel {
    @MainActor static func runSelfTest() async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        func check(_ value: Bool, _ description: String) throws { if !value { throw Fail(description: description) } }
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("layer-panel-" + UUID().uuidString + ".recorder")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("media/card.png")
        guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { throw Fail(description: "Panel fixture") }
        context.setFillColor(CGColor(gray: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "Panel PNG")
        var project = Project(source: Source(pixelWidth: 1280, pixelHeight: 720, duration: 9))
        project.clips = [Clip(sourceStart: 0, sourceEnd: 9)]
        let result = project.addLayer(kind: .image, file: "media/card.png", atOutput: 0, duration: 4,
                                     rect: layerPlacementRect(.card, aspect: 16 / 9, canvas: CGSize(width: 1280, height: 720))!)
        guard let id = result else { throw Fail(description: "Panel layer") }
        let model = EditorModel(packageURL: package, project: project, events: EventLog())
        defer { model.saveNow() }
        model.selection = [id]; model.inspectorShowsProject = false
        let panel = LayerPanel(model: model, layerID: id)
        let thumbnail = await model.layerThumbnail(project.layers[0])
        try check(thumbnail?.width == 320 && model.layerPlacement(project.layers[0], aspect: 16 / 9) == .card, "Thumbnail / Card inference")
        let before = model.project, steps = model.undoStepCount
        model.edit("Speed fixture") { $0.clips[0].speed = 2; $0.layers[0].start = 2; $0.layers[0].end = 6 }
        try check(model.previewTime(start: 2, end: 6, connected: true) == 3, "Connected preview midpoint across speed")
        model.replayEffect(start: 2, end: 6, connected: true)
        try check(model.previewPlaybackEnd == 5 && model.playhead == 0.4, "Connected replay uses output length and layer tail")
        model.stopEffectPreview(); model.previewShowsResult = false; model.undo()
        model.beginGesture()
        for value in [0.2, 0.4, 1.2, 2.1] { panel.fadeBinding(incoming: true).wrappedValue = value }
        model.commitGesture("Layer Fade")
        try check(model.project.layers[0].fadeIn == 2.1 && model.undoStepCount == steps + 1, "Panel fade binding / one undo")
        model.undo(); try check(model.project == before, "Panel fade undo"); model.redo(); model.undo()
        for placement in [LayerPlacement.full, .corner, .card] {
            let original = model.project
            model.setLayerPlacement(id, placement: placement, aspect: 16 / 9, position: NormPoint(x: 0, y: 1))
            try check(model.layerPlacement(model.project.layers[0], aspect: 16 / 9) == placement && model.project.checkInvariants() == nil, "Placement \(placement)")
            model.undo(); try check(model.project == original, "Placement undo")
        }
        model.changeLayer(id, name: "Layer Backdrop") { $0.backdrop = .blur }
        try check(model.project.layers[0].backdrop == .blur, "Backdrop command"); model.undo()
        model.changeLayer(id, name: "Layer Motion") { $0.motion = .slide }
        try check(model.project.layers[0].motion == .slide, "Motion command"); model.undo()
        model.changeLayer(id, name: "Layer Order") { $0.aboveCamera = true }
        try check(model.project.layers[0].aboveCamera, "Camera order command"); model.undo()
        model.setLayerPlacement(id, placement: .corner, aspect: nil)
        model.setLayerPlacement(id, placement: .full, aspect: 16 / 9)
        try await Task.sleep(for: .milliseconds(100))
        try check(model.project.layers[0].rect == NormRect(), "A stale thumbnail task must not overwrite the latest placement")
        model.undo()
        let host = NSHostingView(rootView: InspectorView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 940), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.close() }
        for (name, height) in [("default", 940.0), ("minimum", 400.0), ("bottom", 400.0), ("corner", 940.0), ("missing", 940.0)] {
            if name == "corner" { model.setLayerPlacement(id, placement: .corner, aspect: 16 / 9) }
            if name == "missing" { model.changeLayer(id, name: "Missing fixture") { $0.file = "media/missing.png" } }
            window.setContentSize(CGSize(width: 320, height: height))
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            if name == "bottom" {
                func findScroll(_ view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.compactMap { findScroll($0) }.first }
                guard let scroll = findScroll(host), let document = scroll.documentView else { throw Fail(description: "Layer panel scroll view") }
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                try check(scroll.contentView.bounds.minY > 20, "Minimum inspector must reach its bottom controls")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Fail(description: "Layer panel bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/recorder-t649-panel-\(name).png"))
        }
        print("layer-panel: thumbnail, placements/cancellation, backdrop/motion/order, connected replay, fade binding/undo and native default/minimum/scroll/corner/missing renders verified")
    }
}
