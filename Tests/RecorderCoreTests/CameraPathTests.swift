import Testing
@testable import RecorderCore

/// A tiny deterministic LCG so random tests are reproducible (style matches T-401's plan note).
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func emptyCursor(duration: Double) -> CursorPath {
    CursorPath(events: EventLog(), style: CursorStyle(), hidden: [], duration: duration)
}

@Test func viewportAlwaysInsideSource() {
    var rng = LCG(state: 42)
    let duration = 20.0
    var zooms: [Zoom] = []
    var t = 0.0
    while t < duration - 1 {
        let len = Double.random(in: 0.5...3, using: &rng)
        let start = t
        let end = min(duration, start + len)
        zooms.append(Zoom(start: start, end: end, scale: Double.random(in: 1.2...5, using: &rng),
                           mode: Bool.random(using: &rng) ? .manual : .auto,
                           center: NormPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng)),
                           instant: Bool.random(using: &rng)))
        t = end + Double.random(in: 0.1...1, using: &rng)
    }

    let path = CameraPath(zooms: zooms, cursor: emptyCursor(duration: duration), spring: .focused, duration: duration)
    var s = 0.0
    while s < duration {
        let v = path.sample(atSource: s)
        let half = 0.5 / v.scale
        #expect(v.cx - half >= -1e-6)
        #expect(v.cx + half <= 1 + 1e-6)
        #expect(v.cy - half >= -1e-6)
        #expect(v.cy + half <= 1 + 1e-6)
        s += 1.0 / 60
    }
}

@Test func cameraSampleIsOrderIndependent() {
    let zooms = [Zoom(start: 1, end: 3, scale: 2, mode: .manual, center: NormPoint(x: 0.3, y: 0.7))]
    let path = CameraPath(zooms: zooms, cursor: emptyCursor(duration: 6), spring: .focused, duration: 6)

    let times: [Double] = [5.9, 0.5, 2.0, 1.0, 3.5, 0.0, 6.0]
    let firstPass = times.map { path.sample(atSource: $0) }
    for (t, expected) in zip(times, firstPass) {
        #expect(path.sample(atSource: t) == expected)
    }
}

@Test func instantZoomJumps() {
    let zooms = [Zoom(start: 1, end: 2, scale: 2, mode: .manual, center: NormPoint(x: 0.5, y: 0.5), instant: true)]
    let path = CameraPath(zooms: zooms, cursor: emptyCursor(duration: 3), spring: .focused, duration: 3)

    // Sample times land exactly on the 240 Hz table grid so the jump itself (not the lerp across it) is checked.
    #expect(abs(path.sample(atSource: 0.9).scale - 1) < 0.01)
    #expect(path.sample(atSource: 1.0).scale == 2)
    #expect(abs(path.sample(atSource: 1.9).scale - 2) < 1e-9)
    #expect(path.sample(atSource: 2.0).scale == 1)
}

@Test func outsideZoomsIsIdentityEventually() {
    let zooms = [Zoom(start: 0, end: 1, scale: 3, mode: .manual, center: NormPoint(x: 0.2, y: 0.8))]
    let path = CameraPath(zooms: zooms, cursor: emptyCursor(duration: 5), spring: .focused, duration: 5)
    let v = path.sample(atSource: 4.9)
    #expect(abs(v.cx - 0.5) < 1e-4)
    #expect(abs(v.cy - 0.5) < 1e-4)
    #expect(abs(v.scale - 1) < 1e-4)
}
