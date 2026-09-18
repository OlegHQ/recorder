import Testing
@testable import RecorderCore

@Test func smoothedNeverLeadsRaw() {
    // A near-instant jump from 0.1 to 0.9, held after; a no-overshoot spring must never exceed it.
    let events = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.1, y: 0.1),
        InputEvent(t: 0.01, k: .move, x: 0.9, y: 0.9),
    ])
    let path = CursorPath(events: events, style: CursorStyle(style: .rapid), hidden: [], duration: 2)
    var t = 0.0
    while t < 2 {
        let s = path.sample(atSource: t)
        #expect(s.x <= 0.9 + 1e-6)
        #expect(s.y <= 0.9 + 1e-6)
        t += 1.0 / 240
    }
}

@Test func settlesWithinHalfPixelAfterRest() {
    let events = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.1, y: 0.2),
        InputEvent(t: 0.01, k: .move, x: 0.9, y: 0.8),
    ])
    let path = CursorPath(events: events, style: CursorStyle(style: .rapid), hidden: [], duration: 3)
    let s = path.sample(atSource: 1.01) // 1 s after the move settles
    let halfPixel = 0.5 / 1920.0
    #expect(abs(s.x - 0.9) < halfPixel)
    #expect(abs(s.y - 0.8) < halfPixel)
}

@Test func idleHidesAfterTwoSeconds() {
    let events = EventLog(events: [InputEvent(t: 0, k: .move, x: 0.5, y: 0.5)])
    let path = CursorPath(events: events, style: CursorStyle(), hidden: [], duration: 3)
    #expect(path.sample(atSource: 0).alpha == 1)
    #expect(path.sample(atSource: 1.9).alpha == 1)
    #expect(path.sample(atSource: 2.5).alpha < 0.01)
}

@Test func sampleIsOrderIndependent() {
    let events = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.1, y: 0.1),
        InputEvent(t: 0.5, k: .move, x: 0.6, y: 0.4),
        InputEvent(t: 1.2, k: .down, x: 0.6, y: 0.4, b: 0),
        InputEvent(t: 1.5, k: .move, x: 0.3, y: 0.9),
    ])
    let path = CursorPath(events: events, style: CursorStyle(style: .medium), hidden: [], duration: 3)

    let times: [Double] = [0.3, 2.9, 1.25, 0.0, 1.5, 0.75, 3.0]
    let firstPass = times.map { path.sample(atSource: $0) }
    let secondPass = times.reversed().map { path.sample(atSource: $0) }

    for (t, a) in zip(times, firstPass) {
        let b = path.sample(atSource: t)
        #expect(a.x == b.x && a.y == b.y && a.alpha == b.alpha && a.clickScale == b.clickScale)
    }
    #expect(firstPass.count == secondPass.count)
}
