import CoreGraphics
import Foundation
import Testing
@testable import RecorderCore

@Test func layerEditsPlacement() throws {
    let canvas = CGSize(width: 1600, height: 900)
    let card = try #require(layerPlacementRect(.card, aspect: 2, canvas: canvas))
    #expect(card.w == 0.64 && abs(card.w * 1600 / (card.h * 900) - 2) < 1e-9)
    #expect(abs(card.x + card.w / 2 - 0.5) < 1e-9)
    #expect(layerPlacementRect(.full, aspect: 2, canvas: canvas) == NormRect())
    for position in [NormPoint(x: 0, y: 0), NormPoint(x: 0.5, y: 0.5), NormPoint(x: 1, y: 1)] {
        let corner = try #require(layerPlacementRect(.corner, aspect: 0.1, canvas: canvas, position: position))
        #expect(corner.h <= 0.8 && corner.x >= 0 && corner.y >= 0 && corner.x + corner.w <= 1 && corner.y + corner.h <= 1)
    }
    #expect(layerPlacementRect(.free, aspect: 2, canvas: canvas) == nil)
    #expect(layerPlacementRect(.card, aspect: .nan, canvas: canvas) == nil)
    #expect(layerPlacementRect(.card, aspect: 2, canvas: CGSize(width: CGFloat.infinity, height: 1)) == nil)
}

@Test func layerEditsDuplicateKeepsTimingAndLinkedSound() throws {
    var project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 2)])
    let result = project.addLayer(kind: .video, file: "media/video.mov", atOutput: 1, duration: 4, rect: NormRect(), hasAudio: true)
    let id = try #require(result)
    project.resizeLayer(id, edge: .leading, toOutput: 2, mediaDuration: 4)
    project.audioTracks[0].volume = 0.4; project.audioTracks[0].muted = true
    project.audioClips[0].gain = 0.6
    let old = project
    let duplicate = project.duplicateBlock(id)
    let copyID = try #require(duplicate)
    let copy = try #require(project.layers.first { $0.id == copyID.uuidString })
    #expect(project.layers[0] == old.layers[0])
    #expect(TimeMap(project.clips).outputTime(atSource: copy.start) == 5)
    #expect(copy.end - copy.start == 3 && copy.mediaStart == 1)
    let sound = try #require(project.audioClips.first { $0.layer == copy.id })
    #expect(sound.id != old.audioClips[0].id && sound.mediaStart == 1 && sound.gain == 0.6)
    #expect(project.audioTracks[sound.track].volume == 0.4 && project.audioTracks[sound.track].muted)
    #expect(project.checkInvariants(mediaDurations: ["media/video.mov": 4]) == nil)
    let detachedID = try #require(UUID(uuidString: sound.id))
    let detached = project.unlinkAudio(detachedID)
    #expect(detached)
    let next = project.duplicateBlock(copyID)
    #expect(next != nil && project.audioClips.count == 2)
}

@Test func layerEditsReplacePreservesDetachedMediaAndUndoValue() throws {
    var project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    let result = project.addLayer(kind: .video, file: "media/old.mov", atOutput: 2, duration: 6, rect: NormRect(), hasAudio: true)
    let id = try #require(result)
    project.audioTracks[0].volume = 0.25; project.audioTracks[0].muted = true
    project.audioClips[0].gain = 0.7
    let before = project
    let replaced = project.replaceLayerMedia(id, kind: .video, file: "media/new.mov", duration: 2, rect: NormRect(), hasAudio: true)
    #expect(replaced && project.layers[0].id == id.uuidString && project.layers[0].end == 4 && project.layers[0].mediaStart == 0)
    #expect(project.audioClips.count == 1 && project.audioClips[0].file == "media/new.mov" && project.audioClips[0].gain == 0.7)
    #expect(project.audioTracks[project.audioClips[0].track].volume == 0.25 && project.audioTracks[project.audioClips[0].track].muted)
    #expect(before.layers[0].file == "media/old.mov")
    let detachedID = try #require(UUID(uuidString: project.audioClips[0].id))
    let unlinked = project.unlinkAudio(detachedID)
    #expect(unlinked)
    let detached = project.audioClips
    let image = project.replaceLayerMedia(id, kind: .image, file: "media/still.png", duration: 0, rect: NormRect(), hasAudio: false)
    #expect(image && project.audioClips == detached && project.layers[0].end == 4)
    let valid = project
    let refused = project.replaceLayerMedia(id, kind: .video, file: "media/short.mov", duration: 0.2, rect: NormRect(), hasAudio: true)
    #expect(!refused && project == valid && project.checkInvariants() == nil)
}

@Test func layerEditsDuplicateRespectsDecoderBudget() throws {
    var project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    let result = project.addLayer(kind: .video, file: "media/first.mov", atOutput: 0, duration: 2, rect: NormRect())
    let id = try #require(result)
    for track in 0..<4 {
        let added = project.addLayer(kind: .video, file: "media/next.mov", atOutput: 2, duration: 2, rect: NormRect(), track: track)
        #expect(added != nil)
    }
    let before = project
    let refused = project.duplicateBlock(id)
    #expect(refused == nil && project == before)
    let imageResult = project.addLayer(kind: .image, file: "media/image.png", atOutput: 2, duration: 2, rect: NormRect())
    let image = try #require(imageResult)
    let withImage = project
    let replacement = project.replaceLayerMedia(image, kind: .video, file: "media/fifth.mov", duration: 2, rect: NormRect(), hasAudio: true)
    #expect(!replacement && project == withImage)
}

@Test func layerEditsLinkBackTargetsSelectedVideo() throws {
    var project = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)])
    let first = project.addLayer(kind: .video, file: "media/video.mov", atOutput: 0, duration: 4, rect: NormRect())
    let second = project.addLayer(kind: .video, file: "media/video.mov", atOutput: 0, duration: 4, rect: NormRect())
    let audio = project.addImportedAudio(file: "media/video.mov", atOutput: 0, duration: 4)
    let layer = try #require(second)
    let sound = try #require(audio)
    let linked = project.linkAudio(sound, to: .layer, layer: layer.uuidString)
    #expect(linked && first != second && project.audioClips[0].layer == layer.uuidString && project.checkInvariants() == nil)
}
