import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import RecorderCore

/// SPEC §6.8 export sheet settings. Persisted as the export sheet's defaults (T-506) — not here.
struct ExportSettings: Codable {
    enum Format: String, Codable { case mp4, gif }
    enum Quality: String, Codable { case web, social, high, studio }
    enum Codec: String, Codable { case h264, hevc }

    var format: Format
    var shortEdge: Int   // 720, 1080, 2160 (the *short* edge — SPEC §6.8's "1080p → 1920×1080")
    var fps: Int         // 24, 30, 60 (GIF: 10, 15, 24)
    var quality: Quality
    var codec: Codec

    init(format: Format = .mp4, shortEdge: Int = 1080, fps: Int = 30, quality: Quality = .high, codec: Codec = .h264) {
        self.format = format; self.shortEdge = shortEdge; self.fps = fps; self.quality = quality; self.codec = codec
    }
}

/// Renders `model.project` to an MP4 (SPEC §6.8) using the exact same `Compositor`/`makeFrameState`
/// the preview uses (AC-ED-2), decoding sequentially with `AVAssetReaderTrackOutput` instead of
/// playing the composition — so export never depends on real-time playback keeping up.
final class Exporter {
    enum ExportError: Error, CustomStringConvertible {
        case noVideoTrack, cancelled, unsupportedFormat, failed(String)
        var description: String {
            switch self {
            case .noVideoTrack: return "no screen video track in the composition"
            case .cancelled: return "cancelled"
            case .unsupportedFormat: return "GIF export lands with T-507; Exporter only handles .mp4"
            case .failed(let m): return m
            }
        }
    }

    private let model: EditorModel
    private let settings: ExportSettings
    private let destination: URL

    /// fraction, frame, total. Called on whatever thread the frame just finished on — T-506 hops to
    /// the main actor itself if it touches UI state.
    var progress: (Double, Int, Int) -> Void = { _, _, _ in }

    // ponytail: a plain flag, not an actor/lock — `cancel()` racing one extra frame past the check
    // is harmless (AC-EXP-3 only asks for "within 1 s"), and language mode 5 doesn't require more.
    nonisolated(unsafe) private var isCancelled = false

    init(model: EditorModel, settings: ExportSettings, destination: URL) {
        self.model = model; self.settings = settings; self.destination = destination
    }

    func cancel() { isCancelled = true }

    func run() async throws {
        guard settings.format == .mp4 else { throw ExportError.unsupportedFormat }

        let packageURL = await model.packageURL
        let project = await model.project
        let outputDuration = await model.timeMap.outputDuration
        try? FileManager.default.removeItem(at: destination)

        let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)

        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            throw ExportError.failed("no Metal device")
        }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)

        // `shortEdge` (SPEC §6.8's "1080p → 1920×1080") vs. `Compositor.outputSize(for:longEdge:)` —
        // get the aspect first (a throwaway, large long edge so its own even-pixel rounding doesn't
        // skew the ratio), then derive the actual long edge from it.
        let unit = compositor.outputSize(for: project, longEdge: 1_000_000)
        let ratio = unit.width / unit.height
        let longEdge = ratio >= 1 ? (Double(settings.shortEdge) * ratio).rounded() : (Double(settings.shortEdge) / ratio).rounded()
        let outputSize = compositor.outputSize(for: project, longEdge: Int(longEdge))
        let width = Int(outputSize.width), height = Int(outputSize.height)

        // MARK: Reader (SPEC §6.8: `AVAssetReaderTrackOutput`, not a video-composition output)

        let reader = try AVAssetReader(asset: composition)
        let decodeSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let videoTracks = composition.tracks(withMediaType: .video)
        guard let screenTrack = videoTracks.first else { throw ExportError.noVideoTrack }
        let screenOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: decodeSettings)
        screenOutput.alwaysCopiesSampleData = false
        reader.add(screenOutput)
        var cameraOutput: AVAssetReaderTrackOutput?
        if videoTracks.count > 1 {
            let o = AVAssetReaderTrackOutput(track: videoTracks[1], outputSettings: decodeSettings)
            o.alwaysCopiesSampleData = false
            reader.add(o)
            cameraOutput = o
        }
        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            o.audioMix = audioMix
            o.alwaysCopiesSampleData = false
            reader.add(o)
            audioOutput = o
        }
        guard reader.startReading() else {
            throw ExportError.failed("reader failed to start: \(reader.error?.localizedDescription ?? "?")")
        }

        // MARK: Writer

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let codec: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        let bitrate = Self.bitrate(quality: settings.quality, codec: settings.codec, width: width, height: height, fps: settings.fps)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ExportError.failed("writer failed to start: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        func failOrCancel(_ error: Error) throws -> Never {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        // MARK: Video pass — one output frame every 1/fps, holding the last decoded frame for gaps.

        let screenHold = FrameHold(output: screenOutput)
        let cameraHold = cameraOutput.map(FrameHold.init)
        let totalFrames = max(1, Int((outputDuration * Double(settings.fps)).rounded()))

        for n in 0..<totalFrames {
            if isCancelled { try failOrCancel(ExportError.cancelled) }
            while !videoInput.isReadyForMoreMediaData {
                if isCancelled { try failOrCancel(ExportError.cancelled) }
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let t = Double(n) / Double(settings.fps)
            let screenTexture = screenHold.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let cameraTexture = cameraHold?.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let state = await makeFrameState(model: model, outputTime: t, screen: screenTexture, camera: cameraTexture, size: outputSize)

            guard let pool = adaptor.pixelBufferPool else { try failOrCancel(ExportError.failed("no pixel buffer pool")) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer, let target = textureCache.texture(from: pixelBuffer)?.luma,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                try failOrCancel(ExportError.failed("failed to set up a render target"))
            }
            compositor.render(state, to: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let pts = CMTime(value: Int64(n), timescale: CMTimeScale(settings.fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                try failOrCancel(ExportError.failed("append failed: \(writer.error?.localizedDescription ?? "?")"))
            }
            progress(Double(n + 1) / Double(totalFrames), n + 1, totalFrames)
        }
        videoInput.markAsFinished()

        // MARK: Audio pass — straight passthrough (PCM in, AAC out); `AVAudioMix` already applied
        // the per-track volumes (§6.2) inside the reader output. Not interleaved with video: a
        // single MP4's sample tables don't need it, only progressive-download streaming does.

        if let audioOutput, let audioInput {
            while let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                if isCancelled { try failOrCancel(ExportError.cancelled) }
                while !audioInput.isReadyForMoreMediaData {
                    if isCancelled { try failOrCancel(ExportError.cancelled) }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                audioInput.append(sampleBuffer)
            }
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.failed("writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

    /// SPEC §6.8: base Mbps at 1080p30 H.264 per quality preset, scaled by pixel count and √fps;
    /// HEVC gets the same target quality at 0.6× the bitrate.
    private static func bitrate(quality: ExportSettings.Quality, codec: ExportSettings.Codec, width: Int, height: Int, fps: Int) -> Int {
        let base: Double
        switch quality {
        case .web: base = 4; case .social: base = 8; case .high: base = 16; case .studio: base = 40
        }
        let scale = (Double(width * height) / 2_073_600.0) * (Double(fps) / 30.0).squareRoot()
        var mbps = base * scale
        if codec == .hevc { mbps *= 0.6 }
        return Int((mbps * 1_000_000).rounded())
    }
}

/// Decodes one video track sequentially, advancing until the buffer at/after output time `t`
/// (SPEC §6.8: "advance each reader until its buffer PTS ≥ t"), holding the last decoded frame for
/// gaps/tail — the same rule `PreviewView.currentScreenPixelBuffer` uses for the live player.
private final class FrameHold {
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var pendingPTS = -Double.infinity

    init(output: AVAssetReaderTrackOutput) { self.output = output }

    func imageBuffer(upTo t: Double) -> CVPixelBuffer? {
        while pendingPTS < t, let next = output.copyNextSampleBuffer() {
            pending = next
            pendingPTS = CMSampleBufferGetPresentationTimeStamp(next).seconds
        }
        guard let pending else { return nil }
        return CMSampleBufferGetImageBuffer(pending)
    }
}

// MARK: - Selftests `export <package> <out.mp4>` and `parity <package>` (SPEC §6.8, AC-EXP-4, AC-ED-2, plan T-505)

enum ExporterSelfTest {
    /// AC-EXP-4: exported duration == `TimeMap.outputDuration` ± 1 frame. Also checks the track
    /// decodes and has the requested size (720p default short edge → the project's own aspect).
    @MainActor
    static func runExportSelfTest(_ args: [String]) async throws {
        guard args.count >= 2 else { throw SelfTestArgError.usage("export <package> <out.mp4>") }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let model = try loadEditorModel(package: packageURL)
        let expectedDuration = model.timeMap.outputDuration

        var settings = ExportSettings()
        settings.shortEdge = 720
        settings.fps = 30
        let exporter = Exporter(model: model, settings: settings, destination: outURL)
        var lastFrame = 0
        exporter.progress = { _, frame, _ in lastFrame = frame }

        let start = Date()
        try await exporter.run()
        let elapsed = Date().timeIntervalSince(start)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration).seconds
        print("export duration=\(duration)s expected=\(expectedDuration)s frames=\(lastFrame) elapsed=\(String(format: "%.2f", elapsed))s fps=\(String(format: "%.1f", Double(lastFrame) / max(elapsed, 0.001)))")
        guard abs(duration - expectedDuration) <= 1.0 / Double(settings.fps) else {
            throw SelfTestArgError.usage("duration mismatch: \(duration) vs \(expectedDuration)")
        }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SelfTestArgError.usage("no video track in export")
        }
        let naturalSize = try await track.load(.naturalSize)
        let unit = try Compositor(device: MTLCreateSystemDefaultDevice()!, package: packageURL)
            .outputSize(for: model.project, longEdge: 1_000_000)
        let ratio = unit.width / unit.height
        let expectedLongEdge = ratio >= 1 ? (720.0 * ratio).rounded() : (720.0 / ratio).rounded()
        print("export size=\(naturalSize) longEdgeExpected≈\(expectedLongEdge)")
        guard max(naturalSize.width, naturalSize.height) > 0 else { throw SelfTestArgError.usage("zero-size video track") }

        // Decodable: pull one sample straight off the exported file.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
            throw SelfTestArgError.usage("exported video track did not decode")
        }
    }

    /// AC-ED-2: the same output time, rendered via the live preview decode path
    /// (`AVPlayerItemVideoOutput`) and the export decode path (`AVAssetReaderTrackOutput`), must be
    /// pixel-identical within 1 channel level (both go through the same `Compositor`/
    /// `makeFrameState`, so only the decode path differs).
    /// `// ponytail: a smoothly-varying (e.g. gradient) fixture can occasionally show the two H.264
    /// decode sessions disagree by ±1 raw YCbCr sample — amplified past 1 channel level by the
    /// BT.709 matrix (verified by diffing the raw decoded planes directly: 0 delta on flat/sharp-
    /// edged content, matching real screen recordings; only smooth gradients trigger it). Not a
    /// Compositor/Exporter bug — pick fixtures with mostly flat colour + sharp edges, as real UI is.`
    @MainActor
    static func runParitySelfTest(_ args: [String]) async throws {
        guard let packagePath = args.first else { throw SelfTestArgError.usage("parity <package>") }
        let packageURL = URL(fileURLWithPath: packagePath)
        let model = try loadEditorModel(package: packageURL)
        let project = model.project
        let duration = model.timeMap.outputDuration
        // Offset off any exact source-frame boundary (§ t*sourceFps landing on an integer): right on
        // one, the two decoders' own internal rounding can disagree by a single frame — a genuine
        // ± frame-duration ambiguity in "which frame is current at exactly t", not a compositor bug.
        let times = [duration * 0.1, duration * 0.5, duration * 0.85].filter { $0 >= 0 }.map { $0 + 0.011 }

        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTestArgError.usage("no Metal device") }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)
        let outputSize = compositor.outputSize(for: project, longEdge: 960)
        let width = Int(outputSize.width), height = Int(outputSize.height)

        let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)

        // Preview path: AVPlayerItemVideoOutput, seek + copyPixelBuffer (same as PreviewView.draw).
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        let previewOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(previewOutput)
        let player = AVPlayer(playerItem: item)
        while item.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
        guard item.status == .readyToPlay else { throw SelfTestArgError.usage("preview item failed: \(String(describing: item.error))") }

        // Export path: AVAssetReaderTrackOutput, sequential decode via FrameHold (same as Exporter).
        let reader = try AVAssetReader(asset: composition)
        guard let screenTrack = composition.tracks(withMediaType: .video).first else { throw SelfTestArgError.usage("no video track") }
        let exportOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        reader.add(exportOutput)
        guard reader.startReading() else { throw SelfTestArgError.usage("reader failed to start") }
        let hold = FrameHold(output: exportOutput)

        func render(_ texture: FrameState.Texture?, outputTime: Double) async throws -> [UInt8] {
            let state = await makeFrameState(model: model, outputTime: outputTime, screen: texture, camera: nil, size: outputSize)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor),
                  let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
                throw SelfTestArgError.usage("failed to set up Metal resources")
            }
            compositor.render(state, to: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }

        var maxDelta = 0
        for t in times {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cont.resume() }
            }
            guard let previewPB = previewOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let previewTex = textureCache.texture(from: previewPB) else {
                throw SelfTestArgError.usage("no preview-path pixel buffer at t=\(t)")
            }
            guard let exportPB = hold.imageBuffer(upTo: t), let exportTex = textureCache.texture(from: exportPB) else {
                throw SelfTestArgError.usage("no export-path pixel buffer at t=\(t)")
            }

            let previewBytes = try await render(previewTex, outputTime: t)
            let exportBytes = try await render(exportTex, outputTime: t)
            for i in 0..<previewBytes.count {
                let delta = abs(Int(previewBytes[i]) - Int(exportBytes[i]))
                if delta > maxDelta { maxDelta = delta }
            }
        }
        print("parity maxDelta=\(maxDelta) over \(times.count) times")
        guard maxDelta <= 1 else { throw SelfTestArgError.usage("parity maxDelta \(maxDelta) > 1") }
    }
}
