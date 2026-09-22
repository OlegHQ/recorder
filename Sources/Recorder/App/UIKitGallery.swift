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
        let advanced = CommandLine.arguments.contains("--gallery-advanced")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = advanced ? "Recorder / gallery-advanced" : "Signal UI / Component Gallery"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bgWindow
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UIKitGalleryView(advanced: advanced))
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
        let advanced = CommandLine.arguments.contains("--gallery-advanced")
        let overlay = advanced ? nil : try await WorkspacePreviewContainer.snapshot(in: view)
        defer { overlay?.removeFromSuperview() }
        func capture(_ destination: URL) throws {
            // Capture this window's composited pixels, including native and Metal views.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.capture }
        }
        if CommandLine.arguments.contains("--gallery-check") {
            try await Task.sleep(for: .milliseconds(80))
            try capture(url.deletingPathExtension().appendingPathExtension("entrance.png"))
            try await Task.sleep(for: .milliseconds(160))
            try capture(url.deletingPathExtension().appendingPathExtension("stagger.png"))
            try await Task.sleep(for: .milliseconds(660))
        } else {
            try await Task.sleep(for: .milliseconds(900))
        }
        try capture(url)
        if CommandLine.arguments.contains("--gallery-check") {
            guard advanced, CommandLine.arguments.contains("--gallery-demo") else { throw Failure.capture }
            for (step, expected) in [NSAppearance.Name.darkAqua, .aqua, .aqua, .darkAqua, .darkAqua].enumerated() {
                try await Task.sleep(for: .seconds(2.4))
                guard window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == expected else {
                    throw Failure.capture
                }
                try capture(url.deletingPathExtension().appendingPathExtension("step-\(step).png"))
            }
            window.setContentSize(NSSize(width: 900, height: 620))
            try await Task.sleep(for: .milliseconds(600))
            try capture(url.deletingPathExtension().appendingPathExtension("minimum.png"))
            print("Gallery demo completed: scroll stages, both appearances, minimum size")
        }
    }
}

private struct UIKitGalleryView: View {
    var advanced = false
    @State private var light = CommandLine.arguments.contains("--gallery-light")
    @State private var replay = 0
    @State private var demo = CommandLine.arguments.contains("--gallery-demo")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name = "Capture 042"
    @State private var enabled = true
    @State private var slider = 0.64
    @State private var mode = 1
    @State private var search = ""
    @State private var selectionRect = CGRect(x: 120, y: 80, width: 960, height: 540)

    var body: some View {
        ZStack {
            Theme.bgWindowColor.ignoresSafeArea()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if advanced { themeRail }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            masthead.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay)).id("intro")
                            if !advanced { workspace }
                            TimelineInteractionPrototype(
                                autoAudition: CommandLine.arguments.contains("--ui-gallery-audition"),
                                scrollReveals: advanced, galleryReplay: replay
                            ).id("motion")
                            HStack(alignment: .top, spacing: 12) {
                                typography.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                colors.modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
                            }.frame(height: 154).id("elements")
                            HStack(alignment: .top, spacing: 12) {
                                controls.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                inputs.modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
                            }.frame(height: 250)
                            if advanced { workspace.id("workspace") }
                            states.fixedSize(horizontal: false, vertical: true)
                                .modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                            floatingPanels.fixedSize(horizontal: false, vertical: true)
                                .modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                            signature
                        }
                        .padding(28)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { demo = false }
                    }
                }
                .task(id: demo) {
                    guard advanced && demo else { return }
                    light = false
                    proxy.scrollTo("intro", anchor: .top)
                    replay += 1
                    do {
                        for (section, white) in [("motion", false), ("motion", true),
                                             ("elements", true), ("elements", false), ("intro", false)] {
                            try await Task.sleep(for: .seconds(2.4))
                            light = white
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) {
                                proxy.scrollTo(section, anchor: .top)
                            }
                        }
                        demo = false
                    } catch { /* Direct scrolling and Stop demo cancel the sequence. */ }
                }
            }
        }
        .font(Font(Theme.bodyFont))
        .foregroundStyle(Theme.textPrimaryColor)
        .tint(Theme.accentColor)
        .preferredColorScheme(advanced && light ? .light : .dark)
    }

    private var workspace: some View {
        Group {
            EditorWorkspaceGallery().frame(height: 785)
                .modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
            TechPanel(index: "01", title: "Editor timeline · production") {
                ProductionTimelinePreview().frame(height: 250)
            }.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
        }
    }

    private var themeRail: some View {
        HStack(spacing: 8) {
            Text("gallery-advanced").font(Font(Theme.headingFont(24)))
            Spacer()
            ForEach([false, true], id: \.self) { isLight in
                Button { demo = false; light = isLight } label: {
                    Label(isLight ? "White" : "Black", systemImage: isLight ? "sun.max" : "moon")
                }
                .buttonStyle(TechButtonStyle(kind: light == isLight ? .primary : .secondary))
                .accessibilityAddTraits(light == isLight ? .isSelected : [])
            }
            Button("Replay reveals") { demo = false; replay += 1 }
                .buttonStyle(TechButtonStyle())
            Button(demo ? "Stop demo" : "Play demo") { demo.toggle() }
                .buttonStyle(TechButtonStyle())
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
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
                swatch("Ink", Theme.textPrimaryColor)
                swatch("Text", Theme.textSecondaryColor)
                swatch("Border", Theme.strokeStrongColor)
                swatch("Control", Theme.bgHoverColor)
            }
            Text(advanced && light ? "White background. Black foreground." : "Black background. White foreground.")
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

/// Visibility is measured before the animated content, so reveal motion cannot retrigger itself.
private struct GalleryReveal: ViewModifier {
    let enabled: Bool
    let order: Int
    let replay: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var revealed = false
    @State private var rule = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || revealed ? 1 : 0.08)
            .offset(y: enabled && !revealed && !reduceMotion ? 12 : 0)
            .overlay(alignment: .topLeading) {
                if enabled && !reduceMotion {
                    Rectangle().fill(Theme.textPrimaryColor)
                        .frame(height: 1)
                        .scaleEffect(x: rule ? 1 : 0, anchor: .leading)
                        .opacity(revealed ? 0 : 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
            .task(id: "\(visible)-\(replay)-\(reduceMotion)") {
                guard enabled else { return }
                guard visible else { revealed = false; rule = false; return }
                if reduceMotion { revealed = true; rule = true; return }
                revealed = false
                rule = false
                do {
                    try await Task.sleep(for: .milliseconds(40 + order * 80))
                    withAnimation(.easeOut(duration: 0.24)) { rule = true }
                    try await Task.sleep(for: .milliseconds(75))
                    withAnimation(.easeOut(duration: Theme.Motion.reveal)) { revealed = true }
                } catch { /* Visibility changes and replay cancel pending stages. */ }
            }
    }
}
