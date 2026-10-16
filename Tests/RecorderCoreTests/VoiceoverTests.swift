import Foundation
import Testing
@testable import RecorderCore

@Test func takePlacementCompensatesLatency() {
    #expect(abs(takePlacement(playheadOutput: 8, firstSampleHost: 100.120, playbackHost: 100) - 8.120) < 0.001)
    #expect(abs(takePlacement(playheadOutput: 0, firstSampleHost: 99.8, playbackHost: 100) + 0.2) < 0.001)
}

@Test func takePlacementCommitAndReplacement() throws {
    var project = Project(source: Source(duration: 12, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 12, speed: 2)])
    let original = project.audioClips[0]
    let originalID = UUID(uuidString: original.id)!
    let video = project.clips
    let first = project.addVoiceover(file: "voice/first.m4a", placement: -0.1, duration: 6.5, replacing: originalID)
    let firstID = try #require(first)
    let take = try #require(project.audioClips.first { $0.id == firstID.uuidString })
    #expect(take.link == nil && take.mediaStart == 0.1 && take.end - take.start == 6)
    var linkedTake = take
    linkedTake.link = .screen
    #expect(project.syncOffset(linkedTake) == nil)
    #expect(project.audioClips.first { $0.id == original.id }?.gain == 0)
    #expect(project.clips == video)
    let second = project.addVoiceover(file: "voice/second.m4a", placement: -0.2, duration: 6.6, replacing: originalID)
    #expect(second != nil)
    #expect(project.audioClips.filter { $0.file.hasPrefix("voice/") }.map(\.file) == ["voice/second.m4a"])
    #expect(project.audioTracks.count == 2)
    #expect(project.checkInvariants() == nil)
    var scheduled = project
    scheduled.audioTracks.append(AudioTrack(name: "Voiceover 2"))
    scheduled.audioClips.append(AudioClip(start: 6, end: 7, file: "voice/later.m4a", track: 2))
    scheduled.audioClips.sort { $0.start < $1.start }
    let destination = scheduled.voiceoverDestination(atOutput: 2)
    #expect(destination.track == 2 && destination.stop == 3)
    let before = project
    #expect(project.voiceoverDestination(atOutput: 2).track == 2)
    #expect(project.voiceoverDestination(atOutput: 0, replacing: TimeRange(start: 0, end: 6)).track == 1)
    let tiny = project.addVoiceover(file: "voice/short.m4a", placement: 5, duration: 0.01)
    let invalid = project.addVoiceover(file: "voice/../../outside.m4a", placement: 0, duration: 2)
    #expect(tiny == nil && invalid == nil && project == before)
    let tail = project.addVoiceover(file: "voice/tail.m4a", placement: 8, duration: 3)
    #expect(tail != nil && project.exportDuration == 11)
    #expect(project.checkInvariants() == nil)
}

@Test func takePlacementPartialReplacementPreservesOtherAudio() throws {
    var project = Project(source: Source(duration: 10, hasCamera: true, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 10)])
    let original = project.audioClips[0]
    let cameras = project.cameraClips
    let id = project.addVoiceover(file: "voice/partial.m4a", placement: 2, duration: 3, replacing: UUID(uuidString: original.id)!)
    #expect(id != nil)
    let mic = project.audioClips.filter { $0.file == "mic.m4a" }
    #expect(mic.map(\.gain) == [1, 0, 1])
    #expect(mic.map(\.start) == [0, 2, 5])
    #expect(mic.map(\.mediaStart) == [0, 2, 5])
    #expect(project.cameraClips == cameras)
    #expect(project.checkInvariants() == nil)
}
