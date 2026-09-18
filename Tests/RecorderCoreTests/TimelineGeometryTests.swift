import Testing
@testable import RecorderCore

@Test func zoomKeepsAnchorTime() {
    var g = TimelineGeometry(pxPerSecond: 60, scrollX: 120, width: 800)
    let anchorX = 200.0
    let anchorTime = g.output(forX: anchorX)
    g.zoom(by: 2, anchorX: anchorX, minPxPerSecond: 8, maxPxPerSecond: 4000)
    #expect(g.pxPerSecond == 120)
    #expect(abs(g.output(forX: anchorX) - anchorTime) < 1e-9)
}

@Test func zoomClampsToRange() {
    var g = TimelineGeometry(pxPerSecond: 60, scrollX: 0, width: 800)
    g.zoom(by: 1000, anchorX: 0, minPxPerSecond: 8, maxPxPerSecond: 4000)
    #expect(g.pxPerSecond == 4000)
    g.pxPerSecond = 60
    g.zoom(by: 0.0001, anchorX: 0, minPxPerSecond: 8, maxPxPerSecond: 4000)
    #expect(g.pxPerSecond == 8)
}

@Test func tickIntervalReadable() {
    // At any zoom level, consecutive ticks (tickInterval seconds apart) must land >= 70 pt apart.
    for pxPerSecond in [8.0, 30, 60, 240, 1000, 4000] {
        let g = TimelineGeometry(pxPerSecond: pxPerSecond, scrollX: 0, width: 800)
        let interval = g.tickInterval()
        #expect(interval * pxPerSecond >= 70 - 1e-9)
    }
}
