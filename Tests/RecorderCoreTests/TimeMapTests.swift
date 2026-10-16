import Testing
@testable import RecorderCore

@Test func timeMapRoundTrip() {
    // 0-2s kept, 2-4s removed, 4-8s kept at 2x  => output is 2s + 2s = 4s
    let m = TimeMap([Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 4, sourceEnd: 8, speed: 2)])
    #expect(m.outputDuration == 4)
    #expect(m.sourceTime(atOutput: 1) == 1)
    #expect(m.sourceTime(atOutput: 3) == 6)
    #expect(m.sourceTime(atOutput: 99) == 8)
    #expect(m.outputTime(atSource: 6) == 3)
    #expect(m.outputTime(atSource: 3) == nil)
}

@Test func exportDurationTracksActiveMedia() {
    func gap(_ start: Double, _ end: Double, speed: Double = 1) -> Clip {
        var clip = Clip(sourceStart: start, sourceEnd: end, speed: speed)
        clip.isGap = true
        return clip
    }
    var p = Project(source: Source(duration: 20), clips: [
        Clip(sourceStart: 0, sourceEnd: 2), gap(2, 4),
        Clip(sourceStart: 4, sourceEnd: 8, speed: 2), gap(8, 20)])
    #expect(p.exportDuration == 6) // Interior silence stays; trailing space does not.
    let didSplit = p.split(atOutput: 5)
    #expect(didSplit)
    #expect(p.exportDuration == 6)
    p.linkVideoEdits = false
    p.rippleDelete = false
    p.deleteClips([3])
    #expect(p.exportDuration == 5)
    p.cameraClips = [CameraClip(start: 7, end: 10)]
    #expect(p.exportDuration == 5) // No camera source: stale metadata is not media.
    p.source.hasCamera = true
    #expect(p.exportDuration == 8)
    p.cameraClips = [CameraClip(start: 25, end: 30)]
    #expect(p.exportDuration == 5) // Outside the playback timeline.
    p.cameraClips = []
    p.clips = [Clip(sourceStart: 0, sourceEnd: 4), gap(4, 20)]
    p.placeClip(0, start: 0, end: 2)
    #expect(p.exportDuration == 2)
    p.moveClips([0], byOutput: 3)
    #expect(p.exportDuration == 5)
    p.deleteClips(Set(p.clips.indices))
    #expect(p.exportDuration == 0)
    p.clips = []
    #expect(p.exportDuration == 0)
    p.clips = [Clip(sourceStart: 0, sourceEnd: 1, speed: 0)]
    #expect(p.exportDuration == 0)
}

@Test func audioCompositionTimingAndFades() {
    var gap = Clip(sourceStart: 4, sourceEnd: 6)
    gap.isGap = true
    let project = Project(source: Source(duration: 12),
        clips: [Clip(sourceStart: 0, sourceEnd: 4, speed: 2), gap, Clip(sourceStart: 8, sourceEnd: 12)],
        audioTracks: [AudioTrack(name: "Audio 1")], audioClips: [])
    var audio = AudioClip(start: 2, end: 10, mediaStart: 1, file: "media/tone.m4a", link: .screen, gain: 0.8, fadeIn: 0.5, fadeOut: 1)
    let linked = project.audioSegments(audio)
    #expect(linked.map(\.media) == [TimeRange(start: 1, end: 3), TimeRange(start: 3, end: 5), TimeRange(start: 7, end: 9)])
    #expect(linked.map(\.output) == [TimeRange(start: 1, end: 2), TimeRange(start: 2, end: 4), TimeRange(start: 4, end: 6)])
    let fades = project.audioVolumeRamps(audio)
    #expect(fades.map(\.range) == [TimeRange(start: 1, end: 1.5), TimeRange(start: 1.5, end: 5), TimeRange(start: 5, end: 6)])
    #expect(fades.map(\.start) == [0, 0.8, 0.8] && fades.map(\.end) == [0.8, 0.8, 0])
    audio.link = nil; audio.mediaRate = 0.5
    let detached = project.audioSegments(audio)
    #expect(detached.map(\.media) == [TimeRange(start: 1, end: 5)])
    #expect(detached.map(\.output) == [TimeRange(start: 1, end: 9)])
    audio.end = 3; audio.fadeIn = 1; audio.fadeOut = 1; audio.gain = 2
    let overlap = project.audioVolumeRamps(audio)
    #expect(overlap.map(\.range) == [TimeRange(start: 1, end: 1.5), TimeRange(start: 1.5, end: 2)])
    #expect(overlap.map(\.start) == [0, 1] && overlap.map(\.end) == [1, 0])
}

@Test func exportDurationIncludesAudioAndLayerTails() {
    var project = Project(source: Source(duration: 8), clips: [Clip(sourceStart: 0, sourceEnd: 8, speed: 2)],
        audioTracks: [AudioTrack(name: "Audio 1", muted: true)],
        audioClips: [AudioClip(start: 6, end: 10, file: "media/tone.m4a", gain: 0)],
        layers: [LayerBlock(kind: .image, start: 4, end: 7, file: "media/image.png", rect: NormRect())])
    #expect(project.exportDuration == 7)
    project.audioClips[0].link = .screen
    #expect(project.exportDuration == 5)
    project.layers = []
    #expect(project.exportDuration == 4)
    project.clips = []
    #expect(project.exportDuration == 0)
}
