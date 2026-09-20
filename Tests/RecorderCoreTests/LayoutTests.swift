import Foundation

import Testing
import CoreGraphics
@testable import RecorderCore

@Suite("Layout")
struct LayoutTests {
    @Test func layoutFitsAndCentres() {
        let output = CGSize(width: 1920, height: 1080)
        let padding = 0.08
        for cropAspect in [16.0 / 9.0, 9.0 / 16.0, 1.0, 4.0 / 3.0, 21.0 / 9.0] {
            let rect = screenRect(output: output, cropAspect: cropAspect, padding: padding)

            // Fits inside the output.
            #expect(rect.minX >= -0.001)
            #expect(rect.minY >= -0.001)
            #expect(rect.maxX <= output.width + 0.001)
            #expect(rect.maxY <= output.height + 0.001)

            // Centred.
            #expect(abs(rect.midX - output.width / 2) < 0.001)
            #expect(abs(rect.midY - output.height / 2) < 0.001)

            // Preserves the crop aspect.
            #expect(abs(rect.width / rect.height - cropAspect) < 0.001)

            // At least one axis touches the padded inset (it's the *largest* rect that fits).
            let inset = padding * min(output.width, output.height)
            let touchesWidth = abs(rect.width - (output.width - 2 * inset)) < 0.001
            let touchesHeight = abs(rect.height - (output.height - 2 * inset)) < 0.001
            #expect(touchesWidth || touchesHeight)
        }
    }

    @Test func layoutAspects() {
        let longEdge = 1920
        let source = CGSize(width: 1600, height: 1000) // 16:10
        let cropAspect = source.width / source.height

        // A 9:16 output canvas: portrait, even dimensions, exactly that ratio.
        let output = outputSize(aspect: .r9x16, croppedSource: source, longEdge: longEdge)
        #expect(Int(output.height) == longEdge)
        #expect(output.width.truncatingRemainder(dividingBy: 2) == 0)
        #expect(output.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(abs(output.width / output.height - 9.0 / 16.0) < 0.001)

        // The 16:10 source still keeps its own aspect inside the padded screen rect, letterboxed
        // (top/bottom or side bars) inside the mismatched 9:16 canvas.
        let rect = screenRect(output: output, cropAspect: cropAspect, padding: 0.08)
        #expect(abs(rect.width / rect.height - cropAspect) < 0.001)
        #expect(rect.width <= output.width + 0.001)
        #expect(rect.height <= output.height + 0.001)

        // `.auto` keeps the output canvas itself at the (cropped) source aspect — no letterboxing.
        let autoOutput = outputSize(aspect: .auto, croppedSource: source, longEdge: longEdge)
        #expect(abs(autoOutput.width / autoOutput.height - cropAspect) < 0.01)
        #expect(Int(autoOutput.width) == longEdge)
    }

    @Test func layoutMixFadesAtEdges() {
        let fade = 0.3
        let block = Layout(id: "a", start: 2, end: 8, kind: .cameraFull)

        // 0 well outside the block, and right at its edges.
        #expect(layoutMix(layouts: [block], atSource: 0.5, fade: fade).amount == 0)
        #expect(layoutMix(layouts: [block], atSource: 0.5, fade: fade).kind == nil)
        #expect(layoutMix(layouts: [block], atSource: 9, fade: fade).amount == 0)
        #expect(layoutMix(layouts: [block], atSource: block.start, fade: fade).amount == 0)
        #expect(layoutMix(layouts: [block], atSource: block.end, fade: fade).amount == 0)

        // Rising through the leading edge.
        let rise1 = layoutMix(layouts: [block], atSource: block.start + 0.05, fade: fade).amount
        let rise2 = layoutMix(layouts: [block], atSource: block.start + 0.15, fade: fade).amount
        let rise3 = layoutMix(layouts: [block], atSource: block.start + 0.25, fade: fade).amount
        #expect(0 < rise1 && rise1 < rise2 && rise2 < rise3 && rise3 < 1)

        // 1 well inside the block.
        let mid = layoutMix(layouts: [block], atSource: (block.start + block.end) / 2, fade: fade)
        #expect(mid.kind == .cameraFull)
        #expect(abs(mid.amount - 1) < 1e-9)

        // Falling at the trailing edge, mirroring the rise.
        let fall1 = layoutMix(layouts: [block], atSource: block.end - 0.05, fade: fade).amount
        let fall2 = layoutMix(layouts: [block], atSource: block.end - 0.15, fade: fade).amount
        let fall3 = layoutMix(layouts: [block], atSource: block.end - 0.25, fade: fade).amount
        #expect(0 < fall1 && fall1 < fall2 && fall2 < fall3 && fall3 < 1)
        #expect(abs(fall1 - rise1) < 1e-9) // symmetric in/out
        #expect(abs(fall2 - rise2) < 1e-9)

        // Continuous: a tiny nudge across each boundary (block start/end, and the point each ramp
        // finishes) changes the amount by only a tiny amount.
        let epsilon = 1e-7
        for point in [block.start, block.end, block.start + fade, block.end - fade] {
            let before = layoutMix(layouts: [block], atSource: point - epsilon, fade: fade).amount
            let at = layoutMix(layouts: [block], atSource: point, fade: fade).amount
            let after = layoutMix(layouts: [block], atSource: point + epsilon, fade: fade).amount
            #expect(abs(at - before) < 1e-6)
            #expect(abs(after - at) < 1e-6)
        }

        // Order-independent.
        let other = Layout(id: "b", start: 20, end: 25, kind: .hidden)
        let a = layoutMix(layouts: [block, other], atSource: 22.5, fade: fade)
        let b = layoutMix(layouts: [other, block], atSource: 22.5, fade: fade)
        #expect(a.kind == b.kind && abs(a.amount - b.amount) < 1e-12)
    }
}

@Test func zoomedScreenRectPutsViewportOnBase() {
    let base = CGRect(x: 100, y: 50, width: 800, height: 400)
    #expect(zoomedScreenRect(base: base, view: .identity) == base)
    // 2× clamped to the top-left: that corner keeps its padding, the frame overflows right/down.
    #expect(zoomedScreenRect(base: base, view: ViewTransform(cx: 0.25, cy: 0.25, scale: 2)) == CGRect(x: 100, y: 50, width: 1600, height: 800))
    // 2× centred: grows symmetrically about the base's centre.
    #expect(zoomedScreenRect(base: base, view: ViewTransform(cx: 0.5, cy: 0.5, scale: 2)) == CGRect(x: -300, y: -150, width: 1600, height: 800))
}

@Test func cameraPlacementAndAspectTransitions() throws {
    let output = CGSize(width: 1920, height: 1080)
    var project = Project()
    project.camera.shrinkWhenZoomed = false
    var target = Camera(size: 0.6, shrinkWhenZoomed: false,
                        position: NormPoint(x: 0.2, y: 0.3), aspect: 16.0 / 9)
    let expected = cameraOverlayRect(camera: target, output: output)
    #expect(abs(expected.width / expected.height - 16.0 / 9) < 1e-9)
    #expect(expected.minX >= 0 && expected.maxX <= output.width)
    #expect(expected.minY >= 0 && expected.maxY <= output.height)
    project.layouts = [Layout(start: 2, end: 6, kind: .bubble, camera: target)]
    let base = cameraOverlayRect(camera: project.camera, output: output)
    #expect(cameraOverlayRect(project: project, output: output, atSource: 2) == base)
    let settled = cameraOverlayRect(project: project, output: output, atSource: 4)
    #expect(abs(settled.minX - expected.minX) < 1e-9 && abs(settled.minY - expected.minY) < 1e-9)
    #expect(settled.size == expected.size)
    #expect(cameraOverlayRect(project: project, output: output, atSource: 6) == base)
    let during = cameraOverlayRect(project: project, output: output, atSource: 2.15)
    #expect(during.width > base.width && during.width < expected.width)
    #expect(during.minX < base.minX && during.minX > expected.minX)
    for boundary in [2.0, 2.3, 5.7, 6.0] {
        let before = cameraOverlayRect(project: project, output: output, atSource: boundary - 1e-7)
        let after = cameraOverlayRect(project: project, output: output, atSource: boundary + 1e-7)
        #expect(abs(before.width - after.width) < 0.001)
        #expect(abs(before.minX - after.minX) < 0.001)
    }
    for aspect in [9.0 / 16, 1, 4.0 / 3, 16.0 / 9] {
        target.aspect = aspect
        let rect = cameraOverlayRect(camera: target, output: output)
        #expect(abs(rect.width / rect.height - aspect) < 1e-9)
    }
    let encoded = try JSONEncoder().encode(project)
    #expect(try JSONDecoder().decode(Project.self, from: encoded) == project)
    let legacy = try JSONDecoder().decode(Camera.self, from: Data("{}".utf8))
    #expect(legacy.aspect == 1 && legacy.position == nil)
    let legacyLayout = try JSONDecoder().decode(Layout.self, from: Data("{}".utf8))
    #expect(legacyLayout.camera == nil && legacyLayout.kind == .cameraFull)
}

@Test func fullscreenCameraCropNeverStretches() {
    let source = CGSize(width: 1280, height: 720)
    for destination in [CGSize(width: 200, height: 200), CGSize(width: 1920, height: 1080),
                        CGSize(width: 600, height: 800), CGSize(width: 954, height: 672)] {
        let crop = cameraCrop(source: source, destination: destination)
        #expect(abs(source.width * crop.width / (source.height * crop.height)
                    - destination.width / destination.height) < 1e-9)
        #expect(crop.minX >= 0 && crop.maxX <= 1 && crop.minY >= 0 && crop.maxY <= 1)
    }
    #expect(cameraCrop(source: source, destination: source) == CGRect(x: 0, y: 0, width: 1, height: 1))
}

@Test func overlaySettingsClipsRoundTripAndInterpolate() throws {
    var project = Project(source: Source(duration: 10))
    project.keys = Keys(show: true)
    var block = Layout(start: 2, end: 6, kind: .settings,
                       keys: Keys(show: false, allKeys: true, size: 2, position: NormPoint(x: 0, y: 0), hold: 3))
    project.keystrokeClips = [block]
    #expect(overlayKeys(project: project, atSource: 1).settings == project.keys)
    #expect(overlayKeys(project: project, atSource: 2).opacity == 1)
    let during = overlayKeys(project: project, atSource: 2.15)
    #expect(during.opacity > 0 && during.opacity < 1)
    #expect(during.settings.size > 1 && during.settings.size < 2)
    #expect(during.settings.position.x > 0 && during.settings.position.x < 0.5)
    #expect(overlayKeys(project: project, atSource: 4).opacity == 0)
    #expect(overlayKeys(project: project, atSource: 6).settings == project.keys)
    block.camera = Camera(roundness: 0.1, mirror: false, shadow: 0.2)
    project.keystrokeClips = [block]
    #expect(overlayCamera(project: project, atSource: 4) == project.camera)
    block.kind = .bubble
    project.layouts = [block]
    #expect(abs(overlayCamera(project: project, atSource: 4).roundness - 0.1) < 1e-9)
    #expect(!overlayCamera(project: project, atSource: 4).mirror)
    block.transition = 0
    project.layouts = [block]
    project.keystrokeClips[0].transition = 0
    #expect(overlayKeys(project: project, atSource: 2).opacity == 0)
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
    let legacy = try JSONDecoder().decode(Keys.self, from: Data("{\"show\":true}".utf8))
    #expect(legacy == Keys(show: true))
    let events = [InputEvent(t: 1, k: .key, keyCode: 0, mods: 0), InputEvent(t: 0.9, k: .key, keyCode: 8, mods: 0x100000)]
    #expect(activeKeyChip(events: events, atSource: 1.1, allKeys: true)?.label == "A")
    #expect(activeKeyChip(events: events, atSource: 1.1, allKeys: false)?.label == "⌘ C")
    let output = CGSize(width: 1920, height: 1080)
    let centered = cameraOverlayRect(camera: Camera(position: NormPoint()), output: output)
    #expect(abs(centered.midX - 960) < 1e-9 && abs(centered.midY - 540) < 1e-9)
}
