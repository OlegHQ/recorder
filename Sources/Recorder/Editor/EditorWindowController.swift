import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import Observation
import SwiftUI
import UniformTypeIdentifiers
import RecorderCore

/// The editor's main window: document/navigation bars above preview + transport + timeline,
/// with a full-height inspector alongside. The timeline fits its lanes and can be enlarged; `window` is
/// `.fullSizeContentView` so that top bar draws under the native titlebar strip (T-307 fix).
/// Opened by `RecordingController.finish` and the library through `open(package:)`.
/// `inspectorView`/`timelineView` host `InspectorView` and `TimelineView` (+ its `TimelineToolbar`)
/// and stay swappable NSViews only so `EditorRootView`'s manual layout doesn't care which view is in
/// each slot.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
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
    private var saveStatusButton: NSButton!
    // Typed handles onto the two swappable views above, kept alongside them so the menu actions
    // (T-311) below can reach real API (`InspectorView.init(initialTab:)`, `TimelineView.setZoom`)
    // instead of only the type-erased `NSView` the rest of the window plumbing needs.
    private let inspectorHostingView: NSHostingView<InspectorView>
    // T-610: not `private` — the state snapshot dump (`StateSnapshot.swift`) reads its `geometry`/
    // debug accessors directly instead of duplicating a second way to reach the timeline.
    let coreTimelineView: TimelineView
    var currentInspectorTab: InspectorView.Tab { model.inspectorTab }
    // T-601: kept alive here (its own `view` is only weakly referenced by `PreviewView`'s subview
    // list) and re-laid-out on every preview resize (`preview.onResize` below).
    private let maskOverlay: MaskRectOverlay

    private static var openingWindows: [URL: OpeningEditor] = [:]
    private static var openWindows: [URL: EditorWindowController] = [:]
    // T-610: every constructed controller, including ones from `makeOffscreen` (never added to
    // `openWindows` — that dict is only the URL-keyed "focus the existing window instead of
    // duplicating it" dedup for `open(package:)`). `allOpen` below is what the state snapshot dump
    // walks; `weak` so a closed/deallocated controller just drops out, no manual bookkeeping needed.
    private static var liveControllers: [WeakEditorWindowController] = []

    /// T-610: every constructed, still-alive editor window controller — for the state snapshot dump.
    static var allOpen: [EditorWindowController] { liveControllers.compactMap(\.value) }

    private init(packageURL: URL, project: Project, events: EventLog, orderFront: Bool = true,
                 loadingWindow: NSWindow? = nil, paths: (CursorPath, CameraPath)? = nil, compositor: Compositor? = nil) {
        let model = EditorModel(packageURL: packageURL, project: project, events: events, paths: paths)
        let preview = PreviewView(model: model, preparedCompositor: compositor)
        let transport = NSHostingView(rootView: TransportBar(model: model, preview: preview))
        let inspector = NSHostingView(rootView: InspectorView(model: model))

        // T-601: the mask-rect overlay (SPEC §6.6), mounted per `MaskRectOverlay`'s own documented
        // hook — a subview of `preview` covering its whole image area, forwarded mouse events
        // through `preview`'s single dispatch point (same as the T-415 zoom-target overlay and the
        // camera-bubble drag; selection is exclusive to one lane, so only one overlay is ever live).
        let maskOverlay = MaskRectOverlay(model: model)
        preview.maskOverlayView = maskOverlay.view
        preview.onResize = { [weak maskOverlay] size in maskOverlay?.layout(in: size) }
        maskOverlay.layout(in: preview.bounds.size)

        // SPEC §7.1: a 32 pt toolbar (Fit + zoom slider, T-405) sits above the timeline itself.
        let timelineView = TimelineView(frame: .zero)
        timelineView.model = model
        // AC-TL-7: split-mode hover shows that (paused) frame in the preview without moving the
        // playhead — `hoverTime`'s own doc comment names this exact one-line hook.
        timelineView.onHoverTime = { [weak preview] in preview?.hoverTime = $0 }
        let toolbar = TimelineToolbar(frame: .zero)
        toolbar.timelineView = timelineView
        let timeline = TimelineContainerView(toolbar: toolbar, timeline: timelineView)

        self.model = model
        self.previewView = preview
        self.maskOverlay = maskOverlay
        self.inspectorView = inspector
        self.timelineView = timeline
        self.inspectorHostingView = inspector
        self.coreTimelineView = timelineView
        self.rootView = EditorRootView(topBar: NSView(), navigation: NSHostingView(rootView: EditorCompositionNavigation(model: model)), preview: preview, transport: transport, inspector: inspector, timeline: timeline)

        let window = loadingWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1100, height: 700)
        window.title = project.title
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)

        configureFullSizeTitlebar(window)
        // `rootView.topBar` (not a same-class relay property): building the real bar needs `self` as
        // the buttons' target, which two-phase init forbids any earlier than this — and property
        // observers on `self`'s OWN properties never fire from inside `self`'s own initializer, only
        // from outside it, so assigning a relay property here silently would not have swapped
        // anything in (T-307 fix's second bug, found the same way as the first: a diagnostic tint
        // that never appeared on screen).
        rootView.topBar = buildTopBar()

        window.delegate = self
        if orderFront {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(preview)
        }
        Self.liveControllers.append(WeakEditorWindowController(value: self))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens (or focuses, if already open) the editor for `package`. Dev/HUMAN entry point:
    /// `Recorder --open <package>`; `RecordingController.finish`/the library call this too.
    @discardableResult
    static func open(package: URL) -> Task<EditorWindowController?, Never> {
        let key = package.standardizedFileURL
        if let existing = openWindows[key] {
            existing.focus()
            return Task { existing }
        }
        if let opening = openingWindows[key] {
            opening.window?.deminiaturize(nil)
            opening.window?.makeKeyAndOrderFront(nil)
            return opening.task!
        }
        let opening = OpeningEditor(package: key)
        openingWindows[key] = opening
        opening.onClose = { openingWindows.removeValue(forKey: key) }
        opening.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Disk access, JSON decoding and 240 Hz motion simulation never run on the UI thread.
        let preparation = Task.detached(priority: .userInitiated) {
            let project = try Project.load(from: key.appendingPathComponent("project.json"))
            try Task.checkCancellation()
            let eventsURL = key.appendingPathComponent("events.json")
            let events = (try? JSONDecoder().decode(EventLog.self, from: Data(contentsOf: eventsURL))) ?? EventLog()
            try Task.checkCancellation()
            let paths = EditorModel.buildPaths(project: project, events: events)
            try Task.checkCancellation()
            guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
            let compositor = try Compositor(device: device, package: key)
            try Task.checkCancellation()
            return (project, events, paths, compositor)
        }
        opening.task = Task { @MainActor [weak opening] in
            do {
                let (project, events, paths, compositor) = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                guard let opening, let window = opening.window else { return nil }
                let controller = EditorWindowController(packageURL: key, project: project, events: events,
                                                        orderFront: false, loadingWindow: window, paths: paths, compositor: compositor)
                openWindows[key] = controller
                openingWindows.removeValue(forKey: key)
                // Keep the same native window and its position; don't steal focus after loading.
                if window.isKeyWindow { window.makeFirstResponder(controller.previewView) }
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    controller.rootView.alphaValue = 0
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = Theme.Motion.hover
                        controller.rootView.animator().alphaValue = 1
                    }, completionHandler: nil)
                }
                return controller
            } catch is CancellationError {
                return nil
            } catch {
                opening?.showError(error)
                return nil
            }
        }
        return opening.task!
    }

    private func focus() {
        // Activation-policy changes after Stop settle on the next run-loop turn.
        DispatchQueue.main.async { [self] in
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(previewView)
        }
    }

    /// Flushes every open editor's pending autosave (SPEC §5: "also on window close and
    /// applicationWillTerminate" — `AppDelegate.applicationWillTerminate` calls this).
    static func saveAllNow() {
        for controller in openWindows.values { controller.model.saveNow() }
    }

    /// `--selftest editor-png`: the same window `open(package:)` builds, without ordering it front or
    /// registering it in `openWindows` — just its window, for an offscreen `cacheDisplay` capture.
    static func makeOffscreen(package: URL) -> NSWindow? {
        guard let project = try? Project.load(from: package.appendingPathComponent("project.json")) else { return nil }
        let eventsURL = package.appendingPathComponent("events.json")
        let events = (try? JSONDecoder().decode(EventLog.self, from: Data(contentsOf: eventsURL))) ?? EventLog()
        return EditorWindowController(packageURL: package, project: project, events: events, orderFront: false).window
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
        Self.openWindows.removeValue(forKey: model.packageURL)
    }

    // MARK: - Document bar (Projects, title, save status, Export)

    /// T-307 fix (coordinator report: the titlebar rendered completely empty, live and offscreen
    /// alike): `NSTitlebarAccessoryViewController` with `.layoutAttribute = .right` never reliably
    /// sized a wide, multi-control bar in this environment — its accessory view stayed effectively
    /// invisible however its own constraints were built (confirmed with a diagnostic background tint
    /// that never showed up in a live screenshot either). Root-caused by dropping that API entirely:
    /// `window` opts into `.fullSizeContentView` so `EditorRootView`'s own content extends under the
    /// native titlebar strip, and this bar is just one more manually-positioned subview of
    /// `EditorRootView` (`EditorRootView.layout()` reserves `topBarHeight` at the top for it) — the
    /// same plain frame-layout approach already used for preview/inspector/timeline, not a separate
    /// AppKit subsystem with its own timing rules.
    private func configureFullSizeTitlebar(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }

    private func buildTopBar() -> NSView {
        let stack = buildTopBarStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        let bar = EditorTitleBar()
        TechAppKit.styleSurface(bar)
        bar.addSubview(stack)
        let rule = TechAppKit.rule()
        rule.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rule)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 88),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        return bar
    }

    private func buildTopBarStack() -> NSStackView {
        let back = TechAppKit.button("‹ Projects", kind: .quiet, compact: true,
                                     target: self, action: #selector(backTapped))
        let separator = TechAppKit.rule()
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // Root cause of the top bar showing no title (T-506/T-609 investigation): `NSTextField`
        // only computes a real `intrinsicContentSize` while `isEditable == false` — an editable field
        // (what `NSTextField(string:)` returns) reports `NSView.noIntrinsicMetric` (-1) for width
        // until it actually becomes the window's field editor, so the top bar's `NSStackView` reads
        // "no natural width" and collapses it to ~0 pt; the text was always there, just laid out at
        // near-zero width. Fix: `TitleField` starts non-editable (a real label, sizes correctly,
        // matches SPEC §6.1's static look) and only flips `isEditable` on for the click-to-rename
        // gesture, flipping back off once editing ends (`titleCommitted`).
        let title = TitleField(string: model.project.title)
        title.isBordered = false
        title.drawsBackground = false
        title.font = Theme.headingFont(16)
        title.textColor = Theme.textPrimary
        title.isEditable = false
        title.target = self
        title.action = #selector(titleCommitted(_:))
        titleField = title

        // T-506: wired directly to `self` since it's this window's
        // own control; the Export menu's items reach the same `exportTapped(_:)` through the
        // responder chain instead (`target = nil`, `AppDelegate.buildMainMenu`).
        let export = TechAppKit.button("⬆ Export", kind: .primary,
                                       target: self, action: #selector(exportTapped(_:)))
        export.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        export.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let status = TechAppKit.button(model.saveStatus, kind: .quiet, compact: true,
                                       target: self, action: #selector(saveDocument(_:)))
        status.font = Theme.captionFont
        saveStatusButton = status
        observeDocumentHeader()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [back, separator, title, spacer, status, export])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        return stack
    }

    private func observeDocumentHeader() {
        withObservationTracking {
            let title = model.project.title
            if !titleField.isEditable { titleField.stringValue = title }
            window?.title = title
            saveStatusButton.title = model.saveStatus
            saveStatusButton.contentTintColor = model.saveError == nil ? Theme.textSecondary : .systemRed
            saveStatusButton.toolTip = model.saveError ?? "Changes save automatically. Click to save now."
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeDocumentHeader() }
        }
    }

    @objc private func titleCommitted(_ sender: NSTextField) {
        defer { sender.isEditable = false }
        let newTitle = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { sender.stringValue = model.project.title; return }
        guard newTitle != model.project.title else { return }
        model.edit("rename") { $0.title = newTitle }
        window?.title = newTitle
    }

    @objc func backTapped() {
        if model.isPlaying { previewView.togglePlayPause() }
        model.saveNow()
        window?.orderOut(nil)
        Library.show()
    }

    // Not `private`: also the View ▸ Crop… menu item's action (`buildMainMenu`, `AppDelegate.swift`).
    @objc func cropTapped() {
        guard let window else { return }
        CropSheet.present(for: model, on: window)
    }

    // T-506: also the top bar's `⬆ Export` button's action (`buildTopBarStack`) and the Export ▸
    // Export… ⌘E menu item's action, reached through the responder chain (`target = nil`, so it
    // disables itself with no editor window key — same mechanism as the Edit/View items above).
    @objc func exportTapped(_ sender: Any?) {
        guard let window else { return }
        ExportSheet.present(for: model, on: window)
    }

    /// T-609 wire (Export ▸ Copy Frame as Image ⇧⌘C): composes the CURRENT frame (`model.playhead`)
    /// through the same `makeFrameState`/`Compositor.render` path the preview and exporter both use
    /// (it has no public "current frame image" API to call instead), at the project's own native
    /// (cropped) resolution, and puts the result on the pasteboard as PNG. Decodes with
    /// `AVAssetReader` + sequential `copyNextSampleBuffer()` — the EXPORTER's path (`FrameHold` in
    /// `Render/Exporter.swift`), not the preview's `AVPlayer`/`AVPlayerItemVideoOutput` one: opening
    /// an `AVPlayer` on the SAME `screen.mov` a `PreviewView` already has open competes with its own
    /// decode session for hardware-decoder resources (harmless with one editor window, but the
    /// `menu-actions` selftest opens one, edits it a dozen times — each `model.edit` retriggers
    /// `PreviewView.rebuildComposition()`, T-306, out of this task's file set — and stacking that many
    /// concurrent `AVPlayerItem`s against a second one starved it for minutes). The reader path is
    /// self-contained (no shared player, no completion handler to wait on) and pixel-identical to
    /// export as a bonus. `pasteboard` defaults to `.general`; the `menu-actions` selftest injects a
    /// private one so it never touches the user's real clipboard.
    @objc func copyFrameAsImage(_ sender: Any?) {
        Task { @MainActor in await copyFrameAsImage(to: .general) }
    }

    /// Awaitable core of the action above, factored out so the `menu-actions` selftest can `await` it
    /// directly (with an injected, throwaway `NSPasteboard`) instead of racing a fire-and-forget `Task`.
    @MainActor func copyFrameAsImage(to pasteboard: NSPasteboard) async {
        do {
            let png = try await Self.renderCurrentFramePNG(model: model)
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        } catch {
            NSLog("Copy Frame as Image failed: \(error)")
        }
    }

    @MainActor static func renderCurrentFramePNG(model: EditorModel) async throws -> Data {
        struct RenderFail: Error, CustomStringConvertible { let description: String }
        let project = model.project
        let packageURL = model.packageURL
        let outputTime = model.playhead

        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFail(description: "no Metal device") }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)

        // "Project's output size" = the native cropped resolution (no export quality preset is
        // involved here) — the same `croppedSource` maths `Compositor.outputSize` uses internally.
        let croppedW = Double(project.source.pixelWidth) * project.crop.w
        let croppedH = Double(project.source.pixelHeight) * project.crop.h
        let longEdge = max(2, Int(max(croppedW, croppedH).rounded()))
        let outputSize = compositor.outputSize(for: project, longEdge: longEdge)
        let width = Int(outputSize.width), height = Int(outputSize.height)

        let (composition, _, _, _) = try await makeComposition(package: packageURL, project: project)
        guard let screenTrack = composition.tracks(withMediaType: .video).first else {
            throw RenderFail(description: "no video track")
        }
        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw RenderFail(description: "reader failed to start: \(String(describing: reader.error))")
        }

        // Sequential decode up to `outputTime` (`AVAssetReader` has no random access) — the same
        // "hold the last sample at/before the target, peek one ahead" scan `FrameHold` in
        // `Render/Exporter.swift` uses for the export loop.
        var current: CVPixelBuffer?
        while let sample = readerOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts <= outputTime else { break }
            current = CMSampleBufferGetImageBuffer(sample)
        }
        let screenTexture = current.flatMap { textureCache.texture(from: $0) }

        let state = makeFrameState(model: model, outputTime: outputTime, screen: screenTexture, camera: nil, size: outputSize)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
            throw RenderFail(description: "failed to set up Metal resources")
        }
        compositor.render(state, to: target, commandBuffer: commandBuffer)
        try await commandBuffer.commitAndWait()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // BGRA8 bytes (as rendered by `Compositor`) -> PNG, same layout `Exporter.gifFrame` uses.
        let colorSpace = VideoColor.space
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderFail(description: "CGImage creation failed")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderFail(description: "PNG destination creation failed")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderFail(description: "PNG encode failed") }
        return data as Data
    }

    // MARK: - Menu actions (T-311)

    // `AppDelegate.buildMainMenu` builds the File/Edit/View items below with `target = nil`; AppKit
    // walks the key window's responder chain (first responder → superviews → window → the window's
    // controller, i.e. an instance of this class, since `NSWindowController` is auto-inserted into
    // the chain there) to find an object implementing the selector. With no editor window key, none
    // of these are found and the items disable themselves automatically — no manager object needed.
    // `validateMenuItem` below adds the few conditions that need more than "does a responder exist".

    @objc func saveDocument(_ sender: Any?) { model.saveNow() }

    /// File ▸ Save As…: flushes pending edits, copies the package to a user-chosen location (giving
    /// the copy a fresh id/title so it isn't confused with the original), then opens the copy —
    /// this window keeps editing the original.
    @objc func saveDocumentAs(_ sender: Any?) {
        model.saveNow()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.project.title
        panel.allowedContentTypes = [UTType(exportedAs: "sh.nexo.recorder.project")]
        panel.directoryURL = model.packageURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: model.packageURL, to: url)
            let projectURL = url.appendingPathComponent("project.json")
            var copy = try Project.load(from: projectURL)
            copy.id = UUID().uuidString
            copy.title = url.deletingPathExtension().lastPathComponent
            try copy.save(to: projectURL)
            EditorWindowController.open(package: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// File ▸ Show Raw Files: a Finder window rooted AT the package directory (not just selecting
    /// the `.recorder` bundle in its parent, which Finder would still show as one opaque package).
    @objc func showRawFiles(_ sender: Any?) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.packageURL.path)
    }

    @objc func performUndo(_ sender: Any?) { model.undo() }
    @objc func performRedo(_ sender: Any?) { model.redo() }

    @objc func cut(_ sender: Any?) { coreTimelineView.cut(sender) }
    @objc func copy(_ sender: Any?) { coreTimelineView.copy(sender) }
    @objc func paste(_ sender: Any?) { coreTimelineView.paste(sender) }

    @objc func splitAtPlayhead(_ sender: Any?) {
        coreTimelineView.menuSplitAtPlayhead()
    }

    /// `⌫`: the selected clip, or every selected zoom/layout/mask block. Mirrors
    /// `TimelineView.removeSelection` (private there — this file can't call it, see T-311's file
    /// boundary — so the same few lines are reimplemented here for the menu/responder-chain path).
    @objc func removeSelected(_ sender: Any?) {
        if !model.selectedClips.isEmpty {
            let indices = model.selectedClips
            model.edit("Remove Clips") { $0.deleteClips(indices) }
            model.selectedClip = nil
        } else if !model.selection.isEmpty {
            let ids = model.selection
            model.edit("Remove") { project in for id in ids { project.removeBlock(id) } }
            model.selection = []
        }
    }

    /// `Z`: adds and selects a zoom at the playhead’s source time.
    @objc func addZoomAtPlayhead(_ sender: Any?) {
        let s = model.timeMap.sourceTime(atOutput: model.playhead)
        model.addZoom(atSource: s)
    }

    /// T-410 wire: regenerates `project.zooms` from the recording's click events.
    @objc func regenerateAutoZooms(_ sender: Any?) {
        let zooms = generateAutoZooms(clicks: model.events.clicks(), duration: model.project.source.duration)
        model.edit("Regenerate Auto Zooms") { $0.zooms = zooms }
    }

    @objc func removeAllZooms(_ sender: Any?) {
        model.edit("Remove All Zooms") { $0.zooms = [] }
    }

    @objc func restoreAllCuts(_ sender: Any?) {
        model.edit("Restore All Cuts") { $0.restoreAllCuts() }
    }

    /// T-603 wire: splits clips around every `.typing` run (`typingRanges(events:)`) and doubles
    /// their speed (`Project.speedUpTyping`, `RecorderCore/TimelineOps.swift`).
    @objc func speedUpTyping(_ sender: Any?) {
        let ranges = typingRanges(events: model.events.events)
        guard !ranges.isEmpty else { return }
        model.edit("Speed Up Typing") { $0.speedUpTyping(ranges) }
    }

    /// T-604 wire: appends the selected clip's SOURCE range to `cursorHidden`, merged/sorted with
    /// whatever ranges were already hidden.
    @objc func hideCursorInSelectedClip(_ sender: Any?) {
        guard let i = model.selectedClip, model.project.clips.indices.contains(i) else { return }
        let clip = model.project.clips[i]
        let added = TimeRange(start: clip.sourceStart, end: clip.sourceEnd)
        model.edit("Hide Cursor") { $0.cursorHidden = Self.mergedRanges($0.cursorHidden + [added]) }
    }

    private static func mergedRanges(_ ranges: [TimeRange]) -> [TimeRange] {
        var merged: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, r.start <= last.end {
                last.end = max(last.end, r.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// View ▸ 1–6 shares the visible navigation's state without clearing timeline selection.
    @objc func selectInspectorTab(_ sender: NSMenuItem) {
        guard let tab = InspectorView.Tab(rawValue: sender.tag) else { return }
        model.showProjectInspector(tab)
    }

    /// View ▸ Zoom In/Out/Fit: `TimelineView`'s own public zoom API (its ⌘=/⌘- keyDown handling
    /// does the same thing; these are the menu-equivalent path, since `NSMenu.performKeyEquivalent`
    /// is asked before an unhandled key event ever reaches a view's `keyDown`).
    @objc func timelineZoomIn(_ sender: Any?) {
        coreTimelineView.setZoom(sliderValue: coreTimelineView.zoomSliderValue + 0.1)
    }

    @objc func timelineZoomOut(_ sender: Any?) {
        coreTimelineView.setZoom(sliderValue: coreTimelineView.zoomSliderValue - 0.1)
    }

    @objc func timelineFit(_ sender: Any?) {
        coreTimelineView.fit()
    }

    /// Guards the handful of single-letter shortcuts (`C`, `Z`, `⌫`, `1`–`6`) from firing while a
    /// text field (title, crop fields, …) is being edited — every other item here keeps working
    /// normally since it carries a `⌘` modifier. Also: Undo/Redo's title/availability track the
    /// undo stack, and Remove/Hide Cursor need a selection; everything else just needs an editor.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performUndo):
            item.title = model.undoName.map { "Undo \($0)" } ?? "Undo"
            return model.undoName != nil
        case #selector(performRedo):
            item.title = model.redoName.map { "Redo \($0)" } ?? "Redo"
            return model.redoName != nil
        case #selector(cut(_:)), #selector(copy(_:)):
            return !isTextEditing && coreTimelineView.canCopySelection
        case #selector(paste(_:)):
            return !isTextEditing && coreTimelineView.canPasteSelection
        case #selector(splitAtPlayhead), #selector(addZoomAtPlayhead), #selector(selectInspectorTab(_:)):
            return !isTextEditing
        case #selector(removeSelected):
            return !isTextEditing && (model.selectedClip != nil || !model.selection.isEmpty)
        case #selector(hideCursorInSelectedClip):
            return model.selectedClip != nil
        default:
            return true
        }
    }

    private var isTextEditing: Bool { window?.firstResponder is NSText }

    // Editor shortcuts (SPEC §7.3) work wherever focus is (e.g. after an inspector click): a key
    // nobody handled ends up here, the end of the responder chain, and gets offered to the preview
    // (transport) then the timeline (tools). Their own unhandled keys bubble back here, hence the flag.
    private var isRoutingKey = false
    override func keyDown(with event: NSEvent) {
        guard !isRoutingKey else { return super.keyDown(with: event) }
        isRoutingKey = true
        defer { isRoutingKey = false }
        let transportKeys: Set<UInt16> = [49, 123, 124, 115, 119, 38, 40, 37]
        if transportKeys.contains(event.keyCode), window?.firstResponder !== previewView {
            previewView.keyDown(with: event)
        } else if window?.firstResponder !== coreTimelineView {
            coreTimelineView.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Empty titlebar space keeps native dragging and double-click window enlargement.
private final class EditorTitleBar: NSView {
    override func layout() {
        super.layout()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(kind), let parent = button.superview else { continue }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: parent)
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: center.y - button.frame.height / 2))
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSControl ? hit : (hit == nil ? nil : self)
    }
}

/// Delay rename until a second click can no longer turn the gesture into window enlargement.
private final class TitleField: NSTextField {
    private var pendingRename: DispatchWorkItem?
    override func mouseDown(with event: NSEvent) {
        pendingRename?.cancel()
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        guard !isEditable else { super.mouseDown(with: event); return }
        let rename = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isEditable = true
            self.window?.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
        pendingRename = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: rename)
    }
}

/// SPEC §7.1: the timeline's 32 pt toolbar row sits above the ruler/lanes. Manual layout (like
/// `EditorRootView`) — the toolbar never resizes, the timeline fills the rest.
final class TimelineContainerView: NSView {
    static let toolbarHeight: CGFloat = 32

    let toolbar: TimelineToolbar
    let timeline: TimelineView

    init(toolbar: TimelineToolbar, timeline: TimelineView) {
        self.toolbar = toolbar
        self.timeline = timeline
        super.init(frame: .zero)
        addSubview(toolbar)
        addSubview(timeline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let toolbarHeight = min(Self.toolbarHeight, bounds.height)
        toolbar.frame = NSRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        timeline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
    }
}

/// Manual workspace layout: a full-height inspector alongside preview, transport and a lane-fitted
/// timeline. The divider enlarges the timeline without moving the inspector.
private final class EditorRootView: NSView {
    static let inspectorWidth: CGFloat = InspectorView.width
    static let topBarHeight: CGFloat = 48
    static let navigationHeight: CGFloat = 36
    static let transportHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 6
    static let timelineRange: ClosedRange<CGFloat> = 160...420

    var topBar: NSView { didSet { swap(oldValue, for: topBar) } }
    let navigation: NSView
    let preview: NSView
    let transport: NSView
    var inspector: NSView { didSet { swap(oldValue, for: inspector) } }
    var timeline: NSView { didSet { swap(oldValue, for: timeline) } }

    private var timelineUpperBound: CGFloat {
        max(Self.timelineRange.lowerBound, min(Self.timelineRange.upperBound,
            bounds.height - Self.topBarHeight - Self.navigationHeight - Self.dividerHeight - 180))
    }
    private var timelineHeight: CGFloat?
    private var fittedTimelineHeight: CGFloat {
        (timeline as? TimelineContainerView).map { $0.timeline.contentHeight + TimelineContainerView.toolbarHeight + 26 } ?? 200
    }
    private var resolvedTimelineHeight: CGFloat { timelineHeight ?? fittedTimelineHeight }
    private var dragStartHeight: CGFloat?
    private var dragStartY: CGFloat?

    init(topBar: NSView, navigation: NSView = NSView(), preview: NSView, transport: NSView, inspector: NSView, timeline: NSView) {
        self.topBar = topBar
        self.navigation = navigation
        self.preview = preview
        self.transport = transport
        self.inspector = inspector
        self.timeline = timeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgWindow.cgColor
        for view in [topBar, navigation, preview, transport, inspector, timeline] { addSubview(view) }
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
        let clampedTimeline = min(max(resolvedTimelineHeight, max(Self.timelineRange.lowerBound, fittedTimelineHeight)), timelineUpperBound)
        let available = max(0, bounds.height - clampedTimeline - Self.dividerHeight)
        let rowHeight = max(0, available - Self.topBarHeight - Self.navigationHeight)
        let previewHeight = max(0, rowHeight - Self.transportHeight)
        let previewWidth = max(0, bounds.width - Self.inspectorWidth)
        let rowY = clampedTimeline + Self.dividerHeight

        topBar.frame = NSRect(x: 0, y: rowY + rowHeight + Self.navigationHeight, width: bounds.width, height: Self.topBarHeight)
        navigation.frame = NSRect(x: 0, y: rowY + rowHeight, width: bounds.width, height: Self.navigationHeight)
        timeline.frame = NSRect(x: 0, y: 0, width: previewWidth, height: clampedTimeline)
        transport.frame = NSRect(x: 0, y: rowY, width: previewWidth, height: Self.transportHeight)
        preview.frame = NSRect(x: 0, y: rowY + Self.transportHeight, width: previewWidth, height: previewHeight)
        inspector.frame = NSRect(x: previewWidth, y: 0, width: Self.inspectorWidth, height: rowHeight + rowY)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let y = min(max(resolvedTimelineHeight, max(Self.timelineRange.lowerBound, fittedTimelineHeight)), timelineUpperBound)
        Theme.strokeStrong.setFill()
        NSRect(x: 0, y: y + Self.dividerHeight / 2, width: max(0, bounds.width - Self.inspectorWidth), height: 1).fill()
    }

    // MARK: - Divider drag (timeline height, 160–420 pt)

    private func dividerHitRange() -> ClosedRange<CGFloat> {
        let clamped = min(max(resolvedTimelineHeight, max(Self.timelineRange.lowerBound, fittedTimelineHeight)), timelineUpperBound)
        return (clamped - 3)...(clamped + Self.dividerHeight + 3)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < bounds.width - Self.inspectorWidth, dividerHitRange().contains(point.y) else { super.mouseDown(with: event); return }
        dragStartHeight = min(max(resolvedTimelineHeight, max(Self.timelineRange.lowerBound, fittedTimelineHeight)), timelineUpperBound)
        dragStartY = point.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartHeight, let dragStartY else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let proposed = dragStartHeight + (point.y - dragStartY)
        timelineHeight = min(max(proposed, max(Self.timelineRange.lowerBound, fittedTimelineHeight)), timelineUpperBound)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartHeight = nil
        dragStartY = nil
    }

    override func resetCursorRects() {
        let range = dividerHitRange()
        addCursorRect(NSRect(x: 0, y: range.lowerBound, width: max(0, bounds.width - Self.inspectorWidth), height: range.upperBound - range.lowerBound), cursor: .resizeUpDown)
    }
}

/// T-610: a weak box so `EditorWindowController.liveControllers` doesn't keep closed windows alive.
private struct WeakEditorWindowController {
    weak var value: EditorWindowController?
}

/// A real editor-sized window exists before any project data is read. It owns cancellation until
/// the ready editor takes over the same window; no placeholder project can ever be autosaved.
@MainActor private final class OpeningEditor: NSWindowController, NSWindowDelegate {
    var task: Task<EditorWindowController?, Never>?
    var onClose: (() -> Void)?
    private let package: URL

    init(package: URL) {
        self.package = package
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1100, height: 700)
        window.isReleasedWhenClosed = false
        window.title = package.deletingPathExtension().lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bgWindow
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        showStatus(error: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        onClose?()
    }

    func showError(_ error: Error) { showStatus(error: error.localizedDescription) }

    private func showStatus(error: String?) {
        let back = NSHostingView(rootView: HStack(spacing: 20) {
            Button("‹ Projects") { [weak self] in self?.close(); Library.show() }
                .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            Text(package.deletingPathExtension().lastPathComponent).font(Font(Theme.headingFont(20)))
                .lineLimit(1)
            Spacer()
            Text(error == nil ? "Opening…" : "Couldn’t open project").font(Font(Theme.captionFont))
                .foregroundStyle(Theme.textSecondaryColor)
        }.padding(.leading, 78).padding(.trailing, 20).frame(maxHeight: .infinity)
            .background(Theme.bgWindowColor).signalWindow())
        let status = NSHostingView(rootView: VStack(spacing: 14) {
            Text(error == nil ? "Loading project" : "Couldn’t open project")
                .font(Font(Theme.headingFont(28)))
            Text(error ?? "Preparing your edit…")
                .font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
                .multilineTextAlignment(.center)
            if error != nil {
                Button("Try again") { [weak self] in
                    guard let self else { return }
                    self.close()
                    EditorWindowController.open(package: self.package)
                }.buttonStyle(TechButtonStyle(kind: .primary))
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgWindowColor).signalWindow())
        func placeholder(_ title: String) -> NSView {
            NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                Text(title).font(Font(Theme.headingFont(24))).foregroundStyle(Theme.textSecondaryColor)
                Rectangle().fill(Theme.strokeColor).frame(height: 1)
                Spacer()
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bgPanelColor).signalWindow())
        }
        window?.contentView = EditorRootView(topBar: back, navigation: NSHostingView(rootView: EditorCompositionNavigation(model: nil)), preview: status,
                                             transport: placeholder(""), inspector: placeholder("Inspector"),
                                             timeline: placeholder("Timeline"))
    }
}
