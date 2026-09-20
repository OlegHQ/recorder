import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import RecorderCore
import ScreenCaptureKit

/// T-508/T-114 performance gate selftests: `export-perf`, `record-perf`, `idle-perf`. Built entirely on
/// existing public API (`Exporter`, `CaptureSession`, `ProjectStore`'s siblings) — no changes to
/// Render/Editor/App/Recording files the other lanes are touching. SPEC AC-EXP-1, AC-EXP-2, AC-REC-1,
/// AC-REC-4, AC-APP-3, §6.8.
enum PerfSelfTest {
    struct Fail: Error, CustomStringConvertible { let description: String }

    // MARK: - export-perf (AC-EXP-1, AC-EXP-2)

    /// Synthesizes a moving-content 1920×1080@60 HEVC `screen.mov` of `seconds` length (fixture
    /// synthesis excluded from the measured time), builds a project with a couple of zooms on default
    /// motion-blur settings, and exports it at 1080p60 HEVC/high (SPEC §6.8 defaults) — timing only
    /// `Exporter.run()`.
    @MainActor
    static func runExportPerf(_ args: [String]) async throws {
        let seconds = args.first.flatMap(Double.init) ?? 60
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-export-perf-\(UUID().uuidString)")
        let packageURL = tmp.appendingPathComponent("Perf.recorder")
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let width = 1920, height = 1080, fps: Int32 = 60
        let frameCount = max(1, Int((seconds * Double(fps)).rounded()))
        print("export-perf: synthesizing \(Int(seconds))s \(width)x\(height)@\(fps) fixture (\(frameCount) frames, moving content)…")
        let synthStart = Date()
        try await synthesizeMovingMovie(at: packageURL.appendingPathComponent("screen.mov"),
                                         width: width, height: height, fps: fps, frameCount: frameCount)
        print("export-perf: fixture synthesis took \(String(format: "%.1f", Date().timeIntervalSince(synthStart)))s (excluded from the measured export time)")

        var project = Project(
            title: "Export Perf Fixture",
            source: Source(kind: .display, pixelWidth: width, pixelHeight: height, scale: 1, duration: seconds),
            clips: [Clip(sourceStart: 0, sourceEnd: seconds, speed: 1)]
        )
        // "a couple of zooms + motion-relevant settings on defaults" — Animation() defaults already turn
        // on motion blur (motionBlur 0.5, blurZoom/blurPan/blurCursor true); just add zoom blocks.
        if seconds >= 8 {
            project.zooms = [
                Zoom(start: seconds * 0.2, end: min(seconds * 0.2 + 3, seconds - 0.5), scale: 1.8, mode: .manual),
                Zoom(start: seconds * 0.6, end: min(seconds * 0.6 + 3, seconds - 0.2), scale: 1.5, mode: .manual),
            ]
        }
        try project.save(to: packageURL.appendingPathComponent("project.json"))

        let model = try loadEditorModel(package: packageURL)
        var settings = ExportSettings()
        settings.shortEdge = 1080
        settings.fps = 60
        settings.codec = .hevc
        settings.quality = .high
        let outURL = tmp.appendingPathComponent("out.mp4")
        let exporter = Exporter(model: model, settings: settings, destination: outURL)
        var lastFrame = 0
        exporter.progress = { _, frame, _ in lastFrame = frame }

        let start = Date()
        try await exporter.run()
        let elapsed = Date().timeIntervalSince(start)
        let fpsAchieved = Double(lastFrame) / max(elapsed, 0.001)
        print("export-perf: wall=\(String(format: "%.2f", elapsed))s frames=\(lastFrame) fps=\(String(format: "%.1f", fpsAchieved))")

        // AC-EXP-1 is specified for a 1-minute export; scale the 30 s budget linearly so
        // `export-perf 600` (run separately for the AC-EXP-2 drift check) still prints something sane.
        let budget = 30.0 * (seconds / 60.0)
        let pass1 = elapsed < budget
        let budgetNote = seconds == 60 ? "" : " (scaled to \(String(format: "%.1f", budget))s for a \(Int(seconds))s input)"
        print("AC-EXP-1 (1 min 1080p60 export < 30s\(budgetNote)): \(pass1 ? "PASS" : "FAIL") — \(String(format: "%.2f", elapsed))s")

        // AC-EXP-2: this fixture is video-only (no mic/system audio track), so true A/V drift isn't
        // measurable here — print what IS: exported duration vs. the composition's expected duration,
        // and the last video frame's PTS (both requested explicitly by the task).
        let asset = AVURLAsset(url: outURL)
        let outDuration = try await asset.load(.duration).seconds
        let expectedDuration = model.timeMap.outputDuration
        let drift = outDuration - expectedDuration
        let frameInterval = 1.0 / Double(settings.fps)
        let lastFramePTS = Double(max(lastFrame - 1, 0)) / Double(settings.fps)
        print("AC-EXP-2: video duration=\(String(format: "%.4f", outDuration))s expected=\(String(format: "%.4f", expectedDuration))s "
              + "drift=\(String(format: "%.4f", drift))s lastFramePTS=\(String(format: "%.4f", lastFramePTS))s frameInterval=\(String(format: "%.4f", frameInterval))s "
              + "(no audio track in this synthetic fixture — real A/V drift needs a recorded package with mic/system audio)")
        let framePass = abs(drift) < frameInterval
        print("video duration within 1 frame of expected: \(framePass ? "PASS" : "FAIL")")

        guard pass1 else { throw Fail(description: "AC-EXP-1 FAILED: export took \(elapsed)s, budget \(budget)s") }
    }

    /// Fills a `CVPixelBuffer` per frame with a hue-cycling background (`memset_pattern4`, cheap) plus a
    /// small bouncing rectangle, so the HEVC encoder sees genuinely changing content — not a fixture
    /// concern for the export loop itself, but avoids measuring an unrealistically-fast "all identical
    /// frames" encode.
    private static func synthesizeMovingMovie(at url: URL, width: Int, height: Int, fps: Int32, frameCount: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw Fail(description: "fixture writer failed to start: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let rectSize = min(220, min(width, height) / 4)
        var frame = 0
        while frame < frameCount {
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            guard let pool = adaptor.pixelBufferPool else { throw Fail(description: "no pixel buffer pool") }
            var pixelBufferOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOpt)
            guard let pixelBuffer = pixelBufferOpt else { throw Fail(description: "CVPixelBufferPoolCreatePixelBuffer failed") }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

            let t = Double(frame) / Double(fps)
            let hue = (t / 6).truncatingRemainder(dividingBy: 1)
            let (r, g, b) = hsvToRGB(hue: hue, s: 0.5, v: 0.35)
            let bg: [UInt8] = [b, g, r, 255]
            bg.withUnsafeBufferPointer { p in memset_pattern4(base, p.baseAddress!, bytesPerRow * height) }

            let rx = max(0, min(width - rectSize, Int((0.5 + 0.4 * sin(t * 0.7)) * Double(width - rectSize))))
            let ry = max(0, min(height - rectSize, Int((0.5 + 0.4 * cos(t * 0.9)) * Double(height - rectSize))))
            let fg: [UInt8] = [255, 255, 255, 255]
            fg.withUnsafeBufferPointer { p in
                for row in ry..<(ry + rectSize) {
                    memset_pattern4(base.advanced(by: row * bytesPerRow + rx * 4), p.baseAddress!, rectSize * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            frame += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Fail(description: "fixture writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

    private static func hsvToRGB(hue: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
        let i = Int(hue * 6) % 6
        let f = hue * 6 - Double(Int(hue * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return (UInt8(max(0, min(255, r * 255))), UInt8(max(0, min(255, g * 255))), UInt8(max(0, min(255, b * 255))))
    }

    // MARK: - record-perf (AC-REC-1, AC-REC-4)

    /// TCC-gated: records the main display for `seconds` via `CaptureSession` (real, unmodified public
    /// API), sampling this process's CPU once a second, then inspects the resulting `screen.mov` for
    /// frame count, codec and decoded pixel format. Always deletes its temp package, even on failure.
    static func runRecordPerf(_ args: [String]) async throws {
        let seconds = max(1, Int((args.first.flatMap(Double.init) ?? 20).rounded()))
        guard let display = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).displays.first else {
            throw Fail(description: "no display found (Screen Recording permission likely not granted)")
        }
        let target = CaptureTarget.display(display)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-selftest-record-perf-\(UUID().uuidString).recorder")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let session = try await CaptureSession(target: target, settings: RecordingSettings.shared, packageURL: packageURL)
        try await session.start()

        var cpuSamples: [Double] = []
        var (lastCPU, _) = ProcStats.snapshot()
        var lastWall = Date()
        for _ in 0..<seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let now = Date()
            let (cpu, _) = ProcStats.snapshot()
            let wallDelta = now.timeIntervalSince(lastWall)
            if wallDelta > 0 { cpuSamples.append((cpu - lastCPU) / wallDelta * 100) }
            lastCPU = cpu; lastWall = now
        }
        let source = try await session.finish()

        let avgCPU = cpuSamples.reduce(0, +) / Double(max(cpuSamples.count, 1))
        let maxCPU = cpuSamples.max() ?? 0
        print("record-perf: \(cpuSamples.count) 1s CPU samples avg=\(String(format: "%.1f", avgCPU))% max=\(String(format: "%.1f", maxCPU))% of one core "
              + "(source.duration=\(String(format: "%.2f", source.duration))s)")
        let cpuPass = avgCPU < 25
        print("AC-REC-1 (avg CPU < 25% of one core): \(cpuPass ? "PASS" : "FAIL") — avg \(String(format: "%.1f", avgCPU))%")

        let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Fail(description: "screen.mov has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        let expectedIfAnimating = Int((duration * 60).rounded())

        // Delivered frame count: count compressed samples (no decode).
        let countReader = try AVAssetReader(asset: asset)
        let countOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        countReader.add(countOutput)
        guard countReader.startReading() else { throw Fail(description: "frame-count reader failed to start") }
        var delivered = 0
        while countOutput.copyNextSampleBuffer() != nil { delivered += 1 }
        print("record-perf: duration=\(String(format: "%.2f", duration))s delivered=\(delivered) frames, "
              + "expectedIfAnimating≈\(expectedIfAnimating) frames (60fps × duration — ScreenCaptureKit only delivers a frame when content changes, "
              + "so `delivered` is expected to be far lower on a mostly-static desktop, not a bug)")
        print("record-perf: dropped/late frame count: not exposed by CaptureSession's public API (no counter to read without editing Recording/CaptureSession.swift)")

        guard let formatDesc = try await track.load(.formatDescriptions).first else {
            throw Fail(description: "no format description on screen.mov's video track")
        }
        let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
        let codecStr = fourCC(codecType)
        let isHEVC = codecType == kCMVideoCodecType_HEVC
        print("record-perf: codec=\(codecStr) isHEVC=\(isHEVC)")

        // An empty `outputSettings` dictionary (asking for "whatever's native") throws
        // `NSInvalidArgumentException` on this toolchain — request the exact format `Exporter.swift`'s
        // own `decodeSettings` already decodes `screen.mov` as (420v), the format that actually matters
        // (it's what the rest of the pipeline consumes), and confirm the decode succeeds in it.
        let pixelReader = try AVAssetReader(asset: asset)
        let pixelOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        pixelReader.add(pixelOutput)
        var pixelFormatStr = "?"
        if pixelReader.startReading(), let sb = pixelOutput.copyNextSampleBuffer(), let imageBuffer = CMSampleBufferGetImageBuffer(sb) {
            pixelFormatStr = fourCC(CVPixelBufferGetPixelFormatType(imageBuffer))
        }
        print("record-perf: decodes as pixel format=\(pixelFormatStr) (requested 420v, matching Exporter's own decode settings — not a probe of the encoder's untouched native format)")

        guard isHEVC else { throw Fail(description: "codec \(codecStr) != HEVC") }
        guard cpuPass else { throw Fail(description: "AC-REC-1 FAILED: avg CPU \(avgCPU)% >= 25%") }
    }

    // MARK: - idle-perf (AC-APP-3, lower bound only)

    /// No UI is launched (a headlessly-hosted toolbar panel isn't meaningfully "idle app" per the task) —
    /// this only reports the selftest process's own RSS/CPU while its run loop spins, clearly labelled
    /// as a lower bound. Never PASS/FAIL, per the task.
    static func runIdlePerf(_ args: [String]) async throws {
        let seconds = max(1, Int((args.first.flatMap(Double.init) ?? 10).rounded()))
        let mb = 1024.0 * 1024.0

        var (lastCPU, rss0) = ProcStats.snapshot()
        var rssSamples: [UInt64] = [rss0]
        var cpuPctSamples: [Double] = []
        var lastWall = Date()
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            let now = Date()
            let (cpu, rss) = ProcStats.snapshot()
            let wallDelta = now.timeIntervalSince(lastWall)
            if wallDelta > 0 { cpuPctSamples.append((cpu - lastCPU) / wallDelta * 100) }
            rssSamples.append(rss)
            lastCPU = cpu; lastWall = now
        }

        let avgCPU = cpuPctSamples.reduce(0, +) / Double(max(cpuPctSamples.count, 1))
        let maxCPU = cpuPctSamples.max() ?? 0
        let avgRSS = Double(rssSamples.reduce(0, +)) / Double(max(rssSamples.count, 1))
        let maxRSS = rssSamples.max() ?? 0
        print("idle-perf [LOWER BOUND, not PASS/FAIL — headless selftest process, run loop spinning, no toolbar/panel UI hosted; "
              + "AC-APP-3 (< 1% CPU, < 150 MB RAM) describes the real app idle at the toolbar, which this cannot construct headlessly]:")
        print("  avg CPU=\(String(format: "%.2f", avgCPU))% max CPU=\(String(format: "%.2f", maxCPU))% of one core, "
              + "avg RSS=\(String(format: "%.1f", avgRSS / mb)) MB max RSS=\(String(format: "%.1f", Double(maxRSS) / mb)) MB, over \(seconds)s")
    }

    // MARK: - shared helpers

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "0x" + String(code, radix: 16)
    }
}

/// This process's cumulative CPU time (user+system, seconds) and current resident set size (bytes),
/// via `proc_pid_rusage`/`RUSAGE_INFO_V2` (Darwin, `<sys/resource.h>`) — no XCTest/Instruments needed.
private enum ProcStats {
    static func snapshot() -> (cpuSeconds: Double, rssBytes: UInt64) {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return (0, 0) }
        let cpu = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
        return (cpu, info.ri_resident_size)
    }
}
