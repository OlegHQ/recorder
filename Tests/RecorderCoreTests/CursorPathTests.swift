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

@Test func shakeRemovalDropsBriefExcursion() {
    // A quick (1 ms) 19.2 px jump that returns 40 ms later, well inside the 80 ms window. `.none`
    // spring passes raw straight through so the two paths only differ by the shake filter.
    let events = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.5, y: 0.5),
        InputEvent(t: 0.499, k: .move, x: 0.5, y: 0.5),
        InputEvent(t: 0.5, k: .move, x: 0.51, y: 0.5),
        InputEvent(t: 0.54, k: .move, x: 0.5, y: 0.5),
        InputEvent(t: 2.0, k: .move, x: 0.5, y: 0.5),
    ])
    let kept = CursorPath(events: events, style: CursorStyle(style: .none, removeShakes: false), hidden: [], duration: 3)
    let removed = CursorPath(events: events, style: CursorStyle(style: .none, removeShakes: true), hidden: [], duration: 3)

    #expect(kept.sample(atSource: 0.5).x > 0.505)
    #expect(abs(removed.sample(atSource: 0.5).x - 0.5) < 0.002)
}

@Test func loopSpringsTowardFirstPosition() {
    let events = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.2, y: 0.3),
        InputEvent(t: 1, k: .move, x: 0.8, y: 0.7),
    ])
    let duration = 4.0
    let path = CursorPath(events: events, style: CursorStyle(style: .rapid, loop: true), hidden: [], duration: duration)
    let s = path.sample(atSource: duration)
    #expect(abs(s.x - 0.2) < 0.01)
    #expect(abs(s.y - 0.3) < 0.01)

    // Without loop enabled the tail stays near the last real move, not the start.
    let noLoop = CursorPath(events: events, style: CursorStyle(style: .rapid, loop: false), hidden: [], duration: duration)
    let n = noLoop.sample(atSource: duration)
    #expect(abs(n.x - 0.8) < 0.01)
}

@Test func rotationTiltsWithHorizontalVelocityAndClamps() {
    let sweeping = EventLog(events: [
        InputEvent(t: 0, k: .move, x: 0.0, y: 0.5),
        InputEvent(t: 1, k: .move, x: 1.0, y: 0.5),
    ])
    let path = CursorPath(events: sweeping, style: CursorStyle(style: .none, rotate: true), hidden: [], duration: 2)
    let s = path.sample(atSource: 0.5)
    #expect(s.rotation > 0)
    #expect(s.rotation <= 12 + 1e-6)

    let still = EventLog(events: [InputEvent(t: 0, k: .move, x: 0.5, y: 0.5)])
    let stillPath = CursorPath(events: still, style: CursorStyle(style: .none, rotate: true), hidden: [], duration: 2)
    #expect(stillPath.sample(atSource: 1).rotation == 0)

    let noRotate = CursorPath(events: sweeping, style: CursorStyle(style: .none, rotate: false), hidden: [], duration: 2)
    #expect(noRotate.sample(atSource: 0.5).rotation == 0)
}

@Test func alwaysArrowIgnoresSampledCursorImage() {
    let events = EventLog(events: [
        InputEvent(t: 0, k: .cursor, id: "hand"),
        InputEvent(t: 0, k: .move, x: 0.5, y: 0.5),
    ])
    let normal = CursorPath(events: events, style: CursorStyle(alwaysArrow: false), hidden: [], duration: 1)
    let arrowOnly = CursorPath(events: events, style: CursorStyle(alwaysArrow: true), hidden: [], duration: 1)

    #expect(normal.sample(atSource: 0.5).imageID == "hand")
    #expect(arrowOnly.sample(atSource: 0.5).imageID == nil)
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
