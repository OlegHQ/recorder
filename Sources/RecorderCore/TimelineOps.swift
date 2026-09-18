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

    /// Edit ▸ Speed Up Typing (SPEC "Edit ▸ Speed Up Typing", T-603): splits clips at each SOURCE-time
    /// range's edges (`typingRanges(events:)`, `Events.swift`) and sets every clip that ends up fully
    /// inside a range to `factor`×. Ranges that don't align with a clip boundary get a plain interior
    /// split (same shape as `split(atOutput:)`, but keyed directly on source time since that's what
    /// `clips` and the ranges are already in — no `TimeMap` round trip needed). A range only partially
    /// covered by kept clips (the rest already cut away) still speeds up whatever clip(s) remain.
    mutating func speedUpTyping(_ ranges: [TimeRange], factor: Double = 2) {
        for range in ranges {
            splitClip(atSource: range.start)
            splitClip(atSource: range.end)
            for i in clips.indices where clips[i].sourceStart >= range.start - 1e-6 && clips[i].sourceEnd <= range.end + 1e-6 {
                clips[i].speed = factor
            }
        }
        assert(checkInvariants() == nil)
    }

    /// Splits the clip containing SOURCE time `s` into two clips of the same speed. No-op if `s`
    /// isn't strictly inside a clip (in a gap, or within `minClipLength` of an edge/existing boundary).
    private mutating func splitClip(atSource s: Double) {
        guard let i = clips.firstIndex(where: { s > $0.sourceStart + Self.minClipLength && s < $0.sourceEnd - Self.minClipLength }) else { return }
        let clip = clips[i]
        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips.insert(Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed), at: i + 1)
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
    /// 0.25...16, at least one clip; zooms/layouts/masks sorted, non-overlapping, >= 0.5 s,
    /// within `[0, source.duration]`.
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
        if let e = zooms.blockInvariantError(kind: "zoom", duration: source.duration) { return e }
        if let e = layouts.blockInvariantError(kind: "layout", duration: source.duration) { return e }
        if let e = masks.blockInvariantError(kind: "mask", duration: source.duration) { return e }
        return nil
    }
}

// MARK: - Zoom / layout / mask blocks

/// Common shape of the three timed-block tracks, so `addBlock`/`moveBlock`/`resizeBlock` below are
/// written once. `Zoom`, `Layout` and `Mask` all store `id` as a `String` (SPEC §5 JSON), so this
/// stays `String` too; the public `Project` API below is the only place that talks `UUID`, per the
/// plan's normative signatures, converting at the boundary.
private protocol TimedBlock {
    var id: String { get }
    var start: Double { get set }
    var end: Double { get set }
}
extension Zoom: TimedBlock {}
extension Layout: TimedBlock {}
extension Mask: TimedBlock {}

private extension Array where Element: TimedBlock {
    /// `nil` when every element is sorted by `start`, non-overlapping, >= `minLength`, and within
    /// `[0, duration]`.
    func blockInvariantError(kind: String, duration: Double, minLength: Double = 0.5) -> String? {
        let eps = 1e-9
        var prevEnd: Double?
        for (i, b) in enumerated() {
            if b.end - b.start < minLength - eps { return "\(kind) \(i) shorter than \(minLength)s" }
            if b.start < -eps || b.end > duration + eps { return "\(kind) \(i) outside [0, \(duration)]" }
            if let prevEnd, b.start < prevEnd - eps { return "\(kind) \(i) overlaps the previous \(kind)" }
            prevEnd = b.end
        }
        return nil
    }

    /// Inserts a new block covering as much of `length` as fits in the free gap containing
    /// `s` (clamped to `[0, duration]`), placed as close to `s` as the gap allows. Returns the
    /// inserted block's index, or `nil` if `s` isn't in a gap or the gap is shorter than `minLength`.
    mutating func addBlock(atSource s: Double, length: Double, duration: Double, minLength: Double,
                            make: (_ start: Double, _ end: Double) -> Element) -> Int? {
        let sorted = self.sorted { $0.start < $1.start }
        var lo = 0.0, hi = duration
        for b in sorted {
            if s >= b.start && s <= b.end { return nil }   // s is inside an existing block, not a gap
            if b.end <= s { lo = Swift.max(lo, b.end) }
            if b.start >= s { hi = Swift.min(hi, b.start) }
        }
        guard hi - lo >= minLength - 1e-9 else { return nil }
        let len = Swift.min(length, hi - lo)
        let start = Swift.min(Swift.max(s, lo), hi - len)
        let block = make(start, start + len)
        let insertAt = firstIndex { $0.start > start } ?? count
        insert(block, at: insertAt)
        return insertAt
    }

    /// Moves the block with `id` so it starts at `s`, clamped so it neither overlaps a neighbour
    /// nor leaves `[0, duration]`. No-op if `id` isn't present.
    mutating func moveBlock(id: String, toStart s: Double, duration: Double) {
        guard let i = firstIndex(where: { $0.id == id }) else { return }
        let length = self[i].end - self[i].start
        let lower = i > 0 ? self[i - 1].end : 0
        let upper = (i < count - 1 ? self[i + 1].start : duration) - length
        self[i].start = Swift.min(Swift.max(s, lower), upper)
        self[i].end = self[i].start + length
    }

    /// Drags the block with `id`'s `edge` to source time `s`, clamped against its neighbour, the
    /// minimum length, and `[0, duration]`. No-op if `id` isn't present.
    mutating func resizeBlock(id: String, edge: Edge, to s: Double, duration: Double, minLength: Double) {
        guard let i = firstIndex(where: { $0.id == id }) else { return }
        switch edge {
        case .leading:
            let lower = i > 0 ? self[i - 1].end : 0
            let upper = self[i].end - minLength
            self[i].start = Swift.min(Swift.max(s, lower), upper)
        case .trailing:
            let upper = i < count - 1 ? self[i + 1].start : duration
            let lower = self[i].start + minLength
            self[i].end = Swift.max(Swift.min(s, upper), lower)
        }
    }

    /// Removes the block with `id`, if present. Returns whether one was removed.
    @discardableResult
    mutating func removeBlock(id: String) -> Bool {
        guard let i = firstIndex(where: { $0.id == id }) else { return false }
        remove(at: i)
        return true
    }
}

public extension Project {
    /// Minimum kept length of a zoom/layout/mask block, in source seconds. SPEC §7.4.
    private static let minBlockLength = 0.5

    /// Adds a zoom of `length` seconds (`Zoom.Mode` `mode`) into the free gap in `zooms` that
    /// contains source time `s`. Returns its id, or `nil` if that gap is shorter than 0.5 s.
    @discardableResult
    mutating func addZoom(atSource s: Double, length: Double = 3, mode: Zoom.Mode) -> UUID? {
        let newID = UUID()
        guard zooms.addBlock(atSource: s, length: length, duration: source.duration, minLength: Self.minBlockLength, make: { start, end in
            Zoom(id: newID.uuidString, start: start, end: end, mode: mode)
        }) != nil else { return nil }
        assert(checkInvariants() == nil)
        return newID
    }

    /// Moves zoom `id` so it starts at source time `s`, clamped against its neighbours and
    /// `[0, source.duration]`.
    mutating func moveZoom(_ id: UUID, toStart s: Double) {
        zooms.moveBlock(id: id.uuidString, toStart: s, duration: source.duration)
        assert(checkInvariants() == nil)
    }

    /// Drags zoom `id`'s `edge` to source time `s`, clamped so it stays >= 0.5 s and never
    /// overlaps its neighbour.
    mutating func resizeZoom(_ id: UUID, edge: Edge, to s: Double) {
        zooms.resizeBlock(id: id.uuidString, edge: edge, to: s, duration: source.duration, minLength: Self.minBlockLength)
        assert(checkInvariants() == nil)
    }

    /// Removes the zoom, layout or mask block with `id`, whichever track it's in.
    mutating func removeBlock(_ id: UUID) {
        let key = id.uuidString
        if !zooms.removeBlock(id: key), !layouts.removeBlock(id: key) {
            masks.removeBlock(id: key)
        }
        assert(checkInvariants() == nil)
    }
}

/// Snaps `x` to the nearest of `candidates` within `threshold`; returns `x` unchanged (and
/// `snapped: false`) if none is close enough. SPEC §7.2 "Snapping".
public func snap(_ x: Double, candidates: [Double], threshold: Double) -> (value: Double, snapped: Bool) {
    guard let nearest = candidates.min(by: { abs($0 - x) < abs($1 - x) }), abs(nearest - x) <= threshold else {
        return (x, false)
    }
    return (nearest, true)
}
