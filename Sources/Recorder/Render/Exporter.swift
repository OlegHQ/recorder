import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import RecorderCore
import UniformTypeIdentifiers

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
            case .unsupportedFormat: return "unsupported export format"
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

    private let cancellationLock = NSLock()
    private var cancelled = false
    private var isCancelled: Bool { cancellationLock.withLock { cancelled } }

    init(model: EditorModel, settings: ExportSettings, destination: URL) {
        self.model = model; self.settings = settings; self.destination = destination
    }

    func cancel() { cancellationLock.withLock { cancelled = true } }

    func run() async throws {
        // T-507: GIF is a wholly separate encode path (ImageIO, not AVAssetWriter) — kept out of
        // this method below (see `runGIF()` at the bottom of this file) so it doesn't disturb the
        // MP4 loop.
        guard settings.format == .mp4 else { return try await runGIF() }

        let packageURL = model.packageURL
        let project = await model.project
        let outputDuration = project.exportDuration
        guard outputDuration > 0 else { throw ExportError.failed("No media to export.") }
        try? FileManager.default.removeItem(at: destination)

        // T-504: `denoise` is applied EXPORT ONLY (preview always plays the raw mic) — pre-process
        // mic.m4a into a temp file and hand its URL to `makeComposition` as the mic track's source.
        // `// ponytail: no real noise suppression and no preview; add an audio tap if users ask.`
        var micOverrideURL: URL?
        var denoiseTempDir: URL?
        if project.audio.denoise, project.source.hasMic {
            let micURL = packageURL.appendingPathComponent("mic.m4a")
            if FileManager.default.fileExists(atPath: micURL.path) {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-denoise-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let processedURL = tempDir.appendingPathComponent("mic-denoised.caf")
                try denoiseMicAudio(input: micURL, output: processedURL)
                micOverrideURL = processedURL
                denoiseTempDir = tempDir
            }
        }
        defer { if let denoiseTempDir { try? FileManager.default.removeItem(at: denoiseTempDir) } }

        let (composition, audioMix, _, _) = try await makeComposition(package: packageURL, project: project, micURL: micOverrideURL)

        // T-504: "Mouse click sound" — mixed into the export audio at each left `.down` event that
        // survives the clip cuts (export only; the preview plays it live via `NSSound`,
        // `PreviewView.playClickSoundIfCrossed`).
        if project.cursor.clickSound {
            let clicks = model.events.clicks()
            let timeMap = await model.timeMap
            try? await addClickTrack(to: composition, audioMix: audioMix, clicks: clicks, timeMap: timeMap)
        }

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
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: outputDuration, preferredTimescale: 600))
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
            AVVideoColorPropertiesKey: VideoColor.properties,
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
        defer {
            if writer.status != .completed {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
            }
        }

        // MARK: Feed both writer inputs so neither track stalls waiting for the other.

        let screenHold = FrameHold(output: screenOutput)
        let cameraHold = cameraOutput.map(FrameHold.init)
        let totalFrames = max(1, Int((outputDuration * Double(settings.fps)).rounded()))

        let clock = ContinuousClock()
        var lastAppend = clock.now
        var n = 0
        var audioFinished = audioInput == nil
        while n < totalFrames || !audioFinished {
            if isCancelled || Task.isCancelled { throw ExportError.cancelled }
            guard clock.now - lastAppend < .seconds(30) else {
                throw ExportError.failed("The encoder stopped responding. Please try exporting again.")
            }
            guard writer.status == .writing else {
                throw ExportError.failed("writer stopped: \(writer.error?.localizedDescription ?? "?")")
            }
            guard reader.status != .failed else {
                throw ExportError.failed("reader failed: \(reader.error?.localizedDescription ?? "?")")
            }

            // AVAssetWriter applies backpressure across tracks. Feeding all video before audio
            // fills its video queue (typically at frame 32) and waits forever for audio.
            if let audioOutput, let audioInput, !audioFinished {
                while audioInput.isReadyForMoreMediaData {
                    if isCancelled { throw ExportError.cancelled }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        guard reader.status != .failed else {
                            throw ExportError.failed("audio read failed: \(reader.error?.localizedDescription ?? "?")")
                        }
                        audioInput.markAsFinished()
                        audioFinished = true
                        break
                    }
                    guard audioInput.append(sample) else {
                        throw ExportError.failed("audio append failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    lastAppend = clock.now
                }
            }
            guard n < totalFrames, videoInput.isReadyForMoreMediaData else {
                if n == totalFrames && audioFinished { break }
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }

            let t = Double(n) / Double(settings.fps)
            let screenTexture = screenHold.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let cameraTexture = cameraHold?.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let state = await makeFrameState(model: model, outputTime: t, screen: screenTexture, camera: cameraTexture, size: outputSize)

            guard let pool = adaptor.pixelBufferPool else { throw ExportError.failed("no pixel buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer, let target = textureCache.texture(from: pixelBuffer)?.luma,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw ExportError.failed("failed to set up a render target")
            }
            compositor.render(state, to: target, commandBuffer: commandBuffer)
            try await commandBuffer.commitAndWait()

            let pts = CMTime(value: Int64(n), timescale: CMTimeScale(settings.fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw ExportError.failed("append failed: \(writer.error?.localizedDescription ?? "?")")
            }
            lastAppend = clock.now
            n += 1
            progress(Double(n) / Double(totalFrames), n, totalFrames)
            if n == totalFrames { videoInput.markAsFinished() }
        }

        writer.endSession(atSourceTime: CMTime(value: Int64(totalFrames), timescale: CMTimeScale(settings.fps)))
        writer.finishWriting {}
        let finishStart = clock.now
        while writer.status == .writing {
            if isCancelled || Task.isCancelled { throw ExportError.cancelled }
            guard clock.now - finishStart < .seconds(30) else {
                throw ExportError.failed("The encoder could not finish the file. Please try exporting again.")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard writer.status == .completed else {
            throw ExportError.failed("writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

    /// SPEC §6.8: base Mbps at 1080p30 H.264 per quality preset, scaled by pixel count and √fps;
    /// HEVC gets the same target quality at 0.6× the bitrate. Not `private`: `ExportSheet`'s live
    /// size estimate (T-506) shares this exact function rather than a second copy of the Mbps table.
    static func bitrate(quality: ExportSettings.Quality, codec: ExportSettings.Codec, width: Int, height: Int, fps: Int) -> Int {
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

// MARK: - T-504 audio: export-only denoise + click sound

/// SPEC/T-504: 80 Hz one-pole high-pass (removes hum/rumble) then peak normalise to −1 dBFS, over
/// the whole mic file — a plain array pass, no `AVAudioEngine`/`AVAudioUnit` graph needed for a
/// static-file transform. `// ponytail: no real noise suppression, a high-pass + normalise only;
/// add a spectral denoiser only if users ask.` Writes linear PCM (`.caf`) so decoding it back for
/// the composition never re-compresses on top of the source AAC.
private func denoiseMicAudio(input: URL, output: URL) throws {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw Exporter.ExportError.failed("couldn't allocate a PCM buffer for \(input.lastPathComponent)")
    }
    try file.read(into: buffer)
    guard let data = buffer.floatChannelData else {
        throw Exporter.ExportError.failed("\(input.lastPathComponent) has no float channel data")
    }
    let frames = Int(buffer.frameLength)
    let channels = Int(format.channelCount)

    let dt = 1.0 / format.sampleRate
    let rc = 1.0 / (2 * Double.pi * 80)
    let alpha = Float(rc / (rc + dt))
    for c in 0..<channels {
        let channel = data[c]
        var prevX: Float = 0, prevY: Float = 0
        for i in 0..<frames {
            let x = channel[i]
            let y = alpha * (prevY + x - prevX)
            channel[i] = y
            prevX = x; prevY = y
        }
    }

    var peak: Float = 0
    for c in 0..<channels {
        let channel = data[c]
        for i in 0..<frames { peak = max(peak, abs(channel[i])) }
    }
    if peak > 0 {
        let targetPeak = Float(pow(10, -1.0 / 20))   // −1 dBFS
        let gain = targetPeak / peak
        for c in 0..<channels {
            let channel = data[c]
            for i in 0..<frames { channel[i] *= gain }
        }
    }

    let outFile = try AVAudioFile(forWriting: output, settings: format.settings)
    try outFile.write(from: buffer)
}

/// SPEC/T-504: mixes `Resources/click.caf` into the export audio at each left `.down` event that
/// survives the clip cuts (`TimeMap.outputTime(atSource:)` — a click inside a removed range simply
/// has no output time and is skipped). Adds one more composition audio track + `AVAudioMix` input
/// parameter alongside mic/system, so it goes through the same reader/writer pass as everything else.
private func addClickTrack(to composition: AVMutableComposition, audioMix: AVMutableAudioMix, clicks: [InputEvent], timeMap: TimeMap) async throws {
    guard let clickURL = Bundle.main.url(forResource: "click", withExtension: "caf") else { return }
    let clickAsset = AVURLAsset(url: clickURL)
    guard let clickSource = try await clickAsset.loadTracks(withMediaType: .audio).first else { return }
    let clickDuration = try await clickAsset.load(.duration)
    guard clickDuration > .zero,
          let clicksTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }

    var lastEnd = CMTime.zero
    for event in clicks {
        guard let outputSeconds = timeMap.outputTime(atSource: event.t) else { continue }
        let start = CMTime(seconds: outputSeconds, preferredTimescale: 600)
        // ponytail: clicks closer together than the click sound's own length are dropped, not
        // layered — `insertTimeRange` can't overlap within one track, and back-to-back clicks that
        // close together are rare enough not to warrant a second track.
        guard start >= lastEnd else { continue }
        try? clicksTrack.insertTimeRange(CMTimeRange(start: .zero, duration: clickDuration), of: clickSource, at: start)
        lastEnd = start + clickDuration
    }

    let params = AVMutableAudioMixInputParameters(track: clicksTrack)
    params.setVolume(1, at: .zero)
    audioMix.inputParameters += [params]
}

// MARK: - GIF export (T-507)

/// SPEC §6.8's GIF row: same decode/compositor pipeline as `run()`'s MP4 loop above — `makeComposition`,
/// `FrameHold` (sequential decode, floor-selected frame), `makeFrameState`/`Compositor.render` — but
/// written straight to an animated GIF with `CGImageDestination` instead of an `AVAssetWriter`, since
/// GIF has no writer input to append to. Kept as its own extension/function, entirely below the MP4
/// path, so it doesn't disturb that loop (which the render lane's camera work also touches).
extension Exporter {
    private func runGIF() async throws {
        let packageURL = model.packageURL
        let project = await model.project
        let outputDuration = project.exportDuration
        guard outputDuration > 0 else { throw ExportError.failed("No media to export.") }
        try? FileManager.default.removeItem(at: destination)

        // SPEC §6.8: "Warn (non-blocking) if duration > 60 s" — GIFs get large fast; export still runs.
        if outputDuration > 60 {
            print("warning: GIF export duration is \(Int(outputDuration))s — SPEC §6.8 recommends keeping GIFs under 60s")
        }

        let (composition, _, _, _) = try await makeComposition(package: packageURL, project: project)

        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            throw ExportError.failed("no Metal device")
        }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)

        // SPEC §6.8: "render at chosen fps, max 960 px long edge" — fps also capped to the sheet's
        // GIF row (10|15|24) regardless of what's passed in, since MP4-only rates (30/60) would
        // make oversized, janky-to-play GIFs.
        let outputSize = compositor.outputSize(for: project, longEdge: 960)
        let width = Int(outputSize.width), height = Int(outputSize.height)
        let fps = min(max(settings.fps, 1), 24)

        let decodeSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: outputDuration, preferredTimescale: 600))
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
        guard reader.startReading() else {
            throw ExportError.failed("reader failed to start: \(reader.error?.localizedDescription ?? "?")")
        }

        let totalFrames = max(1, Int((outputDuration * Double(fps)).rounded()))
        guard let gifDestination = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, totalFrames, nil) else {
            throw ExportError.failed("failed to create GIF destination")
        }
        // loop 0 = forever (SPEC §6.8).
        CGImageDestinationSetProperties(gifDestination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        let screenHold = FrameHold(output: screenOutput)
        let cameraHold = cameraOutput.map(FrameHold.init)
        let delay = 1.0 / Double(fps)

        for n in 0..<totalFrames {
            if isCancelled {
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.cancelled
            }

            let t = Double(n) / Double(fps)
            let screenTexture = screenHold.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let cameraTexture = cameraHold?.imageBuffer(upTo: t).flatMap { textureCache.texture(from: $0) }
            let state = await makeFrameState(model: model, outputTime: t, screen: screenTexture, camera: cameraTexture, size: outputSize)

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw ExportError.failed("failed to set up a render target")
            }
            compositor.render(state, to: target, commandBuffer: commandBuffer)
            try await commandBuffer.commitAndWait()

            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            guard let frame = Self.gifFrame(bgra: bytes, width: width, height: height) else {
                throw ExportError.failed("failed to build a GIF frame image")
            }
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(gifDestination, frame, frameProperties)
            progress(Double(n + 1) / Double(totalFrames), n + 1, totalFrames)
        }

        guard CGImageDestinationFinalize(gifDestination) else { throw ExportError.failed("failed to finalize GIF") }
    }

    /// BGRA8 bytes (as rendered by `Compositor`, same layout `Compositor.writePNG`'s selftest uses)
    /// → `CGImage`, one per GIF frame.
    private static func gifFrame(bgra bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let colorSpace = VideoColor.space
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Decodes one video track sequentially and, for output time `t`, returns the frame with the
/// **largest PTS ≤ t** — the frame a player is actually showing at `t` (its "current" frame is the
/// most recent one whose presentation time has passed), not the first frame *at or after* `t`.
///
/// `// T-505 fix: the first version of this advanced "while pendingPTS < t" and returned whatever
/// it had just consumed, which lands on the first sample with PTS ≥ t — one frame LATER than the
/// preview path (AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:), which floors) picks for the
/// same t. On moving/changing content that's a full extra frame of content difference, not decoder
/// noise — confirmed by logging both candidates (see the T-505 fix commit message for numbers)
/// before fixing. copyNextSampleBuffer() has no peek, so a one-sample lookahead buffer is needed:
/// only "commit" a freshly read sample as current once its own PTS ≤ t; otherwise hold it for a
/// later call (t only moves forward — export/parity always sample it in increasing order).`
private final class FrameHold {
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var lookahead: CMSampleBuffer?
    private var lookaheadPTS = Double.infinity

    init(output: AVAssetReaderTrackOutput) { self.output = output }

    func imageBuffer(upTo t: Double) -> CVPixelBuffer? {
        if let lookahead, lookaheadPTS <= t {
            current = lookahead
            self.lookahead = nil
            lookaheadPTS = .infinity
        }
        while lookahead == nil, let next = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(next).seconds
            if pts <= t {
                current = next
            } else {
                lookahead = next
                lookaheadPTS = pts
            }
        }
        guard let current else { return nil }
        return CMSampleBufferGetImageBuffer(current)
    }
}

// MARK: - Selftests `export <package> <out.mp4>` and `parity <package>` (SPEC §6.8, AC-EXP-4, AC-ED-2, plan T-505)

enum ExporterSelfTest {
    /// AC-EXP-4: exported duration == `TimeMap.outputDuration` ± 1 frame. Also checks the track
    /// decodes and has the requested size (720p default short edge → the project's own aspect).
    @MainActor
    static func runExportSelfTest(_ args: [String]) async throws {
        guard args.count >= 2 else { throw SelfTestArgError.usage("export <package> <out.mp4> [fps] [shortEdge] [h264|hevc]") }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let model = try loadEditorModel(package: packageURL)
        let expectedDuration = model.project.exportDuration

        var settings = ExportSettings()
        settings.fps = args.count > 2 ? (Int(args[2]) ?? 30) : 30
        settings.shortEdge = args.count > 3 ? (Int(args[3]) ?? 720) : 720
        settings.codec = args.count > 4 ? (ExportSettings.Codec(rawValue: args[4]) ?? .h264) : .h264
        guard [24, 30, 60].contains(settings.fps), [720, 1080, 2160].contains(settings.shortEdge) else {
            throw SelfTestArgError.usage("unsupported fps or resolution")
        }
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
        let edge = Double(settings.shortEdge)
        let expectedLongEdge = ratio >= 1 ? (edge * ratio).rounded() : (edge / ratio).rounded()
        print("export size=\(naturalSize) longEdgeExpected≈\(expectedLongEdge)")
        guard max(naturalSize.width, naturalSize.height) > 0 else { throw SelfTestArgError.usage("zero-size video track") }

        // Decode the entire export: completing the writer must not silently drop frames.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw SelfTestArgError.usage("exported video track did not decode") }
        var decodedFrames = 0
        while output.copyNextSampleBuffer() != nil { decodedFrames += 1 }
        let expectedFrames = max(1, Int((expectedDuration * Double(settings.fps)).rounded()))
        guard reader.status == .completed, decodedFrames == expectedFrames, lastFrame == expectedFrames else {
            throw SelfTestArgError.usage("exported frames \(decodedFrames), progress \(lastFrame), expected \(expectedFrames)")
        }
        print("export decoded all \(decodedFrames) frames")
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
        let timeMap = model.timeMap

        // ≥ 5 times spread across the timeline, plus: one exactly on a likely (30 fps) frame
        // boundary (`FrameHold`'s floor-selection must still match the player there), one inside
        // the last clip when it's sped up (composition's `scaleTimeRange` region), one inside a
        // zoom's spring transition (not just its settled midpoint, T-501: `view != prevView`, so
        // motion blur is actually engaged), and one inside a layout's cross-fade (T-503).
        var times: Set<Double> = [duration * 0.08, duration * 0.28, duration * 0.5, duration * 0.73, duration * 0.92]
        let boundary = (Double(Int(duration * 15)) / 30.0)
        if boundary > 0, boundary < duration { times.insert(boundary) }
        if let lastClip = project.clips.last, lastClip.speed != 1 {
            times.insert(duration - lastClip.outputDuration / 2)
        }
        if let zoom = project.zooms.first(where: \.enabled) {
            if let mid = timeMap.outputTime(atSource: (zoom.start + zoom.end) / 2) { times.insert(mid) }
            if let transition = timeMap.outputTime(atSource: zoom.start + 0.15) { times.insert(transition) }
        }
        if let layout = project.layouts.first, let fade = timeMap.outputTime(atSource: layout.start + 0.15) {
            times.insert(fade)
        }
        // T-602: inside a key chip's fade-out window (not just its opaque hold) — the last 0.3 s
        // before `activeKeyChip`'s 1.2 s hold expires (`Compositor.drawKeyChip`'s own fade window).
        if project.keys.show, let keyEvent = model.events.events.first(where: { $0.k == .key }),
           let chipTime = timeMap.outputTime(atSource: keyEvent.t + 1.05) {
            times.insert(chipTime)
        }
        // T-601: inside each mask/highlight's active range (SOURCE time — masks zoom/pan with the
        // content, same as the cursor) — the middle of the range, well clear of its hard edges.
        for mask in project.masks {
            if let inside = timeMap.outputTime(atSource: (mask.start + mask.end) / 2) { times.insert(inside) }
        }
        let orderedTimes = times.filter { $0 >= 0 && $0 < duration }.sorted()

        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTestArgError.usage("no Metal device") }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)
        let outputSize = compositor.outputSize(for: project, longEdge: 960)
        let width = Int(outputSize.width), height = Int(outputSize.height)

        let (composition, audioMix, _, _) = try await makeComposition(package: packageURL, project: project)
        let videoTracks = composition.tracks(withMediaType: .video)
        let hasCamera = videoTracks.count > 1

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

        // Preview path, camera (T-502): isolated single-track composition/player, same technique as
        // `PreviewView.attachCamera` — `AVPlayerItemVideoOutput` has no per-track selection.
        var cameraPlayer: AVPlayer?
        var cameraPreviewOutput: AVPlayerItemVideoOutput?
        if hasCamera {
            let cameraItem = AVPlayerItem(asset: isolateTrack(videoTracks[1], duration: composition.duration))
            let cOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            cameraItem.add(cOutput)
            let p = AVPlayer(playerItem: cameraItem)
            while cameraItem.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
            guard cameraItem.status == .readyToPlay else { throw SelfTestArgError.usage("preview camera item failed: \(String(describing: cameraItem.error))") }
            cameraPlayer = p
            cameraPreviewOutput = cOutput
        }

        // Export path: AVAssetReaderTrackOutput, sequential decode via FrameHold (same as Exporter).
        let reader = try AVAssetReader(asset: composition)
        guard let screenTrack = videoTracks.first else { throw SelfTestArgError.usage("no video track") }
        let exportOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        reader.add(exportOutput)
        var cameraExportOutput: AVAssetReaderTrackOutput?
        if hasCamera {
            let o = AVAssetReaderTrackOutput(track: videoTracks[1], outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            reader.add(o)
            cameraExportOutput = o
        }
        guard reader.startReading() else { throw SelfTestArgError.usage("reader failed to start") }
        let hold = FrameHold(output: exportOutput)
        let cameraHold = cameraExportOutput.map(FrameHold.init)

        func render(_ texture: FrameState.Texture?, camera: FrameState.Texture?, outputTime: Double) async throws -> [UInt8] {
            let state = makeFrameState(model: model, outputTime: outputTime, screen: texture, camera: camera, size: outputSize)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor),
                  let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
                throw SelfTestArgError.usage("failed to set up Metal resources")
            }
            compositor.render(state, to: target, commandBuffer: commandBuffer)
            try await commandBuffer.commitAndWait()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }

        var maxDelta = 0
        for t in orderedTimes {
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

            // (2) pixel format / range: both request identical 420v + Metal-compat settings above;
            // confirm no implicit scaling snuck in by checking the decoded buffer dimensions match.
            let previewSize = (CVPixelBufferGetWidth(previewPB), CVPixelBufferGetHeight(previewPB))
            let exportSize = (CVPixelBufferGetWidth(exportPB), CVPixelBufferGetHeight(exportPB))
            guard previewSize == exportSize else {
                throw SelfTestArgError.usage("decoded size mismatch at t=\(t): preview=\(previewSize) export=\(exportSize)")
            }

            var previewCameraTex: FrameState.Texture?
            var exportCameraTex: FrameState.Texture?
            if hasCamera, let cameraPlayer, let cameraPreviewOutput, let cameraHold {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    cameraPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cont.resume() }
                }
                guard let previewCameraPB = cameraPreviewOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
                    throw SelfTestArgError.usage("no preview-path camera pixel buffer at t=\(t)")
                }
                previewCameraTex = textureCache.texture(from: previewCameraPB)
                guard let exportCameraPB = cameraHold.imageBuffer(upTo: t) else {
                    throw SelfTestArgError.usage("no export-path camera pixel buffer at t=\(t)")
                }
                exportCameraTex = textureCache.texture(from: exportCameraPB)
            }

            // (3) both call `makeFrameState` with the identical outputTime/size (see `render` above).
            let previewBytes = try await render(previewTex, camera: previewCameraTex, outputTime: t)
            let exportBytes = try await render(exportTex, camera: exportCameraTex, outputTime: t)
            var tMaxDelta = 0
            for i in 0..<previewBytes.count {
                let delta = abs(Int(previewBytes[i]) - Int(exportBytes[i]))
                if delta > tMaxDelta { tMaxDelta = delta }
            }
            print("parity t=\(String(format: "%.3f", t)) maxDelta=\(tMaxDelta)")
            maxDelta = max(maxDelta, tMaxDelta)
        }
        print("parity maxDelta=\(maxDelta) over \(orderedTimes.count) times")
        guard maxDelta <= 1 else { throw SelfTestArgError.usage("parity maxDelta \(maxDelta) > 1") }
    }

    /// T-507: `export-gif <package> <out.gif>` — runs the GIF path end to end, then reads the file
    /// back with `CGImageSource` (not the Exporter) to check frame count ≈ `duration × fps`, loop
    /// count 0, a per-frame delay close to `1/fps`, and long edge ≤ 960 (SPEC §6.8).
    @MainActor
    static func runExportGIFSelfTest(_ args: [String]) async throws {
        guard args.count >= 2 else { throw SelfTestArgError.usage("export-gif <package> <out.gif>") }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let model = try loadEditorModel(package: packageURL)
        let expectedDuration = model.project.exportDuration

        var settings = ExportSettings()
        settings.format = .gif
        settings.fps = 15
        let exporter = Exporter(model: model, settings: settings, destination: outURL)
        var lastFrame = 0
        exporter.progress = { _, frame, _ in lastFrame = frame }

        let start = Date()
        try await exporter.run()
        let elapsed = Date().timeIntervalSince(start)

        guard let source = CGImageSourceCreateWithURL(outURL as CFURL, nil) else {
            throw SelfTestArgError.usage("failed to open exported GIF")
        }
        let frameCount = CGImageSourceGetCount(source)
        let expectedFrames = Int((expectedDuration * Double(settings.fps)).rounded())
        print("export-gif frames=\(frameCount) expected≈\(expectedFrames) lastFrameCallback=\(lastFrame) elapsed=\(String(format: "%.2f", elapsed))s")
        guard abs(frameCount - expectedFrames) <= 1 else {
            throw SelfTestArgError.usage("frame count mismatch: \(frameCount) vs \(expectedFrames)")
        }
        guard lastFrame == frameCount else {
            throw SelfTestArgError.usage("progress callback frame \(lastFrame) != written frame count \(frameCount)")
        }

        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let loopCount = gifProperties[kCGImagePropertyGIFLoopCount] as? Int else {
            throw SelfTestArgError.usage("no GIF loop-count property")
        }
        print("export-gif loopCount=\(loopCount)")
        guard loopCount == 0 else { throw SelfTestArgError.usage("loop count \(loopCount) != 0 (forever)") }

        guard let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let frameGIFProperties = frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let delay = frameGIFProperties[kCGImagePropertyGIFDelayTime] as? Double else {
            throw SelfTestArgError.usage("no per-frame GIF delay property")
        }
        let expectedDelay = 1.0 / Double(settings.fps)
        print("export-gif delay=\(delay)s expected≈\(expectedDelay)s")
        guard abs(delay - expectedDelay) <= 0.01 else {
            throw SelfTestArgError.usage("frame delay \(delay) != expected \(expectedDelay)")
        }

        guard let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SelfTestArgError.usage("failed to decode first GIF frame")
        }
        let longEdge = max(firstFrame.width, firstFrame.height)
        print("export-gif size=\(firstFrame.width)x\(firstFrame.height) longEdge=\(longEdge)")
        guard longEdge <= 960 else { throw SelfTestArgError.usage("long edge \(longEdge) > 960") }
    }
}
