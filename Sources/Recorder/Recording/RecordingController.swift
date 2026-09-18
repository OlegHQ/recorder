import AppKit
import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

/// Turns a chosen `CaptureTarget` into a recorded `.recorder` package (SPEC §4.7–§4.8, §5). The one
/// caller is `SourcePickerOverlay.startRecording(target:)` (also used by `AreaSelectionOverlay.start`);
/// the M1 stop UI (status item, `AppDelegate`) calls `finish`.
@MainActor final class RecordingController {
    static let shared = RecordingController()

    enum State { case idle, picking, countdown, recording, paused, finishing }
    // `.picking`/`.paused` aren't reached yet: pickers track their own visibility (T-107/T-108), and
    // pause/resume UI arrives with the recording widget (T-203). Kept because the signature is normative.
    private(set) var state: State = .idle

    private var session: CaptureSession?
    private var camera: CameraCapture?
    private var packageURL: URL?

    private init() {}

    /// Elapsed output-clock seconds of the current recording, for the status item (SPEC §4.7).
    var elapsed: Double { session?.elapsed ?? 0 }

    /// From the pickers' Start button. Awaits the countdown (Esc there returns to the picker, which is
    /// still showing at that point), then closes the recording-flow UI and starts capture.
    func begin(target: CaptureTarget) {
        guard state == .idle else { return }
        // CLAUDE.md / SPEC §4.1: no recording without both TCC grants. The toolbar itself never shows
        // without them (AppDelegate.applicationDidFinishLaunching), so this is a defensive backstop.
        guard Permissions.allGranted else {
            NSLog("Recorder: begin(target:) blocked — Screen Recording/Accessibility not granted")
            return
        }
        Task { await start(target: target) }
    }

    private func start(target: CaptureTarget) async {
        let settings = RecordingSettings.shared
        state = .countdown

        if settings.countdown > 0 {
            let targetRect = SourcePickerOverlay.flip(target.frameInScreenPoints, in: NSScreen.screens[0])
            guard await CountdownOverlay.run(seconds: settings.countdown, over: targetRect) else {
                state = .idle // Esc: back to the picker (still open, we haven't touched it yet).
                return
            }
        }

        // Grab our own strong reference before `ToolbarController.close()` drops its own (which would
        // otherwise let the AVCaptureSession deallocate) and hides the bubble.
        let camera = CameraCapture.current
        ToolbarController.shared.close()
        if let camera { CameraBubblePanel.show(previewLayer: camera.previewLayer) }

        let name = "Recording \(RecordingController.folderFormatter.string(from: Date()))"
        let packageURL = settings.projectsFolder.appendingPathComponent("\(name).recorder")

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
            state = .recording
        } catch {
            NSLog("Recorder: capture failed to start: \(error)")
            try? FileManager.default.removeItem(at: packageURL)
            state = .idle
        }
    }

    /// Stop writers → write `events.json` (inside `CaptureSession.finish`) → build & save `project.json`
    /// → reveal the package. Editor hand-off: see the marked call site below.
    func finish() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        Task { await finishCapture() }
    }

    private func finishCapture() async {
        defer { reset() }
        guard let session, let packageURL else { return }

        guard let source = try? await session.finish() else {
            await camera?.stop(cancelled: true)
            try? FileManager.default.removeItem(at: packageURL)
            return
        }
        await camera?.stop(cancelled: false)

        var project = Project(title: packageURL.deletingPathExtension().lastPathComponent,
                               source: source,
                               clips: [Clip(sourceStart: 0, sourceEnd: source.duration)])
        project.camera.corner = CameraBubblePanel.corner

        if let data = try? Data(contentsOf: packageURL.appendingPathComponent("events.json")),
           let log = try? JSONDecoder().decode(EventLog.self, from: data) {
            project.zooms = generateAutoZooms(clicks: log.clicks(), duration: source.duration)
        }

        do {
            try project.save(to: packageURL.appendingPathComponent("project.json"))
        } catch {
            NSLog("Recorder: failed to save project.json: \(error)")
        }

        await writeThumbnail(packageURL: packageURL)

        // MARK: Editor hand-off call site
        // The editor window lands in M3 (another lane). Once `EditorWindowController` exists, replace
        // this with `EditorWindowController.open(package: packageURL)`.
        NSWorkspace.shared.activateFileViewerSelecting([packageURL])
    }

    func cancel() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        let session = self.session
        let camera = self.camera
        Task {
            await session?.cancel()
            await camera?.stop(cancelled: true)
            self.reset()
        }
    }

    private func reset() {
        session = nil
        camera = nil
        packageURL = nil
        state = .idle
        CameraBubblePanel.hide()
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

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
}
