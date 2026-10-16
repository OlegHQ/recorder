import AppKit
import AVFoundation
import CoreMedia
import Metal
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
        try await synthesizeTestScreenMovie(at: tmp.appendingPathComponent("screen.mov"), frameCount: 10)
        try synthesizeToneM4A(at: tmp.appendingPathComponent("mic.m4a"), duration: duration, amplitude: 0.5)

        let project = Project(title: "Audio Mix",
                               source: Source(kind: .display, pixelWidth: 320, pixelHeight: 180, scale: 1, duration: duration, hasMic: true),
                               clips: [Clip(sourceStart: 0, sourceEnd: duration, speed: 1)])
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

        model.edit("Microphone volume") { $0.audioTracks[0].volume = 0.2 }
        try await waitUntil { view.currentItemForTest?.audioMix !== audioMixBefore }
        guard view.currentItemForTest === itemBefore else {
            throw Fail(description: "an audio-only edit replaced the AVPlayerItem (should rebuild only the AVAudioMix)")
        }

        model.edit("Mute microphone") { $0.audioTracks[0].muted = true }
        let audioMixAfterMute = view.currentItemForTest?.audioMix
        try await waitUntil { view.currentItemForTest?.audioMix !== audioMixAfterMute }
        guard view.currentItemForTest === itemBefore else {
            throw Fail(description: "muting replaced the AVPlayerItem")
        }
        // Back to a known state (full volume, unmuted) for the export checks below.
        model.edit("Restore mic") { $0.audioTracks[0].muted = false; $0.audioTracks[0].volume = 1 }
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

        // Cancellation after the old stall point must stop promptly and remove the partial MP4.
        let cancelURL = tmp.appendingPathComponent("cancelled.mp4")
        let cancelledExport = Exporter(model: model, settings: ExportSettings(shortEdge: 180, fps: 30), destination: cancelURL)
        var cancelledAt: ContinuousClock.Instant?
        cancelledExport.progress = { [weak cancelledExport] _, frame, _ in
            if frame == 32 {
                cancelledAt = ContinuousClock.now
                cancelledExport?.cancel()
            }
        }
        do {
            try await cancelledExport.run()
            throw Fail(description: "cancelled export unexpectedly completed")
        } catch Exporter.ExportError.cancelled { }
        guard let cancelledAt, ContinuousClock.now - cancelledAt < .seconds(1),
              !fm.fileExists(atPath: cancelURL.path) else {
            throw Fail(description: "mid-export cancellation was slow or left a partial file")
        }
        print("audio-mix: cancellation at frame 32 completed within 1 s and removed partial file")

        // (c) denoise: peak normalised to ≈ −1 dBFS (0.891 linear). Mic must be un-muted/full-volume
        // here — the last `exportAndMeasureRMS` call above (`muted`) left the microphone track muted.
        model.edit("Denoise") { $0.audio.denoise = true; $0.audioTracks[0].muted = false; $0.audioTracks[0].volume = 1 }
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
        clickProject.audioTracks = []; clickProject.audioClips = []
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

    @MainActor
    static func runLanes() async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        let manager = FileManager.default
        let package = manager.temporaryDirectory.appendingPathComponent("recorder-audio-lanes-\(UUID().uuidString)")
        try manager.createDirectory(at: package.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: package) }
        try await synthesizeTestScreenMovie(at: package.appendingPathComponent("screen.mov"), frameCount: 40)
        try manager.copyItem(at: package.appendingPathComponent("screen.mov"), to: package.appendingPathComponent("camera.mov"))
        try synthesizeToneM4A(at: package.appendingPathComponent("mic.m4a"), duration: 8, amplitude: 0.18)
        try synthesizeToneM4A(at: package.appendingPathComponent("system.m4a"), duration: 8, amplitude: 0.08, frequency: 440)
        try synthesizeToneM4A(at: package.appendingPathComponent("media/music.m4a"), duration: 3, amplitude: 0.12, frequency: 880)
        let toneURL = package.appendingPathComponent("media/video-tone.m4a")
        try synthesizeToneM4A(at: toneURL, duration: 1, amplitude: 0.1, frequency: 660)
        let movieAsset = AVURLAsset(url: package.appendingPathComponent("screen.mov")), toneAsset = AVURLAsset(url: toneURL)
        let movie = AVMutableComposition()
        try await movie.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: movieAsset, at: .zero)
        guard let tone = try await toneAsset.loadTracks(withMediaType: .audio).first,
              let sound = movie.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let writer = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else { throw Fail(description: "video sound fixture") }
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: tone, at: .zero)
        try await writer.export(to: package.appendingPathComponent("media/sound.mov"), as: .mov)
        withExtendedLifetime((movieAsset, toneAsset)) {}
        guard let waveformURL = Waveform.audioURL(in: package, file: "media/sound.mov") else { throw Fail(description: "video waveform file") }
        let videoPeaks = try await Waveform.peaks(for: waveformURL)
        guard videoPeaks.count >= 200, (videoPeaks.max() ?? 0) > 0.05 else { throw Fail(description: "video audio waveform") }
        print("audio-lanes: video-file waveform decoded \(videoPeaks.count) peaks")

        let legacyJSON = """
        {"version":3,"source":{"pixelWidth":320,"pixelHeight":180,"duration":8,"hasCamera":true,"hasMic":true,"hasSystemAudio":true},
         "clips":[{"sourceStart":0,"sourceEnd":2,"speed":1},{"sourceStart":2,"sourceEnd":3,"speed":1,"isGap":true},
                  {"sourceStart":4,"sourceEnd":6,"speed":2},{"sourceStart":6,"sourceEnd":8,"speed":1}],
         "audio":{"micVolume":0.6,"systemVolume":0.5},"keys":{"show":true,"hold":3}}
        """
        try Data(legacyJSON.utf8).write(to: package.appendingPathComponent("project.json"))
        let legacy = try Project.load(from: package.appendingPathComponent("project.json"))
        let (composition, _, tracks, _, _, _) = try await makeComposition(package: package, project: legacy)
        func compare(_ actual: [AVCompositionTrack], _ expected: [AVCompositionTrack]) throws {
            guard actual.count == expected.count else { throw Fail(description: "audio track count \(actual.count), expected \(expected.count)") }
            for (actualTrack, expectedTrack) in zip(actual, expected) {
                guard actualTrack.segments.count == expectedTrack.segments.count else { throw Fail(description: "segment count") }
                for (actualSegment, expectedSegment) in zip(actualTrack.segments, expectedTrack.segments) {
                    let actualRange = actualSegment.timeMapping, expectedRange = expectedSegment.timeMapping
                    guard actualSegment.isEmpty == expectedSegment.isEmpty,
                          abs(actualRange.target.start.seconds - expectedRange.target.start.seconds) < 0.002,
                          abs(actualRange.target.duration.seconds - expectedRange.target.duration.seconds) < 0.002 else { throw Fail(description: "output segment mismatch") }
                    if !actualSegment.isEmpty {
                        guard abs(actualRange.source.start.seconds - expectedRange.source.start.seconds) < 0.002,
                              abs(actualRange.source.duration.seconds - expectedRange.source.duration.seconds) < 0.002 else { throw Fail(description: "media segment mismatch") }
                    }
                }
            }
        }
        let reference = AVMutableComposition()
        var referenceAssets: [AVURLAsset] = []
        for file in ["mic.m4a", "system.m4a"] {
            let asset = AVURLAsset(url: package.appendingPathComponent(file))
            referenceAssets.append(asset)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = reference.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Fail(description: "legacy reference") }
            var cursor = CMTime.zero
            for clip in legacy.clips {
                let duration = CMTime(seconds: clip.outputDuration, preferredTimescale: 600)
                if clip.isEmpty { track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration)) }
                else {
                    let range = CMTimeRange(start: CMTime(seconds: clip.mediaIn, preferredTimescale: 600), duration: CMTime(seconds: clip.mediaDuration, preferredTimescale: 600))
                    try track.insertTimeRange(range, of: source, at: cursor)
                    track.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: duration)
                }
                cursor = cursor + duration
            }
        }
        try compare(tracks, reference.tracks(withMediaType: .audio))
        withExtendedLifetime(referenceAssets) {}
        guard abs(composition.duration.seconds - 6) < 0.002 else { throw Fail(description: "legacy duration") }
        print("audio-lanes: legacy cuts, 2x and gap match the original Mic/System segment lists")
        let shortLegacy = Project(source: legacy.source, clips: [Clip(sourceStart: 0, sourceEnd: 0.1, speed: 2)])
        let (shortComposition, _, _, _, _, _) = try await makeComposition(package: package, project: shortLegacy)
        guard abs(shortComposition.duration.seconds - 0.05) < 0.002 else { throw Fail(description: "short legacy cut lost audio") }
        let fractionalClips = (0..<53).map { index in
            Clip(sourceStart: Double(index) * 0.15, sourceEnd: Double(index + 1) * 0.15, speed: 1.3)
        }
        let fractional = Project(source: legacy.source, clips: fractionalClips)
        let (fractionalComposition, _, fractionalAudio, _, _, _) = try await makeComposition(package: package, project: fractional)
        guard let video = fractionalComposition.tracks(withMediaType: .video).first else { throw Fail(description: "fractional video") }
        let videoSegments = video.segments.filter { !$0.isEmpty }, audioSegments = fractionalAudio[0].segments.filter { !$0.isEmpty }
        guard videoSegments.count == audioSegments.count else {
            throw Fail(description: "fractional segment count video=\(videoSegments.count) audio=\(audioSegments.count)")
        }
        for (video, audio) in zip(videoSegments, audioSegments) {
            guard abs(video.timeMapping.target.start.seconds - audio.timeMapping.target.start.seconds) < 0.001,
                  abs(video.timeMapping.target.duration.seconds - audio.timeMapping.target.duration.seconds) < 0.001 else { throw Fail(description: "fractional-cut audio/video drift") }
        }
        print("audio-lanes: 53 fractional-speed cuts share exact audio/video boundaries")

        let events = EventLog(events: [InputEvent(t: 7.5, k: .key, keyCode: 8, mods: 0x100000)])
        let model = EditorModel(packageURL: package, project: legacy, events: events)
        let preview = PreviewView(model: model)
        preview.setFrameSize(NSSize(width: 320, height: 180))
        func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw Fail(description: message) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await waitUntil("legacy preview", { preview.currentItemForTest?.status == .readyToPlay })
        let originalItem = preview.currentItemForTest
        guard let mic = legacy.audioClips.first(where: { $0.file == "mic.m4a" }), let micID = UUID(uuidString: mic.id) else { throw Fail(description: "derived mic") }
        let layer = LayerBlock(kind: .video, start: 0, end: 0.5, file: "media/sound.mov", mediaStart: 0.25, rect: NormRect())
        let imported = AudioClip(start: 6.5, end: 9.5, file: "media/music.m4a", track: 2, gain: 0.5)
        model.edit("Detach mic and add media") { project in
            _ = project.unlinkAudio(micID)
            project.moveAudio(micID, toStart: 1, propagate: false)
            project.audioTracks += [AudioTrack(name: "Audio 1"), AudioTrack(name: "Audio 2")]
            project.layers.append(layer)
            project.audioClips += [imported, AudioClip(start: 0, end: 0.5, mediaStart: 0.25, file: layer.file,
                                                      track: 3, link: .layer, layer: layer.id, gain: 2)]
            project.audioClips.sort { $0.start < $1.start }
        }
        try await waitUntil("new tracks did not rebuild preview", { preview.currentItemForTest !== originalItem && preview.currentItemForTest?.status == .readyToPlay })
        let itemBeforeMove = preview.currentItemForTest
        model.edit("Move imported sound") { $0.moveAudio(UUID(uuidString: imported.id)!, toStart: 6, propagate: false) }
        try await waitUntil("audio move did not rebuild preview", { preview.currentItemForTest !== itemBeforeMove && preview.currentItemForTest?.status == .readyToPlay })
        guard let live = preview.currentItemForTest else { throw Fail(description: "no live composition") }
        let edits: [(String, (inout Project) -> Void)] = [
            ("Gain", { project in if let index = project.audioClips.firstIndex(where: { $0.id == mic.id }) { project.audioClips[index].gain = 0.75 } }),
            ("Fades", { project in if let index = project.audioClips.firstIndex(where: { $0.id == mic.id }) { project.audioClips[index].fadeIn = 0.5; project.audioClips[index].fadeOut = 0.5 } }),
            ("Mute", { $0.audioTracks[1].muted = true }),
            ("Track volume", { $0.audioTracks[2].volume = 0.5 }),
            ("Boost", { $0.audioTracks[3].volume = 2 })
        ]
        for (name, edit) in edits {
            let oldMix = live.audioMix
            model.edit(name, edit)
            try await waitUntil("\(name) did not refresh mix", { preview.currentItemForTest?.audioMix !== oldMix })
            guard preview.currentItemForTest === live else { throw Fail(description: "\(name) replaced the player item") }
        }
        let (exportComposition, _, exportTracks, _, _, _) = try await makeComposition(package: package, project: model.project)
        guard let previewComposition = live.asset as? AVComposition, exportTracks.count == 4 else { throw Fail(description: "four-track composition") }
        try compare(previewComposition.tracks(withMediaType: .audio), exportTracks)
        guard abs(exportComposition.duration.seconds - 7) < 0.002, model.project.exportDuration == 7 else { throw Fail(description: "audio tail missing") }
        preview.seek(toOutput: 6.5)
        guard model.playhead == 6.5, let device = preview.device,
              let texture = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)) else { throw Fail(description: "audio tail seek") }
        let stale = FrameState.Texture(luma: texture)
        let tail = makeFrameState(model: model, outputTime: 6.5, screen: stale, camera: stale, size: CGSize(width: 320, height: 180))
        guard tail.screen == nil, tail.camera == nil, tail.keyChip == nil else { throw Fail(description: "expired footage/keys leaked into audio tail") }
        print("audio-lanes: four tracks match preview/export; moves rebuild; gain/fades/mute/volume keep the player item")

        let destination = package.appendingPathComponent("multi-track.mp4")
        try await runExport(model: model, destination: destination)
        var samples = try await decodePCM(url: destination)
        func amplitude(_ frequency: Double, at time: Double, radius: Double = 0.06) -> Double {
            let lower = max(0, Int((time - radius) * 44_100)), upper = min(samples.count, Int((time + radius) * 44_100))
            guard upper > lower else { return 0 }
            var sine = 0.0, cosine = 0.0
            for index in lower..<upper {
                let phase = 2 * Double.pi * frequency * Double(index) / 44_100
                sine += Double(samples[index]) * sin(phase); cosine += Double(samples[index]) * cos(phase)
            }
            return 2 * hypot(sine, cosine) / Double(upper - lower)
        }
        let micBefore = amplitude(220, at: 0.75), micDuring = amplitude(220, at: 1.75)
        let fade = amplitude(220, at: 1.08, radius: 0.02), importedTail = amplitude(880, at: 6.5)
        let muted = amplitude(440, at: 0.75), videoSound = amplitude(660, at: 0.25), spedMic = amplitude(220, at: 3.5)
        print("audio-lanes: decoded mic before=\(micBefore) during=\(micDuring) fade=\(fade) sped=\(spedMic), imported tail=\(importedTail), muted=\(muted), video gain=\(videoSound)")
        guard micBefore < 0.004, micDuring > 0.065, micDuring < 0.095, fade < micDuring * 0.4,
              spedMic > 0.08, spedMic < 0.13, importedTail > 0.015, importedTail < 0.045, muted < 0.004, videoSound > 0.32, videoSound < 0.48 else {
            throw Fail(description: "decoded tones do not match clip timing, gain, fades or mute")
        }
        guard samples.count > Int(6.8 * 44_100) else { throw Fail(description: "export truncated audio tail") }
        let videoBeforeDetach = model.project.layers
        guard let sound = model.project.audioClips.first(where: { $0.layer == layer.id }), let soundID = UUID(uuidString: sound.id) else { throw Fail(description: "missing linked layer sound") }
        model.edit("Detach and move layer sound") { project in
            _ = project.unlinkAudio(soundID)
            project.moveAudio(soundID, toOutput: 4.5, propagate: false)
        }
        guard model.project.layers == videoBeforeDetach, model.project.audioClips.first(where: { $0.id == sound.id })?.link == nil else { throw Fail(description: "detached sound moved the video") }
        let detachedMovie = package.appendingPathComponent("detached-layer-sound.mp4")
        try await runExport(model: model, destination: detachedMovie)
        samples = try await decodePCM(url: detachedMovie)
        let oldSound = amplitude(660, at: 0.25), movedSound = amplitude(660, at: 4.75)
        guard oldSound < 0.004, movedSound > 0.32, movedSound < 0.48 else { throw Fail(description: "detached video sound played at the wrong output time: \(oldSound), \(movedSound)") }
        print("audio-lanes: detached layer sound moved independently; decoded old=\(oldSound), moved=\(movedSound)")
        var invalid = model.project
        invalid.audioClips[0].file = "../outside.m4a"
        let protected = package.appendingPathComponent("existing.mp4")
        let existing = Data("keep existing export".utf8)
        try existing.write(to: protected)
        let invalidModel = EditorModel(packageURL: package, project: invalid, events: EventLog())
        do {
            try await Exporter(model: invalidModel, settings: ExportSettings(shortEdge: 180, fps: 30), destination: protected).run()
            throw Fail(description: "accepted a package traversal")
        } catch FrameSourceError.invalidMediaPath { }
        guard try Data(contentsOf: protected) == existing else { throw Fail(description: "invalid media deleted an existing export") }
        var missing = legacy
        missing.audioTracks = [AudioTrack(name: "Audio 1")]
        missing.audioClips = [AudioClip(start: 0, end: 1, file: "media/missing.m4a")]
        let missingModel = EditorModel(packageURL: package, project: missing, events: EventLog())
        let missingPreview = PreviewView(model: missingModel)
        try await waitUntil("missing-media preview", { missingPreview.currentItemForTest?.status == .readyToPlay })
        let silent = package.appendingPathComponent("missing-media.mp4")
        try await runExport(model: missingModel, destination: silent)
        guard try await decodePCM(url: silent).isEmpty else { throw Fail(description: "missing media generated audio") }
        print("audio-lanes: audio/video files, detached timing, fades, gain above unity, mute, tail and missing-media export verified")
    }

    /// Sets microphone track mixing, exports, and returns the
    /// exported file's RMS — callers reuse the same `model` across several export variants.
    @MainActor
    private static func exportAndMeasureRMS(model: EditorModel, tmp: URL, micVolume: Double, micMuted: Bool) async throws -> Float {
        model.edit("Mic settings") { $0.audioTracks[0].volume = micVolume; $0.audioTracks[0].muted = micMuted }
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
        settings.fps = 30  // 60 frames exceeds the writer queue that stalled at frame 32.
        let exporter = Exporter(model: model, settings: settings, destination: destination)
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            exporter.cancel()
        }
        defer { watchdog.cancel() }
        try await exporter.run()
        let asset = AVURLAsset(url: destination)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SelfTestArgError.usage("audio-mix export has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { throw SelfTestArgError.usage("cannot read exported video") }
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        let expected = Int((model.project.exportDuration * Double(settings.fps)).rounded())
        guard reader.status == .completed, frames == expected else {
            throw SelfTestArgError.usage("audio-mix video frames \(frames), expected \(expected)")
        }
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
