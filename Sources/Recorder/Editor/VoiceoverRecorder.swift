import AppKit
@preconcurrency import AVFoundation
import Observation
import RecorderCore
import SwiftUI

@MainActor @Observable final class VoiceoverRecorder: NSObject, AVCaptureFileOutputDelegate, AVCaptureFileOutputRecordingDelegate {
    enum Phase: Equatable { case idle, preparing, countdown(Int), arming, recording, finishing }
    private(set) var phase: Phase = .idle
    private(set) var level: Double = 0
    private(set) var deviceName = "Microphone"
    private(set) var track = 0
    private(set) var trackName = "Voiceover 1"
    private(set) var liveRange: TimeRange?
    private(set) var levels: [(output: Double, peak: Float)] = []
    var hearProject = false { didSet { preview?.setVoiceoverMonitoring(hearProject) } }
    var isActive: Bool { phase != .idle }
    var isPreRoll: Bool { phase == .recording && replacementRange.map { (model?.playhead ?? 0) < $0.start } == true }
    @ObservationIgnored weak var preview: PreviewView?
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var windowObserver: NSObjectProtocol?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var replacementID: UUID?
    @ObservationIgnored private var replacementRange: TimeRange?
    @ObservationIgnored private var stopOutput: Double?
    @ObservationIgnored private var playbackStart = 0.0
    @ObservationIgnored private var playbackHost = 0.0
    @ObservationIgnored private var placement: Double?
    @ObservationIgnored private var discarded = false
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var token = UUID()
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureAudioFileOutput()
    nonisolated private let captureQueue = DispatchQueue(label: "Voiceover.capture")
    nonisolated private let captureLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var armedURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var sampleStart: Double?
    @ObservationIgnored nonisolated(unsafe) private var lastLevelHost = -Double.infinity

    init(model: EditorModel) { self.model = model; super.init() }

    static func isShortcut(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "r" && event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
    }

    func handleRecordingKey(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.keyCode == 53, plain { discard() }
        else if (event.keyCode == 49 && plain) || Self.isShortcut(event) { stop() }
    }

    func discardAndWait() async {
        discard()
        while isActive { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func toggle() {
        if isActive { stop(); return }
        let selected = model?.selection.count == 1 ? model?.selection.first : nil
        let audio = selected.flatMap { id in model?.project.audioClips.first { $0.id == id.uuidString } }
        start(replacing: audio.flatMap { UUID(uuidString: $0.id) })
    }

    func start(replacing id: UUID? = nil) {
        guard !isActive, let model, preview?.window != nil, preview?.window?.attachedSheet == nil, !model.project.clips.isEmpty else { return }
        model.cancelGesture()
        preview?.endVoiceoverPlayback()
        model.isPlaying = false
        replacementID = id
        replacementRange = id.flatMap { id in
            guard let audio = model.project.audioClips.first(where: { $0.id == id.uuidString }) else { return nil }
            let segments = model.project.audioSegments(audio)
            guard let first = segments.first, let last = segments.last else { return nil }
            return TimeRange(start: first.output.start, end: last.output.end)
        }
        guard id == nil || replacementRange != nil else { return }
        let start = replacementRange?.start ?? model.playhead
        let target = model.project.voiceoverDestination(atOutput: start, replacing: replacementRange)
        track = target.track; trackName = target.name
        stopOutput = [target.stop, replacementRange.map { $0.end + 0.4 }].compactMap { $0 }.min()
        playbackStart = replacementRange.map { max(0, $0.start - 1.5) } ?? model.playhead
        liveRange = nil; levels = []; level = 0; placement = nil; failure = nil
        discarded = false; hearProject = false; phase = .preparing
        token = UUID()
        let current = token
        task = Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            var granted = status == .authorized
            if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            guard self.token == current, self.phase == .preparing else { return }
            guard granted else {
                self.phase = .idle
                self.presentError("Allow Recorder to use your microphone in System Settings → Privacy & Security → Microphone.", permission: true)
                return
            }
            guard self.preview?.window?.isVisible == true else { self.discard(); return }
            do {
                self.installKeyMonitor()
                let selected = RecordingSettings.shared.micID
                let device = selected.flatMap { AVCaptureDevice(uniqueID: $0) } ?? (selected == nil ? AVCaptureDevice.default(for: .audio) : nil)
                guard let device, device.hasMediaType(.audio) else { throw self.error("The selected microphone is unavailable. Choose a microphone in the recording toolbar.") }
                self.deviceName = device.localizedName
                self.destination = try Self.takeURL(in: model.packageURL)
                try await self.preview?.prepareVoiceover(atOutput: self.playbackStart)
                guard self.token == current, self.phase == .preparing, !Task.isCancelled else { return }
                try await self.startSession(device: device)
                guard self.token == current, self.phase == .preparing, !Task.isCancelled else { return }
                try await self.countDown()
                guard let destination = self.destination else { throw self.error("The take file is unavailable.") }
                self.phase = .arming
                self.captureLock.withLock { self.armedURL = destination }
                try await Task.sleep(for: .seconds(5))
                if self.phase == .arming { self.discard(error: "The microphone did not deliver audio. Check the input device and try again.") }
            } catch is CancellationError {
                if self.isActive, self.phase != .finishing, !Task.isCancelled { self.discard(error: "Preview preparation was interrupted. Try recording again.") }
            }
            catch { if self.token == current && self.phase != .finishing { self.discard(error: error.localizedDescription) } }
        }
    }

    private func startSession(device: AVCaptureDevice) async throws {
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The microphone stopped working."
            MainActor.assumeIsolated {
                if self?.phase != .finishing { self?.discard(error: message) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [self] in
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) else { throw error("AAC capture is unavailable.") }
                    session.beginConfiguration()
                    for existing in session.inputs { session.removeInput(existing) }
                    guard session.canAddInput(input) else { session.commitConfiguration(); throw error("This microphone cannot be opened.") }
                    session.addInput(input)
                    if session.outputs.isEmpty {
                        guard session.canAddOutput(output) else { session.commitConfiguration(); throw error("Audio capture is unavailable.") }
                        session.addOutput(output)
                    }
                    output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
                    output.maxRecordedDuration = .invalid
                    output.delegate = self
                    session.commitConfiguration()
                    captureLock.withLock { sampleStart = nil; armedURL = nil; lastLevelHost = -.infinity }
                    session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func countDown() async throws {
        for count in (1...3).reversed() {
            try Task.checkCancellation()
            phase = .countdown(count)
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func installKeyMonitor() {
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: preview?.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.discard() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isActive, let preview = self.preview, let window = preview.window, event.window === window else { return false }
                let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                if ((event.keyCode == 49 || event.keyCode == 53) && plain) || Self.isShortcut(event) {
                    self.handleRecordingKey(event)
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    nonisolated func fileOutputShouldProvideSampleAccurateRecordingStart(_ output: AVCaptureFileOutput) -> Bool { true }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { return }
        let host = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock()).seconds
        guard host.isFinite else { return }
        let power = connection.audioChannels.map { pow(10, Double($0.averagePowerLevel) / 20) }.max() ?? 0
        let first: Double? = captureLock.withLock {
            var started = false
            if let url = armedURL, sampleStart == nil {
                sampleStart = host; armedURL = nil; started = true
                self.output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            }
            guard started || host - lastLevelHost >= 1 / 30.0 else { return nil }
            lastLevelHost = host
            return sampleStart ?? -1
        }
        guard let first else { return }
        DispatchQueue.main.async { [weak self] in self?.receivedSample(first: first >= 0 ? first : nil, host: host, power: power) }
    }

    private func receivedSample(first: Double?, host: Double, power: Double) {
        guard isActive, phase != .finishing else { return }
        level = min(1, max(0, power))
        if phase == .arming, let first {
            playbackHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.1
            placement = takePlacement(playheadOutput: playbackStart, firstSampleHost: first, playbackHost: playbackHost)
            phase = .recording
            preview?.startVoiceoverPlayback(atOutput: playbackStart, atHostTime: CMTime(seconds: playbackHost, preferredTimescale: 1_000_000_000))
            if let stopOutput, let placement {
                output.maxRecordedDuration = CMTime(seconds: max(0.1, stopOutput - placement), preferredTimescale: 48_000)
            }
            task?.cancel()
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard let self, self.phase == .recording else { return }
                    let time = self.playbackStart + CMClockGetTime(CMClockGetHostTimeClock()).seconds - self.playbackHost
                    self.model?.playhead = max(self.playbackStart, time)
                    if let stop = self.stopOutput, time >= stop { self.stop() }
                }
            }
        }
        guard phase == .recording, let placement, let first else { return }
        let start = max(0, placement, replacementRange?.start ?? 0)
        let end = min(placement + max(0, host - first), replacementRange?.end ?? .infinity)
        if end > start { liveRange = TimeRange(start: start, end: end) }
        levels.append((placement + host - first, Float(level)))
    }

    func stop() {
        guard isActive, phase != .finishing else { return }
        guard phase == .recording else { discard(); return }
        phase = .finishing
        task?.cancel()
        preview?.endVoiceoverPlayback()
        captureLock.withLock { output.stopRecording() }
    }

    func discard(error message: String? = nil) {
        guard isActive else { return }
        if phase == .finishing { discarded = true; return }
        discarded = true; failure = message; phase = .finishing
        task?.cancel()
        preview?.endVoiceoverPlayback()
        let started = captureLock.withLock { () -> Bool in
            armedURL = nil
            if sampleStart != nil { output.stopRecording(); return true }
            return false
        }
        if !started { Task { await finishCapture(error: nil) } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.destination == outputFileURL else { return }
            let succeeded = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            Task { await self.finishCapture(error: succeeded ? nil : error) }
        }
    }

    private func finishCapture(error captureError: Error?) async {
        phase = .finishing
        task?.cancel()
        preview?.endVoiceoverPlayback()
        await withCheckedContinuation { continuation in
            captureQueue.async { [session] in session.stopRunning(); continuation.resume() }
        }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        let file = destination
        let problem = failure ?? captureError?.localizedDescription
        do {
            if !discarded, problem == nil, let file, let placement { try await commit(file: file, placement: placement, replacing: replacementID) }
            else if let file { try? FileManager.default.removeItem(at: file) }
        } catch is CancellationError {
            if let file { try? FileManager.default.removeItem(at: file) }
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            failure = error.localizedDescription
        }
        captureLock.withLock { armedURL = nil; sampleStart = nil }
        destination = nil; liveRange = nil; level = 0; phase = .idle
        if let message = failure ?? (discarded ? nil : problem) { presentError(message) }
        failure = nil
    }

    private func commit(file: URL, placement: Double, replacing id: UUID?) async throws {
        guard let model else { throw error("The editor was closed before the take finished.") }
        let asset = AVURLAsset(url: file)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw error("The take contains no audio.") }
        let duration = try await asset.load(.duration).seconds
        guard !discarded else { throw CancellationError() }
        let relative = "voice/" + file.lastPathComponent
        var project = model.project
        guard let take = project.addVoiceover(file: relative, placement: placement, duration: duration, replacing: id) else {
            throw error("The take is too short or cannot fit in this range. The original audio has not changed.")
        }
        phase = .idle
        model.edit(id == nil ? "Record Voiceover" : "Re-record Audio") { $0 = project }
        model.selectedClips = []; model.selection = [take]
        model.playhead = max(0, placement, replacementRange?.start ?? 0)
        model.saveNow()
        if let message = model.saveError { presentError("The take is kept in the project package, but the project could not be saved: " + message) }
    }

    private static func takeURL(in package: URL) throws -> URL {
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("voice", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".m4a")
    }

    nonisolated private func error(_ message: String) -> NSError {
        NSError(domain: "Recorder.Voiceover", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func presentError(_ message: String, permission: Bool = false) {
        guard let window = preview?.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = permission ? "Microphone access required" : "Voiceover could not finish"
        alert.informativeText = message
        alert.addButton(withTitle: permission ? "Open Settings" : "OK")
        if permission { alert.addButton(withTitle: "Cancel") }
        alert.beginSheetModal(for: window) { response in
            if permission, response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
}

extension VoiceoverRecorder {
    @MainActor static func runSelfTest(package: URL, input: URL) async throws -> Project {
        struct Fail: Error, CustomStringConvertible { let description: String }
        func check(_ value: Bool, _ message: String) throws { if !value { throw Fail(description: message) } }
        let manager = FileManager.default
        let sourceAsset = AVURLAsset(url: input)
        let duration = try await sourceAsset.load(.duration).seconds
        guard duration >= 1, try await !sourceAsset.loadTracks(withMediaType: .audio).isEmpty else { throw Fail(description: "voiceover fixture needs at least 1 second of audio") }
        let originalBytes = try Data(contentsOf: input)
        try manager.copyItem(at: input, to: package.appendingPathComponent("mic.m4a"))
        var project = Project(title: "Voiceover validation", source: Source(pixelWidth: 320, pixelHeight: 180, duration: 8, hasCamera: true, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 8)])
        let range = TimeRange(start: min(2, duration / 2), end: min(2, duration / 2) + min(1, duration / 3))
        project.audioClips = [AudioClip(start: range.start, end: range.end, mediaStart: range.start, file: "mic.m4a", link: .camera)]
        try project.save(to: package.appendingPathComponent("project.json"))
        guard let window = EditorWindowController.makeOffscreen(package: package),
              let controller = window.windowController as? EditorWindowController else { throw Fail(description: "voiceover editor") }
        defer { window.close() }
        let model = controller.model
        let preview = controller.previewView
        preview.framebufferOnly = false
        window.orderFront(nil)
        let recorder = model.voiceover
        defer { model.saveNow() }
        let originalID = UUID(uuidString: project.audioClips[0].id)!
        try check(isShortcut(key(15, "R", modifiers: .shift)) && !isShortcut(key(15, "R", modifiers: [.shift, .command])), "Voiceover shortcut modifier routing")
        recorder.replacementID = originalID; recorder.replacementRange = range
        recorder.playbackStart = max(0, range.start - 1.5)
        let target = project.voiceoverDestination(atOutput: range.start, replacing: range)
        recorder.track = target.track; recorder.trackName = target.name
        recorder.deviceName = "Synthetic microphone · test fixture"
        recorder.phase = .preparing
        recorder.destination = try takeURL(in: package)
        try manager.copyItem(at: input, to: recorder.destination!)
        try await preview.prepareVoiceover(atOutput: recorder.playbackStart)
        let playerItem = preview.currentItemForTest
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !predicate() {
                guard Date() < deadline else { throw Fail(description: "voiceover state timeout: \(recorder.phase)") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func render(_ name: String) async throws {
            window.contentView?.layoutSubtreeIfNeeded()
            let frame = try await preview.captureRenderedFrame()
            let overlay = NSImageView(frame: preview.bounds)
            overlay.image = NSImage(cgImage: frame, size: preview.bounds.size)
            overlay.imageScaling = .scaleAxesIndependently
            preview.addSubview(overlay, positioned: .below, relativeTo: preview.subviews.first)
            defer { overlay.removeFromSuperview() }
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Fail(description: "voiceover bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/recorder-voiceover-\(name).png"))
        }
        try check(recorder.responds(to: #selector(AVCaptureFileOutputDelegate.fileOutput(_:didOutputSampleBuffer:from:))) &&
                  recorder.responds(to: #selector(AVCaptureFileOutputRecordingDelegate.fileOutput(_:didFinishRecordingTo:from:error:))), "Capture delegates not installed")
        let countdownStarted = Date()
        recorder.task = Task {
            do { try await recorder.countDown(); recorder.phase = .arming }
            catch { }
        }
        for count in (1...3).reversed() {
            try await wait { recorder.phase == .countdown(count) }
            try check(preview.debugRate == 0 && !model.isPlaying, "Playback ran during silent countdown")
            try await render("countdown-\(count)")
            if count == 2 {
                window.setContentSize(CGSize(width: 1100, height: 700))
                try await render("minimum-countdown")
                window.setContentSize(CGSize(width: 1200, height: 760))
            }
        }
        try await wait { recorder.phase == .arming }
        try check(Date().timeIntervalSince(countdownStarted) >= 2.9, "Countdown did not last three seconds")
        let firstHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.12
        let peaks = try await Waveform.peaks(for: input)
        recorder.receivedSample(first: firstHost, host: firstHost, power: Double(peaks.max() ?? 0.1))
        try check(model.isPlaying && preview.voiceoverMonitoringMuted, "Project was not muted while recording")
        recorder.hearProject = true
        try check(!preview.voiceoverMonitoringMuted, "Hear project did not unmute playback")
        recorder.hearProject = false
        recorder.handleRecordingKey(key(49, " ", modifiers: [.control, .option]))
        try check(recorder.phase == .recording, "VoiceOver activation stopped the take")
        try await Task.sleep(for: .milliseconds(40))
        try check(model.playhead >= recorder.playbackStart, "Scheduled playback moved the playhead backwards")
        model.edit("Forbidden edit") { $0.title = "Changed during capture" }
        try check(model.project == project && model.undoStepCount == 0, "Recording allowed an edit")
        for index in 0..<23 {
            try await Task.sleep(for: .milliseconds(100))
            recorder.receivedSample(first: firstHost, host: CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.12,
                                    power: Double(peaks[min(peaks.count - 1, index * 20)]))
            if index == 1 { try await render("pre-roll") }
            if [18, 20, 22].contains(index) { try await render("growing-\(index)") }
        }
        try check(recorder.liveRange != nil && preview.currentItemForTest === playerItem && model.project == project, "Live take changed saved media/composition")
        let expected = recorder.playbackStart + CMClockGetTime(CMClockGetHostTimeClock()).seconds - recorder.playbackHost
        let drift = abs(preview.debugCurrentTime - expected)
        try check(drift < 0.02, "Native playback drifted from the host clock: \(drift) s")
        print("voiceover: native player/host-clock drift \(drift) s")
        let rawPlacement = try unwrap(recorder.placement)
        let firstFile = try unwrap(recorder.destination)
        preview.keyDown(with: key(49, " "))
        try check(recorder.phase == .finishing && !model.isPlaying && !preview.voiceoverMonitoringMuted, "Space did not stop recording and restore monitoring")
        recorder.fileOutput(recorder.output, didFinishRecordingTo: firstFile, from: [], error: nil)
        try await wait { recorder.phase == .idle }
        try check(model.undoStepCount == 1, "Take commit was not one undo step")
        let take = try unwrap(model.project.audioClips.first { $0.file.hasPrefix("voice/") })
        try check(model.project.audioClips.first { $0.id == originalID.uuidString }?.gain == 0 &&
                  abs(take.mediaStart - (range.start - rawPlacement)) < 0.001 &&
                  abs((take.end - take.start) - (range.end - range.start)) < 0.001 && take.link == nil, "Take placement, trim or original mute")
        try check(model.project.cameraClips == project.cameraClips && model.project.checkInvariants() == nil, "Re-record changed linked camera or invariants")
        try await render("committed")
        let firstProject = model.project
        recorder.destination = try takeURL(in: package)
        let secondFile = recorder.destination!
        try manager.copyItem(at: input, to: secondFile)
        recorder.phase = .finishing; recorder.placement = rawPlacement; recorder.discarded = false
        await recorder.finishCapture(error: nil)
        let secondProject = model.project
        try check(secondProject.audioClips.filter { $0.file.hasPrefix("voice/") }.count == 1 && model.undoStepCount == 2 && secondProject != firstProject, "Same-range re-record did not replace the previous take")
        try check(manager.fileExists(atPath: firstFile.path) && manager.fileExists(atPath: secondFile.path), "Re-record deleted an undoable take file")
        model.undo(); try check(model.project == firstProject, "Undo did not restore the previous take")
        model.undo(); try check(model.project == project, "One undo did not restore original audio")
        model.redo(); model.redo()
        try check(model.project == secondProject, "Redo did not restore takes")
        model.saveNow()
        try check(try Project.load(from: package.appendingPathComponent("project.json")) == secondProject, "Voiceover save/load")
        recorder.destination = try takeURL(in: package)
        let discardedFile = recorder.destination!
        try manager.copyItem(at: input, to: discardedFile)
        recorder.phase = .countdown(3)
        recorder.task = Task { do { try await recorder.countDown() } catch { } }
        preview.keyDown(with: key(53, "\u{1b}"))
        try await wait { recorder.phase == .idle }
        try check(!manager.fileExists(atPath: discardedFile.path) && model.project == secondProject && model.undoStepCount == 2, "Escape did not discard without an undo entry")
        try await Task.sleep(for: .milliseconds(1100))
        try check(recorder.phase == .idle, "Cancelled countdown restarted")
        recorder.destination = try takeURL(in: package)
        let quittingFile = recorder.destination!
        try manager.copyItem(at: input, to: quittingFile)
        recorder.phase = .preparing
        await recorder.discardAndWait()
        try check(!manager.fileExists(atPath: quittingFile.path) && model.project == secondProject, "Quit cleanup left a take or modified the project")
        try check(AppDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateNow, "Idle quit did not terminate")
        window.orderOut(nil)
        recorder.destination = try takeURL(in: package)
        let corrupt = recorder.destination!
        try Data("not audio".utf8).write(to: corrupt)
        recorder.phase = .finishing; recorder.discarded = false
        await recorder.finishCapture(error: nil)
        try check(model.project == secondProject && model.undoStepCount == 2 && !manager.fileExists(atPath: corrupt.path), "Corrupt audio changed the project")
        try check(try Data(contentsOf: input) == originalBytes && Data(contentsOf: package.appendingPathComponent("mic.m4a")) == originalBytes, "Original audio file was modified")
        let child = package.appendingPathComponent("path-check")
        let outside = package.appendingPathComponent("outside-path-check")
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: child.appendingPathComponent("voice"), withDestinationURL: outside)
        var rejected = false
        do { _ = try takeURL(in: child) } catch { rejected = true }
        try check(rejected && manager.contentsOfDirectory(atPath: outside.path).isEmpty, "Voice directory escaped the package")
        try manager.removeItem(at: child); try manager.removeItem(at: outside)
        print("voiceover: silent countdown, host-clock playback, live lane, monitoring, placement, original mute, take replacement, one-step undo/redo, Escape, corrupt media and save/load verified")
        return project
    }

    private static func unwrap<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CocoaError(.validationMissingMandatoryProperty) }
        return value
    }

    private static func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}

struct VoiceoverHUD: View {
    let recorder: VoiceoverRecorder

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if case .countdown(let count) = recorder.phase, geometry.size.height >= 260 {
                    Text("\(count)").font(Font(Theme.headingFont(72)))
                        .padding(8).background(Theme.bgPanelColor)
                        .accessibilityLabel("Voiceover starts in \(count)")
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if case .countdown(let count) = recorder.phase, geometry.size.height < 260 {
                            Text("\(count)").font(Font(Theme.headingFont(40))).accessibilityLabel("Voiceover starts in \(count)")
                        }
                        Text(title).font(Font(Theme.headingFont(24)))
                        Spacer()
                        Text(recorder.deviceName).font(Font(Theme.captionFont)).lineLimit(1)
                    }
                    GeometryReader { meter in
                        ZStack(alignment: .leading) {
                            Theme.bgHoverColor
                            Theme.textPrimaryColor.frame(width: meter.size.width * sqrt(recorder.level))
                        }
                    }.frame(height: 3).accessibilityElement(children: .ignore).accessibilityLabel("Microphone level").accessibilityValue("\(Int(recorder.level * 100)) percent")
                    HStack(spacing: 12) {
                        Toggle("Hear project", isOn: Binding(get: { recorder.hearProject }, set: { recorder.hearProject = $0 }))
                            .toggleStyle(TechToggleStyle()).fixedSize()
                        Spacer(minLength: 0)
                        Button("Discard", action: { recorder.discard() }).buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
                        Button("Stop", action: { recorder.stop() }).buttonStyle(TechButtonStyle(kind: .primary, compact: true))
                    }.disabled(recorder.phase == .finishing)
                }
                .padding(12).background(Theme.bgPanelColor).overlay { Rectangle().stroke(Theme.strokeColor, lineWidth: 1) }
                .frame(maxWidth: 560)
            }
            .padding(12).frame(maxWidth: .infinity)
        }
        .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textPrimaryColor)
        .tint(Theme.accentColor).preferredColorScheme(.dark)
    }

    private var title: String {
        switch recorder.phase {
        case .idle, .preparing: return "Preparing voiceover…"
        case .countdown: return "Ready to record"
        case .arming: return "Waiting for microphone…"
        case .recording: return recorder.isPreRoll ? "Pre-roll · get ready" : "Recording voiceover"
        case .finishing: return "Saving take…"
        }
    }
}
