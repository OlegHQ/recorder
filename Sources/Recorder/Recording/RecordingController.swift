import AppKit
import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

/// Turns a chosen `CaptureTarget` into a recorded `.recorder` package (SPEC §4.7–§4.8, §5). The one
/// caller is `SourcePickerOverlay.startRecording(target:)` (also used by `AreaSelectionOverlay.start`);
/// `finish`/`pause`/`resume`/`restart`/`delete` are called by the recording widget
/// (`RecordingWidgetPanel`) and the status-item menu (T-207b).
@MainActor final class RecordingController {
    static let shared = RecordingController()

    enum State { case idle, picking, countdown, recording, paused, finishing }
    // `.picking` isn't reached yet: pickers track their own visibility (T-107/T-108). Kept because the
    // signature is normative.
    private(set) var state: State = .idle

    private var session: CaptureSession?
    private var camera: CameraCapture?
    private var packageURL: URL?
    private var currentTarget: CaptureTarget?
    private var highlightWindow: NSWindow?

    private init() {}

    /// Elapsed output-clock seconds of the current recording, for the status item (SPEC §4.7).
    var elapsed: Double { session?.elapsed ?? 0 }

    /// T-610: read-only for the state snapshot — `currentTarget` itself stays private.
    var currentTargetDescription: String? { currentTarget?.targetDescription }

    /// From the pickers' Start button. Reserve the transition before scheduling asynchronous work.
    func begin(target: CaptureTarget) {
        guard state == .idle else { return }
        // CLAUDE.md / SPEC §4.1: no recording without both TCC grants. The toolbar itself never shows
        // without them (AppDelegate.applicationDidFinishLaunching), so this is a defensive backstop.
        guard Permissions.allGranted else {
            NSLog("Recorder: begin(target:) blocked — Screen Recording/Accessibility not granted")
            return
        }
        state = .countdown
        Task { await start(target: target) }
    }

    /// `isRestart`/`restartCamera`: T-203's `restart()` re-enters here with the countdown and
    /// toolbar-close skipped (no re-prompt, no toolbar to close mid-recording) and its own still-live
    /// `CameraCapture` instance passed through (grabbing `CameraCapture.current` again would miss it —
    /// `ToolbarController` already dropped its reference the first time this ran).
    private func start(target: CaptureTarget, isRestart: Bool = false, restartCamera: CameraCapture? = nil) async {
        let settings = RecordingSettings.shared
        state = .countdown
        // Keep the camera alive while removing every picker/toolbar that could steal countdown keys.
        let camera = isRestart ? restartCamera : CameraCapture.current
        if let cameraID = settings.cameraID, camera?.deviceID != cameraID {
            state = .idle
            SourcePickerOverlay.close()
            let alert = NSAlert()
            alert.messageText = "Camera is not ready"
            alert.informativeText = "Select an available camera and wait for its preview before starting."
            alert.runModal()
            ToolbarController.shared.show()
            return
        }
        if !isRestart { ToolbarController.shared.close() }

        if settings.countdown > 0 && !isRestart {
            let targetRect = SourcePickerOverlay.flip(target.frameInScreenPoints, in: NSScreen.screens[0])
            guard await CountdownOverlay.run(seconds: settings.countdown, over: targetRect) else {
                state = .idle
                ToolbarController.shared.show()
                return
            }
        }

        if let camera { CameraBubblePanel.show(previewLayer: camera.previewLayer) }

        let packageURL = ProjectStore.newProjectURL(in: settings.projectsFolder)

        // Both registered with `FloatingPanel` *before* `CaptureSession` reads the exclusion list below
        // (its `SCContentFilter` is a fixed snapshot, not updated afterward), so neither ever leaks into
        // `screen.mov` (AC-TB-1 applies to every recording-flow surface, including these two). The widget
        // shows here — alongside the highlight, before the capture session even exists — rather than
        // after `session.start()` succeeds, specifically so its window exists in time for that snapshot.
        showHighlight(for: target, settings: settings)
        RecordingWidgetPanel.show()

        do {
            let session = try await CaptureSession(target: target, settings: settings, packageURL: packageURL)
            if let camera {
                session.hasCamera = true
                camera.startWriting(packageURL: packageURL, clock: session)
            }
            try await session.start()
            self.session = session
            self.camera = camera
            self.packageURL = packageURL
            self.currentTarget = target
            state = .recording
            applyDockIconPolicy(hiddenWhileRecording: true)
            if case .window(let window) = target, let pid = window.owningApplication?.processID {
                WindowResizer.focus(pid: pid, windowTitle: window.title, frame: window.frame)
            }
        } catch {
            NSLog("Recorder: capture failed to start: \(error)")
            hideHighlight()
            RecordingWidgetPanel.hide()
            await camera?.stop(cancelled: true)
            CameraBubblePanel.hide()
            try? FileManager.default.removeItem(at: packageURL)
            state = .idle
            NSAlert(error: error).runModal()
            ToolbarController.shared.show()
        }
    }

    /// Stop writers → write `events.json` (inside `CaptureSession.finish`) → build & save `project.json`
    /// → open the editor (SPEC §4.7 "Finish → … → open editor", AC-REC-4). Editor hand-off: see the
    /// marked call site below.
    func finish() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        Task { await finishCapture() }
    }

    private func finishCapture() async {
        defer { if state == .finishing { reset() } }
        guard let session, let packageURL else { return }
        hideHighlight()

        var source: Source
        do {
            source = try await session.finish()
        } catch {
            await camera?.stop(cancelled: false)
            NSAlert(error: error).runModal()
            return // Keep the package available for recovery.
        }
        await camera?.stop(cancelled: false)
        source.hasCamera = camera?.hasRecording == true
        if let error = camera?.error {
            NSAlert(error: error).runModal()
            return // Preserve the package for recovery instead of claiming the camera saved.
        }

        var project = Project(title: packageURL.deletingPathExtension().lastPathComponent,
                               source: source,
                               clips: [Clip(sourceStart: 0, sourceEnd: source.duration)])
        project.camera.corner = CameraBubblePanel.corner
        project.audio.denoise = RecordingSettings.shared.denoise

        if let data = try? Data(contentsOf: packageURL.appendingPathComponent("events.json")),
           let log = try? JSONDecoder().decode(EventLog.self, from: data) {
            project.zooms = generateAutoZooms(clicks: log.clicks(), duration: source.duration)
        }

        do {
            try project.save(to: packageURL.appendingPathComponent("project.json"))
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        reset() // Restore normal activation policy before making the editor key.
        EditorWindowController.open(package: packageURL)
        Task { await writeThumbnail(packageURL: packageURL) }
    }

    func cancel() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        hideHighlight()
        let session = self.session
        let camera = self.camera
        Task {
            await session?.cancel()
            await camera?.stop(cancelled: true)
            self.reset()
        }
    }

    // MARK: - Widget/status-menu operations (SPEC §4.7) — the one implementation of each, shared by
    // `RecordingWidgetPanel` and the status-item menu (T-207b).

    func pause() {
        guard state == .recording else { return }
        session?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
        state = .recording
    }

    /// Discard the current recording and start again with the same target/settings — no countdown
    /// re-prompt (SPEC §4.7). Keeps the camera device open across the restart (see `start(target:)`).
    func restart() {
        guard state == .recording || state == .paused, let target = currentTarget else { return }
        state = .finishing
        hideHighlight()
        let session = self.session
        let camera = self.camera
        Task {
            await camera?.finishWriting(cancelled: true)
            await session?.cancel()
            self.reset()
            await self.start(target: target, isRestart: true, restartCamera: camera)
        }
    }

    /// Confirms via `NSAlert`, then discards exactly like `cancel()` (SPEC §4.7 "Delete asks for
    /// confirmation"). "Keep Recording" is added first — and so is the alert's default button (Return
    /// key, initial focus) — precisely so an accidental Return doesn't discard a recording.
    func delete() {
        guard state == .recording || state == .paused else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Recording")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        cancel()
    }

    private func reset() {
        session = nil
        camera = nil
        packageURL = nil
        currentTarget = nil
        state = .idle
        CameraBubblePanel.hide()
        RecordingWidgetPanel.hide()
        applyDockIconPolicy(hiddenWhileRecording: false)
    }

    /// SPEC §4.2/§4.7 "Hide Recorder dock icon while recording": `.accessory` for the duration of a
    /// recording, `.regular` once it ends — only when the toggle (gear menu) is on.
    // ponytail: `restart()` calls `reset()` then re-enters `start`, so the dock icon can flash back on
    // for the instant in between; not worth extra state to special-case a chain that's already one Task.
    private func applyDockIconPolicy(hiddenWhileRecording: Bool) {
        guard RecordingSettings.shared.hideDockIcon else { return }
        NSApp.setActivationPolicy(hiddenWhileRecording ? .accessory : .regular)
    }

    /// `thumbnail.jpg`, 640 px wide, frame at 1 s (0 for clips shorter than that) — SPEC §5, written once
    /// here; `ProjectStore`/the library only ever read it (T-301).
    private func writeThumbnail(packageURL: URL) async {
        let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 0) // 0 = unconstrained: always exactly 640 px wide
        let time = CMTime(seconds: duration > 1 ? 1 : 0, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [:]) else { return }
        try? data.write(to: packageURL.appendingPathComponent("thumbnail.jpg"))
    }

    // MARK: - Highlight overlay (T-112, SPEC §4.5 "Highlight recorded area during recording")

    private func showHighlight(for target: CaptureTarget, settings: RecordingSettings) {
        guard settings.highlightArea else { return }
        switch target {
        case .display: return // whole display is already fully recorded — nothing to outline
        case .window, .area: break
        }
        let rect = SourcePickerOverlay.flip(target.frameInScreenPoints, in: NSScreen.screens[0])
        let window = HighlightWindow(rect: rect)
        window.orderFrontRegardless()
        highlightWindow = window
    }

    private func hideHighlight() {
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
    }
}

/// Click-through 2 px accent outline, 2 px outside the recorded rect (SPEC §4.5). Not a `FloatingPanel`
/// (those are draggable/key-able); this only needs to sit above the content and be excluded from
/// capture, so it self-registers with `FloatingPanel.allWindowIDs` the same way `AreaSelectionOverlay`'s
/// windows do.
private final class HighlightWindow: NSWindow {
    init(rect: NSRect) {
        let outset = rect.insetBy(dx: -4, dy: -4) // room for a 2 px line sitting 2 px outside `rect`
        super.init(contentRect: outset, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = HighlightOutlineView(frame: NSRect(origin: .zero, size: outset.size))
        FloatingPanel.register(self)
    }

    override var canBecomeKey: Bool { false }
}

private final class HighlightOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        Theme.accent.setStroke()
        path.stroke()
    }
}
