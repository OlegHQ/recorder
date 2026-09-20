import AVFoundation
import CoreVideo
import Metal
import RecorderCore

enum FrameSourceError: Error { case missingScreenTrack, trackCreationFailed }

/// One SDR working space from capture through preview, stills and video encoding.
enum VideoColor {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let properties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
}

/// Builds the `AVMutableComposition` from `project.clips` (insert ranges + `scaleTimeRange` per
/// clip) for screen, camera, mic, system — used by both the preview player (T-306) and the
/// exporter so clip cuts/speed changes and audio come from the same source (SPEC §6.2, §5).
/// Track order: video[0] = screen, video[1] = camera (if present); audio[0] = mic, audio[1] = system.
///
/// Also returns the mic/system `AVMutableCompositionTrack`s (`nil` when the project has none) so a
/// caller can rebuild just the `AVAudioMix` later (T-504: `PreviewView.refreshAudioMix` — volumes/
/// mutes change without a composition rebuild/playback hiccup) via `makeAudioMix` below, without
/// re-inserting any media.
///
/// `micURL`, when given, replaces `mic.m4a` as the mic track's SOURCE (T-504: the exporter's
/// export-only denoise pass builds a processed temp file and passes it here; preview never does,
/// so it always plays the raw mic, per the task).
func makeComposition(package: URL, project: Project, micURL: URL? = nil) async throws
    -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix,
        micTrack: AVMutableCompositionTrack?, systemTrack: AVMutableCompositionTrack?) {
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
    var micAssetKeepAlive: AVURLAsset?
    var systemAssetKeepAlive: AVURLAsset?

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

    var micTrack: AVMutableCompositionTrack?
    var micSource: AVAssetTrack?
    if project.source.hasMic {
        let micAsset = AVURLAsset(url: micURL ?? package.appendingPathComponent("mic.m4a"))
        micAssetKeepAlive = micAsset
        micSource = try await micAsset.loadTracks(withMediaType: .audio).first
        if micSource != nil {
            micTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    var systemTrack: AVMutableCompositionTrack?
    var systemSource: AVAssetTrack?
    if project.source.hasSystemAudio {
        let systemAsset = AVURLAsset(url: package.appendingPathComponent("system.m4a"))
        systemAssetKeepAlive = systemAsset
        systemSource = try await systemAsset.loadTracks(withMediaType: .audio).first
        if systemSource != nil {
            systemTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    let timescale: CMTimeScale = 600
    var cursor = CMTime.zero
    for clip in project.clips {
        let outputDuration = CMTime(seconds: clip.outputDuration, preferredTimescale: timescale)
        guard outputDuration > .zero else { continue }
        // Gaps decode one valid placeholder frame; the compositor draws only the background.
        let mediaDuration = clip.isEmpty ? min(project.source.duration, 1.0 / 30) : clip.mediaDuration
        let range = CMTimeRange(start: CMTime(seconds: clip.isEmpty ? 0 : clip.mediaIn, preferredTimescale: timescale),
                                duration: CMTime(seconds: mediaDuration, preferredTimescale: timescale))
        try screenTrack.insertTimeRange(range, of: screenSource, at: cursor)
        screenTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outputDuration)
        for (track, source) in [(micTrack, micSource), (systemTrack, systemSource)] {
            guard let track, let source else { continue }
            if clip.isEmpty { track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: outputDuration)) }
            else {
                try track.insertTimeRange(range, of: source, at: cursor)
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outputDuration)
            }
        }
        cursor = cursor + outputDuration
    }

    // Compose camera independently. Screen cuts and gaps never remove camera footage.
    if let cameraTrack, let cameraSource {
        let map = TimeMap(project.clips)
        for camera in project.cameraClips {
            for clip in project.clips {
                let lo = max(camera.start, clip.sourceStart), hi = min(camera.end, clip.sourceEnd)
                guard hi > lo, let out = map.outputTime(atSource: lo) else { continue }
                let range = CMTimeRange(start: CMTime(seconds: camera.mediaStart + (lo - camera.start) * (camera.mediaRate ?? 1), preferredTimescale: timescale),
                                        duration: CMTime(seconds: (hi - lo) * (camera.mediaRate ?? 1), preferredTimescale: timescale))
                let at = CMTime(seconds: out, preferredTimescale: timescale)
                try cameraTrack.insertTimeRange(range, of: cameraSource, at: at)
                cameraTrack.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
                                           toDuration: CMTime(seconds: (hi - lo) / clip.timeScale, preferredTimescale: timescale))
            }
        }
    }

    withExtendedLifetime((screenAssetKeepAlive, cameraAssetKeepAlive, micAssetKeepAlive, systemAssetKeepAlive)) {}

    let audioMix = makeAudioMix(project: project, micTrack: micTrack, systemTrack: systemTrack)
    // `audioTimePitchAlgorithm = .spectral` (SPEC §6.2) is a property of the AVPlayerItem/
    // AVAssetExportSession that plays this composition, not of the composition/mix themselves —
    // set on the `AVPlayerItem` in `PreviewView.attach` (T-306) and the exporter (T-505).
    return (composition, audioMix, micTrack, systemTrack)
}

/// T-504: the volume/mute half of `makeComposition` above, factored out so a live `AVPlayerItem`'s
/// mix can be rebuilt from the SAME already-built mic/system tracks when only `project.audio`
/// changes — no composition rebuild, no playback hiccup (`PreviewView.refreshAudioMix`).
func makeAudioMix(project: Project, micTrack: AVMutableCompositionTrack?, systemTrack: AVMutableCompositionTrack?) -> AVMutableAudioMix {
    var inputParameters: [AVMutableAudioMixInputParameters] = []
    if let micTrack {
        let params = AVMutableAudioMixInputParameters(track: micTrack)
        params.setVolume(project.audio.micMuted ? 0 : Float(project.audio.micVolume), at: .zero)
        inputParameters.append(params)
    }
    if let systemTrack {
        let params = AVMutableAudioMixInputParameters(track: systemTrack)
        params.setVolume(project.audio.systemMuted ? 0 : Float(project.audio.systemVolume), at: .zero)
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

/// Prints the built composition's duration; OK when it equals `TimeMap(project.clips).outputDuration` ± 1/60 s.
func runCompositionSelfTest(_ args: [String]) async throws {
    guard let packagePath = args.first else { throw SelfTestArgError.usage("composition <package>") }
    let package = URL(fileURLWithPath: packagePath)
    let project = try Project.load(from: package.appendingPathComponent("project.json"))
    let (composition, _, _, _) = try await makeComposition(package: package, project: project)

    let actual = composition.duration.seconds
    let expected = TimeMap(project.clips).outputDuration
    print("composition duration=\(actual)s expected=\(expected)s")
    guard abs(actual - expected) <= 1.0 / 60.0 else {
        throw SelfTestArgError.usage("duration mismatch: \(actual) vs \(expected)")
    }
}
