import AppKit
import AVFoundation
import Observation
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

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

    var outputDuration: Double { editorModel.timeMap.outputDuration }
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
    func startExport(to destination: URL, copyToPasteboardWhenDone: Bool = false) {
        guard !isExporting else { return }
        exportStart = Date()
        phase = .exporting(fraction: 0, frame: 0, total: 0)

        let exporter = Exporter(model: editorModel, settings: settings, destination: destination)
        self.exporter = exporter
        // Exporter's own doc comment: "T-506 hops to the main actor itself if it touches UI state" —
        // `progress` is called on whatever thread the frame just finished on.
        exporter.progress = { [weak self] fraction, frame, total in
            Task { @MainActor in self?.phase = .exporting(fraction: fraction, frame: frame, total: total) }
        }

        Task { [weak self] in
            do {
                try await exporter.run()
                await MainActor.run {
                    guard let self, self.exporter === exporter else { return }
                    self.exporter = nil
                    if copyToPasteboardWhenDone { Self.copyToPasteboard(destination) }
                    self.phase = .done(url: destination, sizeBytes: Self.fileSize(destination))
                }
            } catch {
                await MainActor.run {
                    guard let self, self.exporter === exporter else { return }
                    self.exporter = nil
                    self.phase = .idle
                }
            }
        }
    }

    /// AC-EXP-3: cancel stops within 1 s; `Exporter.run()` itself deletes the partial file.
    func cancel() { exporter?.cancel() }

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

    static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
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

/// Fixed-size sheet window, same chrome recipe as `CropSheetWindow` (hidden title, hosted SwiftUI
/// content, Esc/red-close = end the sheet — except mid-export, where the window just isn't closable:
/// SPEC §6.8 "editing is locked during export" extends to the sheet itself, so there's nothing an
/// early close should discard).
final class ExportSheetWindow: NSWindow {
    let model: ExportSheetModel

    private static let contentSize = NSSize(width: 620, height: 360)

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
            onCopyResult: { url in ExportSheetModel.copyToPasteboard(url) },
            onDone: { [weak self] in self?.end() })
        contentView = NSHostingView(rootView: content)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }

    /// Esc: no-op mid-export (nothing to discard mid-write); otherwise ends the sheet like Crop's Discard.
    override func cancelOperation(_ sender: Any?) { guard !model.isExporting else { return }; end() }

    override func close() {
        guard !model.isExporting else { return }
        if sheetParent != nil { end() } else { super.close() }
    }

    private func end() {
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
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(Font(Theme.titleFont)).foregroundStyle(Theme.textPrimaryColor)

            VStack(alignment: .leading, spacing: 12) {
                row("Format") {
                    Picker("", selection: $model.settings.format) {
                        Text("MP4").tag(ExportSettings.Format.mp4)
                        Text("GIF").tag(ExportSettings.Format.gif)
                    }
                    .pickerStyle(.segmented).frame(width: 160)
                    .onChange(of: model.settings.format) { _, newFormat in
                        let allowed = newFormat == .gif ? [10, 15, 24] : [24, 30, 60]
                        if !allowed.contains(model.settings.fps) { model.settings.fps = allowed.contains(24) ? 24 : allowed[0] }
                    }
                }
                row("Resolution") {
                    Picker("", selection: $model.settings.shortEdge) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                        Text("4K").tag(2160)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                    Text("→ \(model.resolutionText)").foregroundStyle(Theme.textSecondaryColor)
                }
                row("Frame rate") {
                    Picker("", selection: $model.settings.fps) {
                        ForEach(model.settings.format == .gif ? [10, 15, 24] : [24, 30, 60], id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .pickerStyle(.segmented).frame(width: 160)
                    if model.settings.format == .gif { Text("GIF: 10|15|24").foregroundStyle(Theme.textSecondaryColor) }
                }
                row("Quality") {
                    Picker("", selection: $model.settings.quality) {
                        Text("Web").tag(ExportSettings.Quality.web)
                        Text("Social").tag(ExportSettings.Quality.social)
                        Text("High").tag(ExportSettings.Quality.high)
                        Text("Studio").tag(ExportSettings.Quality.studio)
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                }
                row("Codec") {
                    Picker("", selection: $model.settings.codec) {
                        Text("H.264").tag(ExportSettings.Codec.h264)
                        Text("HEVC").tag(ExportSettings.Codec.hevc)
                    }
                    .pickerStyle(.segmented).frame(width: 160)
                    .disabled(model.settings.format == .gif)
                    .opacity(model.settings.format == .gif ? 0.4 : 1)
                    Text("MP4 only").foregroundStyle(Theme.textSecondaryColor)
                }
                if let warning = model.gifDurationWarning {
                    Text(warning).foregroundStyle(Theme.dangerColor).font(Font(Theme.captionFont))
                }
            }
            .font(Font(Theme.bodyFont))
            .foregroundStyle(Theme.textPrimaryColor)
            .disabled(model.isExporting)
            .opacity(model.isExporting ? 0.5 : 1)

            Divider().background(Theme.strokeColor)

            bottomArea
        }
        .padding(24)
        .frame(width: 620, height: 360, alignment: .top)
        .background(Theme.bgPanelColor)
    }

    @ViewBuilder
    private var bottomArea: some View {
        switch model.phase {
        case .idle:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated size  \(model.estimatedSizeText)")
                    Text("Duration \(model.durationText)").foregroundStyle(Theme.textSecondaryColor)
                }
                .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textPrimaryColor)
                Spacer()
                Button("Copy to clipboard", action: onCopyToClipboard).buttonStyle(.bordered)
                Button("Export…", action: onChooseDestination)
                    .buttonStyle(.borderedProminent).tint(Theme.accentColor)
            }
        case let .exporting(fraction, _, _):
            VStack(alignment: .leading, spacing: 8) {
                Text("Exporting…").foregroundStyle(Theme.textPrimaryColor)
                ProgressView(value: fraction).tint(Theme.accentColor)
                HStack {
                    Text(model.progressDetailText).foregroundStyle(Theme.textSecondaryColor).font(Font(Theme.captionFont))
                    Spacer()
                    Button("Cancel") { model.cancel() }.buttonStyle(.bordered).tint(Theme.dangerColor)
                }
            }
        case let .done(url, sizeBytes):
            HStack {
                Label("Exported \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.textPrimaryColor)
                Spacer()
                Button("Show in Finder") { onShowInFinder(url) }.buttonStyle(.bordered)
                Button("Copy") { onCopyResult(url) }.buttonStyle(.bordered)
                Button("Done", action: onDone).buttonStyle(.borderedProminent).tint(Theme.accentColor)
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
        guard let packagePath = args.first else { throw Fail(description: "usage: export-sheet <package>") }
        let editorModel = try loadEditorModel(package: URL(fileURLWithPath: packagePath))

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
            let expectedBytes = Double(expectedBitrate) * editorModel.timeMap.outputDuration / 8
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

        // (d) cancel immediately (before the export Task even starts) deletes the partial file.
        let cancelledModel = ExportSheetModel(editorModel: editorModel, defaults: defaults)
        cancelledModel.settings = ExportSettings(format: .mp4, shortEdge: 720, fps: 30, quality: .high, codec: .h264)
        let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-sheet-cancel-\(UUID().uuidString).mp4")
        cancelledModel.startExport(to: cancelURL)
        cancelledModel.cancel()
        deadline = Date().addingTimeInterval(15)
        while cancelledModel.isExporting {
            if Date() > deadline { throw Fail(description: "cancel never settled") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard !FileManager.default.fileExists(atPath: cancelURL.path) else {
            throw Fail(description: "cancelled export left a partial file at \(cancelURL.path)")
        }
        print("export-sheet cancel OK")
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
        let editorModel = EditorModel(packageURL: tmp, project: project, events: EventLog())
        let suiteName = "recorder-selftest-export-sheet-png-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Fail(description: "no UserDefaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ExportSheetModel(editorModel: editorModel, defaults: defaults)

        let view = ExportSheetView(model: model, onChooseDestination: {}, onCopyToClipboard: {},
                                    onShowInFinder: { _ in }, onCopyResult: { _ in }, onDone: {})
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 360)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
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
