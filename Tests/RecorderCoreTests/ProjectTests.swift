import Foundation
import Testing
@testable import RecorderCore

@Test func projectRoundTrip() throws {
    let p = Project(
        version: 1,
        id: "11111111-1111-1111-1111-111111111111",
        title: "My Recording",
        createdAt: "2026-09-18T00:00:00Z",
        source: Source(kind: .window, pixelWidth: 2880, pixelHeight: 1800, scale: 2, duration: 93.4,
                        hasCamera: true, hasMic: true, hasSystemAudio: false),
        clips: [Clip(sourceStart: 0, sourceEnd: 41.2, speed: 1), Clip(sourceStart: 47.0, sourceEnd: 93.4, speed: 2)],
        zooms: [Zoom(id: "z1", start: 3.1, end: 7.9, scale: 2.0, mode: .auto,
                      center: NormPoint(x: 0.5, y: 0.5), instant: false, enabled: true)],
        layouts: [Layout(id: "l1", start: 0, end: 5, kind: .cameraFull)],
        masks: [Mask(id: "m1", start: 10, end: 14, kind: .highlight,
                      rect: NormRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4), opacity: 0.8)],
        cursorHidden: [TimeRange(start: 20, end: 25)],
        crop: NormRect(x: 0, y: 0, w: 1, h: 1),
        output: Output(aspect: .r16x9),
        background: Background(kind: .gradient, wallpaper: "01", color: "#5B3DF5",
                                gradient: ["#5B3DF5", "#E0567A"], gradientAngle: 45, imagePath: "background.jpg", blur: 0),
        frame: Frame(padding: 0.08, cornerRadius: 0.02, inset: 0, insetColor: "#000000", shadow: 0.5),
        cursor: CursorStyle(hidden: false, size: 1.5, style: .smooth, hideWhenIdle: true, loop: false,
                             alwaysArrow: false, rotate: false, removeShakes: false, clickSound: false),
        animation: Animation(screen: .focused, motionBlur: 0.5, blurCursor: true, blurZoom: true, blurPan: true),
        camera: Camera(size: 0.2, corner: .bottomRight, roundness: 0.5, mirror: true, shadow: 0.5, shrinkWhenZoomed: true),
        audio: Audio(micVolume: 1, systemVolume: 1, micMuted: false, systemMuted: false, denoise: false),
        keys: Keys(show: false)
    )
    let data = try JSONEncoder().encode(p)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded == p)
}

@Test func projectDefaultsFromMinimalJSON() throws {
    let json = """
    {"version":1,"source":{"kind":"display","pixelWidth":2880,"pixelHeight":1800,"scale":2,"duration":93.4,"hasCamera":true,"hasMic":true,"hasSystemAudio":false}}
    """
    let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(p.frame.padding == 0.08)
    #expect(p.clips.isEmpty)
    #expect(p.crop == NormRect(x: 0, y: 0, w: 1, h: 1))
    #expect(p.source.pixelWidth == 2880)
}

@Test func projectRejectsNewerVersion() throws {
    let json = """
    {"version":\(Project.currentVersion + 1),"source":{}}
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ProjectError.self) {
        try Project.load(from: url)
    }
}

@Test func audioModelRoundTrip() throws {
    let project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20)],
        audioTracks: [AudioTrack(id: "track", name: "Audio 1", volume: 1.5, muted: true)],
        audioClips: [AudioClip(id: "audio", start: 1, end: 4, mediaStart: 2, mediaRate: 0.5,
                              file: "media/video.mov", link: .layer, layer: "video", gain: 0.7, fadeIn: 0.2, fadeOut: 0.4)],
        layers: [LayerBlock(id: "video", kind: .video, start: 1, end: 4, file: "media/video.mov", mediaStart: 2,
                            rect: NormRect(x: 0.1, y: 0.2, w: 0.6, h: 0.4), backdrop: .blur, motion: .slide,
                            fadeIn: 0.1, fadeOut: 0.6, aboveCamera: true),
                 LayerBlock(id: "image", kind: .image, start: 4, end: 8, file: "media/image.png", track: 1,
                            rect: NormRect(), backdrop: .none, motion: .scale, fadeIn: nil, fadeOut: nil)])
    #expect(project.checkInvariants(mediaDurations: ["media/video.mov": 8]) == nil)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
    #expect(Project.currentVersion == 3)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    try project.save(to: url)
    #expect(try Project.load(from: url) == project)
}

@Test func audioModelLegacyDerivation() throws {
    let json = """
    {"source":{"duration":20,"hasCamera":true,"hasMic":true,"hasSystemAudio":true},
     "clips":[{"sourceStart":2,"sourceEnd":6,"speed":2},
              {"sourceStart":6,"sourceEnd":8,"speed":1,"isGap":true},
              {"sourceStart":10,"sourceEnd":14,"speed":2,"clockSpeed":1,"mediaStart":12}],
     "audio":{"micVolume":0.6,"micMuted":true,"systemVolume":1.4,"systemMuted":false,"denoise":true}}
    """
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.audioTracks.map(\.name) == ["Mic", "System"])
    #expect(project.audioTracks.map(\.volume) == [0.6, 1.4])
    #expect(project.audioTracks.map(\.muted) == [true, false])
    #expect(project.audio.denoise)
    #expect(project.audioClips.count == 4)
    #expect(project.checkInvariants() == nil)
    let map = TimeMap(project.clips)
    for track in 0...1 {
        let audioClips = project.audioClips.filter { $0.track == track }
        #expect(audioClips.map(\.file) == Array(repeating: track == 0 ? "mic.m4a" : "system.m4a", count: 2))
        #expect(audioClips.map(\.link) == Array(repeating: track == 0 ? .camera : .screen, count: 2))
        #expect(audioClips.map(\.mediaStart) == [2, 12])
        #expect(audioClips.map(\.mediaRate) == [1, 2])
        #expect(audioClips.map { ($0.end - $0.start) * ($0.mediaRate ?? 1) } == [4, 8])
        #expect(audioClips.map { map.outputTime(atSource: $0.start) } == [0, 4])
        #expect(audioClips.map { map.outputTime(atSource: $0.end) } == [2, 8])
    }
    for hasMic in [false, true] {
        for hasSystem in [false, true] {
            let source = Source(duration: 2, hasMic: hasMic, hasSystemAudio: hasSystem)
            let derived = Project(source: source, clips: [Clip(sourceStart: 0, sourceEnd: 2)])
            #expect(derived.audioTracks.count == (hasMic ? 1 : 0) + (hasSystem ? 1 : 0))
            #expect(derived.audioClips.allSatisfy { $0.link == .screen })
            #expect(derived.checkInvariants() == nil)
        }
    }
    var explicit = project
    explicit.audioClips = []
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(explicit))
    #expect(decoded == explicit)
    let empty = Project(source: project.source, clips: project.clips, audioTracks: [], audioClips: [])
    #expect(empty.audioClips.isEmpty && empty.audioTracks.isEmpty)
}

@Test func audioModelDefaultsAndMediaAdvance() throws {
    let data = Data("{}".utf8)
    let track = try JSONDecoder().decode(AudioTrack.self, from: data)
    #expect(track.volume == 1 && !track.muted)
    var audioClip = try JSONDecoder().decode(AudioClip.self, from: data)
    #expect(audioClip.link == nil && audioClip.layer == nil && audioClip.gain == 1)
    #expect(audioClip.fadeIn == nil && audioClip.fadeOut == nil && audioClip.mediaRate == nil)
    audioClip.mediaRate = 2
    audioClip.advanceMedia(by: 0.5)
    #expect(audioClip.mediaStart == 1)
    var layer = try JSONDecoder().decode(LayerBlock.self, from: data)
    #expect(layer.kind == .image && layer.backdrop == .dim && layer.motion == .fade)
    #expect(layer.fadeIn == 0.3 && layer.fadeOut == 0.3 && !layer.aboveCamera)
    layer.advanceMedia(by: 2)
    #expect(layer.mediaStart == 0)
    layer.kind = .video
    layer.advanceMedia(by: 2)
    #expect(layer.mediaStart == 2)
}

@Test func audioModelInvariants() {
    let base = Project(source: Source(duration: 20),
        clips: [Clip(sourceStart: 0, sourceEnd: 4, speed: 2), Clip(sourceStart: 4, sourceEnd: 20)],
        audioTracks: [AudioTrack(name: "Audio 1")],
        audioClips: [AudioClip(start: 0, end: 1, file: "media/video.mov", link: .layer, layer: "video"),
                     AudioClip(start: 4, end: 6, mediaStart: 1, file: "media/music.m4a")],
        layers: [LayerBlock(id: "video", kind: .video, start: 0, end: 1, file: "media/video.mov", rect: NormRect()),
                 LayerBlock(kind: .image, start: 4, end: 6, file: "media/image.png", rect: NormRect())])
    let durations = ["media/video.mov": 5.0, "media/music.m4a": 8.0]
    #expect(base.checkInvariants(mediaDurations: durations) == nil)
    let invalidEdits: [(inout Project) -> Void] = [
        { $0.audioClips[0].end = 3 },
        { $0.audioClips.reverse() },
        { $0.audioClips[0].track = -1 },
        { $0.audioClips[0].track = 1 },
        { $0.audioClips[0].layer = "missing" },
        { $0.audioClips[0].layer = nil },
        { $0.audioClips[0].link = nil },
        { $0.layers[0].kind = .image },
        { $0.audioClips[0].gain = 2.1 },
        { $0.audioClips[0].gain = -.infinity },
        { $0.audioTracks[0].volume = -0.1 },
        { $0.audioClips[0].mediaStart = -1 },
        { $0.audioClips[0].mediaRate = 0 },
        { $0.audioClips[0].mediaStart = 5 },
        { $0.audioClips[0].fadeIn = -0.1 },
        { $0.audioClips[0].end = 0.09 },
        { $0.audioClips[0].start = .nan },
        { $0.audioClips[0].end = .infinity },
        { $0.layers[0].end = 3 },
        { $0.layers.reverse() },
        { $0.layers[0].end = 0.49 },
        { $0.layers[0].track = -1 },
        { $0.layers[0].rect.w = 0 },
        { $0.layers[0].rect.x = -0.1 },
        { $0.layers[0].rect.h = 1.1 },
        { $0.layers[0].rect.y = .nan },
        { $0.layers[0].mediaStart = 5 },
        { $0.layers[0].fadeOut = .infinity }
    ]
    for edit in invalidEdits {
        var invalid = base
        edit(&invalid)
        #expect(invalid.checkInvariants(mediaDurations: durations) != nil)
    }
    var separateLanes = base
    separateLanes.audioTracks.append(AudioTrack(name: "Audio 2"))
    separateLanes.audioClips[1].start = 1; separateLanes.audioClips[1].end = 3; separateLanes.audioClips[1].track = 1
    separateLanes.layers[1].start = 1; separateLanes.layers[1].end = 3; separateLanes.layers[1].track = 1
    #expect(separateLanes.checkInvariants(mediaDurations: durations) == nil)
    separateLanes.audioClips[1].track = 0
    #expect(separateLanes.checkInvariants(mediaDurations: durations) != nil)
    separateLanes.audioClips[1].track = 1; separateLanes.layers[1].track = 0
    #expect(separateLanes.checkInvariants(mediaDurations: durations) != nil)
    var shortLinked = base
    shortLinked.audioClips[1].link = .screen
    shortLinked.audioClips[1].start = 1; shortLinked.audioClips[1].end = 1.15
    #expect(shortLinked.checkInvariants() != nil)
}

@Test func eventLogRoundTrip() throws {
    let log = EventLog(events: [
        InputEvent(t: 0.1, k: .move, x: 0.10, y: 0.20),
        InputEvent(t: 0.2, k: .down, x: 0.10, y: 0.20, b: 0),
        InputEvent(t: 0.3, k: .drag, x: 0.15, y: 0.25, b: 0),
        InputEvent(t: 0.4, k: .up, x: 0.15, y: 0.25, b: 0),
        InputEvent(t: 0.5, k: .down, x: 0.50, y: 0.50, b: 1),
        InputEvent(t: 0.6, k: .scroll, x: 0.50, y: 0.50),
        InputEvent(t: 0.7, k: .key, keyCode: 8, mods: 1 << 20),
        InputEvent(t: 0.8, k: .typing),
        InputEvent(t: 0.9, k: .cursor, id: "ab12"),
    ])

    let data = try JSONEncoder().encode(log)
    let decoded = try JSONDecoder().decode(EventLog.self, from: data)
    #expect(decoded.events == log.events)

    // drag counts as move
    #expect(decoded.moves().map(\.k) == [.move, .drag])
    // clicks = left .down only (the right .down at t=0.5 is excluded)
    #expect(decoded.clicks().map(\.t) == [0.2])
}

@Test func maskTransitionsAndCompatibility() throws {
    let old = try JSONDecoder().decode(Mask.self, from: Data("{\"start\":1,\"end\":5}".utf8))
    #expect(old.transition == 0)
    #expect(old.strength(at: 1) == 0.8)
    let mask = Mask(start: 1, end: 5, kind: .blur, opacity: 1, transition: 0.5)
    #expect(mask.strength(at: 0) == 0)
    #expect(mask.strength(at: 1) == 0)
    #expect(mask.strength(at: 1.25) == 0.5)
    #expect(mask.strength(at: 3) == 1)
    #expect(mask.strength(at: 4.75) == 0.5)
    #expect(mask.strength(at: 5) == 0)
    #expect(try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(mask)) == mask)
    var project = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10)], masks: [mask])
    let duplicate = project.duplicateBlock(UUID(uuidString: mask.id)!)!
    #expect(project.masks.first { $0.id == duplicate.uuidString }?.transition == 0.5)
}

@Test func captureFramingDefaultsAndOverrides() throws {
    for kind in [Source.Kind.display, .window, .area] {
        // Existing projects have no enabled flag, even when frame styling was saved.
        let json = """
        {"source":{"kind":"\(kind.rawValue)"},"frame":{"padding":0.12,"cornerRadius":0.03,"shadow":0.7}}
        """
        var project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.framingEnabled)
        #expect(Project(source: Source(kind: kind)).framingEnabled)
        let savedFrame = project.frame
        project.frame.enabled = false
        #expect(project.renderedFrame.padding == 0)
        #expect(project.renderedFrame.cornerRadius == 0)
        #expect(project.renderedFrame.shadow == 0)
        #expect(screenRect(output: CGSize(width: 1920, height: 1080), cropAspect: 16.0 / 9,
                           padding: project.renderedFrame.padding) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        project.frame.enabled = true
        #expect(project.renderedFrame.padding == savedFrame.padding)
        #expect(project.renderedFrame.cornerRadius == savedFrame.cornerRadius)
        #expect(project.renderedFrame.shadow == savedFrame.shadow)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.framingEnabled)
        #expect(decoded == project)
        project.frame.enabled = false
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).framingEnabled == false)
    }
}
