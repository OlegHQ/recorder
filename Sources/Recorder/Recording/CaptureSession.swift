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
    // ponytail: one queue for all three outputs; split if audio ever drops.
    private let outputQueue = DispatchQueue(label: "CaptureSession.output")

    private let screenWriter: TrackWriter
    private var systemWriter: TrackWriter?
    private var micWriter: TrackWriter?

    private let pixelWidth: Int
    private let pixelHeight: Int

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
        self.eventRecorder = EventRecorder(target: target, cursorsDir: packageURL.appendingPathComponent("cursors"))

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let size = target.pixelSize
        pixelWidth = Int(size.width)
        pixelHeight = Int(size.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
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

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter = target.filter(content: content, settings: settings)
        let config = target.configuration(settings: settings)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if config.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue) }
        if config.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue) }
        self.stream = stream
    }

    func start() async throws {
        try await stream?.startCapture()
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
        try? await stream?.stopCapture()
        stream = nil

        await screenWriter.finish()
        await systemWriter?.finish()
        await micWriter?.finish()

        let log = eventRecorder.stop()
        try JSONEncoder().encode(log).write(to: packageURL.appendingPathComponent("events.json"), options: .atomic)

        let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
        let duration = try await asset.load(.duration).seconds

        return Source(kind: sourceKind, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                               scale: Double(target.scale), duration: duration, hasCamera: hasCamera,
                               hasMic: settings.micID != nil, hasSystemAudio: settings.systemAudio != .off)
    }

    /// Stops capture, discards every writer, and deletes `packageURL` (no project should be left behind).
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
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
        input.append(retimed)
    }

    func finish() async {
        guard sessionStarted else { writer.cancelWriting(); return }
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
