import AppKit
import SwiftUI
import RecorderCore

/// The editor's main window (SPEC §6.1 mockup): preview | 300 pt inspector over a timeline, laid
/// out manually (no `NSSplitView`), timeline height draggable 160–420 pt, top bar in the titlebar.
/// Opened by `RecordingController.finish` and the library (wired by the coordinator) through
/// `open(package:)`. The inspector/timeline panes are placeholders until their lanes land —
/// `inspectorView`/`timelineView` are replaceable so the coordinator can swap in the real views.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    let previewView: PreviewView

    var inspectorView: NSView {
        didSet { rootView.inspector = inspectorView }
    }
    var timelineView: NSView {
        didSet { rootView.timeline = timelineView }
    }

    private let rootView: EditorRootView
    private var titleField: NSTextField!
    private var widthConstraint: NSLayoutConstraint?
    private var resizeObserver: NSObjectProtocol?

    private static var openWindows: [URL: EditorWindowController] = [:]

    private init(packageURL: URL, project: Project, events: EventLog) {
        let model = EditorModel(packageURL: packageURL, project: project, events: events)
        let preview = PreviewView(model: model)
        let transport = NSHostingView(rootView: TransportBar(model: model, preview: preview))
        let inspector = EditorWindowController.placeholder("Inspector")
        let timeline = EditorWindowController.placeholder("Timeline")

        self.model = model
        self.previewView = preview
        self.inspectorView = inspector
        self.timelineView = timeline
        self.rootView = EditorRootView(preview: preview, transport: transport, inspector: inspector, timeline: timeline)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1100, height: 700)
        window.title = project.title
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)

        window.delegate = self
        installTitlebarAccessory()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(preview)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }

    /// Opens (or focuses, if already open) the editor for `package`. Dev/HUMAN entry point:
    /// `Recorder --open <package>`; `RecordingController.finish`/the library call this too.
    @discardableResult
    static func open(package: URL) -> EditorWindowController? {
        let key = package.standardizedFileURL
        if let existing = openWindows[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return existing
        }
        guard let project = try? Project.load(from: key.appendingPathComponent("project.json")) else { return nil }
        let eventsURL = key.appendingPathComponent("events.json")
        let events = (try? JSONDecoder().decode(EventLog.self, from: Data(contentsOf: eventsURL))) ?? EventLog()
        let controller = EditorWindowController(packageURL: key, project: project, events: events)
        openWindows[key] = controller
        NSApp.activate()
        return controller
    }

    /// Flushes every open editor's pending autosave (SPEC §5: "also on window close and
    /// applicationWillTerminate" — `AppDelegate.applicationWillTerminate` calls this).
    static func saveAllNow() {
        for controller in openWindows.values { controller.model.saveNow() }
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
        Self.openWindows.removeValue(forKey: model.packageURL)
    }

    // MARK: - Titlebar accessory (SPEC §6.1: ‹ Projects · title · Auto ▾ · ⌗ Crop · ⬆ Export)

    private func installTitlebarAccessory() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let stack = buildTopBarStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        // Traffic lights + standard titlebar margin take ~78 pt on the left; approximate the rest
        // as the accessory's width and keep it in sync on resize so the bar spans the titlebar
        // the way the mockup shows (an `NSTitlebarAccessoryViewController` sizes to its view, it
        // doesn't stretch on its own).
        let width = container.widthAnchor.constraint(equalToConstant: max(0, window.frame.width - 78))
        width.isActive = true
        widthConstraint = width
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let window else { return }
            self?.widthConstraint?.constant = max(0, window.frame.width - 78)
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func buildTopBarStack() -> NSStackView {
        let back = NSButton(title: "‹ Projects", target: nil, action: nil) // wired once the library exists
        styleAsText(back)

        let title = NSTextField(string: model.project.title)
        title.isBordered = false
        title.drawsBackground = false
        title.font = Theme.bodyFont
        title.textColor = Theme.textPrimary
        title.target = self
        title.action = #selector(titleCommitted(_:))
        titleField = title

        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.addItems(withTitles: Self.aspectTitles.map(\.1))
        if let index = Self.aspectTitles.firstIndex(where: { $0.0 == model.project.output.aspect }) {
            aspect.selectItem(at: index)
        }
        // T-309 wires this selection to `model.edit { $0.output.aspect = … }`.

        let crop = NSButton(title: "⌗ Crop", target: nil, action: nil) // wired by T-310 (Crop sheet)
        styleAsText(crop)

        let export = NSButton(title: "⬆ Export", target: nil, action: nil)
        styleAsText(export)
        export.isEnabled = false // disabled until M5 (T-506)

        let stack = NSStackView(views: [back, title, aspect, crop, export])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        return stack
    }

    private func styleAsText(_ button: NSButton) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = Theme.accentText
    }

    @objc private func titleCommitted(_ sender: NSTextField) {
        let newTitle = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { sender.stringValue = model.project.title; return }
        guard newTitle != model.project.title else { return }
        model.edit("rename") { $0.title = newTitle }
        window?.title = newTitle
    }

    private static let aspectTitles: [(Output.Aspect, String)] = [
        (.auto, "Auto"), (.r16x9, "16:9"), (.r9x16, "9:16"), (.r1x1, "1:1"), (.r4x3, "4:3"), (.r16x10, "16:10"),
    ]

    private static func placeholder(_ text: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.bgPanel.cgColor
        let label = NSTextField(labelWithString: text)
        label.textColor = Theme.textSecondary
        label.font = Theme.captionFont
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}

/// Manual layout (no `NSSplitView`): preview + transport bar | 300 pt inspector, over the
/// timeline; the divider between them drags the timeline's height (160–420 pt). SPEC §6.1 mockup.
private final class EditorRootView: NSView {
    static let inspectorWidth: CGFloat = 300
    static let transportHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 6
    static let timelineRange: ClosedRange<CGFloat> = 160...420

    let preview: NSView
    let transport: NSView
    var inspector: NSView { didSet { swap(oldValue, for: inspector) } }
    var timeline: NSView { didSet { swap(oldValue, for: timeline) } }

    private var timelineHeight: CGFloat = 220
    private var dragStartHeight: CGFloat?
    private var dragStartY: CGFloat?

    init(preview: NSView, transport: NSView, inspector: NSView, timeline: NSView) {
        self.preview = preview
        self.transport = transport
        self.inspector = inspector
        self.timeline = timeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgWindow.cgColor
        for view in [preview, transport, inspector, timeline] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func swap(_ old: NSView, for new: NSView) {
        old.removeFromSuperview()
        addSubview(new)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let clampedTimeline = min(max(timelineHeight, Self.timelineRange.lowerBound), Self.timelineRange.upperBound)
        let rowHeight = max(0, bounds.height - clampedTimeline - Self.dividerHeight)
        let previewHeight = max(0, rowHeight - Self.transportHeight)
        let previewWidth = max(0, bounds.width - Self.inspectorWidth)
        let rowY = clampedTimeline + Self.dividerHeight

        timeline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: clampedTimeline)
        transport.frame = NSRect(x: 0, y: rowY, width: previewWidth, height: Self.transportHeight)
        preview.frame = NSRect(x: 0, y: rowY + Self.transportHeight, width: previewWidth, height: previewHeight)
        inspector.frame = NSRect(x: previewWidth, y: rowY, width: Self.inspectorWidth, height: rowHeight)
    }

    // MARK: - Divider drag (timeline height, 160–420 pt)

    private func dividerHitRange() -> ClosedRange<CGFloat> {
        let clamped = min(max(timelineHeight, Self.timelineRange.lowerBound), Self.timelineRange.upperBound)
        return (clamped - 3)...(clamped + Self.dividerHeight + 3)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dividerHitRange().contains(point.y) else { super.mouseDown(with: event); return }
        dragStartHeight = min(max(timelineHeight, Self.timelineRange.lowerBound), Self.timelineRange.upperBound)
        dragStartY = point.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartHeight, let dragStartY else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let proposed = dragStartHeight + (point.y - dragStartY)
        timelineHeight = min(max(proposed, Self.timelineRange.lowerBound), Self.timelineRange.upperBound)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartHeight = nil
        dragStartY = nil
    }

    override func resetCursorRects() {
        let range = dividerHitRange()
        addCursorRect(NSRect(x: 0, y: range.lowerBound, width: bounds.width, height: range.upperBound - range.lowerBound), cursor: .resizeUpDown)
    }
}
