import Foundation

/// Which side of a block/clip an edge operation targets. See docs/SPEC.md §7.4.
public enum Edge: Sendable {
    case leading, trailing
}

/// Split/trim/remove/restore/speed edits on `Project.clips`, plus lookup helpers. Pure
/// `Project -> Project` functions (mutating on `self`) with invariants checked in debug via
/// `assert`. The x-axis callers work in is *output* time; conversion to *source* time (where
/// clips live) goes only through `TimeMap`. See docs/SPEC.md §7.4.
public extension Project {
    /// Minimum kept length of a clip, in source seconds.
    private static let minClipLength = 0.1

    /// Splits the clip under output time `t` into two clips of the same speed. Returns `false`
    /// (no change) if `t` is within 2 frames of either edge of that clip, or if the split would
    /// leave a piece shorter than the minimum clip length.
    @discardableResult
    mutating func split(atOutput t: Double, fps: Double = 60) -> Bool {
        guard let i = clipIndex(atOutput: t) else { return false }
        var outStart = 0.0
        for c in clips[0..<i] { outStart += c.outputDuration }
        let outEnd = outStart + clips[i].outputDuration
        let minGap = 2 / fps
        guard t - outStart >= minGap, outEnd - t >= minGap else { return false }

        let clip = clips[i]
        let s = TimeMap(clips).sourceTime(atOutput: t)
        guard s - clip.sourceStart >= Self.minClipLength, clip.sourceEnd - s >= Self.minClipLength else { return false }

        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips.insert(Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed), at: i + 1)
        assert(checkInvariants() == nil)
        return true
    }

    /// Removes clip `i` entirely (its source range disappears from the output). Returns `false`
    /// if `i` is out of range or it is the last remaining clip.
    @discardableResult
    mutating func removeClip(_ i: Int) -> Bool {
        guard clips.indices.contains(i), clips.count > 1 else { return false }
        clips.remove(at: i)
        assert(checkInvariants() == nil)
        return true
    }

    /// Drags clip `i`'s `edge` to source time `s`. Clamps so it never crosses the neighbouring
    /// clip's source boundary (never overlaps), never leaves `[0, source.duration]`, and never
    /// shrinks the clip below the minimum length.
    mutating func trimClip(_ i: Int, edge: Edge, toSource s: Double) {
        guard clips.indices.contains(i) else { return }
        switch edge {
        case .leading:
            let lower = i > 0 ? clips[i - 1].sourceEnd : 0
            let upper = clips[i].sourceEnd - Self.minClipLength
            clips[i].sourceStart = min(max(s, lower), upper)
        case .trailing:
            let upper = i < clips.count - 1 ? clips[i + 1].sourceStart : source.duration
            let lower = clips[i].sourceStart + Self.minClipLength
            clips[i].sourceEnd = max(min(s, upper), lower)
        }
        assert(checkInvariants() == nil)
    }

    /// Re-inserts the removed source range right after clip `i` (`i == -1` = the head, before
    /// the first clip). Merges into the neighbouring clip when there is only one side, or when
    /// both sides exist and their speeds match; otherwise inserts the restored range as its own
    /// clip at speed 1. No-op if there is no cut there.
    mutating func restoreCut(afterClip i: Int) {
        guard i >= -1 && i < clips.count else { return }
        let leftBound = i == -1 ? 0 : clips[i].sourceEnd
        let rightIndex = i + 1
        let rightBound = rightIndex < clips.count ? clips[rightIndex].sourceStart : source.duration
        guard rightBound > leftBound else { return }

        if i == -1 {
            clips[0].sourceStart = leftBound
        } else if rightIndex == clips.count {
            clips[i].sourceEnd = rightBound
        } else if clips[i].speed == clips[rightIndex].speed {
            clips[i].sourceEnd = clips[rightIndex].sourceEnd
            clips.remove(at: rightIndex)
        } else {
            clips.insert(Clip(sourceStart: leftBound, sourceEnd: rightBound, speed: 1), at: rightIndex)
        }
        assert(checkInvariants() == nil)
    }

    /// Restores every cut: the head, every gap between clips, and the tail.
    mutating func restoreAllCuts() {
        var i = clips.count - 1
        while i >= -1 {
            restoreCut(afterClip: i)
            i -= 1
        }
        assert(checkInvariants() == nil)
    }

    /// Sets clip `i`'s playback speed, clamped to 0.25...16.
    mutating func setSpeed(_ i: Int, _ speed: Double) {
        guard clips.indices.contains(i) else { return }
        clips[i].speed = min(16, max(0.25, speed))
        assert(checkInvariants() == nil)
    }

    /// The clip covering output time `t`, clamped to the first/last clip outside `[0, outputDuration]`.
    func clipIndex(atOutput t: Double) -> Int? {
        guard !clips.isEmpty else { return nil }
        var start = 0.0
        for (i, c) in clips.enumerated() {
            let end = start + c.outputDuration
            if t < end { return i }
            start = end
        }
        return clips.count - 1
    }

    /// `nil` when the invariants hold; a message describing the first violation otherwise.
    /// SPEC §7.4: clips sorted by `sourceStart`, non-overlapping, each >= 0.1 s, speed in
    /// 0.25...16, at least one clip.
    func checkInvariants() -> String? {
        let eps = 1e-9
        if clips.isEmpty { return "no clips" }
        var prevEnd: Double?
        for (i, c) in clips.enumerated() {
            if c.sourceEnd - c.sourceStart < Self.minClipLength - eps {
                return "clip \(i) shorter than \(Self.minClipLength)s"
            }
            if c.speed < 0.25 - eps || c.speed > 16 + eps {
                return "clip \(i) speed \(c.speed) out of range"
            }
            if let prevEnd, c.sourceStart < prevEnd - eps {
                return "clip \(i) overlaps the previous clip"
            }
            prevEnd = c.sourceEnd
        }
        return nil
    }
}
