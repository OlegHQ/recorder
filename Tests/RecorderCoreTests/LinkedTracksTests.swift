import Foundation
import Testing
@testable import RecorderCore

private func linkedFixture() -> Project {
    var p = Project(source: Source(duration: 12, hasCamera: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)],
                    zooms: [Zoom(start: 2, end: 10)], keystrokeClips: [Layout(start: 2, end: 10, kind: .settings, keys: Keys(show: true))],
                    masks: [Mask(start: 4, end: 9)], texts: [TextBlock(start: 4, end: 9, text: "hi there", words: [Word(text: "hi", start: 0, end: 2), Word(text: "there", start: 2, end: 5)])])
    p.linkVideoEdits = true
    return p
}

@Test func linkedVideoSplitDeleteAndMoveAreOneWay() throws {
    var p = linkedFixture()
    let split = p.split(atOutput: 6)
    #expect(split)
    #expect(p.cameraClips.count == 2 && p.zooms.count == 2 && p.keystrokeClips.count == 2 && p.masks.count == 2 && p.texts.count == 2)
    #expect(p.texts[1].words?.first?.start == -2) // words are relative to the block start
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
    #expect(p.zooms.allSatisfy { $0.end <= 6 } && p.texts.allSatisfy { $0.end <= 6 })
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

@Test func textBlocksDuplicateRemoveAndRespreadWords() {
    var p = linkedFixture()
    let id = UUID(uuidString: p.texts[0].id)!
    p.moveText(id, toStart: 1)
    #expect(p.texts[0].start == 1 && p.texts[0].words?.count == 2)
    p.texts[0].setText("a b c d 5")
    #expect(p.texts[0].words?.count == 5 && p.texts[0].words?.last?.end == 5)
    #expect(p.texts[0].wordIndex(atSource: 1.5) == 0 && p.texts[0].wordIndex(atSource: 3.2) == 2)
    #expect(p.duplicateBlock(id) != nil && p.texts.count == 2)
    p.removeBlock(id)
    #expect(p.texts.count == 1 && p.checkInvariants() == nil)
    #expect(try! JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
}

@Test func captionPhrasesGroupByCountGapAndPunctuation() {
    func w(_ t: String, _ s: Double) -> Word { Word(text: t, start: s, end: s + 0.3) }
    let words = [w("a", 0), w("b", 0.4), w("c", 0.8), w("d", 1.2), w("e", 1.6), w("Hi.", 2.0), w("there", 2.4), w("late", 5)]
    let phrases = captionPhrases(words: words)
    #expect(phrases.map(\.text) == ["a b c d", "e Hi.", "there", "late"])
    #expect(phrases[0].start == 0 && phrases[0].words?.last?.start == 1.2)
    #expect(phrases.allSatisfy { $0.style == .caption } && zip(phrases, phrases.dropFirst()).allSatisfy { $0.end <= $1.start })
    var p = linkedFixture()
    p.texts[0].style = .title
    p.replaceCaptions(phrases)
    #expect(p.texts.contains { $0.style == .title } && p.checkInvariants() == nil)
    #expect(captionPhrases(words: []).isEmpty)
}

private func linkedAudioFixture() -> Project {
    let layer = LayerBlock(kind: .video, start: 10, end: 14, file: "media/video.mov", mediaStart: 1, rect: NormRect())
    return Project(source: Source(duration: 20, hasCamera: true, hasMic: true, hasSystemAudio: true),
        clips: [Clip(sourceStart: 0, sourceEnd: 20)], cameraClips: [CameraClip(start: 2, end: 8, mediaStart: 2)],
        audioTracks: [AudioTrack(name: "Mic"), AudioTrack(name: "System"), AudioTrack(name: "Audio 1")],
        audioClips: [AudioClip(start: 2, end: 8, mediaStart: 2, file: "mic.m4a", track: 0, link: .camera),
                     AudioClip(start: 0, end: 20, file: "system.m4a", track: 1, link: .screen),
                     AudioClip(start: 10, end: 14, mediaStart: 1, file: layer.file, track: 2, link: .layer, layer: layer.id)],
        layers: [layer])
}

@Test func linkedAudioScreenIgnoresGlobalToggle() throws {
    var project = Project(source: Source(duration: 12, hasCamera: true, hasMic: true, hasSystemAudio: true),
                          clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    project.linkVideoEdits = false
    let originalCamera = project.cameraClips
    let mic = project.audioClips.filter { $0.link == .camera }
    let didSplit = project.split(atOutput: 4)
    #expect(didSplit)
    #expect(project.audioClips.filter { $0.link == .screen }.count == 2)
    let moved = project.placeClip(1, start: 8, end: 16, moving: true)
    let trimmed = project.placeClip(moved, start: 9, end: 15)
    let audio = try #require(project.audioClips.first { $0.start == 9 && $0.link == .screen })
    #expect(audio.end == 15 && audio.mediaStart == 5)
    #expect(project.cameraClips == originalCamera && project.audioClips.filter { $0.link == .camera } == mic)
    #expect(project.syncOffset(audio) == 0)
    project.rippleDelete = false
    project.deleteClips([trimmed])
    #expect(project.audioClips.filter { $0.link == .screen }.map(\.end) == [4])
    #expect(project.checkInvariants() == nil)

    for linked in [false, true] {
        var speed = Project(source: Source(duration: 12, hasCamera: true, hasMic: true, hasSystemAudio: true),
                            clips: [Clip(sourceStart: 0, sourceEnd: 12)])
        speed.linkVideoEdits = linked
        speed.setSpeed(0, 2)
        let system = try #require(speed.audioClips.first { $0.link == .screen })
        #expect(system.end == (linked ? 12 : 6))
        #expect((system.end - system.start) * (system.mediaRate ?? 1) == 12)
        #expect(speed.syncOffset(system) == 0)
        #expect(speed.audioClips.allSatisfy { speed.syncOffset($0) == 0 })
        speed.setSpeed(0, 0.5)
        #expect(speed.audioClips.allSatisfy { speed.syncOffset($0) == 0 })
        #expect(speed.checkInvariants() == nil)
    }
}

@Test func linkedAudioCameraEditsAreBidirectional() throws {
    var project = linkedAudioFixture()
    let camera = try #require(project.cameraClips.first)
    let cameraID = try #require(UUID(uuidString: camera.id))
    let screen = project.clips, system = project.audioClips.filter { $0.link == .screen }
    project.moveCamera(cameraID, toStart: 4)
    #expect(project.audioClips.first { $0.file == "mic.m4a" }?.start == 4)
    let didSplit = project.splitBlock(cameraID, atSource: 7)
    #expect(didSplit)
    let rightID = try #require(UUID(uuidString: project.cameraClips[1].id))
    project.resizeCamera(rightID, edge: .leading, to: 8)
    #expect(project.audioClips.first { $0.start == 8 && $0.link == .camera }?.mediaStart == 6)
    project.resizeCamera(rightID, edge: .leading, to: 7)
    #expect(project.audioClips.first { $0.start == 7 && $0.link == .camera }?.mediaStart == 5)
    let leftAudio = try #require(project.audioClips.first { $0.link == .camera && $0.start == 4 })
    let leftID = try #require(UUID(uuidString: leftAudio.id))
    project.moveAudio(leftID, toStart: 2)
    #expect(project.cameraClips[0].start == 2 && project.cameraClips[0].mediaStart == 2)
    #expect(project.audioClips.filter { $0.link != .layer }.allSatisfy { project.syncOffset($0) == 0 })
    project.resizeAudio(leftID, edge: .leading, to: 3)
    #expect(project.cameraClips[0].start == 3 && project.cameraClips[0].mediaStart == 3)
    project.removeBlock(leftID)
    #expect(project.cameraClips.count == 1)
    #expect(project.clips == screen && project.audioClips.filter { $0.link == .screen } == system)
    #expect(project.checkInvariants() == nil)
}

@Test func linkedAudioLayerEditsKeepPieceReferences() throws {
    var project = linkedAudioFixture()
    let layerID = try #require(UUID(uuidString: project.layers[0].id))
    project.moveLayer(layerID, toStart: 12)
    #expect(project.audioClips.first { $0.link == .layer }?.start == 12)
    let audioID = try #require(UUID(uuidString: project.audioClips.first { $0.link == .layer }!.id))
    let didSplit = project.splitBlock(audioID, atSource: 14)
    #expect(didSplit)
    #expect(project.layers.count == 2)
    for audio in project.audioClips where audio.link == .layer {
        let layer = try #require(project.layers.first { $0.id == audio.layer })
        #expect(audio.start == layer.start && audio.end == layer.end && audio.mediaStart == layer.mediaStart)
    }
    let rightID = try #require(UUID(uuidString: project.audioClips.first { $0.link == .layer && $0.start == 14 }!.id))
    project.resizeAudio(rightID, edge: .leading, to: 15, mediaDuration: 10)
    #expect(project.layers.last?.start == 15 && project.layers.last?.mediaStart == 4)
    project.moveAudio(rightID, toStart: 17)
    #expect(project.layers.last?.start == 17 && project.layers.last?.end == 18)
    #expect(project.audioClips.filter { $0.link == .layer }.allSatisfy { project.syncOffset($0) == 0 })
    project.removeBlock(rightID)
    #expect(project.layers.count == 1 && project.layers[0].start == 12 && project.layers[0].end == 14)
    #expect(project.checkInvariants() == nil)
}

@Test func linkedAudioUnlinkRelinkAndSync() throws {
    for link in [AudioClip.Link.screen, .camera, .layer] {
        var project = linkedAudioFixture()
        project.audioClips[1].end = 12
        project.setSpeed(0, 2)
        let original = try #require(project.audioClips.first { $0.link == link })
        let id = try #require(UUID(uuidString: original.id))
        let map = TimeMap(project.clips)
        let outputStart = try #require(map.outputTime(atSource: original.start))
        let outputLength = link == .layer ? original.end - original.start : try #require(map.outputTime(atSource: original.end)) - outputStart
        let didDetach = project.unlinkAudio(id)
        #expect(didDetach)
        let detached = try #require(project.audioClips.first { $0.id == original.id })
        #expect(detached.link == nil && detached.layer == nil)
        #expect(detached.end - detached.start == outputLength)
        #expect((detached.end - detached.start) * (detached.mediaRate ?? 1) == (original.end - original.start) * (original.mediaRate ?? 1))
        let didRelink = project.linkAudio(id, to: link)
        #expect(didRelink)
        let relinked = try #require(project.audioClips.first { $0.id == original.id })
        #expect(relinked.start == original.start && relinked.end == original.end && relinked.mediaStart == original.mediaStart)
        #expect(abs(project.syncOffset(relinked) ?? 100) < 1e-9)
        project.moveAudio(id, toStart: original.start + 1, propagate: false)
        let shifted = try #require(project.audioClips.first { $0.id == original.id })
        #expect(abs((project.syncOffset(shifted) ?? 100) - 0.5) < 1e-9)
        project.moveIntoSync(id)
        #expect(abs(project.syncOffset(project.audioClips.first { $0.id == original.id }!) ?? 100) < 1e-9)
        #expect(project.checkInvariants() == nil)
    }
    var project = linkedAudioFixture()
    let mic = try #require(project.audioClips.first { $0.link == .camera })
    let id = try #require(UUID(uuidString: mic.id))
    let camera = project.cameraClips
    project.moveAudio(id, toStart: 3, propagate: false)
    #expect(project.cameraClips == camera && project.syncOffset(project.audioClips.first { $0.id == mic.id }!) == 1)
    project.removeBlock(id, propagate: false)
    #expect(project.cameraClips == camera)
    let layer = project.layers[0]
    project.removeBlock(UUID(uuidString: layer.id)!, propagate: false)
    #expect(project.audioClips.contains { $0.file == layer.file && $0.link == nil && $0.layer == nil })
    #expect(project.checkInvariants() == nil)
    #expect(project.syncOffset(AudioClip(start: 0, end: 2, file: "voice/take.m4a")) == nil)
}

@Test func linkedAudioLinkSlicesAtClockAndTargetEdges() throws {
    var project = Project(source: Source(duration: 20),
        clips: [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8, speed: 2), Clip(sourceStart: 8, sourceEnd: 20)],
        audioTracks: [AudioTrack(name: "Audio 1")], audioClips: [AudioClip(start: 2, end: 7, file: "media/music.m4a")])
    let id = UUID(uuidString: project.audioClips[0].id)!
    let didLink = project.linkAudio(id, to: .screen)
    #expect(didLink)
    #expect(project.audioClips.map(\.start) == [2, 4, 8])
    #expect(project.audioClips.map(\.end) == [4, 8, 9])
    #expect(project.audioClips.map(\.mediaStart) == [0, 2, 4])
    #expect(project.audioClips.map(\.mediaRate) == [1, 0.5, 1])
    for audio in project.audioClips {
        let didDetach = project.unlinkAudio(UUID(uuidString: audio.id)!)
        #expect(didDetach)
    }
    #expect(project.audioClips.map { $0.end - $0.start } == [2, 2, 1])
    #expect(project.audioClips.allSatisfy { $0.mediaRate == 1 && $0.link == nil })
    #expect(project.checkInvariants() == nil)
    let before = project
    let didLinkCamera = project.linkAudio(id, to: .camera)
    #expect(!didLinkCamera)
    #expect(project == before)
}

@Test func linkedAudioRandomEditsKeepSync() throws {
    var generator = LinkedAudioRandom(state: 641)
    var project = linkedAudioFixture()
    var changedCount = 0
    for iteration in 0..<500 {
        if iteration % 25 == 0 { project = linkedAudioFixture() }
        let before = project
        switch Int.random(in: 0..<11, using: &generator) {
        case 0: _ = project.split(atOutput: Double.random(in: 1...9, using: &generator))
        case 1: project.setSpeed(Int.random(in: project.clips.indices, using: &generator), [0.5, 1, 2].randomElement(using: &generator)!)
        case 2:
            if let camera = project.cameraClips.randomElement(using: &generator), let id = UUID(uuidString: camera.id) {
                project.moveCamera(id, toStart: Double.random(in: 1...7, using: &generator))
            }
        case 3:
            if let camera = project.cameraClips.randomElement(using: &generator), let id = UUID(uuidString: camera.id) {
                project.resizeCamera(id, edge: .leading, to: camera.start + 0.2)
            }
        case 4:
            if let layer = project.layers.first { project.moveLayer(UUID(uuidString: layer.id)!, toStart: Double.random(in: 8...15, using: &generator)) }
        case 5:
            if let audio = project.audioClips.filter({ $0.link == .camera }).randomElement(using: &generator) {
                _ = project.splitBlock(UUID(uuidString: audio.id)!, atSource: (audio.start + audio.end) / 2)
            }
        case 6:
            if let audio = project.audioClips.first(where: { $0.link == .layer }) {
                project.resizeAudio(UUID(uuidString: audio.id)!, edge: .trailing, to: audio.start + 1.5, mediaDuration: 20)
            }
        case 7:
            if let camera = project.cameraClips.randomElement(using: &generator) { project.removeBlock(UUID(uuidString: camera.id)!) }
        case 8:
            _ = project.moveClips([Int.random(in: project.clips.indices, using: &generator)], byOutput: Double.random(in: -3...3, using: &generator))
        case 9: project.deleteClips([Int.random(in: project.clips.indices, using: &generator)])
        default:
            let index = Int.random(in: project.clips.indices, using: &generator)
            _ = project.placeClip(index, start: project.clips[index].sourceStart + 0.2, end: project.clips[index].sourceEnd)
        }
        if project != before { changedCount += 1 }
        #expect(project.checkInvariants() == nil, "iteration \(iteration)")
        for audio in project.audioClips where audio.link != nil {
            let offset = try #require(project.syncOffset(audio), "iteration \(iteration), clips \(project.clips), camera \(project.cameraClips), audio \(audio)")
            #expect(abs(offset) < 1e-8, "iteration \(iteration), \(audio)")
        }
    }
    #expect(changedCount > 100)
}

@Test func linkedAudioMixedClockMovesAndScreenPartners() throws {
    for linked in [false, true] {
        var project = Project(source: Source(duration: 12, hasCamera: true, hasMic: true, hasSystemAudio: true),
            clips: [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8, speed: 2), Clip(sourceStart: 8, sourceEnd: 12)])
        project.linkVideoEdits = linked
        project.liftClip(1)
        let selected = project.moveClips([2], byOutput: -3)
        #expect(selected.count == 1 && project.clips[selected.first!].sourceStart == 4)
        #expect(project.audioClips.allSatisfy { abs(project.syncOffset($0) ?? 100) < 1e-9 })
        #expect(project.checkInvariants() == nil)
    }
    var project = Project(source: Source(duration: 20, hasCamera: true, hasMic: true, hasSystemAudio: true),
                          clips: [Clip(sourceStart: 0, sourceEnd: 20)])
    _ = project.placeClip(0, start: 0, end: 8)
    let system = try #require(project.audioClips.first { $0.link == .screen })
    let didSplit = project.splitBlock(UUID(uuidString: system.id)!, atSource: 4)
    #expect(didSplit && project.clips.count == 3)
    let rightID = UUID(uuidString: project.audioClips.first { $0.link == .screen && $0.start == 4 }!.id)!
    project.moveAudio(rightID, toStart: 6)
    #expect(project.clips.contains { !$0.isEmpty && $0.sourceStart == 6 && $0.sourceEnd == 10 && $0.mediaIn == 4 })
    project.resizeAudio(rightID, edge: .leading, to: 7)
    #expect(project.clips.contains { !$0.isEmpty && $0.sourceStart == 7 && $0.mediaIn == 5 })
    #expect(project.audioClips.allSatisfy { abs(project.syncOffset($0) ?? 100) < 1e-9 })
    project.removeBlock(rightID)
    #expect(project.audioClips.allSatisfy { $0.end <= 4 })
    #expect(project.checkInvariants() == nil)
}

@Test func linkedAudioIndependentCameraSurvivesVideoCuts() {
    for clip in [Clip(sourceStart: 4, sourceEnd: 20), Clip(sourceStart: 0, sourceEnd: 6), Clip(sourceStart: 10, sourceEnd: 20)] {
        var project = linkedAudioFixture()
        project.layers = []; project.audioClips.removeAll { $0.link == .layer || $0.link == .screen }
        project.clips = [clip]
        #expect(project.checkInvariants() == nil)
        #expect(project.syncOffset(project.audioClips[0]) == 0)
    }
}

@Test func linkedAudioOffsetLayerEditsPreserveSound() throws {
    var project = linkedAudioFixture()
    let layer = project.layers[0], layerID = UUID(uuidString: project.layers[0].id)!
    let audio = try #require(project.audioClips.first { $0.link == .layer })
    let audioID = UUID(uuidString: audio.id)!
    project.moveAudio(audioID, toStart: 11, propagate: false)
    #expect(project.syncOffset(project.audioClips.first { $0.id == audio.id }!) == 1)
    project.resizeLayer(layerID, edge: .leading, to: 10.5, mediaDuration: 10)
    #expect(project.layers[0].start == 10.5)
    #expect(project.audioClips.first { $0.id == audio.id }?.start == 11)
    project.moveLayer(layerID, toStart: 12)
    let shifted = try #require(project.audioClips.first { $0.id == audio.id })
    #expect(shifted.start == 12.5 && shifted.end == 16.5 && shifted.mediaStart == audio.mediaStart)
    #expect(project.syncOffset(shifted) == 1)
    project.removeBlock(layerID)
    #expect(project.audioClips.allSatisfy { $0.file != layer.file })
    #expect(project.checkInvariants() == nil)
}

@Test func linkedAudioVideoClipboardPreservesSync() throws {
    for linked in [false, true] {
        var project = Project(source: Source(duration: 12, hasCamera: true, hasMic: true, hasSystemAudio: true),
            clips: [Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8, speed: 2), Clip(sourceStart: 8, sourceEnd: 12)])
        project.linkVideoEdits = linked
        let copied = try #require(project.copySelection(clips: [1], blocks: []))
        #expect(copied.audioClips.contains { $0.link == .screen && $0.start == 0 && $0.end == 2 && $0.mediaStart == 4 })
        let pasted = project.pasteSelection(copied, atOutput: 1)
        #expect(pasted != nil)
        #expect(project.audioClips.allSatisfy { abs(project.syncOffset($0) ?? 100) < 1e-9 })
        #expect(project.checkInvariants() == nil)
    }
}

@Test func linkedAudioPartialPartnersAndOptionEdits() throws {
    var project = Project(source: Source(duration: 20, hasSystemAudio: true), clips: [Clip(sourceStart: 0, sourceEnd: 20)],
        audioTracks: [AudioTrack(name: "System")],
        audioClips: [AudioClip(start: 2, end: 8, mediaStart: 2, file: "system.m4a", link: .screen)])
    let id = UUID(uuidString: project.audioClips[0].id)!
    project.resizeAudio(id, edge: .leading, to: 3)
    #expect(project.clips.first?.sourceStart == 0 && project.clips.first?.sourceEnd == 2)
    #expect(project.clips.last?.sourceStart == 8 && project.clips.last?.sourceEnd == 20)
    #expect(project.clips.contains { $0.sourceStart == 2 && $0.sourceEnd == 3 && $0.isEmpty })
    let video = project.clips
    project.resizeAudio(id, edge: .leading, to: 4, propagate: false)
    #expect(project.clips == video && project.audioClips[0].start == 4)
    project.removeBlock(id, propagate: false)
    #expect(project.clips == video && project.audioClips.isEmpty)
    project = linkedAudioFixture()
    let cameraID = UUID(uuidString: project.cameraClips[0].id)!
    let audio = project.audioClips
    project.moveCamera(cameraID, toStart: 3, propagate: false)
    #expect(project.audioClips == audio && project.syncOffset(audio[0]) == -1)
    project.removeBlock(cameraID, propagate: false)
    #expect(project.audioClips == audio)
    #expect(project.checkInvariants() == nil)
}

@Test func linkedAudioOptionVideoEditsTouchOnlyVideo() throws {
    var project = Project(source: Source(duration: 12, hasCamera: true, hasMic: true, hasSystemAudio: true),
                          clips: [Clip(sourceStart: 0, sourceEnd: 12)])
    _ = project.placeClip(0, start: 0, end: 8)
    let audio = project.audioClips, camera = project.cameraClips
    let selected = project.moveClips([0], byOutput: 1, propagate: false)
    let index = try #require(selected.first)
    #expect(project.clips[index].sourceStart == 1 && project.audioClips == audio && project.cameraClips == camera)
    project.trimClip(index, edge: .trailing, toSource: 8, propagate: false)
    #expect(project.clips[index].sourceEnd == 8 && project.audioClips == audio && project.cameraClips == camera)
    project.rippleDelete = false
    project.deleteClips([index], propagate: false)
    #expect(project.clips.allSatisfy(\.isEmpty) && project.audioClips == audio && project.cameraClips == camera)
    #expect(project.checkInvariants() == nil)
}

private struct LinkedAudioRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
