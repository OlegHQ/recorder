import Foundation

/// A kept piece of the source recording, played at `speed`. See docs/SPEC.md §5.
public struct Clip: Codable, Equatable, Sendable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public var speed: Double
    public init(sourceStart: Double, sourceEnd: Double, speed: Double = 1) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.speed = speed
    }
    public var outputDuration: Double { (sourceEnd - sourceStart) / speed }
}

/// Maps between output (what the viewer sees) and source (what was recorded) time.
public struct TimeMap: Sendable {
    public let clips: [Clip]
    public init(_ clips: [Clip]) { self.clips = clips }

    public var outputDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }

    /// Clamps to the valid range, so callers can pass any playhead value.
    public func sourceTime(atOutput t: Double) -> Double {
        var start = 0.0
        for c in clips {
            let end = start + c.outputDuration
            if t < end { return c.sourceStart + max(0, t - start) * c.speed }
            start = end
        }
        return clips.last?.sourceEnd ?? 0
    }

    /// nil when `s` falls in a removed segment.
    public func outputTime(atSource s: Double) -> Double? {
        var start = 0.0
        for c in clips {
            if s >= c.sourceStart && s <= c.sourceEnd { return start + (s - c.sourceStart) / c.speed }
            start += c.outputDuration
        }
        return nil
    }
}
