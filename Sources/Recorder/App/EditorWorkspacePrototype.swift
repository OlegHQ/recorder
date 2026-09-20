import AppKit
import AVFoundation
import SwiftUI
import RecorderCore

/// Workspace experiment with the production preview, model and timeline over disposable media.
/// The earlier spatial specimen remains available for an explicit layout comparison.
struct EditorWorkspacePrototype: View {
    let model: EditorModel
    @State private var destination: InspectorView.Tab
    @State private var spatialControls = true
    @State private var productionInspector = true
    @State private var useSpecimen = false
    @State private var mediaReady = false
    @State private var mediaError: String?
    @State private var hoverTime: Double?
    @State private var presentationAnchor = NSView()

    init(model: EditorModel, initialTab: InspectorView.Tab = .background, productionInspector: Bool = true, replayWorkflow: Bool = false) {
        self.model = model
        _replay = State(initialValue: replayWorkflow)
        _productionInspector = State(initialValue: productionInspector)
        _destination = State(initialValue: initialTab)
        model.inspectorTab = initialTab
    }
    @State private var inspectSelection = false
    @State private var replay = false
    @State private var replayStep = 0
    @State private var replayExpectedContext = ""
    @State private var sideRail = false
    private var selectionKey: String {
        model.selectedClips.sorted().map(String.init).joined(separator: ",") + "/" +
        model.selection.map(\.uuidString).sorted().joined(separator: ",")
    }
    private var count: Int { model.selectedClips.count + model.selection.count }
    private var contextKey: String { inspectSelection ? selectionKey : "project-\(destination.rawValue)" }
    private var cameraSelected: Bool {
        model.project.cameraClips.contains { model.selection.contains(UUID(uuidString: $0.id)!) }
    }
    private func title(_ tab: InspectorView.Tab) -> String {
        switch tab {
        case .background: "Canvas"
        case .audio: "Sound"
        case .animations: "Motion"
        case .keys: "Keystrokes"
        default: tab.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Editing workspace").font(Font(Theme.headingFont(28)))
                Text(replay ? "\(replayStep + 1)/9 · \(EditorWorkspaceGallery.workflowStages[replayStep])" : "Gallery study")
                    .foregroundStyle(Theme.textSecondaryColor).lineLimit(1)
                Spacer()
                Menu("Workflows") {
                    Button("Crop source…") {
                        if let window = presentationAnchor.window { CropSheet.present(for: model, on: window) }
                    }
                    Button("Export…") {
                        if let window = presentationAnchor.window { ExportSheet.present(for: model, on: window) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().disabled(!mediaReady)
                Menu("Compare") {
                    Toggle("Production inspector", isOn: $productionInspector)
                    Toggle("Spatial specimen instead of video", isOn: $useSpecimen)
                    Toggle("Side navigation rail", isOn: $sideRail)
                    Toggle("Spatial camera controls", isOn: $spatialControls)
                }.menuStyle(.borderlessButton).fixedSize()
                Button(replay ? "Stop replay" : "Replay workflow") { replay.toggle() }
                    .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                    .disabled(!mediaReady)
            }
            .padding(16)
            Divider()
            if productionInspector {
                EditorCompositionNavigation(model: model).frame(height: 40)
            } else if !sideRail {
                HStack(spacing: 4) {
                    ForEach(InspectorView.Tab.allCases, id: \.rawValue) { tab in destinationButton(tab) }
                }.padding(.horizontal, 12).frame(height: 40)
                Divider()
            }
            HStack(spacing: 0) {
                if sideRail && !productionInspector { navigation.frame(width: 132); Divider() }
                Group {
                    if useSpecimen { specimen }
                    else if mediaReady { WorkspaceLivePreview(model: model, hoverTime: hoverTime) }
                    else {
                        Text(mediaError ?? "Preparing sample recording…")
                            .foregroundStyle(Theme.textSecondaryColor).padding(20)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if productionInspector { InspectorView(model: model) }
                else { properties.frame(width: InspectorView.width) }
            }
            .frame(height: sideRail && !productionInspector ? 470 : 429)
            Divider()
            WorkspaceTimeline(model: model, hoverTime: $hoverTime).frame(height: 250)
        }
        .font(Font(Theme.labelFont))
        .foregroundStyle(Theme.textPrimaryColor)
        .background(Theme.bgPanelColor)
        .background(WorkspaceWindowAnchor(view: presentationAnchor))
        .overlay(Rectangle().strokeBorder(Theme.strokeColor))
        .task {
            do {
                try await WorkspaceMedia.prepare(at: model.packageURL)
                try Task.checkCancellation()
                mediaReady = true
            } catch is CancellationError { }
            catch { mediaError = "Sample unavailable: " + error.localizedDescription }
        }
        .onChange(of: model.cameraInspectorRequested) { _, requested in
            if requested && !productionInspector {
                destination = .camera
                inspectSelection = count > 0
                model.cameraInspectorRequested = false
            }
        }
        .onChange(of: selectionKey) { _, _ in inspectSelection = count > 0 }
        .onChange(of: replayContext) { _, context in
            if replay && context != replayExpectedContext { replay = false }
        }
        .onChange(of: model.project) { _, _ in replay = false }
        .onChange(of: replay) { _, playing in
            if !playing { model.stopEffectPreview() }
        }
        .onDisappear { model.stopEffectPreview() }
        .task(id: replay && mediaReady) {
            guard replay && mediaReady else { return }
            for step in EditorWorkspaceGallery.workflowStages.indices {
                guard !Task.isCancelled else { return }
                replayStep = step
                EditorWorkspaceGallery.showWorkflowStep(step, model: model)
                destination = model.inspectorTab
                inspectSelection = !model.inspectorShowsProject && count > 0
                replayExpectedContext = replayContext
                do {
                    if step == 3 {
                        while model.previewPlaybackEnd != nil {
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    } else { try await Task.sleep(for: .seconds(2.4)) }
                } catch { return }
            }
            replay = false
            if let window = presentationAnchor.window { ExportSheet.present(for: model, on: window) }
        }
    }

    private var replayContext: String {
        "\(selectionKey)/\(model.inspectorTab.rawValue)/\(model.inspectorShowsProject)/\(model.previewShowsResult)"
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Composition").foregroundStyle(Theme.textSecondaryColor).padding(.bottom, 10)
            ForEach(InspectorView.Tab.allCases, id: \.rawValue) { tab in
                destinationButton(tab)
            }
            Spacer()
            Text("Changes over time")
                .font(Font(Theme.headingFont(20)))
            Text("Select an interval below to edit just that moment.")
                .foregroundStyle(Theme.textSecondaryColor).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "arrow.down").padding(.top, 6).accessibilityHidden(true)
        }.padding(12)
    }

    private func destinationButton(_ tab: InspectorView.Tab) -> some View {
        Button {
            replay = false
            destination = tab
            inspectSelection = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon).frame(width: 16)
                Text(title(tab)).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 24)
        }
        .buttonStyle(TechButtonStyle(kind: !inspectSelection && destination == tab ? .primary : .quiet, compact: true))
        .accessibilityAddTraits(!inspectSelection && destination == tab ? .isSelected : [])
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                scopeButton("Whole project", active: !inspectSelection) { inspectSelection = false }
                scopeButton(count == 0 ? "Selection" : "Selection · \(count)", active: inspectSelection) {
                    inspectSelection = true
                }.disabled(count == 0)
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inspectSelection ? (count > 1 ? "Selected items" : "Selected interval") : title(destination))
                            .font(Font(Theme.headingFont(28)))
                        Text(inspectSelection ? "Only the selected timeline content" : ((destination == .camera || destination == .keys) ? "Project default · intervals can override" : "Applies throughout the recording"))
                            .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    }
                    .modifier(InspectorReveal(identity: contextKey, order: 0))
                    Group {
                        if inspectSelection { selectionProperties }
                        else { projectProperties }
                    }
                    .modifier(InspectorReveal(identity: contextKey, order: 1))
                }.padding(16)
            }
            if !inspectSelection && destination == .camera && model.project.source.hasCamera {
                Divider()
                Group {
                    if let layout = activeCameraLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Timed layout active at \(String(format: "%.1f s", model.playhead))")
                                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                            Button("Edit this timed layout") {
                                model.selectedClips = []
                                model.selection = [UUID(uuidString: layout.id)!]
                                inspectSelection = true
                            }.buttonStyle(TechButtonStyle(kind: .primary, compact: true))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        CameraTimelineActions(model: model)
                    }
                }.padding(12)
            }
        }
        .toggleStyle(TechToggleStyle())
    }

    private var activeCameraLayout: RecorderCore.Layout? {
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        return model.project.layouts.first { $0.kind != .settings && time >= $0.start && time < $0.end }
    }

    private func scopeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { replay = false; action() } label: {
            Text(label).frame(maxWidth: .infinity).frame(height: 24)
        }
        .buttonStyle(TechButtonStyle(kind: active ? .primary : .quiet, compact: true))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var projectProperties: some View {
        switch destination {
        case .background: BackgroundTab(model: model)
        case .camera:
            CameraTab(model: model, spatialControls: spatialControls, showsTimelineActions: false)
        case .cursor: CursorTab(model: model)
        case .keys: KeysTab(model: model)
        case .audio: AudioTab(model: model)
        case .animations: AnimationsTab(model: model)
        }
    }

    @ViewBuilder private var selectionProperties: some View {
        if count > 1 {
            Text("\(count) items selected").font(Font(Theme.headingFont(24)))
            Text("Move or remove the group on the timeline. Select one item to edit its properties.")
                .foregroundStyle(Theme.textSecondaryColor)
        } else if cameraSelected {
            Text("Camera footage").font(Font(Theme.headingFont(24)))
            Text("Trim or move this interval on the Camera track. Camera appearance is a project default; layout changes are separate timed intervals.")
                .foregroundStyle(Theme.textSecondaryColor)
            Button("Edit camera appearance") { replay = false; destination = .camera; inspectSelection = false }
                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
        } else if let i = model.selectedClip {
            ClipPanel(model: model, clipIndex: i)
        } else if let id = model.selection.first {
            if model.project.zooms.contains(where: { $0.id == id.uuidString }) { ZoomPanel(model: model, zoomID: id) }
            else if model.project.masks.contains(where: { $0.id == id.uuidString }) { MaskPanel(model: model, maskID: id) }
            else if model.project.layouts.contains(where: { $0.id == id.uuidString }) { LayoutPanel(model: model, layoutID: id) }
            else if model.project.keystrokeClips.contains(where: { $0.id == id.uuidString }) { KeysTab(model: model, layoutID: id) }
        }
    }

    private var specimen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Composition specimen")
                Spacer()
                Text("Spatial study").foregroundStyle(Theme.textSecondaryColor)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let padding = model.project.framingEnabled ? model.project.frame.padding * min(width, height) : 0
                ZStack(alignment: .bottomTrailing) {
                    (model.project.framingEnabled ? Color(nsColor: NSColor(hex: model.project.background.color)) : Theme.bgWindowColor)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: "macwindow"); Text("Recorded screen"); Spacer() }
                        Divider()
                        Text("Recorded content")
                            .font(Font(Theme.headingFont(30)))
                        HStack(spacing: 5) {
                            Theme.clipColor.frame(width: 64, height: 4)
                            Theme.strokeColor.frame(height: 4)
                        }
                        Spacer(minLength: 0)

                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.bgControlColor)
                    .clipShape(RoundedRectangle(cornerRadius: model.project.frame.cornerRadius * width))
                    .padding(padding)
                    let camera = model.project.camera
                    let size = min(width, height) * camera.size
                    let position = camera.position ?? NormPoint(x: 1, y: 1)
                    Button { replay = false; destination = .camera; inspectSelection = false } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "person.crop.square").font(.system(size: 24, weight: .ultraLight))
                            Text("Camera").font(Font(Theme.captionFont))
                        }
                        .frame(width: max(56, size), height: max(56, size / camera.aspect))
                        .foregroundStyle(Theme.bgWindowColor)
                        .background(Theme.layoutColor)
                        .clipShape(RoundedRectangle(cornerRadius: camera.roundness * size / 2))
                    }
                    .buttonStyle(.plain)
                    .position(x: padding + size / 2 + (width - 2 * padding - size) * position.x,
                              y: padding + size / camera.aspect / 2 + (height - 2 * padding - size / camera.aspect) * position.y)
                    .accessibilityLabel("Edit project camera appearance")
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            Text("Spatial specimen · playback and effects are not rendered here.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)

        }.padding(16)
    }
}


/// Resolve sheets against this gallery, even while another window is active.
private struct WorkspaceWindowAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct WorkspaceTimeline: NSViewRepresentable {
    let model: EditorModel
    @Binding var hoverTime: Double?
    func makeNSView(context: Context) -> TimelineContainerView {
        let timeline = TimelineView(frame: .zero)
        timeline.model = model
        timeline.onHoverTime = { hoverTime = $0 }
        let toolbar = TimelineToolbar(frame: .zero)
        toolbar.timelineView = timeline
        return TimelineContainerView(toolbar: toolbar, timeline: timeline)
    }
    func updateNSView(_ view: TimelineContainerView, context: Context) {}
}

struct EditorWorkspaceGallery: NSViewRepresentable {
    static let workflowStages = ["Frame", "Trim", "Zoom target", "Replay zoom", "Timed camera",
                                 "Camera default", "Keystrokes", "Sound", "Export"]

    /// Navigate the disposable example without changing its project or undo history.
    @MainActor static func showWorkflowStep(_ step: Int, model: EditorModel) {
        model.stopEffectPreview()
        model.isPlaying = false
        switch step {
        case 0:
            model.selectedClips = []; model.selection = []; model.playhead = 0
            model.showProjectInspector(.background)
        case 1:
            model.selection = []; model.selectedClips = [0]; model.playhead = 2
            model.inspectorShowsProject = false
        case 2, 3:
            model.selectedClips = []
            guard let zoom = model.project.zooms.first, let id = UUID(uuidString: zoom.id) else { return }
            model.selection = [id]
            model.inspectorShowsProject = false
            model.playhead = model.previewTime(start: zoom.start, end: zoom.end) ?? model.playhead
            model.previewShowsResult = false
            if step == 3 { model.replayEffect(start: zoom.start, end: zoom.end) }
        case 4:
            guard let layout = model.project.layouts.first, let id = UUID(uuidString: layout.id) else { return }
            model.selection = [id]
            model.inspectorShowsProject = false
            model.playhead = model.previewTime(start: layout.start, end: layout.end) ?? model.playhead
        case 5:
            model.playhead = 12
            model.showProjectInspector(.camera)
        case 6:
            model.selection = []; model.playhead = 22.5
            model.showProjectInspector(.keys)
        case 7:
            model.showProjectInspector(.audio)
        default:
            model.selection = []; model.selectedClips = []; model.playhead = 0
            model.showProjectInspector(.background)
        }
    }

    final class Coordinator {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-workspace-study-" + UUID().uuidString)
        var model: EditorModel?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSHostingView<EditorWorkspacePrototype> {
        let model = Self.makeModel(at: context.coordinator.url)
        context.coordinator.model = model
        return NSHostingView(rootView: EditorWorkspacePrototype(model: model))
    }
    @MainActor static func makeModel(at url: URL) -> EditorModel {
        var project = Project(title: "Workspace study", source: Source(pixelWidth: 960, pixelHeight: 540, duration: 32, hasCamera: true))
        project.clips = [Clip(sourceStart: 0, sourceEnd: 12), Clip(sourceStart: 12, sourceEnd: 24), Clip(sourceStart: 24, sourceEnd: 32)]
        project.zooms = [Zoom(start: 4, end: 9, scale: 2, mode: .manual)]
        project.cameraClips = [CameraClip(start: 0, end: 32)]
        project.background.kind = .color
        project.background.color = "#D7EAF0"
        project.keys.show = true
        project.addKeys(atSource: 21, length: 4)
        project.camera.size = 0.28
        var override = project.camera
        override.position = NormPoint(x: 0, y: 0)
        override.size = 0.4
        project.layouts = [Layout(start: 16, end: 20, kind: .bubble, camera: override)]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var events: [InputEvent] = []
        // Labelled gallery activity uses the same event pipeline as recordings.
        for step in 0...128 {
            let time = Double(step) / 4
            let phase = time.truncatingRemainder(dividingBy: 8) / 8
            events.append(InputEvent(t: time, k: .move, x: 0.2 + 0.6 * phase,
                                     y: 0.5 + 0.12 * sin(phase * 2 * .pi)))
        }
        for time in [2.0, 10, 22, 28] {
            events.append(InputEvent(t: time, k: .key, keyCode: 8, mods: 1 << 20))
        }
        events.sort { $0.t < $1.t }
        return EditorModel(packageURL: url, project: project, events: EventLog(events: events))
    }
    func updateNSView(_ view: NSHostingView<EditorWorkspacePrototype>, context: Context) {}
    static func dismantleNSView(_ view: NSHostingView<EditorWorkspacePrototype>, coordinator: Coordinator) {
        coordinator.model?.saveNow()
        coordinator.model = nil
        try? FileManager.default.removeItem(at: coordinator.url)
    }
}


extension EditorWorkspaceGallery {
    @MainActor static func render(to url: URL, width: CGFloat = 1120) async throws {
        enum Failure: Error { case bitmap, unexpectedEdit }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-workspace-check-" + UUID().uuidString)
        let model = makeModel(at: scratch)
        try await WorkspaceMedia.prepare(at: scratch)
        defer { model.saveNow(); try? FileManager.default.removeItem(at: scratch) }
        let original = model.project
        let view = NSHostingView(rootView: EditorWorkspacePrototype(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 785),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for state in ["canvas", "zoom", "camera", "layout", "group", "empty"] {
            model.selectedClips = []
            model.selection = []
            switch state {
            case "zoom": model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
            case "camera": model.selection = [UUID(uuidString: model.project.cameraClips[0].id)!]
            case "layout": model.selection = [UUID(uuidString: model.project.layouts[0].id)!]
            case "group": model.selectedClips = [0, 1]
            default: break
            }
            try await Task.sleep(for: .milliseconds(500))
            view.layoutSubtreeIfNeeded()
            let overlay = try await WorkspacePreviewContainer.snapshot(in: view)
            defer { overlay.removeFromSuperview() }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.bitmap }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            let target = state == "canvas" ? url : url.deletingPathExtension().appendingPathExtension(state + ".png")
            try data.write(to: target, options: .atomic)
        }
        model.edit("Portrait framing") { $0.output.aspect = .r9x16 }
        try await Task.sleep(for: .milliseconds(300))
        let portraitOverlay = try await WorkspacePreviewContainer.snapshot(in: view)
        guard let portraitRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.bitmap }
        view.cacheDisplay(in: view.bounds, to: portraitRep)
        portraitOverlay.removeFromSuperview()
        guard let portraitData = portraitRep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
        try portraitData.write(to: url.deletingPathExtension().appendingPathExtension("portrait.png"), options: .atomic)
        model.undo()
        guard model.project == original, model.undoStepCount == 0 else { throw Failure.unexpectedEdit }
        let cameraView = NSHostingView(rootView: EditorWorkspacePrototype(model: model, initialTab: .camera))
        window.contentView = cameraView
        try await Task.sleep(for: .milliseconds(500))
        cameraView.layoutSubtreeIfNeeded()
        guard let rep = cameraView.bitmapImageRepForCachingDisplay(in: cameraView.bounds) else { throw Failure.bitmap }
        let placementOverlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
        cameraView.cacheDisplay(in: cameraView.bounds, to: rep)
        placementOverlay.removeFromSuperview()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
        try data.write(to: url.deletingPathExtension().appendingPathExtension("placement.png"), options: .atomic)
        model.playhead = 17
        try await Task.sleep(for: .milliseconds(500))
        cameraView.layoutSubtreeIfNeeded()
        let overrideOverlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
        cameraView.cacheDisplay(in: cameraView.bounds, to: rep)
        overrideOverlay.removeFromSuperview()
        guard let overrideData = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
        try overrideData.write(to: url.deletingPathExtension().appendingPathExtension("override.png"), options: .atomic)
        guard model.project == original, model.undoStepCount == 0 else { throw Failure.unexpectedEdit }
        // Verify the visible result, including scope precedence and undo, using real GPU pixels.
        guard let preview = WorkspacePreviewContainer.find(in: cameraView)?.preview else { throw Failure.bitmap }
        func pixels() async throws -> Data {
            try await Task.sleep(for: .milliseconds(100))
            let image = try await preview.captureRenderedFrame()
            guard let data = image.dataProvider?.data else { throw Failure.bitmap }
            return data as Data
        }
        func dragCamera(by delta: CGPoint) {
            let output = ExportSettings.outputSize(project: model.project, shortEdge: 720)
            let viewport = screenRect(output: preview.bounds.size, cropAspect: output.width / output.height, padding: 0)
            let time = model.timeMap.sourceTime(atOutput: model.playhead)
            let rect = cameraOverlayRect(project: model.project, output: viewport.size, atSource: time,
                                         viewScale: model.cameraPath.sample(atSource: time).scale)
            let start = CGPoint(x: viewport.minX + rect.midX, y: viewport.minY + viewport.height - rect.midY)
            let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: preview.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            preview.mouseDown(with: event(.leftMouseDown, start))
            preview.mouseDragged(with: event(.leftMouseDragged, end))
            preview.mouseUp(with: event(.leftMouseUp, end))
        }
        let active = try await pixels()
        model.edit("Check camera default") { $0.camera.position = NormPoint(x: 0.5, y: 1) }
        guard try await pixels() == active else { throw Failure.unexpectedEdit }
        model.undo()
        dragCamera(by: CGPoint(x: 50, y: -25))
        guard try await pixels() != active, model.project.camera == original.camera,
              model.undoStepCount == 1 else { throw Failure.unexpectedEdit }
        model.undo()
        guard try await pixels() == active else { throw Failure.unexpectedEdit }
        model.playhead = 0
        let readyOverlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
        readyOverlay.removeFromSuperview()
        let defaults = try await pixels()
        dragCamera(by: CGPoint(x: -50, y: 25))
        guard try await pixels() != defaults, model.project.layouts == original.layouts,
              model.undoStepCount == 1 else { throw Failure.unexpectedEdit }
        model.undo()
        guard try await pixels() == defaults, model.project == original, model.undoStepCount == 0
        else { throw Failure.unexpectedEdit }

        model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
        model.playhead = model.previewTime(start: 4, end: 9)!
        try await Task.sleep(for: .milliseconds(200))
        guard let target = preview.subviews.first(where: { $0 is SelectionRectView }) as? SelectionRectView,
              !target.isHidden else { throw Failure.bitmap }
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124)!
        let originalCenter = model.project.zooms[0].center
        target.keyDown(with: right)
        guard model.project.zooms[0].center.x > originalCenter.x,
              model.project.zooms[0].center.y == originalCenter.y, model.undoStepCount == 1
        else { throw Failure.unexpectedEdit }
        model.undo()
        guard model.project == original else { throw Failure.unexpectedEdit }
        model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
        var regionPixels: Data?
        for result in [false, true] {
            model.previewShowsResult = result
            try await Task.sleep(for: .milliseconds(500))
            let overlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
            defer { overlay.removeFromSuperview() }
            let current = try await pixels()
            if result {
                guard current != regionPixels, model.selection.count == 1 else { throw Failure.unexpectedEdit }
                model.previewShowsResult = false
                model.showProjectInspector(.background)
                guard try await pixels() == current else { throw Failure.unexpectedEdit }
                model.inspectorShowsProject = false
                guard try await pixels() == regionPixels else { throw Failure.unexpectedEdit }
                model.previewShowsResult = true
                try await Task.sleep(for: .milliseconds(300))
            } else { regionPixels = current }
            guard let image = cameraView.bitmapImageRepForCachingDisplay(in: cameraView.bounds) else { throw Failure.bitmap }
            cameraView.cacheDisplay(in: cameraView.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            try data.write(to: url.deletingPathExtension().appendingPathExtension(result ? "zoom-result.png" : "zoom-region.png"), options: .atomic)
        }
        model.replayEffect(start: 4, end: 9)
        let replayDeadline = Date().addingTimeInterval(12)
        while model.isPlaying {
            guard Date() < replayDeadline else { model.isPlaying = false; throw Failure.unexpectedEdit }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard abs(model.playhead - 10.5) < 1e-6, model.previewPlaybackEnd == nil,
              model.selection.count == 1, model.previewShowsResult else { throw Failure.unexpectedEdit }
        print("Live interval replay passed: playback advances, stops after exit, preserves selection and result mode")
        model.selection = []
        guard !model.previewShowsResult, model.project == original, model.undoStepCount == 0 else { throw Failure.unexpectedEdit }
        // Inspect masks over an active zoom: the source-space region must map into the result.
        model.playhead = 6
        model.showProjectInspector(.background)
        let unmasked = try await pixels()
        var maskResults = Set<Data>()
        var maskRegionPixels: Data?
        for (kind, name) in [(Mask.Kind.mask, "cover"), (.blur, "blur"), (.highlight, "highlight")] {
            var maskID: UUID?
            model.edit("Mask workflow fixture") {
                maskID = $0.addMask(atSource: 4, length: 5, kind: kind,
                    rect: NormRect(x: 0.35, y: 0.3, w: 0.3, h: 0.3), opacity: 1)
            }
            guard let maskID else { throw Failure.unexpectedEdit }
            model.selection = [maskID]
            for result in [false, true] {
                model.previewShowsResult = result
                try await Task.sleep(for: .milliseconds(500))
                guard preview.maskOverlayView?.isHidden == result else { throw Failure.unexpectedEdit }
                if result {
                    let rendered = try await pixels()
                    guard rendered != unmasked, maskResults.insert(rendered).inserted else { throw Failure.unexpectedEdit }
                } else {
                    let rendered = try await pixels()
                    if let maskRegionPixels {
                        guard rendered == maskRegionPixels else { throw Failure.unexpectedEdit }
                    } else { maskRegionPixels = rendered }
                }
                let overlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
                defer { overlay.removeFromSuperview() }
                guard let image = cameraView.bitmapImageRepForCachingDisplay(in: cameraView.bounds) else { throw Failure.bitmap }
                cameraView.cacheDisplay(in: cameraView.bounds, to: image)
                guard let data = image.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
                try data.write(to: url.deletingPathExtension().appendingPathExtension("mask-" + name + (result ? "-result.png" : "-region.png")), options: .atomic)
            }
            model.undo()
            model.selection = []
            guard model.project == original, model.undoStepCount == 0,
                  try await pixels() == unmasked else { throw Failure.unexpectedEdit }
        }
        print("Live mask pixels passed: cover, blur, highlight, edit/result guides and undo over active zoom")
        model.playhead = 0
        for (tab, time, name) in [(InspectorView.Tab.cursor, 0.0, "cursor"), (.audio, 0, "sound"),
                                  (.animations, 0, "motion"), (.animations, 6, "motion-active"), (.keys, 2.5, "keystrokes"), (.keys, 22.5, "keystrokes-active")] {
            model.showProjectInspector(tab)
            model.playhead = time
            try await Task.sleep(for: .milliseconds(500))
            let overlay = try await WorkspacePreviewContainer.snapshot(in: cameraView)
            defer { overlay.removeFromSuperview() }
            guard let image = cameraView.bitmapImageRepForCachingDisplay(in: cameraView.bounds) else { throw Failure.bitmap }
            cameraView.cacheDisplay(in: cameraView.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            try data.write(to: url.deletingPathExtension().appendingPathExtension(name + ".png"), options: .atomic)
        }
        model.playhead = 0
        let spatialView = NSHostingView(rootView: EditorWorkspacePrototype(model: model, initialTab: .camera, productionInspector: false))
        window.contentView = spatialView
        let spatialOverlay = try await WorkspacePreviewContainer.snapshot(in: spatialView)
        defer { spatialOverlay.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(500))
        guard let spatialRep = spatialView.bitmapImageRepForCachingDisplay(in: spatialView.bounds) else { throw Failure.bitmap }
        spatialView.cacheDisplay(in: spatialView.bounds, to: spatialRep)
        guard let spatialData = spatialRep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
        try spatialData.write(to: url.deletingPathExtension().appendingPathExtension("spatial.png"), options: .atomic)
        print("Live preview pixels passed: defaults, timed overrides, undo, region/result modes, project/selection scope")
        print("Workspace renders passed: canvas, zoom, camera, layout, group, deselected, placement, active override; no project edits")
    }
}


extension EditorWorkspaceGallery {
    /// Capture the actual shared inspector while changing scope, including an interrupted reveal.
    @MainActor static func renderInspectorMotion(to directory: URL) async throws {
        enum Failure: Error { case bitmap, state }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-inspector-motion-" + UUID().uuidString)
        let model = makeModel(at: scratch)
        defer { model.saveNow(); try? FileManager.default.removeItem(at: scratch) }
        let original = model.project
        model.showProjectInspector(.camera)
        let view = NSHostingView(rootView: InspectorView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func capture(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.bitmap }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(400))
        try capture("00-camera")
        model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
        for (delay, name) in [(20, "01-zoom-20ms"), (60, "02-zoom-80ms"), (80, "03-zoom-160ms"), (200, "04-zoom-settled")] {
            try await Task.sleep(for: .milliseconds(delay))
            try capture(name)
        }
        model.showProjectInspector(.camera)
        try await Task.sleep(for: .milliseconds(50))
        model.showProjectInspector(.audio)
        try await Task.sleep(for: .milliseconds(50))
        try capture("05-interrupted-50ms")
        try await Task.sleep(for: .milliseconds(350))
        try capture("06-sound-settled")
        guard model.inspectorTab == .audio, model.inspectorShowsProject,
              model.selection.count == 1, model.project == original, model.undoStepCount == 0 else { throw Failure.state }
        print("Inspector motion sequence captured; interruption preserves final scope, selection and project")
    }
}


extension EditorWorkspaceGallery {
    @MainActor static func checkPreviewRecovery(to directory: URL) async throws {
        enum Failure: Error { case state, bitmap }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-preview-recovery-" + UUID().uuidString)
        let model = makeModel(at: scratch)
        defer { model.saveNow(); try? FileManager.default.removeItem(at: scratch) }
        let original = model.project
        let preview = PreviewView(model: model)
        preview.framebufferOnly = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = preview
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func button(_ title: String) -> NSButton? {
            descendants(preview).compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() {
                guard Date() < deadline else { throw Failure.state }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        func capture(_ name: String) async throws {
            let frame = try await preview.captureRenderedFrame()
            let image = NSImageView(frame: preview.bounds)
            image.image = NSImage(cgImage: frame, size: preview.bounds.size)
            image.imageScaling = .scaleAxesIndependently
            preview.addSubview(image, positioned: .below, relativeTo: preview.subviews.first)
            defer { image.removeFromSuperview() }
            preview.layoutSubtreeIfNeeded()
            guard let rep = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { throw Failure.bitmap }
            preview.cacheDisplay(in: preview.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try await waitFor { button("Retry preview") != nil }
        try await capture("unavailable")
        try await WorkspaceMedia.prepare(at: scratch)
        let retryButton = button("Retry preview")!
        let retryPoint = retryButton.convert(CGPoint(x: retryButton.bounds.midX, y: retryButton.bounds.midY), to: preview.superview)
        guard preview.hitTest(retryPoint) === retryButton else { throw Failure.state }
        retryButton.performClick(nil)
        try await waitFor { preview.debugHasScreenPixelBuffer }
        guard !model.isPlaying else { throw Failure.state }
        try await capture("recovered")
        model.edit("Remove clips") { $0.clips = [] }
        try await waitFor { button("Undo Remove clips") != nil }
        guard !preview.debugHasScreenPixelBuffer, !model.isPlaying else { throw Failure.state }
        try await capture("empty")
        button("Undo Remove clips")!.performClick(nil)
        try await waitFor { preview.debugHasScreenPixelBuffer }
        guard model.project == original, model.undoStepCount == 0 else { throw Failure.state }
        // Empty again while the previous composition is still being prepared.
        model.edit("Remove clips") { $0.clips = [] }
        try await Task.sleep(for: .milliseconds(50))
        model.undo()
        try await Task.sleep(for: .milliseconds(1))
        model.edit("Remove clips") { $0.clips = [] }
        try await Task.sleep(for: .milliseconds(500))
        guard button("Undo Remove clips") != nil, !preview.debugHasScreenPixelBuffer else { throw Failure.state }
        model.undo()
        print("Preview recovery passed: missing media → native Retry → decoded frame; empty → native Undo; stale load cannot replace empty state")
    }
}


extension EditorWorkspaceGallery {
    @MainActor static func checkWorkflowReplay() async throws {
        enum Failure: Error { case timeout, state }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-workflow-replay-" + UUID().uuidString)
        let model = makeModel(at: scratch)
        try await WorkspaceMedia.prepare(at: scratch)
        defer { model.saveNow(); try? FileManager.default.removeItem(at: scratch) }
        let original = model.project
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 785),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: EditorWorkspacePrototype(model: model, replayWorkflow: true))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            model.stopEffectPreview()
        }
        var deadline = Date().addingTimeInterval(40)
        var sawPlayback = false
        while window.attachedSheet == nil {
            guard Date() < deadline else {
                print("Walkthrough timeout: tab=\(model.inspectorTab) scope=\(model.inspectorShowsProject) clips=\(model.selectedClips) selection=\(model.selection) time=\(model.playhead) playing=\(model.isPlaying) key=\(String(describing: NSApp.keyWindow))")
                throw Failure.timeout
            }
            sawPlayback = sawPlayback || model.isPlaying
            try await Task.sleep(for: .milliseconds(100))
        }
        guard window.attachedSheet is ExportSheetWindow, sawPlayback,
              model.project == original, model.undoStepCount == 0 else { throw Failure.state }
        window.endSheet(window.attachedSheet!)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView = NSHostingView(rootView: EditorWorkspacePrototype(model: model, replayWorkflow: true))
        deadline = Date().addingTimeInterval(12)
        while model.selection.isEmpty {
            guard Date() < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
        model.showProjectInspector(.cursor)
        try await Task.sleep(for: .seconds(3))
        guard model.inspectorShowsProject, model.inspectorTab == .cursor, !model.isPlaying,
              window.attachedSheet == nil, model.project == original, model.undoStepCount == 0 else { throw Failure.state }
        print("Actual gallery walkthrough passed: real playback, export sheet, unchanged project; manual context change cancels the next step")

        // Continue on the same project: combined edits must survive review, export and reopening.
        // Individual pointer/keyboard routing is covered by the focused interaction checks.
        model.showProjectInspector(.background)
        model.edit("Frame recording") { $0.output.aspect = .r16x9; $0.frame.padding = 0.12 }
        model.selectedClips = [0]
        model.edit("Trim opening") { $0.trimClip(0, edge: .leading, toSource: 1) }
        guard let zoom = model.addZoom(atSource: 10, length: 1) else { throw Failure.state }
        model.replayEffect(start: 10, end: 11)
        deadline = Date().addingTimeInterval(10)
        while model.isPlaying {
            guard Date() < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.selection == [zoom], model.previewShowsResult else { throw Failure.state }
        var hidden: UUID?
        model.edit("Hide camera for interval") { hidden = $0.addLayout(atSource: 12, length: 2, kind: .hidden) }
        guard let hidden else { throw Failure.state }
        model.selection = [hidden]
        model.showProjectInspector(.camera)
        model.edit("Camera default") { $0.camera.position = NormPoint(x: 0.2, y: 0.8) }
        guard model.selection == [hidden], model.inspectorShowsProject,
              model.project.layouts.contains(where: { $0.id == hidden.uuidString && $0.kind == .hidden }) else {
            throw Failure.state
        }
        var mask: UUID?
        model.edit("Cover private detail") {
            mask = $0.addMask(atSource: 10, length: 2, kind: .mask,
                             rect: NormRect(x: 0.2, y: 0.3, w: 0.3, h: 0.2), opacity: 1)
        }
        guard let mask else { throw Failure.state }
        model.selection = [mask]
        model.playhead = model.previewTime(start: 10, end: 12)!
        model.previewShowsResult = true
        model.showProjectInspector(.keys)
        model.edit("Keystroke duration") { $0.keys.hold = 1.5 }
        model.showProjectInspector(.audio)
        let edited = model.project
        let steps = model.undoStepCount
        model.undo()
        model.redo()
        guard model.project == edited, model.undoStepCount == steps,
              abs(model.timeMap.outputDuration - 31) < 0.01 else { throw Failure.state }
        let overlay = try await WorkspacePreviewContainer.snapshot(in: window.contentView!)
        overlay.removeFromSuperview()
        model.saveNow()
        guard try Project.load(from: scratch.appendingPathComponent("project.json")) == edited else { throw Failure.state }

        let suite = "recorder-workflow-export-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ExportSheetModel(editorModel: model, defaults: defaults)
        export.settings.shortEdge = 720
        export.settings.fps = 30
        let sheet = ExportSheetWindow(model: export)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        let output = scratch.appendingPathComponent("Edited walkthrough.mp4")
        export.startExport(to: output)
        deadline = Date().addingTimeInterval(120)
        while export.isExporting {
            guard Date() < deadline else { export.cancel(); throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case let .done(url, bytes) = export.phase, url == output, bytes > 0,
              abs(try await AVURLAsset(url: output).load(.duration).seconds - 31) < 0.1 else { throw Failure.state }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        export.copyResult(output, pasteboard: board)
        guard (board.readObjects(forClasses: [NSURL.self]) as? [URL]) == [output],
              model.project == edited, model.undoStepCount == steps else { throw Failure.state }
        print("Continuous editing passed: frame, trim, new zoom and live replay, timed hide, global camera, mask, keys, save/reload, playable 31-second export and file-copy handoff. Native Save/Finder is separate.")
    }
}


extension EditorWorkspaceGallery {
    @MainActor static func checkInspectorScroll(to directory: URL) async throws {
        enum Failure: Error { case scrollView, bitmap, position }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-inspector-scroll-" + UUID().uuidString)
        let model = makeModel(at: scratch)
        defer { model.saveNow(); try? FileManager.default.removeItem(at: scratch) }
        model.showProjectInspector(.camera)
        let view = NSHostingView(rootView: InspectorView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        func capture(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.bitmap }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let scroll = findScroll(view), let document = scroll.documentView else { throw Failure.scrollView }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        guard scroll.contentView.bounds.minY > 20 else { throw Failure.position }
        try capture("camera-bottom")
        let collapsedHeight = document.bounds.height
        // Native click on the visible Shape & finish disclosure in this fixed-size specimen.
        let disclosure = CGPoint(x: 18, y: view.isFlipped ? 189 : view.bounds.height - 189)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(disclosure, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(400))
        guard document.bounds.height > collapsedHeight + 40 else { throw Failure.position }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        try capture("camera-finish-expanded")
        let savedOffset = scroll.contentView.bounds.minY
        let wasMirrored = model.project.camera.mirror
        let mirror = CGPoint(x: 24, y: view.isFlipped ? 161 : view.bounds.height - 161)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(mirror, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(250))
        guard model.project.camera.mirror != wasMirrored,
              abs(scroll.contentView.bounds.minY - savedOffset) < 1 else { throw Failure.position }
        model.undo()
        model.showProjectInspector(.keys)
        try await Task.sleep(for: .milliseconds(500))
        try capture("keys-after-camera")
        guard let next = findScroll(view) else { throw Failure.scrollView }
        print("Inspector scroll offset after destination change: \(next.contentView.bounds.minY)")
        guard abs(next.contentView.bounds.minY) < 1 else { throw Failure.position }
        model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
        try await Task.sleep(for: .milliseconds(500))
        try capture("zoom-after-keys")
        guard let selected = findScroll(view), abs(selected.contentView.bounds.minY) < 1 else { throw Failure.position }
        print("Compact inspector scroll passed: bottom reachable, destination and selection begin at the top")
    }
}


extension EditorWorkspaceGallery {
    /// Final layout review in the actual document window, with its live Metal preview included.
    @MainActor static func renderNativeEditor(to directory: URL) async throws {
        enum Failure: Error { case window, preview, bitmap }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-native-review-" + UUID().uuidString)
        let fixture = makeModel(at: scratch)
        fixture.edit("Mask fixture") {
            _ = $0.addMask(atSource: 10, length: 2, kind: .mask,
                          rect: NormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.2))
        }
        fixture.saveNow()
        try await WorkspaceMedia.prepare(at: scratch)
        guard let window = EditorWindowController.makeOffscreen(package: scratch),
              let controller = window.windowController as? EditorWindowController,
              let root = window.contentView else { throw Failure.window }
        window.isReleasedWhenClosed = false
        defer { window.close(); try? FileManager.default.removeItem(at: scratch) }
        func findPreview(_ view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            return view.subviews.lazy.compactMap { findPreview($0) }.first
        }
        guard let preview = findPreview(root) else { throw Failure.preview }
        preview.framebufferOnly = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        let model = controller.model
        model.edit("Long title fixture") {
            $0.title = "Product walkthrough — recording the complete setup, demonstration and review for the team"
        }
        for (width, height, size) in [(1100.0, 700.0, "minimum"), (1200.0, 760.0, "default")] {
            window.setContentSize(NSSize(width: width, height: height))
            for state in ["canvas", "camera", "cursor", "keys", "sound", "motion", "clip", "layout", "mask", "zoom", "camera-clip", "keys-clip", "multiple"] {
                model.selectedClips = []; model.selection = []
                if state == "zoom" {
                    model.selection = [UUID(uuidString: model.project.zooms[0].id)!]
                    model.inspectorShowsProject = false
                    model.playhead = 6
                } else if state == "camera-clip" || state == "keys-clip" {
                    let id = state == "camera-clip" ? model.project.cameraClips[0].id : model.project.keystrokeClips[0].id
                    model.selection = [UUID(uuidString: id)!]
                    model.inspectorShowsProject = false
                } else if state == "multiple" {
                    model.selectedClips = [0, 1]
                    model.inspectorShowsProject = false
                } else if state == "clip" {
                    model.selectedClip = 0
                    model.inspectorShowsProject = false
                } else if state == "layout", let id = model.project.layouts.first?.id {
                    model.selection = [UUID(uuidString: id)!]
                    model.inspectorShowsProject = false
                } else if state == "mask", let id = model.project.masks.first?.id {
                    model.selection = [UUID(uuidString: id)!]
                    model.inspectorShowsProject = false
                } else {
                    let tabs: [String: InspectorView.Tab] = ["canvas": .background, "camera": .camera,
                        "cursor": .cursor, "keys": .keys, "sound": .audio, "motion": .animations]
                    model.showProjectInspector(tabs[state] ?? .background)
                    model.playhead = 0
                }
                try await Task.sleep(for: .milliseconds(700))
                guard window.title == model.project.title,
                      controller.inspectorView.frame.minY == 0,
                      controller.timelineView.frame.maxX == controller.inspectorView.frame.minX,
                      controller.coreTimelineView.bounds.height >= controller.coreTimelineView.contentHeight else { throw Failure.window }
                let frame = try await preview.captureRenderedFrame()
                let overlay = NSImageView(frame: preview.bounds)
                overlay.image = NSImage(cgImage: frame, size: preview.bounds.size)
                overlay.imageScaling = .scaleAxesIndependently
                preview.addSubview(overlay, positioned: .below, relativeTo: preview.subviews.first)
                defer { overlay.removeFromSuperview() }
                let capture = root.superview ?? root
                capture.layoutSubtreeIfNeeded()
                guard let rep = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { throw Failure.bitmap }
                capture.cacheDisplay(in: capture.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.bitmap }
                try data.write(to: directory.appendingPathComponent(size + "-" + state + ".png"))
            }
        }
        // Dispatch native events through the real window; sample the switch in motion and settled.
        model.showProjectInspector(.keys)
        try await Task.sleep(for: .milliseconds(500))
        let beforeSwitch = model.project
        let inspector = controller.inspectorView
        let switchPoint = NSPoint(x: 280, y: inspector.isFlipped ? 151 : inspector.bounds.height - 151)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: inspector.convert(switchPoint, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        for (delay, name) in [(90, "switch-transition"), (220, "switch-settled")] {
            try await Task.sleep(for: .milliseconds(delay))
            guard let rep = inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds) else { throw Failure.bitmap }
            inspector.cacheDisplay(in: inspector.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        }
        guard model.project.keys.show != beforeSwitch.keys.show else { throw Failure.window }
        model.undo()
        guard model.project == beforeSwitch else { throw Failure.window }

        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        guard let scroll = findScroll(inspector), let document = scroll.documentView else { throw Failure.window }
        let collapsedHeight = document.bounds.height
        let disclosurePoint = NSPoint(x: 120, y: inspector.isFlipped ? 410 : inspector.bounds.height - 410)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: inspector.convert(disclosurePoint, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(300))
        guard document.bounds.height > collapsedHeight + 40, model.project == beforeSwitch else { throw Failure.window }
        if let rep = inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds) {
            inspector.cacheDisplay(in: inspector.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("keys-expanded.png"))
        }
        func titleField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == model.project.title { return field }
            return view.subviews.lazy.compactMap { titleField(in: $0) }.first
        }
        guard let title = titleField(in: root) else { throw Failure.window }
        let originalFrame = window.frame
        for count in [1, 2] {
            let event = NSEvent.mouseEvent(with: .leftMouseDown,
                location: title.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            title.mouseDown(with: event)
        }
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
        guard !title.isEditable, window.frame != originalFrame else { throw Failure.window }
        window.setFrame(originalFrame, display: true)
        print("Native switch click changed one setting with one undo; transition sampled; title double-click resized without entering rename")
        model.undo()
        try await Task.sleep(for: .milliseconds(100))
        guard window.title == fixture.project.title else { throw Failure.window }
        guard TransportBar.timecode(59.999) == "01:00.00",
              TransportBar.timecode(-1) == "00:00.00" else { throw Failure.window }
        print("Native editor rendered at minimum/default sizes with live media, camera pad, selected zoom and long title; title undo synchronized")
    }
}
