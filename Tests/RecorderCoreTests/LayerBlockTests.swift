import Foundation
import Testing
@testable import RecorderCore

@Test func idleRangesIgnoreMotionAndPadInward() {
    let events = [InputEvent(t: 12, k: .move), InputEvent(t: 2, k: .key), InputEvent(t: 8, k: .down),
                  InputEvent(t: 5, k: .scroll), InputEvent(t: 9, k: .typing), InputEvent(t: .nan, k: .key)]
    #expect(idleRanges(events: events) == [TimeRange(start: 2.25, end: 7.75), TimeRange(start: 9.25, end: 11.75)])
    #expect(idleRanges(events: []) == [])
    #expect(idleRanges(events: [InputEvent(t: 3, k: .move)]) == [TimeRange(start: 0.25, end: 2.75)])
    #expect(idleRanges(events: events, minDuration: .infinity) == [])
}

@Test func layerBlocksImportAndLanePlacement() throws {
    var project = Project(source: Source(duration: 20, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 2)])
    let rect = NormRect(x: 0.18, y: 0.18, w: 0.64, h: 0.64)
    let imageResult = project.addLayer(kind: .image, file: "media/image.png", atOutput: 2, duration: 4, rect: rect)
    let image = try #require(imageResult)
    let videoResult = project.addLayer(kind: .video, file: "media/video.mov", atOutput: 3, duration: 20, rect: rect, hasAudio: true)
    let video = try #require(videoResult)
    #expect(project.layers.map(\.track) == [0, 1])
    #expect(project.layers[0].start == 4 && project.layers[0].end == 8)
    #expect(project.layers[1].end - project.layers[1].start == 7)
    let sound = try #require(project.audioClips.first { $0.layer == video.uuidString })
    #expect(sound.link == .layer && sound.track == 1 && project.audioTracks[1].name == "Audio 1")
    let music = project.addImportedAudio(file: "media/music.m4a", atOutput: 3, duration: 12)
    #expect(music != nil)
    #expect(project.audioTracks.last?.name == "Audio 2" && project.exportDuration == 15)
    let later = project.addImportedAudio(file: "media/later.m4a", atOutput: 17, duration: 1)
    #expect(later != nil)
    #expect(project.audioTracks.count == 3 && project.checkInvariants() == nil)
    let before = project
    let short = project.addLayer(kind: .video, file: "media/short.mov", atOutput: 18, duration: 2, rect: rect)
    let invalid = project.addLayer(kind: .image, file: "media/../bad.png", atOutput: 0, duration: 1, rect: rect)
    #expect(short == nil && invalid == nil)
    #expect(project == before && project.layers.contains { $0.id == image.uuidString })
}

@Test func layerBlocksMoveTrimSplitAndUndoInput() throws {
    var project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    let rect = NormRect(x: 0.18, y: 0.18, w: 0.64, h: 0.64)
    let result = project.addLayer(kind: .video, file: "media/video.mov", atOutput: 2, duration: 8, rect: rect, hasAudio: true)
    let id = try #require(result)
    project.moveLayer(id, toOutput: 4, track: 1)
    #expect(project.layers[0].track == 1 && project.layers[0].start == 4 && project.audioClips[0].start == 4)
    project.resizeLayer(id, edge: .leading, toOutput: 6, mediaDuration: 8)
    #expect(project.layers[0].mediaStart == 2 && project.audioClips[0].mediaStart == 2)
    project.resizeLayer(id, edge: .trailing, toOutput: 100, mediaDuration: 8)
    #expect(project.layers[0].end == 12 && project.audioClips[0].end == 12)
    #expect(TimeMap(project.clips).outputDuration == 20)
    let invalidBefore = project
    project.resizeLayer(UUID(), edge: .trailing, toOutput: 100)
    #expect(project == invalidBefore)
    let split = project.splitBlock(id, atSource: 8)
    #expect(split)
    #expect(project.layers.count == 2 && project.audioClips.count == 2)
    #expect(project.layers[1].mediaStart == 4 && project.audioClips[1].layer == project.layers[1].id)
    #expect(project.checkInvariants(mediaDurations: ["media/video.mov": 8]) == nil)
    let before = project
    project.moveLayer(id, toOutput: 9, track: 1)
    #expect(project == before)
    project.moveLayer(id, toOutput: 1, track: 0, propagate: false)
    #expect(project.audioClips == before.audioClips && project.layers[0].start == 1)
}

@Test func layerBlocksImageCanExtendWithoutRetiming() throws {
    var project = Project(source: Source(duration: 8), clips: [Clip(sourceStart: 0, sourceEnd: 8, speed: 2)])
    let result = project.addLayer(kind: .image, file: "media/image.png", atOutput: 1, duration: 4, rect: NormRect())
    let id = try #require(result)
    project.resizeLayer(id, edge: .trailing, toOutput: 10)
    #expect(project.layers[0].end - project.layers[0].start == 9 && project.exportDuration == 10)
    project.moveLayer(id, toOutput: 12)
    #expect(project.exportDuration == 21 && project.checkInvariants() == nil)
}

@Test func layerBlocksVideoDecoderBudgetReusesLanesOrRefuses() throws {
    var project = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)])
    for track in 0..<4 {
        let added = project.addLayer(kind: .video, file: "media/video-\(track).mov", atOutput: 0, duration: 2, rect: NormRect(), track: track)
        #expect(added != nil)
    }
    let original = project
    let refused = project.addLayer(kind: .video, file: "media/fifth.mov", atOutput: 0, duration: 2, rect: NormRect())
    #expect(refused == nil && project == original)
    let reused = project.addLayer(kind: .video, file: "media/later.mov", atOutput: 3, duration: 2, rect: NormRect(), track: 9)
    #expect(reused != nil && project.layers.last?.track == 0 && project.videoLayerLanes == [0, 1, 2, 3])
    let beforeMove = project
    project.moveLayer(UUID(uuidString: project.layers[0].id)!, toOutput: 0, track: 7)
    #expect(project == beforeMove)
    let image = project.addLayer(kind: .image, file: "media/image.png", atOutput: 0, duration: 2, rect: NormRect())
    #expect(image != nil && project.layers.first { $0.id == image?.uuidString }?.track == 4 && project.checkInvariants() == nil)
}
