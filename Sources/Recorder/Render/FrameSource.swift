import AVFoundation
import CoreVideo
import Metal
import RecorderCore

enum FrameSourceError: Error { case missingScreenTrack, trackCreationFailed }

/// Builds the `AVMutableComposition` from `project.clips` (insert ranges + `scaleTimeRange` per
/// clip) for screen, camera, mic, system — used by both the preview player (T-306) and the
/// exporter so clip cuts/speed changes and audio come from the same source (SPEC §6.2, §5).
/// Track order: video[0] = screen, video[1] = camera (if present); audio[0] = mic, audio[1] = system.
func makeComposition(package: URL, project: Project) async throws -> (AVMutableComposition, AVAudioMix) {
    let composition = AVMutableComposition()

    let screenAsset = AVURLAsset(url: package.appendingPathComponent("screen.mov"))
    guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
        throw FrameSourceError.missingScreenTrack
    }
    guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw FrameSourceError.trackCreationFailed
    }

    var cameraTrack: AVMutableCompositionTrack?
    var cameraSource: AVAssetTrack?
    if project.source.hasCamera {
        let cameraAsset = AVURLAsset(url: package.appendingPathComponent("camera.mov"))
        cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first
        if cameraSource != nil {
            cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    var micTrack: AVMutableCompositionTrack?
    var micSource: AVAssetTrack?
    if project.source.hasMic {
        let micAsset = AVURLAsset(url: package.appendingPathComponent("mic.m4a"))
        micSource = try await micAsset.loadTracks(withMediaType: .audio).first
        if micSource != nil {
            micTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    var systemTrack: AVMutableCompositionTrack?
    var systemSource: AVAssetTrack?
    if project.source.hasSystemAudio {
        let systemAsset = AVURLAsset(url: package.appendingPathComponent("system.m4a"))
        systemSource = try await systemAsset.loadTracks(withMediaType: .audio).first
        if systemSource != nil {
            systemTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
    }

    let timescale: CMTimeScale = 600
    var cursor = CMTime.zero
    for clip in project.clips {
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: clip.sourceStart, preferredTimescale: timescale),
            end: CMTime(seconds: clip.sourceEnd, preferredTimescale: timescale))
        guard sourceRange.duration > .zero else { continue }

        try screenTrack.insertTimeRange(sourceRange, of: screenSource, at: cursor)
        if let cameraTrack, let cameraSource { try cameraTrack.insertTimeRange(sourceRange, of: cameraSource, at: cursor) }
        if let micTrack, let micSource { try micTrack.insertTimeRange(sourceRange, of: micSource, at: cursor) }
        if let systemTrack, let systemSource { try systemTrack.insertTimeRange(sourceRange, of: systemSource, at: cursor) }

        let outputDuration = CMTime(seconds: clip.outputDuration, preferredTimescale: timescale)
        if clip.speed != 1 {
            composition.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: outputDuration)
        }
        cursor = cursor + outputDuration
    }

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
    // ponytail: `audioTimePitchAlgorithm = .spectral` (SPEC §6.2) is a property of the
    // AVPlayerItem/AVAssetExportSession that plays this composition (T-306), not of the
    // composition/mix themselves — set it there.
    return (composition, audioMix)
}

/// Zero-copy `CVPixelBuffer` → `MTLTexture`, cached per-buffer generation by `CVMetalTextureCache`.
final class TextureCache {
    private let cache: CVMetalTextureCache

    init(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.cache = cache!
    }

    /// `// ponytail: real captures decode to 420v (biplanar 4:2:0 YCbCr) — that needs luma +
    /// chroma textures and a shader mode-4 BT.709 YCbCr→RGB pass. This returns the luma plane
    /// for those; full colour conversion is wired when the preview (T-306) starts decoding real
    /// frames. Single-plane formats (BGRA — synthetic fixtures) map directly.`
    func texture(from pb: CVPixelBuffer) -> MTLTexture? {
        let isPlanar = CVPixelBufferIsPlanar(pb)
        let width = isPlanar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let height = isPlanar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let pixelFormat: MTLPixelFormat = isPlanar ? .r8Unorm : .bgra8Unorm

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, pixelFormat, width, height, 0, &cvTexture)
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
    let (composition, _) = try await makeComposition(package: package, project: project)

    let actual = composition.duration.seconds
    let expected = TimeMap(project.clips).outputDuration
    print("composition duration=\(actual)s expected=\(expected)s")
    guard abs(actual - expected) <= 1.0 / 60.0 else {
        throw SelfTestArgError.usage("duration mismatch: \(actual) vs \(expected)")
    }
}
