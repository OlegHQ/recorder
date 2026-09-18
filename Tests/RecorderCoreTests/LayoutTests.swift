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
