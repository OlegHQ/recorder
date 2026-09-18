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
/// pulse → hidden ranges.
public struct CursorPath: Sendable {
    // ponytail: shake removal/rotation work in normalised (0…1) source coordinates but SPEC's
    // shake threshold is in pixels; no real source pixel width flows through CursorPath, so it
    // reuses the same 1920 px reference the tests already assume (see CursorPathTests'
    // `halfPixel`). Upgrade: thread `source.pixelWidth` through once a caller actually has it.
    private static let referenceWidth = 1920.0
    private static let shakePixels = 3.0
    private static let shakeWindow = 0.08
    private static let loopWindow = 1.5
    private static let maxRotationDegrees = 12.0

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

        // Raw pointer position (piecewise-linear between recorded moves) + time since the last
        // move, one entry per 240 Hz step.
        var moveIdx = 0
        var rawXs = [Double](repeating: 0.5, count: steps)
        var rawYs = [Double](repeating: 0.5, count: steps)
        var idleSince = [Double](repeating: 0, count: steps)
        for i in 0..<steps {
            let t = Double(i) * dt
            advance(moves, &moveIdx, upTo: t)
            let prevMove = moveIdx > 0 ? moves[moveIdx - 1] : nil
            let nextMove = moveIdx < moves.count ? moves[moveIdx] : nil
            switch (prevMove, nextMove) {
            case (nil, nil):
                rawXs[i] = 0.5; rawYs[i] = 0.5; idleSince[i] = t
            case (nil, .some(let n)):
                rawXs[i] = n.x ?? 0.5; rawYs[i] = n.y ?? 0.5; idleSince[i] = t
            case (.some(let p), nil):
                rawXs[i] = p.x ?? 0.5; rawYs[i] = p.y ?? 0.5; idleSince[i] = t - p.t
            case (.some(let p), .some(let n)):
                let span = n.t - p.t
                let frac = span > 0 ? (t - p.t) / span : 0
                rawXs[i] = (p.x ?? 0.5) + ((n.x ?? 0.5) - (p.x ?? 0.5)) * frac
                rawYs[i] = (p.y ?? 0.5) + ((n.y ?? 0.5) - (p.y ?? 0.5)) * frac
                idleSince[i] = t - p.t
            }
        }

        // Stage 1: shake removal — drop excursions < 3 px that return within 80 ms of leaving a
        // held ("base") position.
        if style.removeShakes {
            (rawXs, rawYs) = Self.removeShakes(xs: rawXs, ys: rawYs, rate: rate)
        }

        // Stage 2: spring follow.
        var xs = [Double](repeating: 0.5, count: steps)
        var ys = [Double](repeating: 0.5, count: steps)
        var x = 0.5, y = 0.5, vx = 0.0, vy = 0.0
        for i in 0..<steps {
            if let spring {
                spring.step(x: &x, v: &vx, target: rawXs[i], dt: dt)
                spring.step(x: &y, v: &vy, target: rawYs[i], dt: dt)
            } else {
                x = rawXs[i]; y = rawYs[i]
            }
            xs[i] = x; ys[i] = y
        }

        // Stage 3: idle hide — linear fade to 0 over 0.3 s once idle >= 2 s, fade back to 1 over 0.15 s.
        var alphas = [Double](repeating: 1, count: steps)
        var alpha = 1.0
        for i in 0..<steps {
            let target: Double = (style.hideWhenIdle && idleSince[i] >= 2.0) ? 0 : 1
            if alpha < target { alpha = min(target, alpha + dt / 0.15) }
            else if alpha > target { alpha = max(target, alpha - dt / 0.3) }
            alphas[i] = alpha
        }

        // Stage 4: loop — the last 1.5 s springs toward the recording's first (raw) position, so a
        // looped export lands back where the cursor started.
        if style.loop && steps > 1 {
            let windowSteps = min(steps - 1, Int((Self.loopWindow * rate).rounded()))
            if windowSteps > 0 {
                let startIdx = steps - 1 - windowSteps
                let loopSpring = spring ?? .cursorMedium
                var lx = xs[startIdx], ly = ys[startIdx], lvx = 0.0, lvy = 0.0
                for i in (startIdx + 1)..<steps {
                    loopSpring.step(x: &lx, v: &lvx, target: rawXs[0], dt: dt)
                    loopSpring.step(x: &ly, v: &lvy, target: rawYs[0], dt: dt)
                    xs[i] = lx; ys[i] = ly
                }
            }
        }

        // Stage 5: rotation — tilt proportional to horizontal velocity (a full-width sweep in 1 s
        // saturates the tilt), max 12°, off unless enabled.
        var rotations = [Double](repeating: 0, count: steps)
        if style.rotate {
            for i in 1..<steps {
                let velocity = (xs[i] - xs[i - 1]) / dt
                rotations[i] = max(-Self.maxRotationDegrees, min(Self.maxRotationDegrees, velocity * Self.maxRotationDegrees))
            }
        }

        // Stage 6: click pulse — scale 1→0.85→1 over 0.2 s on `down`.
        var clickIdx = 0
        var clickScales = [Double](repeating: 1, count: steps)
        for i in 0..<steps {
            let t = Double(i) * dt
            advance(clicks, &clickIdx, upTo: t)
            let lastClick = clickIdx > 0 ? clicks[clickIdx - 1] : nil
            let sincePulse = lastClick.map { t - $0.t } ?? .infinity
            if sincePulse < 0.2 {
                let half = 0.1
                clickScales[i] = sincePulse < half ? 1 - 0.15 * (sincePulse / half) : 0.85 + 0.15 * ((sincePulse - half) / half)
            } else {
                clickScales[i] = 1
            }
        }

        // Sampled cursor image: the last recorded `cursor` event's id — unless "always use arrow",
        // which reports no override (`nil`) so the renderer always draws the plain arrow.
        var cursorIdx = 0
        var imageIDs = [String?](repeating: nil, count: steps)
        if !style.alwaysArrow {
            for i in 0..<steps {
                let t = Double(i) * dt
                advance(cursorEvents, &cursorIdx, upTo: t)
                imageIDs[i] = cursorIdx > 0 ? cursorEvents[cursorIdx - 1].id : nil
            }
        }

        // prevX/prevY: position one render frame (1/60 s) earlier, for motion blur (SPEC §6.2 pass 3).
        let stepsBack = max(1, Int((rate / 60).rounded()))
        table = (0..<steps).map { i in
            let j = max(0, i - stepsBack)
            let t = Double(i) * dt
            // Stage 7: hidden ranges (and the master "hidden" toggle) always win last.
            let a = (style.hidden || hidden.contains { t >= $0.start && t <= $0.end }) ? 0 : alphas[i]
            return CursorSample(x: xs[i], y: ys[i], prevX: xs[j], prevY: ys[j],
                                 imageID: imageIDs[i], alpha: a, rotation: rotations[i], clickScale: clickScales[i])
        }
    }

    /// Drop excursions of less than `shakePixels` (at `referenceWidth`) that return within
    /// `shakeWindow` seconds of leaving the last held ("base") position.
    private static func removeShakes(xs: [Double], ys: [Double], rate: Double) -> ([Double], [Double]) {
        guard xs.count > 1 else { return (xs, ys) }
        let threshold = shakePixels / referenceWidth
        let windowSteps = max(1, Int((shakeWindow * rate).rounded()))
        var cleanXs = xs, cleanYs = ys
        var baseIdx = 0
        var i = 1
        func dist(_ a: Int, _ b: Int) -> Double {
            let dx = xs[a] - xs[b], dy = ys[a] - ys[b]
            return (dx * dx + dy * dy).squareRoot()
        }
        while i < xs.count {
            if dist(i, baseIdx) < threshold {
                cleanXs[i] = xs[baseIdx]; cleanYs[i] = ys[baseIdx]
                i += 1
                continue
            }
            let windowEnd = min(xs.count - 1, i + windowSteps)
            var returnIdx: Int?
            if windowEnd > i {
                for j in (i + 1)...windowEnd where dist(j, baseIdx) < threshold {
                    returnIdx = j
                    break
                }
            }
            if let r = returnIdx {
                for k in i...r { cleanXs[k] = xs[baseIdx]; cleanYs[k] = ys[baseIdx] }
                i = r + 1
            } else {
                baseIdx = i
                i += 1
            }
        }
        return (cleanXs, cleanYs)
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
