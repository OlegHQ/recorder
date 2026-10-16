import Foundation
import Testing
@testable import RecorderCore

@Test func clipboardAudioAndTailEdits() throws {
    for link in [nil, AudioClip.Link.screen, .camera] {
        var project = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12, speed: 2)])
        project.audioTracks = [AudioTrack(name: "Audio 1")]
        project.audioClips = [AudioClip(start: 2, end: 6, mediaStart: 2, file: "media/music.m4a", track: 0, link: link)]
        let audio = project.audioClips[0]
        let copied = try #require(project.copySelection(clips: [], blocks: [UUID(uuidString: audio.id)!]))
        let result = project.pasteSelection(copied, atOutput: 4)
        let selection = try #require(result)
        let pasted = try #require(project.audioClips.first { UUID(uuidString: $0.id).map(selection.blocks.contains) ?? false })
        #expect(project.audioSegments(pasted).first?.output.start == 4)
        #expect(pasted.mediaStart == 2)
        #expect(project.checkInvariants() == nil)
    }
    do {
        var project = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
        let layer = LayerBlock(kind: .video, start: 0, end: 6, file: "media/movie.mov", rect: NormRect())
        project.layers = [layer]
        project.audioTracks = [AudioTrack(name: "Audio 1")]
        let slipped = AudioClip(start: 5, end: 9, mediaStart: 1, file: layer.file, link: .layer, layer: layer.id)
        project.audioClips = [slipped]
        let id = UUID(uuidString: slipped.id)!
        let copied = try #require(project.copySelection(clips: [], blocks: [id]))
        #expect(copied.audioClips[0].end - copied.audioClips[0].start == 4)
        project.removeBlock(id)
        let result = project.pasteSelection(copied, atOutput: 8)
        #expect(result != nil)
        #expect(project.audioClips[0].end - project.audioClips[0].start == 4)
        #expect(project.checkInvariants() == nil)
        project.audioClips[0].end = project.audioClips[0].start + 0.2
        let short = UUID(uuidString: project.audioClips[0].id)!
        #expect(project.copySelection(clips: [], blocks: [short]) == nil)
    }
    var project = Project(source: Source(duration: 4), clips: [Clip(sourceStart: 0, sourceEnd: 4)])
    project.audioTracks = [AudioTrack(name: "Audio 1")]
    let audio = AudioClip(start: 3, end: 9, file: "media/music.m4a", track: 0)
    let id = UUID(uuidString: audio.id)!
    project.audioClips = [audio]
    project.resizeAudio(id, edge: .trailing, toOutput: 8, mediaDuration: 5)
    #expect(project.audioClips[0].end == 8)
    project.resizeAudio(id, edge: .leading, toOutput: 5, mediaDuration: 5)
    #expect(project.audioSegments(project.audioClips[0]).first?.output.start == 5)
    #expect(project.audioClips[0].mediaStart == 2)
    project.moveAudio(id, toOutput: 7)
    #expect(project.audioSegments(project.audioClips[0]).first?.output.start == 7)
    let split = project.splitAudio(id, atOutput: 8)
    #expect(split)
    #expect(project.audioClips.count == 2)
    #expect(project.exportDuration == 10)
    #expect(project.checkInvariants(mediaDurations: [audio.file: 5]) == nil)
    project.audioTracks.append(AudioTrack(name: "Voiceover 1", volume: 0.5))
    let take = AudioClip(start: 1, end: 3, file: "voice/take.m4a", track: 1)
    project.audioClips.append(take)
    project.audioClips.sort { $0.start < $1.start }
    let copied = try #require(project.copySelection(clips: [], blocks: [UUID(uuidString: take.id)!]))
    project.audioTracks = []; project.audioClips = []
    let pasted = project.pasteSelection(copied, atOutput: 0)
    #expect(pasted != nil)
    #expect(project.audioTracks.count == 1 && project.audioTracks[0].name == "Voiceover 1" && project.audioTracks[0].volume == 0.5)
    #expect(project.audioClips.count == 1 && project.audioClips[0].track == 0)
    #expect(project.checkInvariants() == nil)
}

@Test func clipboardCutAudioRetainsItsLinkedVideo() throws {
    for link in [AudioClip.Link.screen, .camera, .layer] {
        var project = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
        project.audioTracks = [AudioTrack(name: "Audio 1")]
        let layer = LayerBlock(kind: .video, start: 0, end: 12, file: "media/movie.mov", track: 0, rect: NormRect())
        if link == .layer { project.layers = [layer] }
        let audio = AudioClip(start: 2, end: 6, mediaStart: 2, file: "media/movie.mov", link: link, layer: link == .layer ? layer.id : nil)
        project.audioClips = [audio]
        let id = UUID(uuidString: audio.id)!
        let copied = try #require(project.copySelection(clips: [], blocks: [id]))
        project.removeBlock(id)
        let result = project.pasteSelection(copied, atOutput: 8)
        #expect(result != nil)
        let pasted = try #require(project.audioClips.first { $0.mediaStart == 2 })
        #expect(project.audioSegments(pasted).first?.output.start == 8)
        switch link {
        case .screen: #expect(project.clips.contains { $0.sourceStart == 8 && $0.mediaIn == 2 })
        case .camera: #expect(project.cameraClips.contains { $0.start == 8 && $0.mediaStart == 2 })
        case .layer: #expect(project.layers.contains { $0.id == pasted.layer && $0.start == 8 && $0.mediaStart == 2 })
        }
        #expect(project.checkInvariants() == nil)
    }
}

@Test func clipboardPreservesMediaAndInsertsVideo() throws {
    var p = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12, speed: 2)])
    p.keystrokeClips = [Layout(start: 0, end: 12, kind: .settings, keys: Keys(show: true))]
    _ = p.split(atOutput: 2)
    let copied = try #require(p.copySelection(clips: [1], blocks: []))
    #expect(copied.clips[0].outputDuration == 4)
    #expect(copied.clips[0].mediaIn == 4)
    p.deleteClips([1])
    let result = p.pasteSelection(copied, atOutput: 1)
    let pasted = try #require(result)
    #expect(pasted.clips == [1])
    #expect(TimeMap(p.clips).outputDuration == 6)
    #expect(p.clips.map(\.mediaIn) == [0, 4, 2])
    #expect(p.clips.map(\.sourceStart) == [0, 1, 5])
    #expect(p.cameraClips.map(\.mediaStart) == [0, 4, 2])
    #expect(p.keystrokeClips.map(\.mediaStart) == [0, 4, 2])
    #expect(p.cameraClips.allSatisfy { $0.mediaRate == 2 })
    #expect(p.checkInvariants() == nil)
    let secondResult = p.pasteSelection(copied, atOutput: 6)
    let again = try #require(secondResult)
    #expect(again.clips == [3])
    #expect(p.clips[3].mediaIn == 4)
    #expect(Set(p.cameraClips.map(\.id)).count == p.cameraClips.count)
}

@Test func clipboardLayerPasteKeepsOtherLanesAndOutsidePieces() throws {
    var p = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    p.linkVideoEdits = false
    let id = p.addKeys(atSource: 2, length: 4)!
    let copied = try #require(p.copySelection(clips: [], blocks: [id]))
    p.removeBlock(id)
    let video = p.clips
    _ = p.pasteSelection(copied, atOutput: 8)
    #expect(p.clips[0].outputDuration == video[0].outputDuration)
    #expect(p.keystrokeClips[0].start == 8 && p.keystrokeClips[0].end == 12)
    #expect(p.keystrokeClips[0].mediaStart == 2)
    _ = p.pasteSelection(copied, atOutput: 10)
    #expect(p.keystrokeClips.map(\.start) == [8, 10])
    #expect(p.keystrokeClips.map(\.end) == [10, 14])
    #expect(p.clips.last?.isEmpty == true)
    #expect(TimeMap(p.clips).outputDuration == 14)
    #expect(p.checkInvariants() == nil)
}

@Test func clipboardReusesGapAndPreservesRippleChoice() throws {
    for ripple in [true, false] {
        var p = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
        p.rippleDelete = ripple
        let copied = try #require(p.copySelection(clips: [0], blocks: []))
        p.deleteClips([0])
        _ = p.pasteSelection(copied, atOutput: 0)
        #expect(p.clips.count == 1 && !p.clips[0].isEmpty)
        #expect(TimeMap(p.clips).outputDuration == 12)
        #expect(p.rippleDelete == ripple)
    }
}

@Test func clipboardRejectsInvalidPasteWithoutChangingProject() throws {
    var p = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    let copied = try #require(p.copySelection(clips: [0], blocks: []))
    let before = p
    let tiny = p.pasteSelection(copied, atOutput: 0.01)
    #expect(tiny == nil)
    #expect(p == before)
    let invalid = p.pasteSelection(copied, atOutput: .nan)
    #expect(invalid == nil)
    #expect(p.copySelection(clips: [99], blocks: []) == nil)
}
