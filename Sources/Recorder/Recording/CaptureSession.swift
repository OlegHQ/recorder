import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import ScreenCaptureKit

/// Captures `target` to `packageURL` (SPEC §4.8, §5): a cursor-less `screen.mov` plus optional
/// `system.m4a`/`mic.m4a`, and `events.json` via `EventRecorder`. One `TrackWriter` per media file;
/// all three share the clock `t0` (PTS of the first complete screen frame) and `pausedSoFar`.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let target: CaptureTarget
    private let settings: RecordingSettings
    private let packageURL: URL
    private let eventRecorder: EventRecorder

    private var stream: SCStream?
    private var audioStream: SCStream?
    // ponytail: one queue for all three outputs; split if audio ever drops.
    private let outputQueue = DispatchQueue(label: "CaptureSession.output")

    private let screenWriter: TrackWriter
    private var systemWriter: TrackWriter?
    private var micWriter: TrackWriter?

    private let pixelWidth: Int
    private let pixelHeight: Int

    /// Normalised to the shorter captured dimension; read after finish drains the output queue.
    private(set) var windowCornerRadius: Double?

    /// Shared clock (SPEC §4.8): `CameraCapture`'s fourth `TrackWriter` retimes onto the same `t0`/
    /// `pausedSoFar`/`isPaused` so `camera.mov` stays in sync with `screen.mov` (AC-CAM-2).
    private(set) var t0: CMTime?
    private(set) var pausedSoFar: CMTime = .zero
    private(set) var isPaused = false
    private var pauseStart: CMTime?

    /// Set by whoever attaches a `CameraCapture` to this session, so `finish()` reports `hasCamera`
    /// correctly (SPEC §5 `Source.hasCamera`).
    var hasCamera = false

    /// Elapsed output-clock seconds, for the recording widget/status item (SPEC §4.7). Derived from the
    /// host clock minus the paused duration (frozen at the pause point while paused) rather than the
    /// latest screen frame's PTS, which would visibly freeze whenever SCK sends no frames (idle content).
    var elapsed: Double {
        guard let t0 else { return 0 }
        let now = isPaused ? (pauseStart ?? CMClockGetTime(CMClockGetHostTimeClock())) : CMClockGetTime(CMClockGetHostTimeClock())
        return max(0, (now - t0 - pausedSoFar).seconds)
    }

    init(target: CaptureTarget, settings: RecordingSettings, packageURL: URL) async throws {
        self.target = target
        self.settings = settings
        self.packageURL = packageURL
        self.eventRecorder = EventRecorder(target: target, cursorsDir: packageURL.appendingPathComponent("cursors"), recordAllKeys: settings.recordAllKeys)

        if let micID = settings.micID {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed, AVCaptureDevice(uniqueID: micID) != nil else {
                throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The selected microphone is unavailable. Check Microphone access in System Settings and reconnect or select another microphone."])
            }
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let size = target.pixelSize
        pixelWidth = Int(size.width)
        pixelHeight = Int(size.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoColorPropertiesKey: VideoColor.properties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(60_000_000, pixelWidth * pixelHeight * 4),
            ],
        ]
        screenWriter = try TrackWriter(url: packageURL.appendingPathComponent("screen.mov"), videoSettings: videoSettings)

        if settings.systemAudio != .off {
            systemWriter = try TrackWriter(url: packageURL.appendingPathComponent("system.m4a"),
                                            audioSettings: CaptureSession.audioSettings)
        }
        if settings.micID != nil {
            micWriter = try TrackWriter(url: packageURL.appendingPathComponent("mic.m4a"),
                                         audioSettings: CaptureSession.audioSettings)
        }

        super.init()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = target.filter(content: content, settings: settings)
        let config = target.configuration(settings: settings)
        // Audio scope is independent of the recorded window/display. A second stream keeps
        // selected-app filtering from changing the video, and “all apps” works in window mode.
        if settings.systemAudio != .off, let display = content.displays.first {
            let audioFilter: SCContentFilter
            if case .apps(let ids) = settings.systemAudio {
                audioFilter = SCContentFilter(display: display,
                    including: content.applications.filter { ids.contains($0.bundleIdentifier) }, exceptingWindows: [])
            } else {
                audioFilter = SCContentFilter(display: display, excludingWindows: [])
            }
            let audioConfig = SCStreamConfiguration()
            audioConfig.width = 2
            audioConfig.height = 2
            audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            audioConfig.capturesAudio = true
            audioConfig.excludesCurrentProcessAudio = true
            audioConfig.sampleRate = 48_000
            audioConfig.channelCount = 2
            let audioStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
            try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            self.audioStream = audioStream
        }
        config.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if config.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue) }
        self.stream = stream
    }

    func start() async throws {
        do {
            try await audioStream?.startCapture()
            try await stream?.startCapture()
        } catch {
            try? await audioStream?.stopCapture()
            throw error
        }
    }

    /// Stop appending samples; `resume` adds the gap to `pausedSoFar` so every subsequent
    /// video/audio/event timestamp shifts back by the paused duration (SPEC §4.7 AC-REC-2).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
        eventRecorder.pause()
    }

    func resume() {
        guard isPaused, let pauseStart else { return }
        pausedSoFar = pausedSoFar + (CMClockGetTime(CMClockGetHostTimeClock()) - pauseStart)
        isPaused = false
        self.pauseStart = nil
        eventRecorder.resume()
    }

    /// Stops the stream, finishes every writer, writes `events.json`, and returns the measured
    /// `Source` (duration read back from the finished `screen.mov`, not the wall clock).
    func finish() async throws -> Source {
        let endTime = CMTime(seconds: elapsed, preferredTimescale: 60000)
        try? await stream?.stopCapture()
        try? await audioStream?.stopCapture()
        stream = nil
        audioStream = nil
        // Drain callbacks before closing their inputs.
        await withCheckedContinuation { continuation in
            outputQueue.async { continuation.resume() }
        }

        await screenWriter.finish(at: endTime)
        await systemWriter?.finish()
        await micWriter?.finish()

        let log = eventRecorder.stop()
        try JSONEncoder().encode(log).write(to: packageURL.appendingPathComponent("events.json"), options: .atomic)

        if let error = screenWriter.error ?? systemWriter?.error ?? micWriter?.error { throw error }
        let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
        let duration = try await asset.load(.duration).seconds

        return Source(kind: sourceKind, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                               scale: Double(target.scale), duration: duration, hasCamera: hasCamera,
                               hasMic: micWriter?.hasSamples == true, hasSystemAudio: systemWriter?.hasSamples == true)
    }

    /// Stops capture, discards every writer, and deletes `packageURL` (no project should be left behind).
    func cancel() async {
        try? await stream?.stopCapture()
        try? await audioStream?.stopCapture()
        stream = nil
        audioStream = nil
        await withCheckedContinuation { continuation in
            outputQueue.async { continuation.resume() }
        }
        screenWriter.cancel()
        systemWriter?.cancel()
        micWriter?.cancel()
        _ = eventRecorder.stop()
        try? FileManager.default.removeItem(at: packageURL)
    }

    private var sourceKind: Source.Kind {
        switch target {
        case .display: return .display
        case .window: return .window
        case .area: return .area
        }
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !isPaused else { return }

        switch type {
        case .screen:
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachmentsArray.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete else { return }

            if case .window = target, let buffer = sampleBuffer.imageBuffer,
               CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    if let radius = detectedWindowCornerRadius(width: width, height: height,
                        alpha: { x, y in bytes[y * stride + x * 4 + 3] }) {
                        windowCornerRadius = max(windowCornerRadius ?? 0, radius / Double(min(width, height)))
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            let pts = sampleBuffer.presentationTimeStamp
            if t0 == nil {
                t0 = pts
                eventRecorder.start(t0HostTime: pts)
            }
            guard let t0 else { return }
            let offset = pts - t0 - pausedSoFar
            screenWriter.append(sampleBuffer, offset: offset)

        case .audio:
            guard let t0 else { return } // drop audio that arrives before the first complete screen frame
            systemWriter?.append(sampleBuffer, offset: sampleBuffer.presentationTimeStamp - t0 - pausedSoFar)

        case .microphone:
            guard let t0 else { return }
            micWriter?.append(sampleBuffer, offset: sampleBuffer.presentationTimeStamp - t0 - pausedSoFar)

        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Recorder: capture stream stopped: \(error)")
    }
}

/// `AVAssetWriter` + one real-time input, retiming every appended buffer to an explicit output-clock
/// offset (SPEC §4.8). One instance per media file (`screen.mov`/`system.m4a`/`mic.m4a`/`camera.mov`).
/// Internal (not `private`) so `CameraCapture` can reuse it for the fourth writer.
final class TrackWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoTime: CMTime = .zero
    var error: Error? { writer.error }
    private(set) var hasSamples = false

    init(url: URL, videoSettings: [String: Any]) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.add(input)
    }

    init(url: URL, audioSettings: [String: Any]) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.add(input)
    }

    func append(_ sb: CMSampleBuffer, offset: CMTime) {
        guard offset >= .zero, let retimed = TrackWriter.retimed(sb, to: offset) else { return }
        if !sessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(retimed) {
            hasSamples = true
            if input.mediaType == .video {
                lastVideoSample = sb
                lastVideoTime = offset
            }
        }
    }

    func finish(at endTime: CMTime? = nil) async {
        guard sessionStarted else { writer.cancelWriting(); return }
        // SCK emits no complete frames for an idle screen. Hold its last image through Stop.
        if let endTime, let sample = lastVideoSample, endTime > lastVideoTime {
            for _ in 0..<200 where !input.isReadyForMoreMediaData && writer.status == .writing {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            append(sample, offset: endTime)
            writer.endSession(atSourceTime: endTime)
        }
        lastVideoSample = nil
        input.markAsFinished()
        await writer.finishWriting()
    }

    func cancel() {
        guard sessionStarted else { return }
        writer.cancelWriting()
    }

    private static func retimed(_ sb: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = newPTS
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: timing.count,
                                                             sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
