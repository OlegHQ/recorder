import Foundation
import Testing
@testable import RecorderCore

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
