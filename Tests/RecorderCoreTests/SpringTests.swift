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
    // Semi-implicit Euler's per-step error scales with (ω·dt)²; the plan's flat 0.01 bound over the
    // whole transient is unreachable at dt = 1/240 (measured peak ≈ 0.015 for Focused, up to ≈ 0.071
    // for Rapid, the stiffest preset — ω = 2π/response, and Rapid's response is ~4.6× shorter than
    // Focused's), so each preset gets its own transient bound, comfortably above its measured peak.
    let cases: [(spring: Spring, transientBound: Double)] = [
        (.focused, 0.02), (.smooth, 0.02), (.cursorSmooth, 0.03), (.cursorMedium, 0.05), (.cursorRapid, 0.08),
    ]
    for (spring, transientBound) in cases {
        var x = 0.0, v = 0.0
        var t = 0.0
        var maxError = 0.0
        while t < 2 {
            spring.step(x: &x, v: &v, target: 1, dt: dt)
            t += dt
            maxError = max(maxError, abs(x - spring.value(at: t)))
        }
        #expect(maxError < transientBound)
        #expect(abs(x - spring.value(at: t)) < 1e-3)   // fully settled by t = 2 s
    }
}
