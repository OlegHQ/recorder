import AppKit
import AVFoundation
import CoreMedia
import RecorderCore

// MARK: - Selftest `audio-mix <package-is-built-here>` (T-504)

/// T-504: (a) volumes/mutes rebuild ONLY the live `AVPlayerItem.audioMix` (same item, no
/// composition rebuild/playback hiccup — `PreviewView.refreshAudioMix`); (b) the exported file's
/// mic level reflects `micVolume`/`micMuted` (RMS on a synthesized tone); (c) `denoise` peak ≈
/// −1 dBFS; (d) the click sound is present in the export at each click's output time when enabled.
enum AudioMixSelfTest {
    @MainActor
    static func run(_ args: [String]) async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-audio-mix-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let duration = 2.0
        try await synthesizeTestScreenMovie(at: tmp.appendingPathComponent("screen.mov"))
        try synthesizeToneM4A(at: tmp.appendingPathComponent("mic.m4a"), duration: duration, amplitude: 0.5)

        var project = Project(title: "Audio Mix",
                               source: Source(kind: .display, pixelWidth: 320, pixelHeight: 180, scale: 1, duration: duration, hasMic: true))
        project.clips = [Clip(sourceStart: 0, sourceEnd: duration, speed: 1)]
        try project.save(to: tmp.appendingPathComponent("project.json"))

        // (a) live preview: a volume-only edit swaps `audioMix`, never the `AVPlayerItem` itself.
        let model = try loadEditorModel(package: tmp)
        let view = PreviewView(model: model)
        view.setFrameSize(NSSize(width: 320, height: 180))

        func waitUntil(_ timeout: Double = 5, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() {
                guard Date() < deadline else { throw Fail(description: "timed out waiting") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await waitUntil { view.currentItemForTest != nil }
        guard let itemBefore = view.currentItemForTest else { throw Fail(description: "no live AVPlayerItem") }
        let audioMixBefore = itemBefore.audioMix

        model.edit("Microphone volume") { $0.audio.micVolume = 0.2 }
        try await waitUntil { view.currentItemForTest?.audioMix !== audioMixBefore }
        guard view.currentItemForTest === itemBefore else {
            throw Fail(description: "an audio-only edit replaced the AVPlayerItem (should rebuild only the AVAudioMix)")
        }

        model.edit("Mute microphone") { $0.audio.micMuted = true }
        let audioMixAfterMute = view.currentItemForTest?.audioMix
        try await waitUntil { view.currentItemForTest?.audioMix !== audioMixAfterMute }
        guard view.currentItemForTest === itemBefore else {
            throw Fail(description: "muting replaced the AVPlayerItem")
        }
        // Back to a known state (full volume, unmuted) for the export checks below.
        model.edit("Restore mic") { $0.audio.micMuted = false; $0.audio.micVolume = 1 }
        try await waitUntil { view.currentItemForTest != nil }
        print("audio-mix: live preview swaps AVAudioMix on the same AVPlayerItem (2 edits, item unchanged) OK")

        // (b) export RMS reflects `micVolume`/`micMuted`.
        let rmsFull = try await exportAndMeasureRMS(model: model, tmp: tmp, micVolume: 1, micMuted: false)
        let rmsQuiet = try await exportAndMeasureRMS(model: model, tmp: tmp, micVolume: 0.25, micMuted: false)
        let rmsMuted = try await exportAndMeasureRMS(model: model, tmp: tmp, micVolume: 1, micMuted: true)
        print("audio-mix: rms full=\(rmsFull) quiet=\(rmsQuiet) muted=\(rmsMuted)")
        guard rmsFull > 0.05 else { throw Fail(description: "full-volume export RMS too low: \(rmsFull)") }
        guard rmsQuiet < rmsFull * 0.6, rmsQuiet > rmsFull * 0.1 else {
            throw Fail(description: "quiet export RMS \(rmsQuiet) doesn't reflect micVolume=0.25 vs full \(rmsFull)")
        }
        guard rmsMuted < rmsFull * 0.05 else { throw Fail(description: "muted export RMS \(rmsMuted) isn't ~silent (full=\(rmsFull))") }

        // (c) denoise: peak normalised to ≈ −1 dBFS (0.891 linear). Mic must be un-muted/full-volume
        // here — the last `exportAndMeasureRMS` call above (`muted`) left `audio.micMuted = true`.
        model.edit("Denoise") { $0.audio.denoise = true; $0.audio.micMuted = false; $0.audio.micVolume = 1 }
        let denoisedURL = tmp.appendingPathComponent("denoised.mp4")
        try await runExport(model: model, destination: denoisedURL)
        let denoisedSamples = try await decodePCM(url: denoisedURL)
        let denoisedPeak = denoisedSamples.map { abs($0) }.max() ?? 0
        let expectedPeak: Float = pow(10, -1.0 / 20)
        print("audio-mix: denoise peak=\(denoisedPeak) expected≈\(expectedPeak)")
        guard abs(denoisedPeak - expectedPeak) < 0.05 else {
            throw Fail(description: "denoise peak \(denoisedPeak) not ≈ -1 dBFS (\(expectedPeak))")
        }
        model.edit("Denoise off") { $0.audio.denoise = false }

        // (d) click sound: present (energy) at each click's output time, silent well away from one,
        // over an otherwise-silent track (no mic) so the click itself is unambiguous.
        var clickProject = project
        clickProject.source.hasMic = false
        clickProject.cursor.clickSound = true
        try clickProject.save(to: tmp.appendingPathComponent("project.json"))
        let clickEvents = EventLog(events: [
            InputEvent(t: 0.5, k: .down, x: 0.5, y: 0.5, b: 0),
            InputEvent(t: 1.3, k: .down, x: 0.4, y: 0.6, b: 0),
        ])
        let clickModel = EditorModel(packageURL: tmp, project: clickProject, events: clickEvents)
        let clickURL = tmp.appendingPathComponent("clicks.mp4")
        try await runExport(model: clickModel, destination: clickURL)
        let clickSamples = try await decodePCM(url: clickURL)
        guard !clickSamples.isEmpty else { throw Fail(description: "click export has no audio track") }
        let sampleRate = 44_100.0
        func rms(around t: Double, radius: Double) -> Float {
            let lo = max(0, Int((t - radius) * sampleRate))
            let hi = min(clickSamples.count, Int((t + radius) * sampleRate))
            guard hi > lo else { return 0 }
            var sum: Float = 0
            for i in lo..<hi { sum += clickSamples[i] * clickSamples[i] }
            return sqrt(sum / Float(hi - lo))
        }
        let atClick = rms(around: 0.5, radius: 0.02)
        let awayFromClick = rms(around: 1.0, radius: 0.05)
        print("audio-mix: click rms atClick=\(atClick) awayFromClick=\(awayFromClick)")
        guard atClick > 0.01 else { throw Fail(description: "no click energy at t=0.5: rms=\(atClick)") }
        guard awayFromClick < atClick * 0.2 else {
            throw Fail(description: "track isn't silent away from a click: \(awayFromClick) vs \(atClick)")
        }

        print("audio-mix OK: live mix swap without item replacement, export volume/mute/denoise/click all verified")
    }

    /// Sets `model.project.audio.micVolume`/`micMuted` (one edit), exports, and returns the
    /// exported file's RMS — callers reuse the same `model` across several export variants.
    @MainActor
    private static func exportAndMeasureRMS(model: EditorModel, tmp: URL, micVolume: Double, micMuted: Bool) async throws -> Float {
        model.edit("Mic settings") { $0.audio.micVolume = micVolume; $0.audio.micMuted = micMuted }
        let url = tmp.appendingPathComponent("export-\(UUID().uuidString).mp4")
        try await runExport(model: model, destination: url)
        let samples = try await decodePCM(url: url)
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }

    @MainActor
    private static func runExport(model: EditorModel, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        var settings = ExportSettings()
        settings.shortEdge = 180
        settings.fps = 5   // a handful of output frames is enough for an audio-only check
        let exporter = Exporter(model: model, settings: settings, destination: destination)
        try await exporter.run()
    }

    /// Decodes an exported file's audio track to mono Float32 PCM at a fixed 44.1 kHz (AVFoundation
    /// resamples/mixes down for us via `outputSettings`), so RMS/peak/windowed checks are simple
    /// array math and index-by-time arithmetic.
    private static func decodePCM(url: URL, sampleRate: Double = 44_100) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else {
            throw SelfTestArgError.usage("audio reader failed to start: \(reader.error?.localizedDescription ?? "?")")
        }
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard let dataPointer else { continue }
            let count = length / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
            }
        }
        return samples
    }
}

/// A short, silent-container-friendly test video (solid colour, no audio) — just enough for
/// `Exporter` to have a screen track to decode. Same `AVAssetWriter` shape/codec `SelfTest.swift`'s
/// own fixture writers use (HEVC — H.264 at this tiny a resolution measured ~1 s/frame to decode
/// back, presumably a software-decode fallback; HEVC matches every other already-fast fixture in
/// this repo), kept here (not shared) since it's `Render/`-local test-only code. A handful of
/// frames at a low fps is enough — `Exporter` holds the last decoded frame for any output time past
/// the last encoded one (SPEC §6.2 "holds last frame for VFR gaps").
private func synthesizeTestScreenMovie(at url: URL, width: Int = 320, height: Int = 180, fps: Int32 = 5, frameCount: Int = 6) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var frame = 0
    while frame < frameCount {
        guard input.isReadyForMoreMediaData else { try await Task.sleep(nanoseconds: 5_000_000); continue }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pixelBuffer else { throw SelfTestArgError.usage("CVPixelBufferCreate failed") }
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        frame += 1
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SelfTestArgError.usage("movie writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
    }
}

/// A pure sine tone `mic.m4a` fixture at a known amplitude, so exported RMS/peak checks have a
/// predictable baseline (unlike `SelfTest.swift`'s own varying-envelope waveform fixture).
private func synthesizeToneM4A(at url: URL, duration: Double, amplitude: Float, frequency: Double = 220, sampleRate: Double = 44_100) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
        throw SelfTestArgError.usage("couldn't allocate a PCM buffer for the mic tone fixture")
    }
    buffer.frameLength = buffer.frameCapacity
    let channel = buffer.floatChannelData![0]
    for i in 0..<Int(buffer.frameLength) {
        let t = Double(i) / sampleRate
        channel[i] = amplitude * Float(sin(2 * .pi * frequency * t))
    }
    try file.write(from: buffer)
}
