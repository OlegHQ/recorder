import Foundation

/// One sampled instant of the rendered (smoothed) cursor. See docs/SPEC.md §6.5, §6.2.
public struct CursorSample: Sendable {
    public var x, y, prevX, prevY: Double
    public var imageID: String?
    public var alpha, rotation, clickScale: Double

    public init(x: Double = 0.5, y: Double = 0.5, prevX: Double = 0.5, prevY: Double = 0.5,
                imageID: String? = nil, alpha: Double = 1, rotation: Double = 0, clickScale: Double = 1) {
        self.x = x; self.y = y; self.prevX = prevX; self.prevY = prevY
        self.imageID = imageID; self.alpha = alpha; self.rotation = rotation; self.clickScale = clickScale
    }
}

/// Raw `move` events → a 240 Hz lookup table of smoothed cursor state. See docs/SPEC.md §6.5.
///
/// Pipeline order (SPEC §6.5): shake removal → spring follow → idle hide → loop → rotation → click
/// pulse → hidden ranges. M4 implements spring follow, idle hide, click pulse, imageID and the
/// hidden ranges; shake removal, loop and rotation are `// T-604`.
public struct CursorPath: Sendable {
    private let rate: Double
    private let duration: Double
    private let table: [CursorSample]

    public init(events: EventLog, style: CursorStyle, hidden: [TimeRange], duration: Double, rate: Double = 240) {
        self.rate = rate
        self.duration = max(duration, 0)
        let dt = 1 / rate
        let steps = max(1, Int((self.duration * rate).rounded()) + 1)

        let moves = events.moves()
        let clicks = events.clicks()
        let cursorEvents = events.events.filter { $0.k == .cursor }

        let spring: Spring? = {
            switch style.style {
            case .smooth: return .cursorSmooth
            case .medium: return .cursorMedium
            case .rapid: return .cursorRapid
            case .none: return nil
            }
        }()

        func advance(_ es: [InputEvent], _ idx: inout Int, upTo t: Double) {
            while idx < es.count && es[idx].t <= t { idx += 1 }
        }

        var moveIdx = 0, clickIdx = 0, cursorIdx = 0
        var xs = [Double](repeating: 0.5, count: steps)
        var ys = [Double](repeating: 0.5, count: steps)
        var alphas = [Double](repeating: 1, count: steps)
        var clickScales = [Double](repeating: 1, count: steps)
        var imageIDs = [String?](repeating: nil, count: steps)

        var x = 0.5, y = 0.5, vx = 0.0, vy = 0.0
        var alpha = 1.0

        for i in 0..<steps {
            let t = Double(i) * dt

            advance(moves, &moveIdx, upTo: t)
            let prevMove = moveIdx > 0 ? moves[moveIdx - 1] : nil
            let nextMove = moveIdx < moves.count ? moves[moveIdx] : nil
            let rawX: Double, rawY: Double, lastMoveTime: Double
            switch (prevMove, nextMove) {
            case (nil, nil):
                rawX = 0.5; rawY = 0.5; lastMoveTime = 0
            case (nil, .some(let n)):
                rawX = n.x ?? 0.5; rawY = n.y ?? 0.5; lastMoveTime = 0
            case (.some(let p), nil):
                rawX = p.x ?? 0.5; rawY = p.y ?? 0.5; lastMoveTime = p.t
            case (.some(let p), .some(let n)):
                let span = n.t - p.t
                let frac = span > 0 ? (t - p.t) / span : 0
                rawX = (p.x ?? 0.5) + ((n.x ?? 0.5) - (p.x ?? 0.5)) * frac
                rawY = (p.y ?? 0.5) + ((n.y ?? 0.5) - (p.y ?? 0.5)) * frac
                lastMoveTime = p.t
            }

            // T-604: shake removal (drop excursions < 3 px that return within 80 ms) belongs here,
            // before the spring follow, once cursor positions are in pixel space.
            if let spring {
                spring.step(x: &x, v: &vx, target: rawX, dt: dt)
                spring.step(x: &y, v: &vy, target: rawY, dt: dt)
            } else {
                x = rawX; y = rawY
            }
            xs[i] = x; ys[i] = y

            // Idle hide: linear fade to 0 over 0.3 s once idle >= 2 s, fade back to 1 over 0.15 s.
            let idle = t - lastMoveTime
            let target: Double = (style.hideWhenIdle && idle >= 2.0) ? 0 : 1
            if alpha < target { alpha = min(target, alpha + dt / 0.15) }
            else if alpha > target { alpha = max(target, alpha - dt / 0.3) }
            alphas[i] = alpha

            // T-604: loop — the last 1.5 s springs toward the first position.

            advance(clicks, &clickIdx, upTo: t)
            let lastClick = clickIdx > 0 ? clicks[clickIdx - 1] : nil
            let sincePulse = lastClick.map { t - $0.t } ?? .infinity
            if sincePulse < 0.2 {
                let half = 0.1
                clickScales[i] = sincePulse < half ? 1 - 0.15 * (sincePulse / half) : 0.85 + 0.15 * ((sincePulse - half) / half)
            } else {
                clickScales[i] = 1
            }

            advance(cursorEvents, &cursorIdx, upTo: t)
            imageIDs[i] = cursorIdx > 0 ? cursorEvents[cursorIdx - 1].id : nil
        }

        // prevX/prevY: position one render frame (1/60 s) earlier, for motion blur (SPEC §6.2 pass 3).
        let stepsBack = max(1, Int((rate / 60).rounded()))
        table = (0..<steps).map { i in
            let j = max(0, i - stepsBack)
            let t = Double(i) * dt
            // T-604: rotation (tilt ∝ horizontal velocity, max 12°) belongs here.
            let a = (style.hidden || hidden.contains { t >= $0.start && t <= $0.end }) ? 0 : alphas[i]
            return CursorSample(x: xs[i], y: ys[i], prevX: xs[j], prevY: ys[j],
                                 imageID: imageIDs[i], alpha: a, rotation: 0, clickScale: clickScales[i])
        }
    }

    /// Index + lerp; pure lookup — deterministic regardless of sampling order (AC-CUR-1 style).
    public func sample(atSource t: Double) -> CursorSample {
        let clamped = min(max(t, 0), duration)
        let f = clamped * rate
        let i0 = min(max(Int(f), 0), table.count - 1)
        let i1 = min(i0 + 1, table.count - 1)
        let frac = f - Double(i0)
        let a = table[i0], b = table[i1]
        return CursorSample(
            x: a.x + (b.x - a.x) * frac,
            y: a.y + (b.y - a.y) * frac,
            prevX: a.prevX + (b.prevX - a.prevX) * frac,
            prevY: a.prevY + (b.prevY - a.prevY) * frac,
            imageID: a.imageID,
            alpha: a.alpha + (b.alpha - a.alpha) * frac,
            rotation: a.rotation + (b.rotation - a.rotation) * frac,
            clickScale: a.clickScale + (b.clickScale - a.clickScale) * frac)
    }
}
