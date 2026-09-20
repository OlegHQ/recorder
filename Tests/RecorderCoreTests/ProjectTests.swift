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
