import Foundation

/// Damped harmonic oscillator, rest → 1. See docs/SPEC.md §6.3.
public struct Spring: Sendable {
    public var response: Double   // ω = 2π/response
    public var damping: Double    // ζ

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }

    /// Closed form, rest → 1.
    /// ζ ≥ 1: `1 − (1 + ωt)·e^(−ωt)`.
    /// ζ < 1: `1 − e^(−ζωt)·(cos ω_d t + (ζω/ω_d)·sin ω_d t)`, `ω_d = ω√(1−ζ²)`.
    public func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        if damping >= 1 {
            return 1 - (1 + omega * t) * exp(-omega * t)
        }
        let omegaD = omega * sqrt(1 - damping * damping)
        return 1 - exp(-damping * omega * t) * (cos(omegaD * t) + (damping * omega / omegaD) * sin(omegaD * t))
    }

    /// One semi-implicit Euler step toward a moving target.
    /// `a = ω²(target − x) − 2ζω·v`; `v += a·dt`; `x += v·dt`.
    public func step(x: inout Double, v: inout Double, target: Double, dt: Double) {
        let omega = 2 * Double.pi / response
        let a = omega * omega * (target - x) - 2 * damping * omega * v
        v += a * dt
        x += v * dt
    }

    public static let focused = Spring(response: 0.55, damping: 1)
    public static let smooth = Spring(response: 0.9, damping: 0.85)
    public static let cursorRapid = Spring(response: 0.12, damping: 1)
    public static let cursorMedium = Spring(response: 0.22, damping: 1)
    public static let cursorSmooth = Spring(response: 0.38, damping: 1)
}
