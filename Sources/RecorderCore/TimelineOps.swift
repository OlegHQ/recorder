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
        guard let i = clipIndex(atOutput: t), !clips[i].isEmpty else { return false }
        var outStart = 0.0
        for c in clips[0..<i] { outStart += c.outputDuration }
        let outEnd = outStart + clips[i].outputDuration
        let minGap = 2 / fps
        guard t - outStart >= minGap, outEnd - t >= minGap else { return false }

        let clip = clips[i]
        let s = TimeMap(clips).sourceTime(atOutput: t)
        guard clip.mediaTime(atSource: s) - clip.mediaIn >= Self.minClipLength,
              clip.mediaIn + clip.mediaDuration - clip.mediaTime(atSource: s) >= Self.minClipLength else { return false }

        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips[i].mediaStart = clip.mediaStart
        clips[i].clockSpeed = clip.clockSpeed
        var right = Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed)
        right.mediaStart = clip.mediaTime(atSource: s)
        right.clockSpeed = clip.clockSpeed
        clips.insert(right, at: i + 1)
        if linkVideoEdits { editLinkedLayers(in: s...s, moveBy: 0) }
        assert(checkInvariants() == nil)
        return true
    }

    /// Only video edits call this. Editing a layer never calls back into video or its siblings.
    private mutating func editLinkedLayers(in range: ClosedRange<Double>, moveBy delta: Double?) {
        func slice<T: TimedBlock>(_ block: T, _ start: Double, _ end: Double, newID: Bool) -> T {
            var part = block
            part.advanceMedia(by: start - block.start)
            part.start = start; part.end = end
            if newID { part.id = UUID().uuidString }
            return part
        }
        func edit<T: TimedBlock>(_ blocks: inout [T]) {
            var stationary: [T] = [], moved: [T] = []
            for block in blocks {
                let lo = max(block.start, range.lowerBound), hi = min(block.end, range.upperBound)
                guard lo <= hi, block.end > range.lowerBound, block.start < range.upperBound else {
                    stationary.append(block); continue
                }
                if block.start < lo { stationary.append(slice(block, block.start, lo, newID: false)) }
                if hi < block.end { stationary.append(slice(block, hi, block.end, newID: block.start < lo || hi > lo)) }
                if hi > lo, let delta {
                    var part = slice(block, lo, hi, newID: block.start < lo)
                    part.start += delta; part.end += delta
                    moved.append(part)
                }
            }
            // A linked move overwrites its destination on affected lanes, just as the video does.
            for part in moved where delta != 0 {
                stationary = stationary.flatMap { block -> [T] in
                    guard block.start < part.end, block.end > part.start else { return [block] }
                    var pieces: [T] = []
                    if block.start < part.start { pieces.append(slice(block, block.start, part.start, newID: false)) }
                    if block.end > part.end { pieces.append(slice(block, part.end, block.end, newID: block.start < part.start)) }
                    return pieces
                }
            }
            blocks = (stationary + moved).sorted { $0.start < $1.start }
        }
        edit(&cameraClips); edit(&zooms); edit(&keystrokeClips); edit(&layouts); edit(&masks)
    }

    /// Lift video without changing the timing of any other lane.
    mutating func liftClip(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        if linkVideoEdits { editLinkedLayers(in: clips[i].sourceStart...clips[i].sourceEnd, moveBy: nil) }
        clips[i].isGap = true
    }

    /// Delete uses the two independent timeline modes. Keep one gap when deleting all video.
    mutating func deleteClips(_ indices: Set<Int>) {
        for i in indices.sorted(by: >) where clips.indices.contains(i) && !clips[i].isEmpty {
            liftClip(i)
            if rippleDelete && clips.count > 1 { clips.remove(at: i) }
        }
    }

    /// Put mixed-speed clips on one editing clock before moving across their boundaries.
    /// Playback rates and layer media positions stay unchanged; only timeline coordinates change.
    private mutating func useOutputClock() {
        let original = clips
        func output(_ source: Double) -> Double {
            var time = 0.0
            for clip in original {
                if source < clip.sourceStart { return time }
                if source <= clip.sourceEnd { return time + (source - clip.sourceStart) / clip.timeScale }
                time += clip.outputDuration
            }
            return time + max(0, source - (original.last?.sourceEnd ?? 0))
        }
        func retime<T: TimedBlock>(_ blocks: inout [T]) {
            blocks = blocks.compactMap { block in
                var moved = block
                moved.start = output(block.start); moved.end = output(block.end)
                return moved.end > moved.start ? moved : nil
            }
        }
        // Media-bearing layers are sliced at clock changes so their footage keeps its exact rate.
        func retimeMedia<T: TimedBlock>(_ blocks: inout [T], rate: WritableKeyPath<T, Double?>) {
            blocks = blocks.flatMap { block -> [T] in
                var pieces: [T] = []
                for clip in original {
                    let lo = max(block.start, clip.sourceStart), hi = min(block.end, clip.sourceEnd)
                    guard hi > lo else { continue }
                    var piece = block
                    if !pieces.isEmpty { piece.id = UUID().uuidString }
                    piece.advanceMedia(by: lo - block.start)
                    piece.start = output(lo); piece.end = output(hi)
                    piece[keyPath: rate] = (block[keyPath: rate] ?? 1) * clip.timeScale
                    pieces.append(piece)
                }
                return pieces
            }
        }
        retimeMedia(&cameraClips, rate: \.mediaRate)
        retimeMedia(&keystrokeClips, rate: \.mediaRate)
        retime(&zooms); retime(&layouts); retime(&masks)
        var time = 0.0
        clips = original.map { clip in
            var moved = clip
            moved.mediaStart = clip.mediaIn
            moved.sourceStart = time
            time += clip.outputDuration
            moved.sourceEnd = time
            moved.clockSpeed = 1
            return moved
        }
    }

    /// Clipboard content uses output seconds relative to the selection, with media in-points
    /// frozen. Reuse Project's track arrays/settings; no second serialization model is needed.
    func copySelection(clips indices: Set<Int>, blocks ids: Set<UUID>) -> Project? {
        let selected = indices.filter { clips.indices.contains($0) && !clips[$0].isEmpty }
        let ranges = selected.sorted().map { clips[$0].sourceStart...clips[$0].sourceEnd }
        let blockIDs = Set(ids.map(\.uuidString))
        func selectedBlocks<T: TimedBlock>(_ blocks: [T]) -> [T] {
            blocks.flatMap { block -> [T] in
                if blockIDs.contains(block.id) { return [block] }
                guard linkVideoEdits else { return [] }
                return ranges.compactMap { range in
                    let lo = max(block.start, range.lowerBound), hi = min(block.end, range.upperBound)
                    guard hi > lo else { return nil }
                    var part = block
                    part.advanceMedia(by: lo - block.start)
                    part.start = lo; part.end = hi
                    return part
                }
            }
        }
        var copied = self
        copied.cameraClips = selectedBlocks(cameraClips)
        copied.zooms = selectedBlocks(zooms)
        copied.keystrokeClips = selectedBlocks(keystrokeClips)
        copied.layouts = selectedBlocks(layouts)
        copied.masks = selectedBlocks(masks)
        copied.useOutputClock()
        copied.clips = copied.clips.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        let starts = copied.clips.map(\.sourceStart) + copied.cameraClips.map(\.start) + copied.zooms.map(\.start)
            + copied.keystrokeClips.map(\.start) + copied.layouts.map(\.start) + copied.masks.map(\.start)
        guard let origin = starts.min() else { return nil }
        func offset<T: TimedBlock>(_ blocks: inout [T]) {
            for i in blocks.indices { blocks[i].start -= origin; blocks[i].end -= origin }
        }
        for i in copied.clips.indices { copied.clips[i].sourceStart -= origin; copied.clips[i].sourceEnd -= origin }
        offset(&copied.cameraClips); offset(&copied.zooms); offset(&copied.keystrokeClips)
        offset(&copied.layouts); offset(&copied.masks)
        return copied
    }

    /// Insert video at the playhead, shifting existing content to keep it intact. Layer-only
    /// pastes replace their own lane's overlapping range, retaining both outside pieces.
    /// Returns the pasted selection; refuses cuts that would leave invalid video slivers.
    mutating func pasteSelection(_ copied: Project, atOutput time: Double) -> (clips: Set<Int>, blocks: Set<UUID>)? {
        guard time.isFinite, time >= 0 else { return nil }
        var result = self
        result.useOutputClock()
        let duration = TimeMap(result.clips).outputDuration
        let t = min(time, duration)
        let pastedDuration = copied.clips.last?.sourceEnd ?? 0
        var gapEnd = t
        for clip in result.clips where clip.sourceEnd > t {
            guard clip.isEmpty, clip.sourceStart <= gapEnd else { break }
            gapEnd = clip.sourceEnd
        }
        let replaceEnd = t + min(pastedDuration, gapEnd - t)
        let insertDuration = pastedDuration - (replaceEnd - t)
        if insertDuration > 0,
           let clip = result.clips.first(where: { !$0.isEmpty && $0.sourceStart < t && $0.sourceEnd > t }),
           min(t - clip.sourceStart, clip.sourceEnd - t) * clip.speed < Self.minClipLength - 1e-9 { return nil }

        func slice<T: TimedBlock>(_ block: T, start: Double, end: Double) -> T {
            var part = block
            part.advanceMedia(by: start - block.start)
            part.start = start; part.end = end
            if start != block.start { part.id = UUID().uuidString }
            return part
        }
        var pastedIDs: Set<UUID> = []
        func paste<T: TimedBlock>(_ incoming: [T], into blocks: inout [T]) {
            if insertDuration > 0 {
                blocks = blocks.flatMap { block -> [T] in
                    if block.end <= replaceEnd { return [block] }
                    var right = slice(block, start: max(replaceEnd, block.start), end: block.end)
                    right.start += insertDuration; right.end += insertDuration
                    return block.start < replaceEnd ? [slice(block, start: block.start, end: replaceEnd), right] : [right]
                }
            }
            for block in incoming {
                var pasted = block
                let id = UUID()
                pasted.id = id.uuidString
                pasted.start += t; pasted.end += t
                blocks = blocks.flatMap { existing -> [T] in
                    guard existing.start < pasted.end, existing.end > pasted.start else { return [existing] }
                    var pieces: [T] = []
                    if existing.start < pasted.start { pieces.append(slice(existing, start: existing.start, end: pasted.start)) }
                    if existing.end > pasted.end { pieces.append(slice(existing, start: pasted.end, end: existing.end)) }
                    return pieces
                }
                blocks.append(pasted)
                pastedIDs.insert(id)
            }
            blocks.sort { $0.start < $1.start }
        }
        paste(copied.cameraClips, into: &result.cameraClips)
        paste(copied.zooms, into: &result.zooms)
        paste(copied.keystrokeClips, into: &result.keystrokeClips)
        paste(copied.layouts, into: &result.layouts)
        paste(copied.masks, into: &result.masks)

        var before: [Clip] = [], after: [Clip] = []
        for clip in result.clips {
            if pastedDuration == 0 || clip.sourceEnd <= t { before.append(clip) }
            else if clip.sourceStart >= replaceEnd {
                var moved = clip
                moved.sourceStart += insertDuration; moved.sourceEnd += insertDuration
                after.append(moved)
            } else {
                if clip.sourceStart < t {
                    var left = clip; left.sourceEnd = t
                    before.append(left)
                }
                if clip.sourceEnd > replaceEnd {
                    var right = clip
                    right.mediaStart = clip.mediaTime(atSource: replaceEnd)
                    right.sourceStart = replaceEnd + insertDuration; right.sourceEnd += insertDuration
                    after.append(right)
                }
            }
        }
        var pastedClips: Set<Int> = []
        for clip in copied.clips {
            let start = t + clip.sourceStart
            let previousEnd = before.last?.sourceEnd ?? 0
            if start > previousEnd {
                var gap = Clip(sourceStart: previousEnd, sourceEnd: start); gap.isGap = true
                before.append(gap)
            }
            var pasted = clip
            pasted.sourceStart += t; pasted.sourceEnd += t
            pastedClips.insert(before.count)
            before.append(pasted)
        }
        result.clips = before + after
        var ends = [result.clips.last?.sourceEnd ?? 0]
        ends += result.cameraClips.map(\.end)
        ends += result.zooms.map(\.end)
        ends += result.keystrokeClips.map(\.end)
        ends += result.layouts.map(\.end)
        ends += result.masks.map(\.end)
        let end = ends.max() ?? 0
        let videoEnd = result.clips.last?.sourceEnd ?? 0
        if end > videoEnd {
            var gap = Clip(sourceStart: videoEnd, sourceEnd: end); gap.isGap = true
            result.clips.append(gap)
        }
        guard !pastedClips.isEmpty || !pastedIDs.isEmpty, result.checkInvariants() == nil else { return nil }
        self = result
        return (pastedClips, pastedIDs)
    }

    /// Move a selection as one unit, retaining the spacing between its clips.
    /// The same collision constraints as a single move apply to the whole selection.
    @discardableResult
    mutating func moveClips(_ indices: Set<Int>, byOutput requested: Double) -> Set<Int> {
        let selected = indices.sorted().filter { clips.indices.contains($0) && !clips[$0].isEmpty }
        guard !selected.isEmpty, requested.isFinite, abs(requested) > 1e-8 else { return Set(selected) }
        var beforeClockChange: Project?
        if Set(clips.map(\.timeScale)).count > 1 || zip(clips, clips.dropFirst()).contains(where: { abs($0.sourceEnd - $1.sourceStart) > 1e-8 }) {
            beforeClockChange = self
            useOutputClock()
        }
        let original = clips
        var delta = requested
        for i in selected {
            let clip = original[i]
            var lo = i, hi = i
            while lo > 0, (original[lo - 1].isEmpty || indices.contains(lo - 1)),
                  original[lo - 1].timeScale == clip.timeScale,
                  abs(original[lo - 1].sourceEnd - original[lo].sourceStart) < 1e-8 { lo -= 1 }
            while hi + 1 < original.count, (original[hi + 1].isEmpty || indices.contains(hi + 1)),
                  original[hi + 1].timeScale == clip.timeScale,
                  abs(original[hi].sourceEnd - original[hi + 1].sourceStart) < 1e-8 { hi += 1 }
            delta = max(delta, (original[lo].sourceStart - clip.sourceStart) / clip.timeScale)
            if hi + 1 < original.count { delta = min(delta, (original[hi].sourceEnd - clip.sourceEnd) / clip.timeScale) }
        }
        guard abs(delta) > 1e-8 else {
            if let beforeClockChange { self = beforeClockChange }
            return Set(selected)
        }
        // Move the leading clips first so they vacate space for the rest of the group.
        let order = delta > 0 ? selected.reversed().map { $0 } : selected
        for i in order {
            let clip = original[i]
            guard let current = clips.firstIndex(of: clip) else { continue }
            _ = placeClip(current, start: clip.sourceStart + delta * clip.timeScale,
                          end: clip.sourceEnd + delta * clip.timeScale, moving: true)
        }
        return Set(selected.compactMap { i in
            let old = original[i]
            return clips.firstIndex { !$0.isEmpty && abs($0.sourceStart - old.sourceStart - delta * old.timeScale) < 1e-8 && $0.mediaIn == old.mediaIn }
        })
    }

    /// A short smooth arrival after empty video; the opening frame and adjacent cuts stay immediate.
    func videoOpacity(atOutput time: Double) -> Double {
        guard let i = clipIndex(atOutput: time), !clips[i].isEmpty else { return 0 }
        guard i > 0, clips[i - 1].isEmpty else { return 1 }
        let start = clips[..<i].reduce(0) { $0 + $1.outputDuration }
        let t = min(1, max(0, (time - start) / min(0.18, clips[i].outputDuration / 2)))
        return t * t * (3 - 2 * t)
    }

    /// Trim/move only within adjacent free space. Gap pieces retain the clock mapping, so
    /// camera, keys and effects stay at exactly the same output times.
    @discardableResult
    mutating func placeClip(_ i: Int, start: Double, end: Double, moving: Bool = false) -> Int {
        guard clips.indices.contains(i), !clips[i].isEmpty, start.isFinite, end.isFinite else { return i }
        let old = clips[i]
        var lo = i, hi = i
        while lo > 0, clips[lo - 1].isEmpty, clips[lo - 1].timeScale == old.timeScale,
              abs(clips[lo - 1].sourceEnd - clips[lo].sourceStart) < 1e-8 { lo -= 1 }
        while hi + 1 < clips.count, clips[hi + 1].isEmpty, clips[hi + 1].timeScale == old.timeScale,
              abs(clips[hi].sourceEnd - clips[hi + 1].sourceStart) < 1e-8 { hi += 1 }
        let lower = clips[lo].sourceStart
        let upper = hi == clips.count - 1 ? max(clips[hi].sourceEnd, end) : clips[hi].sourceEnd
        let length = old.sourceEnd - old.sourceStart
        let a: Double, b: Double
        if moving {
            a = min(max(start, lower), upper - length); b = a + length
        } else {
            let mediaLower = old.sourceStart - old.mediaIn * old.timeScale / old.speed
            let mediaUpper = old.sourceStart + (source.duration - old.mediaIn) * old.timeScale / old.speed
            let minimum = min(old.sourceEnd - old.sourceStart, Self.minClipLength * old.timeScale / old.speed)
            // Ripple deletion leaves missing source ranges, not explicit gap clips.
            // Recover that footage up to the remaining neighbours and media limits.
            let trimLower = lo == 0 ? 0 : clips[lo - 1].sourceEnd
            let trimUpper = hi + 1 < clips.count ? clips[hi + 1].sourceStart : upper
            a = min(max(start, max(trimLower, mediaLower)), old.sourceEnd - minimum)
            b = max(min(end, min(trimUpper, mediaUpper)), a + minimum)
        }
        var placed = old
        placed.sourceStart = a; placed.sourceEnd = b
        placed.mediaStart = moving ? old.mediaIn : old.mediaTime(atSource: a)
        var pieces: [Clip] = []
        if a > lower + 1e-8 {
            var gap = Clip(sourceStart: lower, sourceEnd: a, speed: old.timeScale); gap.isGap = true
            pieces.append(gap)
        }
        let selected = lo + pieces.count
        pieces.append(placed)
        if b < upper - 1e-8 {
            var gap = Clip(sourceStart: b, sourceEnd: upper, speed: old.timeScale); gap.isGap = true
            pieces.append(gap)
        }
        clips.replaceSubrange(lo...hi, with: pieces)
        if linkVideoEdits {
            if moving, abs(a - old.sourceStart) > 1e-8 {
                editLinkedLayers(in: old.sourceStart...old.sourceEnd, moveBy: a - old.sourceStart)
            } else if !moving {
                if a > old.sourceStart { editLinkedLayers(in: old.sourceStart...a, moveBy: nil) }
                if b < old.sourceEnd { editLinkedLayers(in: b...old.sourceEnd, moveBy: nil) }
            }
        }
        return selected
    }

    mutating func moveKeys(_ id: UUID, toStart s: Double) {
        guard let i = keystrokeClips.firstIndex(where: { $0.id == id.uuidString }) else { return }
        keystrokeClips[i].advanceMedia(by: 0)
        moveBlock(id, in: \.keystrokeClips, toStart: s)
    }
    mutating func resizeKeys(_ id: UUID, edge: Edge, to s: Double) {
        guard let i = keystrokeClips.firstIndex(where: { $0.id == id.uuidString }) else { return }
        let old = keystrokeClips[i]
        resizeBlock(id, in: \.keystrokeClips, edge: edge, to: s)
        keystrokeClips[i].mediaStart = (old.mediaStart ?? old.start) + (keystrokeClips[i].start - old.start) * (old.mediaRate ?? 1)
    }
    @discardableResult
    mutating func addKeys(atSource s: Double, length: Double = 3) -> UUID? {
        var settings = keys
        settings.show = true
        return addBlock(atSource: s, length: length, in: \.keystrokeClips) { id, start, end in
            Layout(id: id, start: start, end: end, kind: .settings, keys: settings)
        }
    }

    mutating func moveCamera(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.cameraClips, toStart: s) }
    mutating func resizeCamera(_ id: UUID, edge: Edge, to s: Double) {
        guard let i = cameraClips.firstIndex(where: { $0.id == id.uuidString }) else { return }
        let old = cameraClips[i]
        let lower = old.start - old.mediaStart / (old.mediaRate ?? 1)
        let upper = old.start + (source.duration - old.mediaStart) / (old.mediaRate ?? 1)
        cameraClips.resizeBlock(id: id.uuidString, edge: edge, to: min(upper, max(lower, s)), duration: timelineSourceDuration, minLength: Self.minClipLength)
        cameraClips[i].mediaStart += (cameraClips[i].start - old.start) * (old.mediaRate ?? 1)
    }
    @discardableResult
    mutating func addCamera(atSource s: Double, length: Double = 3) -> UUID? {
        guard source.hasCamera else { return nil }
        let mediaDuration = source.duration
        return addBlock(atSource: s, length: min(length, mediaDuration), in: \.cameraClips) { id, start, end in
            CameraClip(id: id, start: start, end: end, mediaStart: max(0, min(start, mediaDuration - (end - start))))
        }
    }

    /// A blade edit changes only its target block, preserving its settings.
    @discardableResult
    mutating func splitBlock(_ id: UUID, atSource s: Double) -> Bool {
        func split<T: TimedBlock>(_ blocks: inout [T], minimum: Double = 0.5) -> Bool {
            guard let i = blocks.firstIndex(where: { $0.id == id.uuidString }),
                  s - blocks[i].start >= minimum, blocks[i].end - s >= minimum else { return false }
            var right = blocks[i]
            right.id = UUID().uuidString
            right.advanceMedia(by: s - right.start)
            right.start = s
            blocks[i].end = s
            blocks.insert(right, at: i + 1)
            return true
        }
        if split(&cameraClips, minimum: Self.minClipLength) { return true }
        if split(&zooms) { return true }
        if split(&keystrokeClips) { return true }
        if split(&layouts) { return true }
        return split(&masks)
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
        let gapIndex = i + 1
        if clips.indices.contains(gapIndex), clips[gapIndex].isEmpty {
            let gap = clips[gapIndex]
            if gap.sourceEnd - gap.sourceStart < Self.minClipLength {
                // A tiny gap can only be restored by extending available neighbouring media.
                if i >= 0, !clips[i].isEmpty, clips[i].speed == gap.speed,
                   clips[i].mediaIn + gap.sourceEnd - clips[i].sourceStart <= source.duration {
                    clips[i].sourceEnd = gap.sourceEnd
                    clips.remove(at: gapIndex)
                } else if gapIndex + 1 < clips.count, !clips[gapIndex + 1].isEmpty,
                          clips[gapIndex + 1].speed == gap.speed,
                          clips[gapIndex + 1].mediaIn >= gap.sourceEnd - gap.sourceStart {
                    clips[gapIndex + 1].mediaStart = clips[gapIndex + 1].mediaIn - (gap.sourceEnd - gap.sourceStart)
                    clips[gapIndex + 1].sourceStart = gap.sourceStart
                    clips.remove(at: gapIndex)
                }
                return
            }
            guard gap.mediaIn >= 0, gap.mediaIn + gap.mediaDuration <= source.duration + 1e-8 else { return }
            clips[gapIndex].isGap = nil
            mergeContiguousVideo()
            return
        }
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

    private mutating func mergeContiguousVideo() {
        var i = 0
        while i + 1 < clips.count {
            let a = clips[i], b = clips[i + 1]
            if !a.isEmpty, !b.isEmpty, a.speed == b.speed, a.timeScale == b.timeScale,
               abs(a.sourceEnd - b.sourceStart) < 1e-8,
               abs(a.mediaIn + a.mediaDuration - b.mediaIn) < 1e-8 {
                clips[i].sourceEnd = b.sourceEnd
                clips.remove(at: i + 1)
            } else { i += 1 }
        }
    }

    /// Restores every cut: the head, every gap between clips, and the tail.
    mutating func restoreAllCuts() {
        for i in clips.indices.reversed() where clips.indices.contains(i) && clips[i].isEmpty {
            restoreCut(afterClip: i - 1)
        }
        var i = clips.count - 1
        while i >= -1 {
            restoreCut(afterClip: i)
            i -= 1
        }
        assert(checkInvariants() == nil)
    }

    /// Sets clip `i`'s playback speed, clamped to 0.25...16.
    mutating func setSpeed(_ i: Int, _ speed: Double) {
        guard clips.indices.contains(i), !clips[i].isEmpty, speed.isFinite else { return }
        let old = clips[i], requested = min(16, max(0.25, speed))
        guard abs(requested - old.speed) > 1e-9 else { return }
        if linkVideoEdits {
            clips[i].clockSpeed = old.timeScale * requested / old.speed
            clips[i].speed = requested
        } else {
            // Consume adjacent free space, or extend the last clip. Occupied video is never overwritten.
            var hi = i
            while hi + 1 < clips.count, clips[hi + 1].isEmpty, clips[hi + 1].timeScale == old.timeScale,
                  abs(clips[hi].sourceEnd - clips[hi + 1].sourceStart) < 1e-8 { hi += 1 }
            let requestedEnd = old.sourceStart + old.mediaDuration / requested * old.timeScale
            let availableEnd = hi == clips.count - 1 ? max(clips[hi].sourceEnd, requestedEnd) : clips[hi].sourceEnd
            let newEnd = min(requestedEnd, availableEnd)
            var changed = old
            changed.speed = old.mediaDuration / ((newEnd - old.sourceStart) / old.timeScale)
            changed.clockSpeed = old.timeScale
            changed.sourceEnd = newEnd
            changed.mediaStart = old.mediaIn
            var replacement = [changed]
            if newEnd < availableEnd - 1e-8 {
                var gap = Clip(sourceStart: newEnd, sourceEnd: availableEnd, speed: old.timeScale)
                gap.isGap = true
                replacement.append(gap)
            }
            clips.replaceSubrange(i...hi, with: replacement)
        }
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
            for i in clips.indices.reversed() where !clips[i].isEmpty && clips[i].sourceStart >= range.start - 1e-6 && clips[i].sourceEnd <= range.end + 1e-6 {
                setSpeed(i, factor)
            }
        }
        assert(checkInvariants() == nil)
    }

    /// Splits the clip containing SOURCE time `s` into two clips of the same speed. No-op if `s`
    /// isn't strictly inside a clip (in a gap, or within `minClipLength` of an edge/existing boundary).
    private mutating func splitClip(atSource s: Double) {
        guard let i = clips.firstIndex(where: { !$0.isEmpty && s > $0.sourceStart + Self.minClipLength && s < $0.sourceEnd - Self.minClipLength }) else { return }
        let clip = clips[i]
        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips[i].mediaStart = clip.mediaStart
        clips[i].clockSpeed = clip.clockSpeed
        var right = Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed)
        right.mediaStart = clip.mediaTime(atSource: s)
        right.clockSpeed = clip.clockSpeed
        clips.insert(right, at: i + 1)
        if linkVideoEdits { editLinkedLayers(in: s...s, moveBy: 0) }
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
            if c.sourceEnd <= c.sourceStart || (!c.isEmpty && c.mediaDuration < Self.minClipLength - eps) {
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
        if let e = keystrokeClips.blockInvariantError(kind: "keystrokes", duration: timelineSourceDuration) { return e }
        if let e = cameraClips.blockInvariantError(kind: "camera", duration: timelineSourceDuration, minLength: 0) { return e }
        if let e = zooms.blockInvariantError(kind: "zoom", duration: timelineSourceDuration) { return e }
        if let e = layouts.blockInvariantError(kind: "layout", duration: timelineSourceDuration) { return e }
        if let e = masks.blockInvariantError(kind: "mask", duration: timelineSourceDuration) { return e }
        return nil
    }
}

// MARK: - Zoom / layout / mask blocks

/// Common shape of the three timed-block tracks, so `addBlock`/`moveBlock`/`resizeBlock` below are
/// written once. `Zoom`, `Layout` and `Mask` all store `id` as a `String` (SPEC §5 JSON), so this
/// stays `String` too; the public `Project` API below is the only place that talks `UUID`, per the
/// plan's normative signatures, converting at the boundary.
private protocol TimedBlock {
    var id: String { get set }
    var start: Double { get set }
    var end: Double { get set }
    mutating func advanceMedia(by delta: Double)
}
private extension TimedBlock { mutating func advanceMedia(by delta: Double) {} }
extension Zoom: TimedBlock {}
extension Layout: TimedBlock {
    mutating func advanceMedia(by delta: Double) { if keys != nil { mediaStart = (mediaStart ?? start) + delta * (mediaRate ?? 1) } }
}
extension CameraClip: TimedBlock {
    mutating func advanceMedia(by delta: Double) { mediaStart += delta * (mediaRate ?? 1) }
}
extension Mask: TimedBlock {}

private extension Array where Element: TimedBlock {
    /// `nil` when every element is sorted by `start`, non-overlapping, >= `minLength`, and within
    /// `[0, duration]`.
    func blockInvariantError(kind: String, duration: Double, minLength: Double = 0) -> String? {
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
            // Half-open `[start, end)`: `s` sitting exactly on another block's end is the instant
            // its gap begins, not "inside" it — root-cause fix so `duplicateBlock`'s anchor (a
            // block's own `end`) lands in the gap right after it, not refused as self-overlapping.
            if s >= b.start && s < b.end { return nil }
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
        let minLength = Swift.min(minLength, self[i].end - self[i].start)
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

    // MARK: - Generic engine (shared by zoom/layout/mask — T-417/T-503/T-601: "parametrise by
    // lane, no copies"). `T: TimedBlock` is a file-private protocol, so these stay `private` too
    // (Swift access control lets a `private` member's signature mention a less-visible type); the
    // public, per-lane API below is a thin one-line wrapper per op, keyed on a `WritableKeyPath`
    // into `zooms`/`layouts`/`masks`.

    /// Adds a block of `length` seconds into the free gap in the lane at `keyPath` containing
    /// source time `s`. Returns its id, or `nil` if that gap is shorter than `minBlockLength`.
    @discardableResult
    private mutating func addBlock<T: TimedBlock>(atSource s: Double, length: Double, in keyPath: WritableKeyPath<Project, [T]>,
                                                    make: (_ id: String, _ start: Double, _ end: Double) -> T) -> UUID? {
        let newID = UUID()
        guard self[keyPath: keyPath].addBlock(atSource: s, length: length, duration: timelineSourceDuration, minLength: Self.minBlockLength,
                                               make: { start, end in make(newID.uuidString, start, end) }) != nil else { return nil }
        assert(checkInvariants() == nil)
        return newID
    }

    /// Moves the block with `id` in the lane at `keyPath` so it starts at source time `s`,
    /// clamped against its neighbours and `[0, source.duration]`.
    private mutating func moveBlock<T: TimedBlock>(_ id: UUID, in keyPath: WritableKeyPath<Project, [T]>, toStart s: Double) {
        self[keyPath: keyPath].moveBlock(id: id.uuidString, toStart: s, duration: timelineSourceDuration)
        assert(checkInvariants() == nil)
    }

    /// Drags the block with `id`'s `edge` (in the lane at `keyPath`) to source time `s`, clamped
    /// so it stays >= `minBlockLength` and never overlaps its neighbour.
    private mutating func resizeBlock<T: TimedBlock>(_ id: UUID, in keyPath: WritableKeyPath<Project, [T]>, edge: Edge, to s: Double) {
        self[keyPath: keyPath].resizeBlock(id: id.uuidString, edge: edge, to: s, duration: timelineSourceDuration, minLength: Self.minBlockLength)
        assert(checkInvariants() == nil)
    }

    // MARK: - Zoom (SPEC §7.4 normative names)

    /// Adds a zoom of `length` seconds (`Zoom.Mode` `mode`) into the free gap in `zooms` that
    /// contains source time `s`. Returns its id, or `nil` if that gap is shorter than 0.5 s.
    @discardableResult
    mutating func addZoom(atSource s: Double, length: Double = 3, mode: Zoom.Mode) -> UUID? {
        addBlock(atSource: s, length: length, in: \.zooms) { id, start, end in Zoom(id: id, start: start, end: end, mode: mode) }
    }

    /// Moves zoom `id` so it starts at source time `s`, clamped against its neighbours and
    /// `[0, source.duration]`.
    mutating func moveZoom(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.zooms, toStart: s) }

    /// Drags zoom `id`'s `edge` to source time `s`, clamped so it stays >= 0.5 s and never
    /// overlaps its neighbour.
    mutating func resizeZoom(_ id: UUID, edge: Edge, to s: Double) { resizeBlock(id, in: \.zooms, edge: edge, to: s) }

    // MARK: - Layout (`moveLayout` landed with T-417 for the accessibility nudge)

    /// Adds a layout of `length` seconds (`Layout.Kind` `kind`) into the free gap in `layouts`
    /// that contains source time `s`. Returns its id, or `nil` if that gap is shorter than 0.5 s.
    @discardableResult
    mutating func addLayout(atSource s: Double, length: Double = 3, kind: Layout.Kind) -> UUID? {
        if kind == .settings { return addKeys(atSource: s, length: length) }
        let camera = self.camera
        let kind: Layout.Kind = kind == .bubble && !source.hasCamera ? .settings : kind
        let keys = kind == .settings ? self.keys : nil
        return addBlock(atSource: s, length: length, in: \.layouts) { id, start, end in
            Layout(id: id, start: start, end: end, kind: kind, camera: kind == .bubble ? camera : nil, keys: keys)
        }
    }

    /// Moves layout `id` so it starts at source time `s`, clamped against its neighbours and
    /// `[0, source.duration]`.
    mutating func moveLayout(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.layouts, toStart: s) }

    /// Drags layout `id`'s `edge` to source time `s`, clamped so it stays >= 0.5 s and never
    /// overlaps its neighbour.
    mutating func resizeLayout(_ id: UUID, edge: Edge, to s: Double) { resizeBlock(id, in: \.layouts, edge: edge, to: s) }

    /// Non-mutating preview of where `addLayout(atSource:length:kind:)` would place a new block —
    /// for the empty layout-lane "ghost" (SPEC §7.2). `nil` exactly when `addLayout` would also fail.
    func previewLayoutPlacement(atSource s: Double, length: Double = 3) -> (start: Double, end: Double)? {
        var trial = self
        guard let id = trial.addLayout(atSource: s, length: length, kind: .cameraFull),
              let layout = trial.layouts.first(where: { $0.id == id.uuidString }) else { return nil }
        return (layout.start, layout.end)
    }

    // MARK: - Mask (`moveMask` landed with T-417 for the accessibility nudge)

    /// Adds a mask of `length` seconds (`Mask.Kind` `kind`, default rect/opacity) into the free
    /// gap in `masks` that contains source time `s`. Returns its id, or `nil` if that gap is
    /// shorter than 0.5 s.
    @discardableResult
    mutating func addMask(atSource s: Double, length: Double = 3, kind: Mask.Kind, rect: NormRect = NormRect(), opacity: Double = 0.8) -> UUID? {
        addBlock(atSource: s, length: length, in: \.masks) { id, start, end in Mask(id: id, start: start, end: end, kind: kind, rect: rect, opacity: opacity) }
    }

    /// Moves mask `id` so it starts at source time `s`, clamped against its neighbours and
    /// `[0, source.duration]`.
    mutating func moveMask(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.masks, toStart: s) }

    /// Drags mask `id`'s `edge` to source time `s`, clamped so it stays >= 0.5 s and never
    /// overlaps its neighbour.
    mutating func resizeMask(_ id: UUID, edge: Edge, to s: Double) { resizeBlock(id, in: \.masks, edge: edge, to: s) }

    /// Non-mutating preview of where `addMask(atSource:length:kind:)` would place a new block —
    /// for the empty mask-lane "ghost" (SPEC §7.2). `nil` exactly when `addMask` would also fail.
    func previewMaskPlacement(atSource s: Double, length: Double = 3) -> (start: Double, end: Double)? {
        var trial = self
        guard let id = trial.addMask(atSource: s, length: length, kind: .mask),
              let mask = trial.masks.first(where: { $0.id == id.uuidString }) else { return nil }
        return (mask.start, mask.end)
    }

    /// Removes the zoom, layout or mask block with `id`, whichever track it's in.
    mutating func removeBlock(_ id: UUID) {
        let key = id.uuidString
        if !keystrokeClips.removeBlock(id: key), !cameraClips.removeBlock(id: key), !zooms.removeBlock(id: key), !layouts.removeBlock(id: key) {
            masks.removeBlock(id: key)
        }
        assert(checkInvariants() == nil)
    }

    /// SPEC §7.3 `⌘D`: "duplicate selected zoom/mask after itself" — a copy of `id`'s block
    /// (same scale/mode/center/instant/enabled, or opacity/rect for a mask), placed in the free
    /// gap right after it. Returns the copy's id, or `nil` if `id` isn't a zoom/mask or there's no
    /// room. Layout isn't in SPEC's keyboard map for `⌘D`.
    @discardableResult
    mutating func duplicateBlock(_ id: UUID) -> UUID? {
        let key = id.uuidString
        let newID = UUID()
        if let zoom = zooms.first(where: { $0.id == key }) {
            guard zooms.addBlock(atSource: zoom.end, length: zoom.end - zoom.start, duration: timelineSourceDuration, minLength: Self.minBlockLength, make: { start, end in
                Zoom(id: newID.uuidString, start: start, end: end, scale: zoom.scale, mode: zoom.mode, center: zoom.center, instant: zoom.instant, enabled: zoom.enabled)
            }) != nil else { return nil }
        } else if let mask = masks.first(where: { $0.id == key }) {
            guard masks.addBlock(atSource: mask.end, length: mask.end - mask.start, duration: timelineSourceDuration, minLength: Self.minBlockLength, make: { start, end in
                Mask(id: newID.uuidString, start: start, end: end, kind: mask.kind, rect: mask.rect, opacity: mask.opacity, transition: mask.transition)
            }) != nil else { return nil }
        } else {
            return nil
        }
        assert(checkInvariants() == nil)
        return newID
    }

    /// Non-mutating preview of where `addZoom(atSource:length:)` would place a new block — for the
    /// empty zoom-lane "ghost" (SPEC §7.2 "Zoom blocks"). `nil` exactly when `addZoom` would also fail.
    func previewZoomPlacement(atSource s: Double, length: Double = 3) -> (start: Double, end: Double)? {
        var trial = self
        guard let id = trial.addZoom(atSource: s, length: length, mode: .manual),
              let zoom = trial.zooms.first(where: { $0.id == id.uuidString }) else { return nil }
        return (zoom.start, zoom.end)
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
