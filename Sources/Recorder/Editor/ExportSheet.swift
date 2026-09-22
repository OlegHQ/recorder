import AppKit
import AVFoundation
import Observation
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// Export sheet (SPEC §6.8 mockup, ⌘E): pickers → live size/duration estimate → `Export…` (NSSavePanel)
/// or `Copy to clipboard` (temp file + `NSPasteboard`) → Exporting (progress, Cancel) → Done (Show in
/// Finder, Copy, Done). Reuses `Exporter`/`ExportSettings` (T-505/T-507) as-is — this file only adds the
/// UI and the settings' `UserDefaults` persistence.
///
/// ONE entry point: the not-yet-merged editor window's Export button / ⌘E calls `ExportSheet.present(for:on:)`
/// — that's the whole integration surface for T-506, same pattern as `CropSheet.present(for:on:)`.
enum ExportSheet {
    @MainActor
    static func present(for model: EditorModel, on window: NSWindow) {
        let sheet = ExportSheetWindow(model: ExportSheetModel(editorModel: model))
        window.beginSheet(sheet) { _ in }
        sheet.monitorOutsideClicks()
    }
}

// MARK: - Model

/// The sheet's state machine, factored out of the window so it can be driven directly by tests
/// (`CropSheet.confirm`'s pattern) without a real window or NSSavePanel.
@MainActor @Observable final class ExportSheetModel {
    enum Phase: Equatable {
        case idle
        case exporting(fraction: Double, frame: Int, total: Int)
        case done(url: URL, sizeBytes: Int64)
    }

    let editorModel: EditorModel
    private let defaults: UserDefaults

    var settings: ExportSettings { didSet { settings.persist(to: defaults) } }
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    private(set) var copyStatus: String?
    private(set) var isCancelling = false

    private var exporter: Exporter?
    private var exportStart: Date?

    /// True only while an export is actually running. The coordinator could gate editing on this,
    /// but doesn't need to: the sheet is presented document-modal (`window.beginSheet`, the same
    /// mechanism `CropSheet` uses), which already blocks the editor window for the whole
    /// Idle → Exporting → Done flow — SPEC §6.8's "editing is locked during export" — so nothing
    /// currently reads this outside tests.
    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    init(editorModel: EditorModel, defaults: UserDefaults = .standard) {
        self.editorModel = editorModel
        self.defaults = defaults
        self.settings = ExportSettings.loadDefault(from: defaults)
    }

    var outputDuration: Double { editorModel.project.exportDuration }
    var canExport: Bool { outputDuration > 0 }
    var durationText: String { Self.mmss(outputDuration) }

    /// SPEC §6.8: "Estimated size ~48 MB" = `bitrate × duration / 8`, the exact `Exporter.bitrate`
    /// formula the exporter itself uses to set the writer's bit rate — one shared function, not a
    /// second copy of the Mbps table. GIF has no codec bit rate to estimate from (ImageIO picks its
    /// own per-frame palette), so it just says so rather than faking a number SPEC never defines.
    var estimatedSizeText: String {
        guard settings.format == .mp4 else { return "Varies with content" }
        let size = ExportSettings.outputSize(project: editorModel.project, shortEdge: settings.shortEdge)
        let bitrate = Exporter.bitrate(quality: settings.quality, codec: settings.codec,
                                        width: Int(size.width), height: Int(size.height), fps: settings.fps)
        let bytes = Double(bitrate) * outputDuration / 8
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var resolutionText: String {
        let size = ExportSettings.outputSize(project: editorModel.project, shortEdge: settings.shortEdge)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// SPEC §6.8: "Warn (non-blocking) if duration > 60 s" for GIF — the exporter itself only prints
    /// this (headless selftests have no UI); the sheet also shows it so a HUMAN sees it before export.
    var gifDurationWarning: String? {
        guard settings.format == .gif, outputDuration > 60 else { return nil }
        return "GIF is \(durationText) — long GIFs get very large."
    }

    func defaultFileName() -> String {
        let title = editorModel.project.title.replacingOccurrences(of: "/", with: "-")
        return "\(title).\(settings.format == .gif ? "gif" : "mp4")"
    }

    /// The exact call the sheet's `Export…` and `Copy to clipboard` buttons make — driven directly
    /// by the `export-sheet` selftest, no window/NSSavePanel required.
    func startExport(to destination: URL, copyToPasteboardWhenDone: Bool = false, pasteboard: NSPasteboard = .general) {
        guard !isExporting else { return }
        guard canExport else { errorMessage = "No media to export."; return }
        errorMessage = nil
        isCancelling = false
        copyStatus = nil
        exportStart = Date()
        phase = .exporting(fraction: 0, frame: 0, total: 0)

        let exporter = Exporter(model: editorModel, settings: settings, destination: destination)
        self.exporter = exporter
        // Exporter's own doc comment: "T-506 hops to the main actor itself if it touches UI state" —
        // `progress` is called on whatever thread the frame just finished on.
        exporter.progress = { [weak self, weak exporter] fraction, frame, total in
            Task { @MainActor in
                guard let self, let exporter, self.exporter === exporter, self.isExporting else { return }
                self.phase = .exporting(fraction: fraction, frame: frame, total: total)
            }
        }

        Task { [weak self] in
            do {
                try await exporter.run()
                await MainActor.run {
                    guard let self, self.exporter === exporter else { return }
                    self.exporter = nil
                    self.isCancelling = false
                    if copyToPasteboardWhenDone { self.copyResult(destination, pasteboard: pasteboard) }
                    self.phase = .done(url: destination, sizeBytes: Self.fileSize(destination))
                }
            } catch {
                await MainActor.run {
                    guard let self, self.exporter === exporter else { return }
                    self.exporter = nil
                    self.isCancelling = false
                    if case Exporter.ExportError.cancelled = error { self.errorMessage = nil }
                    else if let error = error as? Exporter.ExportError {
                        self.errorMessage = error.description
                    } else { self.errorMessage = error.localizedDescription }
                    self.phase = .idle
                }
            }
        }
    }

    /// AC-EXP-3: cancel stops within 1 s; `Exporter.run()` itself deletes the partial file.
    func cancel() {
        guard isExporting, !isCancelling else { return }
        isCancelling = true
        exporter?.cancel()
    }

    func backToIdle() { phase = .idle }

    /// Progress row text: "58%  ·  412 / 5580 frames  ·  ~00:21 left".
    var progressDetailText: String {
        guard case let .exporting(fraction, frame, total) = phase else { return "" }
        let percent = Int((fraction * 100).rounded())
        var remaining = ""
        if let exportStart, frame > 0 {
            let elapsed = Date().timeIntervalSince(exportStart)
            let rate = Double(frame) / elapsed
            if rate > 0 { remaining = "  ·  ~\(Self.mmss(Double(total - frame) / rate)) left" }
        }
        return "\(percent)%  ·  \(frame) / \(total) frames\(remaining)"
    }

    func copyResult(_ url: URL, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        copyStatus = pasteboard.writeObjects([url as NSURL])
            ? "File copied — ready to paste."
            : "Couldn’t copy the file. Try again or use Show in Finder."
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private static func mmss(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension ExportSettings {
    private static let defaultsKey = "export.settings"

    /// `ExportSettings` is already `Codable` (T-505) — persisted as one JSON blob under one key
    /// rather than a field per `UserDefaults` key (`RecordingSettings`'s pattern), since nothing
    /// else needs to read individual fields. `defaults` is injectable so tests use a throwaway suite.
    static func loadDefault(from defaults: UserDefaults = .standard) -> ExportSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ExportSettings.self, from: data) else {
            return ExportSettings()
        }
        return decoded
    }

    func persist(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// SPEC §6.8: "preset = short edge; keeps output aspect" → the actual output pixel size, so the
    /// sheet can show "→ 1920 × 1080" and feed `Exporter.bitrate`. Metal-free (unlike
    /// `Compositor.outputSize(for:longEdge:)`) so the sheet can compute it live with no device/package
    /// — same maths `Exporter.run()` uses to turn "short edge" into `RecorderCore.outputSize`'s
    /// "long edge": get the aspect first from a throwaway large long edge, then derive the real one.
    static func outputSize(project: Project, shortEdge: Int) -> CGSize {
        let croppedSource = CGSize(width: Double(project.source.pixelWidth) * project.crop.w,
                                    height: Double(project.source.pixelHeight) * project.crop.h)
        let unit = RecorderCore.outputSize(aspect: project.output.aspect, croppedSource: croppedSource, longEdge: 1_000_000)
        let ratio = unit.height > 0 ? unit.width / unit.height : 1
        let longEdge = ratio >= 1 ? (Double(shortEdge) * ratio).rounded() : (Double(shortEdge) / ratio).rounded()
        return RecorderCore.outputSize(aspect: project.output.aspect, croppedSource: croppedSource, longEdge: Int(longEdge))
    }
}

// MARK: - Window

/// Fixed-size sheet window, same chrome recipe as `CropSheetWindow`: hidden title, hosted SwiftUI
/// content. Escape cancels an active export; otherwise Escape/Cancel dismisses the sheet.
final class ExportSheetWindow: NSWindow {
    let model: ExportSheetModel
    private var outsideClickMonitor: Any?

    private static let contentSize = NSSize(width: 620, height: 440)

    init(model: ExportSheetModel) {
        self.model = model
        let size = Self.contentSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = Theme.bgPanel

        let content = ExportSheetView(
            model: model,
            onChooseDestination: { [weak self] in self?.chooseDestinationAndExport() },
            onCopyToClipboard: { [weak self] in self?.copyToClipboard() },
            onShowInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            onCopyResult: { url in model.copyResult(url) },
            onDone: { [weak self] in self?.end() })
        contentView = NSHostingView(rootView: content)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if model.isExporting { model.cancel() } else { end() }
    }

    func monitorOutsideClicks() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let parent = self.sheetParent, event.window === parent,
                  self.attachedSheet == nil, !self.model.isExporting else { return event }
            self.end()
            return nil // Dismiss without activating an editor control underneath.
        }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    override func close() {
        guard !model.isExporting else { model.cancel(); return }
        if sheetParent != nil { end() } else { super.close() }
    }

    private func end() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let parent = sheetParent { parent.endSheet(self) } else { orderOut(nil) }
    }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.defaultFileName()
        panel.allowedContentTypes = [model.settings.format == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.startExport(to: url)
        }
    }

    private func copyToClipboard() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(model.defaultFileName())")
        model.startExport(to: destination, copyToPasteboardWhenDone: true)
    }
}

// MARK: - Content (SPEC §6.8 mockup)

// Internal, not `private`, so the `export-sheet-png` selftest can render it offscreen directly
// (`InspectorView`'s pattern) without going through a real `ExportSheetWindow`/NSSavePanel.
struct ExportSheetView: View {
    @Bindable var model: ExportSheetModel
    let onChooseDestination: () -> Void
    let onCopyToClipboard: () -> Void
    let onShowInFinder: (URL) -> Void
    let onCopyResult: (URL) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Export").font(Font(Theme.titleFont)).foregroundStyle(Theme.textPrimaryColor)
                Spacer()
                Text(model.durationText)
                    .font(Font(Theme.timecodeFont(12)))
                    .foregroundStyle(Theme.textTertiaryColor)
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimaryColor).frame(height: 2) }

            if model.phase == .idle {
            VStack(alignment: .leading, spacing: 8) {
                row("Format") {
                    TechSegmentedControl(selection: $model.settings.format,
                                         options: [(.mp4, "MP4"), (.gif, "GIF")])
                        .frame(width: 160)
                    .onChange(of: model.settings.format) { _, newFormat in
                        let allowed = newFormat == .gif ? [10, 15, 24] : [24, 30, 60]
                        if !allowed.contains(model.settings.fps) { model.settings.fps = allowed.contains(24) ? 24 : allowed[0] }
                    }
                }
                row("Resolution") {
                    TechSegmentedControl(selection: $model.settings.shortEdge,
                                         options: [(720, "720p"), (1080, "1080p"), (2160, "4K")])
                        .frame(width: 220)
                    Text("→ \(model.resolutionText)").foregroundStyle(Theme.textSecondaryColor)
                }
                row("Frame rate") {
                    TechSegmentedControl(selection: $model.settings.fps,
                                         options: (model.settings.format == .gif ? [10, 15, 24] : [24, 30, 60])
                                            .map { ($0, "\($0)") })
                        .frame(width: 160)
                    Text("fps").foregroundStyle(Theme.textSecondaryColor)
                }
                if model.settings.format == .mp4 {
                    row("Quality") {
                        TechSegmentedControl(selection: $model.settings.quality, options: [
                            (.web, "Web"), (.social, "Social"), (.high, "High"), (.studio, "Studio"),
                        ]).frame(width: 260)
                    }
                    row("Codec") {
                        TechSegmentedControl(selection: $model.settings.codec,
                                             options: [(.h264, "H.264"), (.hevc, "HEVC")])
                            .frame(width: 160)
                    }
                }
                Text(model.settings.format == .gif ? "Animated image · no audio" : "Video · uses your Sound settings")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                if let warning = model.gifDurationWarning {
                    Text(warning).foregroundStyle(Theme.dangerColor).font(Font(Theme.captionFont))
                }
            }
            .font(Font(Theme.bodyFont))
            .foregroundStyle(Theme.textPrimaryColor)
            } else {
                Text("\(model.resolutionText) · \(model.settings.fps) fps · \(model.durationText)")
                    .font(Font(Theme.timecodeFont(13))).foregroundStyle(Theme.textSecondaryColor)
            }
            if case .done = model.phase { } else { Spacer(minLength: 0) }
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Export failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.dangerColor)
                    Text(error).font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textSecondaryColor).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(error)
                }
            }
            Divider().background(Theme.strokeColor)

            bottomArea
        }
        .padding(24)
        .frame(width: 620, height: 440, alignment: .top)
        .background {
            ZStack { Theme.bgPanelColor; TechGridBackground(step: 40).opacity(0.25) }
        }
        .signalWindow()
    }

    @ViewBuilder
    private var bottomArea: some View {
        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Estimated size  \(model.estimatedSizeText)")
                    Spacer()
                    Text(model.canExport ? "Final size may vary" : "No media to export").foregroundStyle(Theme.textSecondaryColor)
                }
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textPrimaryColor)
                HStack {
                    Button("Cancel", action: onDone)
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Copy to clipboard", action: onCopyToClipboard)
                        .disabled(!model.canExport)
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                    Button("Export…", action: onChooseDestination)
                        .disabled(!model.canExport)
                        .buttonStyle(TechButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        case let .exporting(fraction, _, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(model.isCancelling ? "Cancelling…" : "Exporting…").foregroundStyle(Theme.textPrimaryColor)
                ProgressView(value: fraction).tint(Theme.accentColor)
                HStack {
                    Text(model.progressDetailText).foregroundStyle(Theme.textSecondaryColor).font(Font(Theme.captionFont))
                    Spacer()
                    Button(model.isCancelling ? "Cancelling…" : "Cancel export") { model.cancel() }
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCancelling)
                }
            }
        case let .done(url, sizeBytes):
            VStack(alignment: .leading, spacing: 14) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .font(Font(Theme.headingFont(24))).foregroundStyle(Theme.textPrimaryColor)
                Text(url.lastPathComponent).lineLimit(2).truncationMode(.middle).help(url.path)
                    .foregroundStyle(Theme.textPrimaryColor)
                Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                    .font(Font(Theme.timecodeFont(12))).foregroundStyle(Theme.textSecondaryColor)
                if let status = model.copyStatus {
                    Text(status).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Show in Finder") { onShowInFinder(url) }.buttonStyle(TechButtonStyle(kind: .secondary))
                    Button("Copy file") { onCopyResult(url) }.buttonStyle(TechButtonStyle(kind: .secondary))
                    Spacer()
                    Button("Done", action: onDone).buttonStyle(TechButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(Theme.textSecondaryColor)
            content()
        }
    }
}

// MARK: - Selftests `export-sheet <package>` and `export-sheet-png <out.png>` (T-506)

enum ExportSheetSelfTest {
    private struct Fail: Error, CustomStringConvertible { let description: String }

    /// Model-level, no window/NSSavePanel: (a) `estimatedSizeText` matches the shared `Exporter.bitrate`
    /// formula for a couple of settings, (b) `ExportSettings` round-trips through a throwaway
    /// `UserDefaults` suite, (c) `model.startExport(to:)` — the exact call the sheet's Export/
    /// Copy-to-clipboard buttons make — produces a playable file and its progress reaches 1.0,
    /// (d) cancelling immediately after starting deletes the partial file (AC-EXP-3).
    @MainActor
    static func run(_ args: [String]) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-export-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let editorModel: EditorModel
        if let packagePath = args.first {
            editorModel = try loadEditorModel(package: URL(fileURLWithPath: packagePath))
        } else {
            editorModel = EditorWorkspaceGallery.makeModel(at: scratch)
            try await WorkspaceMedia.prepare(at: scratch)
            editorModel.edit("Short export fixture") { $0.clips = [Clip(sourceStart: 0, sourceEnd: 1)] }
        }
        defer { editorModel.saveNow(); try? FileManager.default.removeItem(at: scratch) }

        let suiteName = "recorder-selftest-export-sheet-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Fail(description: "no UserDefaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // (a) estimatedSizeText == the shared bitrate formula, for two different settings.
        let model = ExportSheetModel(editorModel: editorModel, defaults: defaults)
        let cases: [(ExportSettings.Quality, ExportSettings.Codec, Int, Int)] = [
            (.high, .h264, 1080, 30), (.web, .hevc, 720, 60),
        ]
        for (quality, codec, shortEdge, fps) in cases {
            model.settings.quality = quality
            model.settings.codec = codec
            model.settings.shortEdge = shortEdge
            model.settings.fps = fps
            let size = ExportSettings.outputSize(project: editorModel.project, shortEdge: shortEdge)
            let expectedBitrate = Exporter.bitrate(quality: quality, codec: codec, width: Int(size.width), height: Int(size.height), fps: fps)
            let expectedBytes = Double(expectedBitrate) * editorModel.project.exportDuration / 8
            let expectedText = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
            guard model.estimatedSizeText == expectedText else {
                throw Fail(description: "estimate mismatch: \(model.estimatedSizeText) vs \(expectedText)")
            }
        }
        print("export-sheet estimate OK")

        // (b) settings persist round trip through UserDefaults (a throwaway suite here).
        model.settings.format = .gif
        model.settings.fps = 15
        model.settings.shortEdge = 720
        let reloaded = ExportSettings.loadDefault(from: defaults)
        guard reloaded.format == .gif, reloaded.fps == 15, reloaded.shortEdge == 720 else {
            throw Fail(description: "settings didn't round-trip: format=\(reloaded.format) fps=\(reloaded.fps) shortEdge=\(reloaded.shortEdge)")
        }
        print("export-sheet persistence OK")

        // (c) a real export through `startExport(to:)`, progress reaching 1.0, playable output.
        model.settings = ExportSettings(format: .mp4, shortEdge: 720, fps: 30, quality: .high, codec: .h264)
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-sheet-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }
        model.startExport(to: outURL)
        var maxFraction = 0.0
        var deadline = Date().addingTimeInterval(15)
        while true {
            if case let .exporting(fraction, _, _) = model.phase { maxFraction = max(maxFraction, fraction) }
            if case .done = model.phase { break }
            if Date() > deadline { throw Fail(description: "export-sheet export timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard maxFraction >= 0.999 else { throw Fail(description: "progress never reached 1.0 (max \(maxFraction))") }
        guard FileManager.default.fileExists(atPath: outURL.path) else { throw Fail(description: "no output file at \(outURL.path)") }
        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw Fail(description: "exported file has zero duration") }
        print("export-sheet run OK duration=\(duration)s maxFraction=\(maxFraction)")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        model.copyResult(outURL, pasteboard: pasteboard)
        guard pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [outURL],
              model.copyStatus == "File copied — ready to paste." else {
            throw Fail(description: "file handoff or copy receipt failed")
        }
        print("export-sheet file pasteboard and receipt OK")

        // Exercise the GIF + automatic clipboard branch that crashed in the shipped app.
        let gifURL = scratch.appendingPathComponent("clipboard.gif")
        model.settings = ExportSettings(format: .gif, fps: 15)
        model.startExport(to: gifURL, copyToPasteboardWhenDone: true, pasteboard: pasteboard)
        deadline = Date().addingTimeInterval(30)
        while model.isExporting {
            guard Date() < deadline else { throw Fail(description: "GIF clipboard export timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .done = model.phase,
              pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [gifURL],
              let gif = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              CGImageSourceGetCount(gif) == max(1, Int((editorModel.project.exportDuration * 15).rounded())) else {
            throw Fail(description: "GIF clipboard export failed: \(model.errorMessage ?? "invalid frames or pasteboard")")
        }
        print("export-sheet animated GIF and automatic clipboard handoff OK")

        // (d) cancel immediately (before the export Task even starts) deletes the partial file.
        let cancelledModel = ExportSheetModel(editorModel: editorModel, defaults: defaults)
        cancelledModel.settings = ExportSettings(format: .mp4, shortEdge: 720, fps: 30, quality: .high, codec: .h264)
        let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-sheet-cancel-\(UUID().uuidString).mp4")
        cancelledModel.startExport(to: cancelURL)
        let cancelWindow = ExportSheetWindow(model: cancelledModel)
        cancelWindow.cancelOperation(nil)
        guard cancelledModel.isCancelling else { throw Fail(description: "Escape did not cancel export") }
        deadline = Date().addingTimeInterval(15)
        while cancelledModel.isExporting {
            if Date() > deadline { throw Fail(description: "cancel never settled") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard !FileManager.default.fileExists(atPath: cancelURL.path) else {
            throw Fail(description: "cancelled export left a partial file at \(cancelURL.path)")
        }
        guard cancelledModel.phase == .idle, !cancelledModel.isCancelling, cancelledModel.errorMessage == nil else {
            throw Fail(description: "cancel presented as a failure")
        }
        print("export-sheet cancel OK")
        let retrySettings = cancelledModel.settings
        defer { try? FileManager.default.removeItem(at: cancelURL) }
        cancelledModel.startExport(to: cancelURL)
        deadline = Date().addingTimeInterval(15)
        while cancelledModel.isExporting {
            guard Date() < deadline else { throw Fail(description: "retry did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .done = cancelledModel.phase, cancelledModel.settings.format == retrySettings.format,
              cancelledModel.settings.shortEdge == retrySettings.shortEdge,
              cancelledModel.settings.fps == retrySettings.fps,
              cancelledModel.settings.quality == retrySettings.quality,
              cancelledModel.settings.codec == retrySettings.codec,
              cancelledModel.errorMessage == nil else { throw Fail(description: "retry failed or lost settings") }
        guard try await AVURLAsset(url: cancelURL).load(.duration).seconds > 0 else {
            throw Fail(description: "retry output is not playable")
        }
        print("export-sheet retry OK; settings retained and output playable")

        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        ExportSheet.present(for: editorModel, on: parent)
        try await Task.sleep(for: .milliseconds(250))
        guard parent.attachedSheet is ExportSheetWindow else { throw Fail(description: "export sheet not presented") }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
                                       modifierFlags: [], timestamp: 0, windowNumber: parent.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(click)
        try await Task.sleep(for: .milliseconds(250))
        guard parent.attachedSheet == nil else { throw Fail(description: "outside click did not dismiss export sheet") }
        ExportSheet.present(for: editorModel, on: parent)
        try await Task.sleep(for: .milliseconds(250))
        (parent.attachedSheet as? ExportSheetWindow)?.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard parent.attachedSheet == nil else { throw Fail(description: "Escape did not dismiss idle sheet") }
        print("export-sheet outside click and idle Escape dismissal OK")
    }

    /// Renders `ExportSheetView` offscreen (dark appearance, forced before the hosting view is
    /// created — `inspector-png`'s recipe) to a PNG, for comparison against the SPEC §6.8 mockup
    /// (`Read` tool). Not part of the automated pass/fail contract.
    @MainActor
    static func runPNG(_ args: [String]) async throws {
        guard let outPath = args.first else { throw Fail(description: "usage: export-sheet-png <out.png>") }

        var project = Project(title: "My Recording",
                               source: Source(kind: .display, pixelWidth: 2880, pixelHeight: 1800, scale: 2, duration: 93.4))
        project.clips = [Clip(sourceStart: 0, sourceEnd: 93.4, speed: 1)]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-selftest-export-sheet-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try project.save(to: tmp.appendingPathComponent("project.json"))
        if ["done", "copied"].contains(args.dropFirst().first ?? "") {
            project.source.pixelWidth = 960
            project.source.pixelHeight = 540
            project.clips = [Clip(sourceStart: 0, sourceEnd: 1)]
            try await WorkspaceMedia.prepare(at: tmp)
        }
        let editorModel = EditorModel(packageURL: tmp, project: project, events: EventLog())
        let suiteName = "recorder-selftest-export-sheet-png-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Fail(description: "no UserDefaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ExportSheetModel(editorModel: editorModel, defaults: defaults)

        let variant = args.dropFirst().first
        if variant == "gif" { model.settings.format = .gif; model.settings.fps = 15 }
        if variant == "failure" || variant == "done" || variant == "copied" {
            let destination = tmp.appendingPathComponent("Project walkthrough with a deliberately long descriptive filename for review.mp4")
            model.startExport(to: destination)
            let deadline = Date().addingTimeInterval(20)
            while model.isExporting {
                guard Date() < deadline else { throw Fail(description: "export state did not settle") }
                try await Task.sleep(for: .milliseconds(20))
            }
            if variant == "failure" {
                guard model.phase == .idle, model.errorMessage != nil else { throw Fail(description: "missing visible export failure") }
            } else {
                guard case .done = model.phase, model.errorMessage == nil else { throw Fail(description: "export did not succeed") }
            }
        }

        if variant == "copied", case let .done(url, _) = model.phase {
            let pasteboard = NSPasteboard.withUniqueName()
            model.copyResult(url, pasteboard: pasteboard)
            pasteboard.releaseGlobally()
        }

        let view = ExportSheetView(model: model, onChooseDestination: {}, onCopyToClipboard: {},
                                    onShowInFinder: { _ in }, onCopyResult: { _ in }, onDone: {})
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 440)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw Fail(description: "no bitmap rep")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Fail(description: "png encode failed") }
        try png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
    }
}


extension ExportSheetSelfTest {
    @MainActor static func checkNativeHandoff() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-native-export-" + UUID().uuidString)
        let editor = EditorWorkspaceGallery.makeModel(at: scratch)
        try await WorkspaceMedia.prepare(at: scratch)
        editor.edit("Short export fixture") { $0.clips = [Clip(sourceStart: 0, sourceEnd: 1)] }
        let suiteName = "recorder-native-export-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Fail(description: "defaults unavailable") }
        defer { editor.saveNow(); try? FileManager.default.removeItem(at: scratch); defaults.removePersistentDomain(forName: suiteName) }
        let model = ExportSheetModel(editorModel: editor, defaults: defaults)
        model.settings.shortEdge = 720
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = ExportSheetWindow(model: model)
        sheet.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(sheet) { _ in }
        defer {
            if let panel = sheet.attachedSheet { sheet.endSheet(panel) }
            if parent.attachedSheet != nil { parent.endSheet(sheet) }
            parent.orderOut(nil)
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() {
                guard Date() < deadline else { throw Fail(description: message + "; phase=\(model.phase)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        func pressReturn(in target: NSWindow? = nil) {
            let target = target ?? sheet
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            target.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(400))
        pressReturn()
        try await waitFor("Return did not present Save", { sheet.attachedSheet is NSSavePanel })
        guard let first = sheet.attachedSheet as? NSSavePanel,
              first.allowedContentTypes == [.mpeg4Movie], first.nameFieldStringValue == model.defaultFileName() else {
            throw Fail(description: "Save filename/type did not reflect export settings")
        }
        first.cancel(nil)
        try await waitFor("Save cancellation did not dismiss", { sheet.attachedSheet == nil })
        guard model.phase == .idle, model.settings.shortEdge == 720, model.errorMessage == nil else {
            throw Fail(description: "Save cancellation changed export settings or phase")
        }
        // Native opening/cancellation and an explicit temporary export are separate checks.
        // Never export to an unconfirmed remote dialog URL.
        let destination = scratch.appendingPathComponent("Native handoff.mp4")
        model.startExport(to: destination)
        try await waitFor("Chosen destination did not complete export", { if case .done = model.phase { return true }; return false })
        guard case let .done(url, bytes) = model.phase, url.lastPathComponent == destination.lastPathComponent,
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == scratch.resolvingSymlinksInPath().path, bytes > 0 else {
            throw Fail(description: "Selected destination produced the wrong result: \(model.phase), expected directory \(scratch.path)")
        }
        try await Task.sleep(for: .milliseconds(300))
        pressReturn()
        try await waitFor("Return did not close completion", { parent.attachedSheet == nil })
        print("Native export passed: Return opens Save; cancel retains settings; explicit test destination exports; Return closes completion. System Save confirmation is not simulated.")
    }
}


extension ExportSheetSelfTest {
    @MainActor static func runRange() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-export-range-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await WorkspaceMedia.prepare(at: scratch)
        var gap = Clip(sourceStart: 1, sourceEnd: 3)
        gap.isGap = true
        let project = Project(source: Source(pixelWidth: 960, pixelHeight: 540, duration: 32),
                              clips: [Clip(sourceStart: 0, sourceEnd: 1), gap])
        let editor = EditorModel(packageURL: scratch, project: project, events: EventLog(events: [
            InputEvent(t: 0.5, k: .down, x: 0.5, y: 0.5, b: 0), InputEvent(t: 2.5, k: .down, x: 0.5, y: 0.5, b: 0)]))
        let suite = "recorder-range-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sheet = ExportSheetModel(editorModel: editor, defaults: defaults)
        guard sheet.outputDuration == 1 else { throw Fail(description: "sheet includes trailing gap") }
        editor.edit("Trim") { $0.placeClip(0, start: 0, end: 0.5) }
        guard sheet.outputDuration == 0.5 else { throw Fail(description: "trim did not update range") }
        editor.undo()
        guard sheet.outputDuration == 1 else { throw Fail(description: "undo did not update range") }
        editor.redo()
        guard sheet.outputDuration == 0.5 else { throw Fail(description: "redo did not update range") }
        editor.undo()
        editor.edit("Click audio") { $0.cursor.clickSound = true }
        for camera in [false, true] {
            editor.edit("Camera tail") {
                $0.source.hasCamera = camera
                $0.cameraClips = camera ? [CameraClip(start: 0, end: 1.5)] : []
            }
            let expected = camera ? 1.5 : 1.0
            guard sheet.outputDuration == expected else { throw Fail(description: "camera tail not reflected in sheet") }
            for format in [ExportSettings.Format.mp4, .gif] {
                let out = scratch.appendingPathComponent("range-\(camera).\(format == .mp4 ? "mp4" : "gif")")
                sheet.settings = ExportSettings(format: format, shortEdge: 720, fps: 10, quality: .web, codec: .h264)
                sheet.startExport(to: out)
                let deadline = Date().addingTimeInterval(30)
                while sheet.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                guard case .done = sheet.phase else {
                    sheet.cancel()
                    throw Fail(description: "range export failed: \(sheet.errorMessage ?? "timeout")")
                }
                if format == .mp4 {
                    let asset = AVURLAsset(url: out)
                    let duration = try await asset.load(.duration).seconds
                    guard abs(duration - expected) < 0.11 else { throw Fail(description: "MP4 tail: \(duration), expected \(expected)") }
                    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw Fail(description: "audio clamp was not exercised") }
                } else {
                    guard let image = CGImageSourceCreateWithURL(out as CFURL, nil),
                          CGImageSourceGetCount(image) == Int(expected * 10) else { throw Fail(description: "GIF tail") }
                }
                sheet.backToIdle()
            }
        }
        editor.edit("Delete all media") { $0.cameraClips = []; $0.deleteClips(Set($0.clips.indices)) }
        guard sheet.outputDuration == 0, !sheet.canExport else { throw Fail(description: "empty export enabled") }
        let sentinel = scratch.appendingPathComponent("untouched.mp4")
        let bytes = Data("existing file".utf8)
        try bytes.write(to: sentinel)
        sheet.startExport(to: sentinel)
        guard !sheet.isExporting, sheet.errorMessage == "No media to export." else { throw Fail(description: "empty sheet export started") }
        do {
            try await Exporter(model: editor, settings: sheet.settings, destination: sentinel).run()
            throw Fail(description: "empty exporter succeeded")
        } catch is Exporter.ExportError { }
        guard try Data(contentsOf: sentinel) == bytes else { throw Fail(description: "empty export modified destination") }
        editor.saveNow()
    }
}
