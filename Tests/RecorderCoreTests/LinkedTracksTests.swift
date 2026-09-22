import Foundation
import Testing
@testable import RecorderCore

private func linkedFixture() -> Project {
    var p = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)],
                    zooms: [Zoom(start: 2, end: 10)], keystrokeClips: [Layout(start: 2, end: 10, kind: .settings, keys: Keys(show: true))],
                    masks: [Mask(start: 4, end: 9)])
    p.linkVideoEdits = true
    return p
}

@Test func linkedVideoSplitDeleteAndMoveAreOneWay() throws {
    var p = linkedFixture()
    let split = p.split(atOutput: 6)
    #expect(split)
    #expect(p.cameraClips.count == 2 && p.zooms.count == 2 && p.keystrokeClips.count == 2 && p.masks.count == 2)
    let leftCamera = p.cameraClips[0]
    let moved = p.placeClip(1, start: 9, end: 15, moving: true)
    #expect(p.clips[moved].sourceStart == 9 && p.clips[1].isEmpty)
    #expect(TimeMap(p.clips).outputDuration == 15)
    #expect(p.cameraClips[0] == leftCamera)
    #expect(p.cameraClips[1].start == 9 && p.cameraClips[1].mediaStart == 6)
    #expect(p.zooms[1].start == 9 && p.zooms[1].end == 13)
    #expect(p.keystrokeClips[1].mediaStart == 6)
    let video = p.clips, camera = p.cameraClips, keys = p.keystrokeClips
    p.moveZoom(UUID(uuidString: p.zooms[1].id)!, toStart: 10)
    #expect(p.clips == video && p.cameraClips == camera && p.keystrokeClips == keys)
    p.liftClip(moved)
    #expect(p.cameraClips == [leftCamera])
    #expect(p.zooms.allSatisfy { $0.end <= 6 })
    #expect(p.checkInvariants() == nil)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
}

@Test func movingRightCreatesGapWithoutLinking() {
    var p = linkedFixture(); p.linkVideoEdits = false
    let split = p.split(atOutput: 6)
    #expect(split)
    let camera = p.cameraClips, zoom = p.zooms
    let i = p.placeClip(1, start: 8, end: 14, moving: true)
    #expect(p.clips[i].mediaIn == 6 && p.clips[1].isEmpty)
    #expect(TimeMap(p.clips).outputDuration == 14)
    #expect(p.cameraClips == camera && p.zooms == zoom)
}

@Test func linkedAndUnlinkedSpeedHaveDifferentClocks() {
    var p = linkedFixture()
    p.setSpeed(0, 2)
    #expect(TimeMap(p.clips).outputTime(atSource: p.cameraClips[0].end) == 6)
    #expect(TimeMap(p.clips).outputTime(atSource: p.zooms[0].start) == 1)
    #expect(p.clips[0].mediaDuration == 12)
    p.setSpeed(0, 0.5)
    #expect(TimeMap(p.clips).outputDuration == 24)
    #expect(p.clips[0].mediaDuration == 12)

    var independent = linkedFixture(); independent.linkVideoEdits = false
    independent.setSpeed(0, 2)
    #expect(independent.clips[0].outputDuration == 6)
    #expect(independent.clips[1].isEmpty)
    #expect(TimeMap(independent.clips).outputTime(atSource: 10) == 10)
    #expect(independent.clips[0].mediaTime(atSource: 3) == 6)
    independent.setSpeed(0, 0.5)
    #expect(TimeMap(independent.clips).outputDuration == 24)
    #expect(TimeMap(independent.clips).outputTime(atSource: 10) == 10)
    #expect(independent.clips[0].mediaDuration == 12)
    #expect(independent.checkInvariants() == nil)
}

@Test func linkedTrimSlicesOnlyOverlappingRanges() {
    var p = linkedFixture()
    _ = p.placeClip(0, start: 3, end: 8)
    #expect(p.cameraClips[0].start == 3 && p.cameraClips[0].end == 8 && p.cameraClips[0].mediaStart == 3)
    #expect(p.zooms[0].start == 3 && p.zooms[0].end == 8)
    #expect(TimeMap(p.clips).outputDuration == 12)
    #expect(p.checkInvariants() == nil)
}

@Test func timelineModesSelectionMovesAndGapArrival() throws {
    var p = linkedFixture()
    #expect(p.rippleDelete && p.linkVideoEdits)
    _ = p.split(atOutput: 4)
    _ = p.split(atOutput: 8)
    let original = p
    let selected = p.moveClips([1, 2], byOutput: 3)
    #expect(selected.count == 2)
    #expect(p.clips.filter { !$0.isEmpty }.map(\.sourceStart) == [0, 7, 11])
    #expect(p.cameraClips.map(\.start) == [0, 7, 11])
    #expect(p.cameraClips.map(\.mediaStart) == [0, 4, 8])
    #expect(p.zooms.map(\.start) == [2, 7, 11])
    #expect(p.videoOpacity(atOutput: 0) == 1)
    #expect(p.videoOpacity(atOutput: 6) == 0)
    #expect(p.videoOpacity(atOutput: 7) == 1)
    #expect(p.videoOpacity(atOutput: 7.09) == 1)
    #expect(p.videoOpacity(atOutput: 7.18) == 1)
    #expect(p.videoOpacity(atOutput: 11) == 1)
    let movedBack = p.moveClips(selected, byOutput: -100)
    #expect(movedBack.count == 2)
    #expect(p.clips.filter { !$0.isEmpty }.map(\.sourceStart) == [0, 4, 8])
    #expect(p.checkInvariants() == nil)
    p = original
    p.deleteClips([1])
    #expect(TimeMap(p.clips).outputDuration == 8)
    #expect(p.cameraClips.map(\.mediaStart) == [0, 8])
    #expect(TimeMap(p.clips).outputTime(atSource: p.cameraClips[1].start) == 4)
    p = original
    p.rippleDelete = false
    p.deleteClips([1])
    #expect(p.clips[1].isEmpty && TimeMap(p.clips).outputDuration == 12)
    p = original
    p.linkVideoEdits = false
    let layers = p.cameraClips
    _ = p.moveClips([1, 2], byOutput: 3)
    #expect(p.cameraClips == layers)
    p.deleteClips(Set(p.clips.indices))
    #expect(p.clips.allSatisfy { $0.isEmpty })
    #expect(p.checkInvariants() == nil)
    let decoded = try JSONDecoder().decode(Project.self, from: Data(#"{"source":{"duration":12}}"#.utf8))
    #expect(decoded.linkVideoEdits && decoded.rippleDelete)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
}

// Recording 2026-09-19 17.18.40: a 0.5× gap before a 1× / 1.5× selection.
@Test func mixedSpeedSelectionClosesGapInEveryTimelineMode() throws {
    let edges = [0.0, 0.6692174906858273, 1.0827187971131864, 1.4685061887882884,
                 1.607303546989051, 2.3197057555573224, 8.097644645059678, 8.633333333333333]
    let speeds = [1.0, 0.5, 0.5, 0.5, 1.0, 1.5, 1.0]
    var clips = speeds.indices.map { Clip(sourceStart: edges[$0], sourceEnd: edges[$0 + 1], speed: speeds[$0]) }
    clips[3].isGap = true; clips[6].isGap = true
    clips[5].mediaStart = 2.8553944438309773
    for linked in [false, true] {
        for ripple in [false, true] {
            var p = Project(source: Source(duration: edges.last!, hasCamera: true), clips: clips)
            p.linkVideoEdits = linked; p.rippleDelete = ripple
            p.keystrokeClips = [Layout(start: 0, end: edges.last!, kind: .settings, keys: Keys(show: true))]
            let before = p
            _ = p.moveClips([0], byOutput: -1)
            #expect(p == before)
            let oldMap = TimeMap(clips)
            let gap = clips[3].outputDuration
            let originalDuration = oldMap.outputDuration
            let selected = p.moveClips([4, 5], byOutput: -100)
            let moved = selected.sorted().map { p.clips[$0] }
            #expect(moved.count == 2)
            #expect(abs(moved[0].sourceStart - clips.prefix(3).reduce(0) { $0 + $1.outputDuration }) < 1e-8)
            #expect(abs(moved[1].sourceStart - moved[0].sourceEnd) < 1e-8)
            for (clip, old) in zip(moved, [clips[4], clips[5]]) {
                #expect(clip.speed == old.speed && clip.mediaIn == old.mediaIn)
                #expect(abs(clip.outputDuration - old.outputDuration) < 1e-8)
            }
            #expect(abs(TimeMap(p.clips).outputDuration - originalDuration) < 1e-8)
            // Camera media remains identical, shifted only for linked video edits.
            for i in [0, 1, 2, 4, 5] {
                let source = (clips[i].sourceStart + clips[i].sourceEnd) / 2
                let output = oldMap.outputTime(atSource: source)! - (linked && i >= 4 ? gap : 0)
                let block = try #require(p.cameraClips.first { $0.start <= output && output < $0.end })
                #expect(abs(block.mediaStart + (output - block.start) * (block.mediaRate ?? 1) - source) < 1e-8)
                let keys = try #require(p.keystrokeClips.first { $0.start <= output && output < $0.end })
                #expect(abs((keys.mediaStart ?? keys.start) + (output - keys.start) * (keys.mediaRate ?? 1) - source) < 1e-8)
            }
            #expect(p.checkInvariants() == nil)
            #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
            let returned = p.moveClips(selected, byOutput: gap)
            #expect(returned.count == 2)
            #expect(abs(p.clips[returned.min()!].sourceStart - oldMap.outputTime(atSource: clips[4].sourceStart)!) < 1e-8)
        }
    }
}


@Test func explicitClipFadesDefaultOffAndPreserveOuterSplitEdges() throws {
    let old = try JSONDecoder().decode(Clip.self, from: Data(#"{"sourceStart":0,"sourceEnd":4,"speed":2}"#.utf8))
    var p = Project(source: Source(duration: 4), clips: [old])
    #expect(old.fadeIn == nil && old.fadeOut == nil)
    #expect(p.videoOpacity(atOutput: 0) == 1)
    p.clips[0].fadeIn = 0.4; p.clips[0].fadeOut = 0.8
    #expect(p.videoOpacity(atOutput: 0) == 0)
    #expect(abs(p.videoOpacity(atOutput: 0.2) - 0.5) < 1e-9)
    #expect(p.videoOpacity(atOutput: 0.8) == 1)
    #expect(abs(p.videoOpacity(atOutput: 1.6) - 0.5) < 1e-9)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
    let didSplit = p.split(atOutput: 1)
    #expect(didSplit)
    #expect(p.clips[0].fadeIn == 0.4 && p.clips[0].fadeOut == nil)
    #expect(p.clips[1].fadeIn == nil && p.clips[1].fadeOut == 0.8)
    #expect(p.videoOpacity(atOutput: 1) == 1)
    p.clips[0].fadeIn = .nan
    #expect(p.videoOpacity(atOutput: 0) == 1)
}
