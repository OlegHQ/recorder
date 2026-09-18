import Testing
@testable import RecorderCore

@Test func springStartsAtZeroEndsAtOne() {
    for spring in [Spring.focused, .smooth, .cursorRapid, .cursorMedium, .cursorSmooth] {
        #expect(spring.value(at: 0) == 0)
        #expect(abs(spring.value(at: spring.response * 20) - 1) < 1e-6)
    }
}

@Test func criticallyDampedIsMonotonicNoOvershoot() {
    let spring = Spring.focused
    var last = 0.0
    var t = 0.0
    while t < 5 {
        let v = spring.value(at: t)
        #expect(v >= last - 1e-9)
        #expect(v <= 1 + 1e-9)
        last = v
        t += 1.0 / 240
    }
}

@Test func stepConvergesToClosedForm() {
    let dt = 1.0 / 240
    for spring in [Spring.focused, .smooth, .cursorRapid, .cursorMedium, .cursorSmooth] {
        var x = 0.0, v = 0.0
        var t = 0.0
        while t < 2 {
            spring.step(x: &x, v: &v, target: 1, dt: dt)
            t += dt
        }
        #expect(abs(x - spring.value(at: t)) < 0.01)
    }
}
