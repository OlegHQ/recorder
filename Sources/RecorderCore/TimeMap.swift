import Foundation

/// A kept piece of the source recording, played at `speed`. See docs/SPEC.md §5.
public struct Clip: Codable, Equatable, Sendable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public var speed: Double
    /// Explicit fade lengths in output seconds; missing values mean Off (including older projects).
    public var fadeIn: Double? = nil
    public var fadeOut: Double? = nil
    public var isGap: Bool? = nil
    public var mediaStart: Double? = nil
    /// Separate the timeline clock from playback rate for an unlinked speed edit.
    public var clockSpeed: Double? = nil
    public var timeScale: Double { clockSpeed ?? speed }
    public var mediaDuration: Double { outputDuration * speed }
    public func mediaTime(atSource time: Double) -> Double { mediaIn + (time - sourceStart) * speed / timeScale }
    public var mediaIn: Double { mediaStart ?? sourceStart }
    public var isEmpty: Bool { isGap == true }
    public init(sourceStart: Double, sourceEnd: Double, speed: Double = 1) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.speed = speed
    }
    public var outputDuration: Double { (sourceEnd - sourceStart) / timeScale }
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
            if t < end { return c.sourceStart + max(0, t - start) * c.timeScale }
            start = end
        }
        return clips.last?.sourceEnd ?? 0
    }

    /// nil when `s` falls in a removed segment.
    public func outputTime(atSource s: Double) -> Double? {
        var start = 0.0
        for c in clips {
            if s >= c.sourceStart && s <= c.sourceEnd { return start + (s - c.sourceStart) / c.timeScale }
            start += c.outputDuration
        }
        return nil
    }
}

public extension Project {
    /// End of retained screen/camera media in output time. Interior gaps stay in the export;
    /// trailing gaps and effect blocks alone do not extend it.
    var exportDuration: Double {
        var output = 0.0, end = 0.0
        for clip in clips {
            let duration = clip.outputDuration
            guard duration.isFinite, duration >= 0, clip.timeScale > 0 else { return 0 }
            if !clip.isEmpty { end = output + duration }
            if source.hasCamera {
                for camera in cameraClips {
                    let lo = max(clip.sourceStart, camera.start), hi = min(clip.sourceEnd, camera.end)
                    if hi > lo { end = max(end, output + (hi - clip.sourceStart) / clip.timeScale) }
                }
            }
            output += duration
        }
        return end.isFinite ? end : 0
    }
}
