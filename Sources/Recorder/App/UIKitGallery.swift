import AppKit
import SwiftUI
import RecorderCore

enum UIKitGallery {
    private static var window: NSWindow?

    @MainActor static func show() {
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @MainActor static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Signal UI / Component Gallery"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bgWindow
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UIKitGalleryView())
        window.center()
        return window
    }

    @MainActor static func renderPNG(to url: URL) async throws {
        enum Failure: Error { case capture }
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.orderOut(nil) }
        guard let view = window.contentView else { throw Failure.capture }
        view.layoutSubtreeIfNeeded()
        let overlay = try await WorkspacePreviewContainer.snapshot(in: view)
        defer { overlay.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(300))
        // Nested SwiftUI scroll surfaces can cache as black. Capture only this window's
        // composited pixels, including Metal, through the system's window capture utility.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw Failure.capture }
    }
}

private struct UIKitGalleryView: View {
    @State private var name = "Capture 042"
    @State private var enabled = true
    @State private var slider = 0.64
    @State private var mode = 1
    @State private var search = ""
    @State private var selectionRect = CGRect(x: 120, y: 80, width: 960, height: 540)

    var body: some View {
        ZStack {
            Theme.bgWindowColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    masthead
                    EditorWorkspaceGallery().frame(height: 785)
                    TechPanel(index: "01", title: "Editor timeline · production") {
                        ProductionTimelinePreview().frame(height: 250)
                    }
                    TimelineInteractionPrototype(
                        autoAudition: CommandLine.arguments.contains("--ui-gallery-audition")
                    )
                    HStack(alignment: .top, spacing: 12) {
                        typography
                        colors
                    }.frame(height: 154)
                    HStack(alignment: .top, spacing: 12) {
                        controls
                        inputs
                    }.frame(height: 250)
                    states.fixedSize(horizontal: false, vertical: true)
                    floatingPanels.fixedSize(horizontal: false, vertical: true)
                    signature
                }
                .padding(28)
            }
        }
        .signalWindow()
    }

    private var masthead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Recorder").font(Font(Theme.headingFont(44)))
                    Image(systemName: "arrow.up.right").font(.system(size: 20, weight: .heavy))
                        .accessibilityHidden(true)
                }
                Text("Interface components")
                    .font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("01—07")
                    .font(Font(Theme.headingFont(26)))
                    .foregroundStyle(Theme.bgWindowColor)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .background(Theme.textPrimaryColor)
                Text("Type, controls & timeline")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimaryColor).frame(height: 3) }
    }

    private var typography: some View {
        TechPanel(index: "01", title: "Typography") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screen recording").font(Font(Theme.headingFont(26)))
                Text("Barlow Semi Condensed Light / Andale Mono")
                    .font(Font(Theme.labelFont)).foregroundStyle(Theme.accentColor)
                Text("00:14:32:18  ·  3840×2160  ·  60 fps")
                    .font(Font(Theme.timecodeFont(12))).foregroundStyle(Theme.textSecondaryColor)
            }
        }
    }

    private var colors: some View {
        TechPanel(index: "02", title: "Surfaces") {
            HStack(spacing: 8) {
                swatch("White", Theme.textPrimaryColor)
                swatch("Text", Theme.textSecondaryColor)
                swatch("Border", Theme.strokeStrongColor)
                swatch("Control", Theme.bgHoverColor)
            }
            Text("Black background. White foreground.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private var controls: some View {
        TechPanel(index: "03", title: "Actions") {
            HStack(spacing: 4) {
                Button("Record") {}.buttonStyle(TechButtonStyle(kind: .primary))
                Button("Export") {}.buttonStyle(TechButtonStyle())
                Button("Cancel") {}.buttonStyle(TechButtonStyle(kind: .quiet))
                Button("Unavailable") {}.buttonStyle(TechButtonStyle()).disabled(true)
            }
            HStack(spacing: 8) {
                Text("Native AppKit")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                TechAppKitButtonPreview(title: "Timeline action")
                    .fixedSize()
                Menu { Button("Example") {} } label: { TechMenuLabel(title: "Menu") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                ForEach(["display", "macwindow", "rectangle.dashed"], id: \.self) { icon in
                    Button {} label: { Image(systemName: icon).frame(width: 18, height: 18) }
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                }
                Button {} label: {
                    HStack(spacing: 0) {
                        Theme.textPrimaryColor
                        Theme.bgHoverColor
                    }
                    .frame(width: 54, height: 26)
                }
                .buttonStyle(TechSelectableTileStyle(selected: true))
            }
            HStack {
                Text("Start recording").foregroundStyle(Theme.textSecondaryColor)
                Spacer()
                Text("⌘ N").foregroundStyle(Theme.textPrimaryColor)
            }
            .font(Font(Theme.captionFont))
            .padding(.top, 8)
            .overlay(alignment: .top) { Theme.strokeColor.frame(height: 1) }
        }
    }

    private var inputs: some View {
        TechPanel(index: "04", title: "Inputs") {
            TextField("Recording name", text: $name).textFieldStyle(TechFieldStyle())
            TechSearchField(placeholder: "Search projects", text: $search, width: 260)
            Toggle("Include microphone", isOn: $enabled).toggleStyle(TechToggleStyle())
            HStack {
                Text("Gain").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Slider(value: $slider).tint(Theme.accentColor).labelsHidden()
                Text(slider, format: .percent.precision(.fractionLength(0)))
                    .font(Font(Theme.timecodeFont(11))).frame(width: 38, alignment: .trailing)
            }
            TechSegmentedControl(selection: $mode,
                                 options: [(0, "Display"), (1, "Window"), (2, "Area")])
                .frame(width: 220)
        }
    }

    private var states: some View {
        TechPanel(index: "05", title: "Status + data") {
            HStack(spacing: 18) {
                TechStatus(title: "Ready", color: Theme.textPrimaryColor)
                TechStatus(title: "Recording", color: Theme.dangerColor)
                TechStatus(title: "Paused", color: Theme.warningColor)
            }
            HStack(spacing: 8) {
                metric("Duration", "14:32")
                metric("Frames", "52.3k")
                metric("Dropped", "000")
            }
            HStack {
                Text("Export progress")
                Spacer()
                Text("72%")
            }.font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Theme.bgHoverColor
                    Theme.textPrimaryColor.frame(width: geometry.size.width * 0.72)
                }
            }.frame(height: 6)
        }
    }

    private var floatingPanels: some View {
        TechPanel(index: "07", title: "Floating capture") {
            VStack(alignment: .leading, spacing: 10) {
                ToolbarView(onClose: {}, onSelectMode: { _ in }, onCamera: {}, onMicrophone: {},
                            onSystemAudio: {}, onSettings: {})
                HStack(spacing: 12) {
                    RecordingWidgetView(state: WidgetState(elapsed: 42), onFinish: {}, onPause: {},
                                        onResume: {}, onRestart: {}, onDelete: {})
                    CountdownView(state: CountdownState(remaining: 3))
                        .scaleEffect(0.42)
                        .frame(width: 68, height: 48)
                }
                HStack(spacing: 12) {
                    AreaFieldsView(rect: $selectionRect).fixedSize()
                    StartRecordingButton(action: {})
                }
            }
        }
    }

    private var timeline: some View {
        TechPanel(index: "06", title: "Timeline") {
            VStack(spacing: 6) {
                HStack {
                    Text("00:00")
                    Spacer()
                    Text("00:15")
                    Spacer()
                    Text("00:30")
                }
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                .padding(.leading, 51)
                lane(label: "Video", color: Theme.clipColor, widths: [0.32, 0.16, 0.42])
                lane(label: "Zoom", color: Theme.zoomColor, widths: [0.14, 0.26])
                lane(label: "Layout", color: Theme.layoutColor, widths: [0.38])
                lane(label: "Mask", color: Theme.maskColor, widths: [0.18, 0.12])
            }
        }
    }

    private var signature: some View {
        HStack {
            Text("Recorder")
            Spacer()
            Text("Component gallery")
        }
        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            color.frame(height: 24)
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }.frame(maxWidth: .infinity)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
            Text(value).font(Font(Theme.headingFont(26))).foregroundStyle(Theme.textPrimaryColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lane(label: String, color: Color, widths: [CGFloat]) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geometry in
                HStack(spacing: 4) {
                    ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                        Rectangle().fill(color).frame(width: geometry.size.width * width)
                            .overlay(alignment: .leading) {
                                Text(String(format: "%02d", index + 1))
                                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.bgWindowColor)
                                    .padding(.leading, 5)
                            }
                    }
                }
            }.frame(height: 23)
        }
    }
}

/// The actual editor widgets, backed by a disposable project rather than a second timeline implementation.
private struct ProductionTimelinePreview: NSViewRepresentable {
    final class Coordinator {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-gallery-" + UUID().uuidString)
        var model: EditorModel?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TimelineContainerView {
        var project = Project(title: "Timeline study", source: Source(duration: 48, hasCamera: true))
        project.clips = [Clip(sourceStart: 0, sourceEnd: 16), Clip(sourceStart: 16, sourceEnd: 32, speed: 2),
                         Clip(sourceStart: 36, sourceEnd: 48)]
        project.zooms = [Zoom(start: 3, end: 9, scale: 2, mode: .auto), Zoom(start: 20, end: 29, scale: 1.6, mode: .manual)]
        project.keystrokeClips = [Layout(start: 4, end: 12, kind: .settings, keys: Keys(show: true))]
        project.cameraClips = [CameraClip(start: 0, end: 14), CameraClip(start: 20, end: 45)]
        project.liftClip(1)
        project.masks = [Mask(start: 38, end: 45, kind: .blur, rect: NormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.3), opacity: 1)]
        try? FileManager.default.createDirectory(at: context.coordinator.url, withIntermediateDirectories: true)
        let model = EditorModel(packageURL: context.coordinator.url, project: project, events: EventLog())
        model.playhead = 11
        model.selection = [UUID(uuidString: project.zooms[0].id)!]
        context.coordinator.model = model
        let timeline = TimelineView(frame: .zero)
        timeline.model = model
        let toolbar = TimelineToolbar(frame: .zero)
        toolbar.timelineView = timeline
        return TimelineContainerView(toolbar: toolbar, timeline: timeline)
    }
    func updateNSView(_ view: TimelineContainerView, context: Context) {}
    static func dismantleNSView(_ view: TimelineContainerView, coordinator: Coordinator) {
        coordinator.model?.saveNow()
        view.timeline.model = nil
        coordinator.model = nil
        try? FileManager.default.removeItem(at: coordinator.url)
    }
}
