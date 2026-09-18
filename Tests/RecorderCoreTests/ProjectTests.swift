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
    {"version":2,"source":{}}
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ProjectError.self) {
        try Project.load(from: url)
    }
}
