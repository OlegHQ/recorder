import Foundation
import Testing
@testable import RecorderCore

@Test func independentTracksPreserveGapsAndMedia() throws {
    var p = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    p.linkVideoEdits = false
    let cameraID = UUID(uuidString: p.cameraClips[0].id)!
    let keysID = p.addKeys(atSource: 2, length: 6)!
    let originalCamera = p.cameraClips
    let firstSplit = p.split(atOutput: 3)
    #expect(firstSplit)
    let secondSplit = p.split(atOutput: 7)
    #expect(secondSplit)
    #expect(p.cameraClips == originalCamera)
    #expect(p.keystrokeClips.count == 1)
    p.liftClip(1)
    #expect(TimeMap(p.clips).outputDuration == 12)
    #expect(p.clips[1].isEmpty)
    let cameraSplit = p.splitBlock(cameraID, atSource: 5)
    #expect(cameraSplit)
    #expect(p.cameraClips[1].mediaStart == 5)
    p.removeBlock(cameraID)
    let rightCamera = UUID(uuidString: p.cameraClips[0].id)!
    p.moveCamera(rightCamera, toStart: 2)
    #expect(p.cameraClips[0].start == 2)
    #expect(p.cameraClips[0].mediaStart == 5)
    p.resizeCamera(rightCamera, edge: .leading, to: 3)
    #expect(p.cameraClips[0].mediaStart == 6)
    #expect(p.keystrokeClips[0].id == keysID.uuidString)
    let i = p.placeClip(0, start: 1, end: 4, moving: true)
    #expect(p.clips[i].sourceStart == 1)
    #expect(p.clips[i].mediaIn == 0)
    #expect(p.clips[0].isEmpty)
    #expect(TimeMap(p.clips).outputDuration == 12)
    let trimmed = p.placeClip(i, start: 2, end: 4)
    #expect(p.clips[trimmed].mediaIn == 1)
    #expect(TimeMap(p.clips).outputDuration == 12)
    #expect(p.checkInvariants() == nil)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
    p.removeBlock(rightCamera)
    #expect(p.cameraClips.isEmpty)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)).cameraClips.isEmpty)
}

@Test func legacyCameraAndKeystrokesMigrateSeparately() throws {
    let json = #"{"source":{"duration":10,"hasCamera":true},"layouts":[{"start":2,"end":5,"kind":"settings","keys":{"show":true}}]}"#
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.cameraClips.count == 1)
    #expect(project.keystrokeClips.count == 1)
    #expect(project.layouts.isEmpty)
    #expect(project.framingEnabled)
    let oldClip = try JSONDecoder().decode(Clip.self, from: Data(#"{"sourceStart":0,"sourceEnd":10,"speed":1}"#.utf8))
    #expect(!oldClip.isEmpty && oldClip.mediaIn == 0)
}

@Test func restoringTinyMovedGapKeepsValidMedia() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)])
    let i = p.placeClip(0, start: 0, end: 5)
    _ = p.placeClip(i, start: 0.01, end: 5.01, moving: true)
    p.restoreAllCuts()
    #expect(p.checkInvariants() == nil)
    #expect(TimeMap(p.clips).outputDuration == 10)
}

@Test func splitClipRecoversDeletedFootage() {
    var p = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    _ = p.split(atOutput: 4)
    _ = p.split(atOutput: 8)
    p.deleteClips([0, 2])
    #expect(p.clips.count == 1)
    let i = p.placeClip(0, start: 2, end: 10)
    #expect(p.clips[i].sourceStart == 2)
    #expect(p.clips[i].sourceEnd == 10)
    #expect(p.clips[i].mediaIn == 2)
    _ = p.placeClip(i, start: -20, end: 30)
    #expect(p.clips[0].mediaIn == 0)
    #expect(p.clips[0].mediaDuration == 12)
    #expect(p.checkInvariants() == nil)

    var bounded = Project(source: Source(duration: 12), clips: [Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 4, sourceEnd: 6), Clip(sourceStart: 10, sourceEnd: 12)])
    _ = bounded.placeClip(1, start: 0, end: 12)
    #expect(bounded.clips[1].sourceStart == 2)
    #expect(bounded.clips[1].sourceEnd == 10)
    #expect(bounded.checkInvariants() == nil)
}
