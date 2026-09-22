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
