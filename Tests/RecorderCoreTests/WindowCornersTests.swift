import Testing
@testable import RecorderCore

@Test func windowCornersFollowNativeAlpha() {
    for (width, height, radius) in [(400, 200, 0.0), (400, 200, 12.0), (800, 400, 48.0)] {
        let detected = detectedWindowCornerRadius(width: width, height: height) { x, y in
            let dx = max(0, radius - Double(min(x, width - 1 - x)) - 0.5)
            let dy = max(0, radius - Double(min(y, height - 1 - y)) - 0.5)
            return dx * dx + dy * dy <= radius * radius ? 255 : 0
        }
        #expect(detected != nil)
        #expect(abs((detected ?? -100) - radius) <= 1.5)
    }
    #expect(detectedWindowCornerRadius(width: 200, height: 100) { _, _ in 0 } == nil)
    #expect(detectedWindowCornerRadius(width: 0, height: 0) { _, _ in 255 } == nil)
}
