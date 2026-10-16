import AVFoundation
import CoreVideo
import Metal
import RecorderCore

enum FrameSourceError: Error {
    case missingScreenTrack, trackCreationFailed
    case invalidProject(String), invalidMediaPath(String), missingAudioTrack(String)
}

/// One SDR working space from capture through preview, stills and video encoding.
enum VideoColor {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let properties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
}

/// Shared preview/export composition; audio track indices match `Project.audioTracks`.
/// `micURL` overrides only `mic.m4a` for export cleanup. Assets stay alive through all insertions.
func makeComposition(package: URL, project: Project, micURL: URL? = nil) async throws
    -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix, audioTracks: [AVMutableCompositionTrack]) {
    guard project.clips.allSatisfy({ $0.timeScale.isFinite && $0.timeScale > 0 && $0.outputDuration.isFinite && $0.outputDuration > 0 }),
          project.audioTracks.allSatisfy({ $0.volume.isFinite && (0...2).contains($0.volume) }) else {
        throw FrameSourceError.invalidProject("Invalid video clock or track volume")
    }
    let composition = AVMutableComposition()

    // Every `AVURLAsset` below is kept alive (a `var …Asset: AVURLAsset?` at function scope, not a
    // `let` scoped inside its own `if`) until the `insertTimeRange` calls near the bottom finish —
    // T-502 fix: an asset scoped only inside its `if project.source.has…` block gets deallocated
    // (tearing down its decode session) as soon as that block exits, even though the `AVAssetTrack`
    // extracted from it is still held; a *later* `insertTimeRange(_:of:at:)` using that track then
    // fails with a generic `AVFoundationErrorDomain` -11800/-12780 (confirmed by reproducing it with
    // a minimal two-video-track composition: identical code succeeds when the source asset is kept
    // alive in an outer scope, fails when it's only reachable via its already-extracted track).
    var screenAssetKeepAlive: AVURLAsset?
    var cameraAssetKeepAlive: AVURLAsset?
    var audioAssets: [String: AVURLAsset] = [:]
    var audioSources: [String: AVAssetTrack] = [:]

    let screenAsset = AVURLAsset(url: package.appendingPathComponent("screen.mov"))
    screenAssetKeepAlive = screenAsset
    guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
        throw FrameSourceError.missingScreenTrack
    }
    guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw FrameSourceError.trackCreationFailed
    }

    var cameraTrack: AVMutableCompositionTrack?
    var cameraSource: AVAssetTrack?
    if project.source.hasCamera && !project.cameraClips.isEmpty {
        let cameraAsset = AVURLAsset(url: package.appendingPathComponent("camera.mov"))
        cameraAssetKeepAlive = cameraAsset
        cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first
        if cameraSource != nil {
            cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    var audioTracks: [AVMutableCompositionTrack] = []
    for _ in project.audioTracks {
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FrameSourceError.trackCreationFailed
        }
        audioTracks.append(track)
    }

    // Windows 1…N (SPEC "Windows as layers") play through the same one screen track, switched by
    // `windowShots`, so preview and export keep decoding a single screen track. A missing file falls back to window 0.
    var windowSources: [AVAssetTrack] = [screenSource]
    var windowAssetsKeepAlive: [AVURLAsset] = []
    for i in 1..<max(1, project.windowCount) {
        let asset = AVURLAsset(url: package.appendingPathComponent("window-\(i).mov"))
        windowAssetsKeepAlive.append(asset)
        windowSources.append(try await asset.loadTracks(withMediaType: .video).first ?? screenSource)
    }

    let timescale: CMTimeScale = 600
    var cursor = CMTime.zero
    var outputSeconds = 0.0
    for clip in project.clips {
        let outputEnd = CMTime(seconds: outputSeconds + clip.outputDuration, preferredTimescale: timescale)
        let outputDuration = outputEnd - cursor
        defer { outputSeconds += clip.outputDuration; cursor = outputEnd }
        guard outputDuration > .zero else { continue }
        // Gaps decode one valid placeholder frame; the compositor draws only the background.
        let mediaDuration = clip.isEmpty ? min(project.source.duration, 1.0 / 30) : clip.mediaDuration
        let range = CMTimeRange(start: CMTime(seconds: clip.isEmpty ? 0 : clip.mediaIn, preferredTimescale: timescale),
                                end: CMTime(seconds: (clip.isEmpty ? 0 : clip.mediaIn) + mediaDuration, preferredTimescale: timescale))
        if project.windowCount > 1 && !clip.isEmpty {
            // One piece per shot boundary inside the clip; the last piece absorbs rounding so the clip stays exact.
            let edges = project.windowShots.flatMap { [$0.start, $0.end] }
            var lo = clip.sourceStart
            var at = cursor
            while lo < clip.sourceEnd - 1e-9 {
                let hi = min(clip.sourceEnd, edges.filter { $0 > lo + 1e-9 }.min() ?? clip.sourceEnd)
                let piece = CMTimeRange(start: CMTime(seconds: clip.mediaTime(atSource: lo), preferredTimescale: timescale),
                                        end: CMTime(seconds: clip.mediaTime(atSource: hi), preferredTimescale: timescale))
                let pieceOut = hi >= clip.sourceEnd - 1e-9 ? outputEnd - at
                    : CMTime(seconds: outputSeconds + (hi - clip.sourceStart) / clip.timeScale, preferredTimescale: timescale) - at
                try screenTrack.insertTimeRange(piece, of: windowSources[project.windowIndex(atSource: lo)], at: at)
                screenTrack.scaleTimeRange(CMTimeRange(start: at, duration: piece.duration), toDuration: pieceOut)
                at = at + pieceOut
                lo = hi
            }
        } else {
            try screenTrack.insertTimeRange(range, of: screenSource, at: cursor)
            screenTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outputDuration)
        }
    }

    // Compose camera independently. Screen cuts and gaps never remove camera footage.
    if let cameraTrack, let cameraSource {
        let map = TimeMap(project.clips)
        for camera in project.cameraClips {
            for clip in project.clips {
                let lo = max(camera.start, clip.sourceStart), hi = min(camera.end, clip.sourceEnd)
                guard hi > lo, let out = map.outputTime(atSource: lo) else { continue }
                let range = CMTimeRange(start: CMTime(seconds: camera.mediaStart + (lo - camera.start) * (camera.mediaRate ?? 1), preferredTimescale: timescale),
                                        end: CMTime(seconds: camera.mediaStart + (hi - camera.start) * (camera.mediaRate ?? 1), preferredTimescale: timescale))
                let at = CMTime(seconds: out, preferredTimescale: timescale)
                try cameraTrack.insertTimeRange(range, of: cameraSource, at: at)
                let end = CMTime(seconds: out + (hi - lo) / clip.timeScale, preferredTimescale: timescale)
                cameraTrack.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: end - at)
            }
        }
    }

    let packageRoot = package.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    for audio in project.audioClips {
        guard audioTracks.indices.contains(audio.track), audio.start.isFinite, audio.start >= 0,
              audio.end.isFinite, audio.end > audio.start, audio.mediaStart.isFinite, audio.mediaStart >= 0,
              (audio.mediaRate ?? 1).isFinite, (audio.mediaRate ?? 1) > 0, audio.gain.isFinite, (0...2).contains(audio.gain),
              [audio.fadeIn, audio.fadeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw FrameSourceError.invalidProject("Invalid audio clip \(audio.id)")
        }
        let fileURL = package.appendingPathComponent(audio.file).standardizedFileURL.resolvingSymlinksInPath()
        guard !audio.file.isEmpty, !audio.file.hasPrefix("/"), fileURL.path.hasPrefix(packageRoot) else { throw FrameSourceError.invalidMediaPath(audio.file) }
        let url = audio.file == "mic.m4a" ? micURL ?? fileURL : fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        if audioSources[audio.file] == nil {
            let asset = AVURLAsset(url: url)
            audioAssets[audio.file] = asset
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw FrameSourceError.missingAudioTrack(audio.file)
            }
            audioSources[audio.file] = source
        }
        guard let source = audioSources[audio.file] else { continue }
        let track = audioTracks[audio.track]
        for segment in project.audioSegments(audio) {
            let range = CMTimeRange(start: CMTime(seconds: segment.media.start, preferredTimescale: timescale),
                                    end: CMTime(seconds: segment.media.end, preferredTimescale: timescale))
            let at = CMTime(seconds: segment.output.start, preferredTimescale: timescale)
            let duration = CMTime(seconds: segment.output.end, preferredTimescale: timescale) - at
            guard range.duration.isNumeric, range.start.isNumeric, range.duration > .zero, at.isNumeric, duration.isNumeric, duration > .zero else {
                throw FrameSourceError.invalidProject("Unrepresentable audio segment \(audio.id)")
            }
            try track.insertTimeRange(range, of: source, at: at)
            track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: duration)
        }
    }
    let duration = CMTime(seconds: project.exportDuration, preferredTimescale: timescale)
    if duration > composition.duration {
        composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration))
    }
    withExtendedLifetime((screenAssetKeepAlive, cameraAssetKeepAlive, audioAssets, windowAssetsKeepAlive)) {}
    return (composition, makeAudioMix(project: project, audioTracks: audioTracks), audioTracks)
}

/// Gain, fades and track mixing can refresh on the existing player's tracks without rebuilding media.
func makeAudioMix(project: Project, audioTracks: [AVMutableCompositionTrack]) -> AVMutableAudioMix {
    var inputParameters: [AVMutableAudioMixInputParameters] = []
    for (index, track) in audioTracks.enumerated() where project.audioTracks.indices.contains(index) {
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTimePitchAlgorithm = .spectral
        params.setVolume(0, at: .zero)
        let settings = project.audioTracks[index]
        let volume = settings.muted ? 0 : settings.volume
        for audio in project.audioClips where audio.track == index {
            let ramps = project.audioVolumeRamps(audio)
            for ramp in ramps {
                let range = CMTimeRange(start: CMTime(seconds: ramp.range.start, preferredTimescale: 600),
                                        end: CMTime(seconds: ramp.range.end, preferredTimescale: 600))
                params.setVolumeRamp(fromStartVolume: Float(volume * ramp.start), toEndVolume: Float(volume * ramp.end), timeRange: range)
            }
            if let end = ramps.last?.range.end { params.setVolume(0, at: CMTime(seconds: end, preferredTimescale: 600)) }
        }
        inputParameters.append(params)
    }
    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = inputParameters
    return audioMix
}

/// `AVPlayerItemVideoOutput` has no per-track selection — it always yields the composited/"current"
/// video, so a second simultaneous track (camera, T-502) needs its own single-track composition to
/// get its own output. Copies `track`'s already-composed timeline (any `scaleTimeRange` a caller
/// applied to the parent composition is baked into `track`'s segments) into a fresh composition.
/// Shared by `PreviewView`'s live camera output and the `preview-frame`/`parity` selftests, which
/// build the same "preview path" outside `PreviewView`.
func isolateTrack(_ track: AVAssetTrack, duration: CMTime) -> AVMutableComposition {
    let isolated = AVMutableComposition()
    if let newTrack = isolated.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try? newTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
    }
    return isolated
}

/// Zero-copy `CVPixelBuffer` → `MTLTexture`, cached per-buffer generation by `CVMetalTextureCache`.
final class TextureCache {
    private let cache: CVMetalTextureCache

    init(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.cache = cache!
    }

    /// Keep the source buffer and its color metadata for Compositor's native conversion.
    /// Plane views also serve zero-copy BGRA writer targets, which are never decoded.
    func texture(from pb: CVPixelBuffer) -> FrameState.Texture? {
        guard CVPixelBufferIsPlanar(pb) else {
            guard let bgra = plane(pb, index: 0, pixelFormat: .bgra8Unorm) else { return nil }
            return FrameState.Texture(luma: bgra, pixelBuffer: pb)
        }
        guard let luma = plane(pb, index: 0, pixelFormat: .r8Unorm),
              let chroma = plane(pb, index: 1, pixelFormat: .rg8Unorm) else { return nil }
        return FrameState.Texture(luma: luma, chroma: chroma, pixelBuffer: pb)
    }

    private func plane(_ pb: CVPixelBuffer, index: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let isPlanar = CVPixelBufferIsPlanar(pb)
        let width = isPlanar ? CVPixelBufferGetWidthOfPlane(pb, index) : CVPixelBufferGetWidth(pb)
        let height = isPlanar ? CVPixelBufferGetHeightOfPlane(pb, index) : CVPixelBufferGetHeight(pb)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, pixelFormat, width, height, index, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}

// MARK: - Selftest `composition <package>` (SPEC §6.2, plan T-305)

/// Checks the composition covers the editing clock and all audio/layer tails within 1/60 s.
func runCompositionSelfTest(_ args: [String]) async throws {
    guard let packagePath = args.first else { throw SelfTestArgError.usage("composition <package>") }
    let package = URL(fileURLWithPath: packagePath)
    let project = try Project.load(from: package.appendingPathComponent("project.json"))
    let (composition, _, _) = try await makeComposition(package: package, project: project)

    let actual = composition.duration.seconds
    let expected = max(TimeMap(project.clips).outputDuration, project.exportDuration)
    print("composition duration=\(actual)s expected=\(expected)s")
    guard abs(actual - expected) <= 1.0 / 60.0 else {
        throw SelfTestArgError.usage("duration mismatch: \(actual) vs \(expected)")
    }
}
