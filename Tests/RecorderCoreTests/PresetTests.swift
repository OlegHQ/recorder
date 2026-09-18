import Testing
import Foundation
@testable import RecorderCore

@Test func presetRoundTripAndApply() throws {
    var source = Project()
    source.title = "Source project"
    source.clips = [Clip(sourceStart: 1, sourceEnd: 5, speed: 2)]
    source.zooms = [Zoom(start: 1, end: 3, scale: 1.8)]
    source.crop = NormRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)
    source.background = Background(kind: .color, color: "#123456", blur: 0.4)
    source.frame = Frame(padding: 0.2, cornerRadius: 0.1, shadow: 0.9)
    source.cursor = CursorStyle(size: 2.5, style: .rapid, loop: true)
    source.animation = Animation(screen: .smooth, motionBlur: 0.9)
    source.camera = Camera(size: 0.4, corner: .topLeft, roundness: 0.9)

    let preset = Preset(name: "My preset", from: source)
    #expect(preset.name == "My preset")
    #expect(preset.background == source.background)
    #expect(preset.frame == source.frame)
    #expect(preset.cursor == source.cursor)
    #expect(preset.animation == source.animation)
    #expect(preset.camera == source.camera)

    // Apply onto an unrelated project: only the styling subset changes.
    var target = Project()
    target.title = "Target project"
    target.clips = [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)]
    target.zooms = [Zoom(start: 4, end: 6, scale: 1.2)]
    target.crop = NormRect(x: 0, y: 0, w: 1, h: 1)
    let untouchedSource = target.source
    let untouchedClips = target.clips
    let untouchedZooms = target.zooms
    let untouchedCrop = target.crop
    let untouchedTitle = target.title

    preset.apply(to: &target)

    #expect(target.background == source.background)
    #expect(target.frame == source.frame)
    #expect(target.cursor == source.cursor)
    #expect(target.animation == source.animation)
    #expect(target.camera == source.camera)

    #expect(target.source == untouchedSource)
    #expect(target.clips == untouchedClips)
    #expect(target.zooms == untouchedZooms)
    #expect(target.crop == untouchedCrop)
    #expect(target.title == untouchedTitle)

    // JSON round-trip.
    let data = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(Preset.self, from: data)
    #expect(decoded == preset)
}
