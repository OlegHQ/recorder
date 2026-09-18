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
}
