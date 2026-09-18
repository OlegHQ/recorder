import Foundation

/// Where the compositor looks at the source frame: a centre and a zoom scale. See docs/SPEC.md §6.2, §6.3.
public struct ViewTransform: Sendable, Equatable {
    public var cx, cy, scale: Double
    public init(cx: Double, cy: Double, scale: Double) { self.cx = cx; self.cy = cy; self.scale = scale }
    public static let identity = ViewTransform(cx: 0.5, cy: 0.5, scale: 1)
}

/// `zooms` → a 240 Hz lookup table of `ViewTransform`, simulated once. See docs/SPEC.md §6.3.
///
/// Target signal per step: outside any enabled zoom, identity; inside one, `scale = zoom.scale` and
/// centre = the zoom's manual centre, or (auto) the smoothed cursor position with a dead-zone — the
/// target only moves when the cursor leaves the central 60% of the *current* viewport, and then by
/// just enough to bring it back to that box. `instant` zooms jump straight to the target (zero
/// velocity) on both the entering and leaving edge; everything else reaches the target through `spring`.
public struct CameraPath: Sendable {
    private let rate: Double
    private let duration: Double
    private let table: [ViewTransform]

    public init(zooms: [Zoom], cursor: CursorPath, spring: Spring, duration: Double, rate: Double = 240) {
        self.rate = rate
        self.duration = max(duration, 0)
        let dt = 1 / rate
        let steps = max(1, Int((self.duration * rate).rounded()) + 1)

        func activeZoom(at t: Double) -> Zoom? {
            zooms.first { $0.enabled && t >= $0.start && t < $0.end }
        }
        func deadZoneTarget(cursorPos: Double, currentCenter: Double, scale: Double) -> Double {
            let half = 0.3 / scale
            if cursorPos < currentCenter - half { return cursorPos + half }
            if cursorPos > currentCenter + half { return cursorPos - half }
            return currentCenter
        }

        var cx = 0.5, cy = 0.5, scale = 1.0
        var vx = 0.0, vy = 0.0, vScale = 0.0
        var previousZoom: Zoom?
        var values = [ViewTransform](repeating: .identity, count: steps)

        for i in 0..<steps {
            let t = Double(i) * dt
            let zoom = activeZoom(at: t)

            let targetScale = zoom?.scale ?? 1
            let targetCX: Double, targetCY: Double
            if let zoom {
                if zoom.mode == .manual {
                    targetCX = zoom.center.x
                    targetCY = zoom.center.y
                } else {
                    let c = cursor.sample(atSource: t)
                    targetCX = deadZoneTarget(cursorPos: c.x, currentCenter: cx, scale: scale)
                    targetCY = deadZoneTarget(cursorPos: c.y, currentCenter: cy, scale: scale)
                }
            } else {
                targetCX = 0.5
                targetCY = 0.5
            }

            let boundaryZoom = zoom ?? previousZoom
            if zoom != previousZoom && boundaryZoom?.instant == true {
                cx = targetCX; cy = targetCY; scale = targetScale
                vx = 0; vy = 0; vScale = 0
            } else {
                spring.step(x: &cx, v: &vx, target: targetCX, dt: dt)
                spring.step(x: &cy, v: &vy, target: targetCY, dt: dt)
                spring.step(x: &scale, v: &vScale, target: targetScale, dt: dt)
            }

            // Clamp the viewport [c - 0.5/scale, c + 0.5/scale] inside 0...1 (AC-ZM-2).
            if scale <= 1 {
                cx = 0.5; cy = 0.5
            } else {
                let half = 0.5 / scale
                cx = min(max(cx, half), 1 - half)
                cy = min(max(cy, half), 1 - half)
            }

            values[i] = ViewTransform(cx: cx, cy: cy, scale: scale)
            previousZoom = zoom
        }
        table = values
    }

    /// Index + lerp; pure lookup — deterministic regardless of sampling order (AC-ZM-3).
    public func sample(atSource t: Double) -> ViewTransform {
        let clamped = min(max(t, 0), duration)
        let f = clamped * rate
        let i0 = min(max(Int(f), 0), table.count - 1)
        let i1 = min(i0 + 1, table.count - 1)
        let frac = f - Double(i0)
        let a = table[i0], b = table[i1]
        return ViewTransform(cx: a.cx + (b.cx - a.cx) * frac,
                              cy: a.cy + (b.cy - a.cy) * frac,
                              scale: a.scale + (b.scale - a.scale) * frac)
    }
}
