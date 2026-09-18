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

/// The editor's main window (SPEC §6.1 mockup): a top bar over preview | 300 pt inspector over a
/// timeline, laid out manually (no `NSSplitView`), timeline height draggable 160–420 pt, `window` is
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
    private var aspectPopUp: NSPopUpButton!
    // Typed handles onto the two swappable views above, kept alongside them so the menu actions
    // (T-311) below can reach real API (`InspectorView.init(initialTab:)`, `TimelineView.setZoom`)
    // instead of only the type-erased `NSView` the rest of the window plumbing needs.
    private let inspectorHostingView: NSHostingView<InspectorView>
    // T-610: not `private` — the state snapshot dump (`StateSnapshot.swift`) reads its `geometry`/
    // debug accessors directly instead of duplicating a second way to reach the timeline.
    let coreTimelineView: TimelineView
    /// T-610: which of the 6 inspector tabs `View ▸ 1–6`/`selectInspectorTab` last selected — a
    /// ponytail-scoped stand-in for "the tab actually on screen": SwiftUI's own tab-button clicks
    /// inside `InspectorView` are a private `@State` with no callback out, so a click made without
    /// going through the menu isn't reflected here. Good enough for a debugging snapshot; the
    /// selection panel case (clip/zoom/layout/mask) is computed separately in `StateSnapshot` from
    /// `model.selection`/`selectedClip`, which IS always accurate.
    private(set) var currentInspectorTab: InspectorView.Tab = .background
    // T-601: kept alive here (its own `view` is only weakly referenced by `PreviewView`'s subview
    // list) and re-laid-out on every preview resize (`preview.onResize` below).
    private let maskOverlay: MaskRectOverlay

    private static var openWindows: [URL: EditorWindowController] = [:]
    // T-610: every constructed controller, including ones from `makeOffscreen` (never added to
    // `openWindows` — that dict is only the URL-keyed "focus the existing window instead of
    // duplicating it" dedup for `open(package:)`). `allOpen` below is what the state snapshot dump
    // walks; `weak` so a closed/deallocated controller just drops out, no manual bookkeeping needed.
    private static var liveControllers: [WeakEditorWindowController] = []

    /// T-610: every constructed, still-alive editor window controller — for the state snapshot dump.
    static var allOpen: [EditorWindowController] { liveControllers.compactMap(\.value) }

    private init(packageURL: URL, project: Project, events: EventLog, orderFront: Bool = true) {
        let model = EditorModel(packageURL: packageURL, project: project, events: events)
        let preview = PreviewView(model: model)
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
        self.rootView = EditorRootView(topBar: NSView(), preview: preview, transport: transport, inspector: inspector, timeline: timeline)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
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
        observeAspect()
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

    // MARK: - Top bar (SPEC §6.1: ‹ Projects · title · Auto ▾ · ⌗ Crop · ⬆ Export)

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
        let bar = NSView()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            // 78 pt clears the traffic lights (only floating over our content now that the window
            // is `.fullSizeContentView`), matching the mockup's `● ● ●   ‹ Projects` spacing.
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 78),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func buildTopBarStack() -> NSStackView {
        let back = NSButton(title: "‹ Projects", target: self, action: #selector(backTapped))
        styleAsText(back)

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
        title.font = Theme.bodyFont
        title.textColor = Theme.textPrimary
        title.isEditable = false
        title.target = self
        title.action = #selector(titleCommitted(_:))
        titleField = title

        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.addItems(withTitles: Self.aspectTitles.map(\.1))
        if let index = Self.aspectTitles.firstIndex(where: { $0.0 == model.project.output.aspect }) {
            aspect.selectItem(at: index)
        }
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))
        aspectPopUp = aspect

        let crop = NSButton(title: "⌗ Crop", target: self, action: #selector(cropTapped))
        styleAsText(crop)

        // T-506: wired directly to `self` (like the `⌗ Crop` button above) since it's this window's
        // own control; the Export menu's items reach the same `exportTapped(_:)` through the
        // responder chain instead (`target = nil`, `AppDelegate.buildMainMenu`).
        let export = NSButton(title: "⬆ Export", target: self, action: #selector(exportTapped(_:)))
        styleAsText(export)

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
        defer { sender.isEditable = false }
        let newTitle = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { sender.stringValue = model.project.title; return }
        guard newTitle != model.project.title else { return }
        model.edit("rename") { $0.title = newTitle }
        window?.title = newTitle
    }

    @objc private func backTapped() { Library.show() }

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

        let state = await makeFrameState(model: model, outputTime: outputTime, screen: screenTexture, camera: nil, size: outputSize)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
            throw RenderFail(description: "failed to set up Metal resources")
        }
        compositor.render(state, to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // BGRA8 bytes (as rendered by `Compositor`) -> PNG, same layout `Exporter.gifFrame` uses.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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

    /// T-309: the `Auto ▾` popup edits `project.output.aspect` through `model.edit` (one undo step);
    /// `observeAspect` below keeps the popup's selection in sync when that value changes some other
    /// way (undo/redo).
    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.aspectTitles.indices.contains(index) else { return }
        let aspect = Self.aspectTitles[index].0
        guard aspect != model.project.output.aspect else { return }
        model.edit("Aspect") { $0.output.aspect = aspect }
    }

    private func observeAspect() {
        withObservationTracking {
            _ = model.project.output.aspect
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncAspectPopUp()
                self.observeAspect()
            }
        }
    }

    private func syncAspectPopUp() {
        guard let index = Self.aspectTitles.firstIndex(where: { $0.0 == model.project.output.aspect }) else { return }
        aspectPopUp.selectItem(at: index)
    }

    private static let aspectTitles: [(Output.Aspect, String)] = [
        (.auto, "Auto"), (.r16x9, "16:9"), (.r9x16, "9:16"), (.r1x1, "1:1"), (.r4x3, "4:3"), (.r16x10, "16:10"),
    ]

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

    @objc func splitAtPlayhead(_ sender: Any?) {
        model.edit("Split") { $0.split(atOutput: model.playhead) }
    }

    /// `⌫`: the selected clip, or every selected zoom/layout/mask block. Mirrors
    /// `TimelineView.removeSelection` (private there — this file can't call it, see T-311's file
    /// boundary — so the same few lines are reimplemented here for the menu/responder-chain path).
    @objc func removeSelected(_ sender: Any?) {
        if let i = model.selectedClip {
            model.edit("Remove Clip") { _ = $0.removeClip(i) }
            model.selectedClip = nil
        } else if !model.selection.isEmpty {
            let ids = model.selection
            model.edit("Remove") { project in for id in ids { project.removeBlock(id) } }
            model.selection = []
        }
    }

    /// `Z`: adds a zoom at the playhead's SOURCE time (via `TimeMap`), mode `.auto`.
    @objc func addZoomAtPlayhead(_ sender: Any?) {
        let s = model.timeMap.sourceTime(atOutput: model.playhead)
        model.edit("Add Zoom") { _ = $0.addZoom(atSource: s, mode: .auto) }
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

    /// View ▸ 1–6: reconstructs `InspectorView` with a new `initialTab` (its existing public API,
    /// the same one the `inspector-panels` selftest uses) — `tag` carries `Tab.rawValue`, set when
    /// `AppDelegate.buildMainMenu` builds these items.
    @objc func selectInspectorTab(_ sender: NSMenuItem) {
        guard let tab = InspectorView.Tab(rawValue: sender.tag) else { return }
        inspectorHostingView.rootView = InspectorView(model: model, initialTab: tab)
        currentInspectorTab = tab
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

/// The top bar's project title (SPEC §6.1: "`My Recording ▾` (click = rename)"). A plain
/// `NSTextField` only reports a real `intrinsicContentSize` while non-editable (see the root-cause
/// comment in `EditorWindowController.buildTopBarStack`), so this starts as a label and switches
/// itself into edit mode on click, handing focus to the field editor with the text pre-selected.
private final class TitleField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        guard isEditable else {
            isEditable = true
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }
}

/// SPEC §7.1: the timeline's 32 pt toolbar row sits above the ruler/lanes. Manual layout (like
/// `EditorRootView`) — the toolbar never resizes, the timeline fills the rest.
private final class TimelineContainerView: NSView {
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

/// Manual layout (no `NSSplitView`): a top bar (SPEC §6.1's `‹ Projects … ⬆ Export` row, drawn under
/// the native titlebar — `window` is `.fullSizeContentView`, see `EditorWindowController
/// .configureFullSizeTitlebar`) over preview + transport bar | 300 pt inspector, over the timeline;
/// the divider between them drags the timeline's height (160–420 pt).
private final class EditorRootView: NSView {
    static let inspectorWidth: CGFloat = 300
    static let topBarHeight: CGFloat = 44
    static let transportHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 6
    static let timelineRange: ClosedRange<CGFloat> = 160...420

    var topBar: NSView { didSet { swap(oldValue, for: topBar) } }
    let preview: NSView
    let transport: NSView
    var inspector: NSView { didSet { swap(oldValue, for: inspector) } }
    var timeline: NSView { didSet { swap(oldValue, for: timeline) } }

    private var timelineHeight: CGFloat = 220
    private var dragStartHeight: CGFloat?
    private var dragStartY: CGFloat?

    init(topBar: NSView, preview: NSView, transport: NSView, inspector: NSView, timeline: NSView) {
        self.topBar = topBar
        self.preview = preview
        self.transport = transport
        self.inspector = inspector
        self.timeline = timeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgWindow.cgColor
        for view in [topBar, preview, transport, inspector, timeline] { addSubview(view) }
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
        let available = max(0, bounds.height - clampedTimeline - Self.dividerHeight)
        let rowHeight = max(0, available - Self.topBarHeight)
        let previewHeight = max(0, rowHeight - Self.transportHeight)
        let previewWidth = max(0, bounds.width - Self.inspectorWidth)
        let rowY = clampedTimeline + Self.dividerHeight

        topBar.frame = NSRect(x: 0, y: rowY + rowHeight, width: bounds.width, height: Self.topBarHeight)
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

/// T-610: a weak box so `EditorWindowController.liveControllers` doesn't keep closed windows alive.
private struct WeakEditorWindowController {
    weak var value: EditorWindowController?
}
