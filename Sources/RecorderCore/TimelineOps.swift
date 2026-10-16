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
    private func importedAudioTrack(start: Double, end: Double) -> Int {
        for track in audioTracks.indices where audioTracks[track].name.hasPrefix("Audio ") {
            if !audioClips.contains(where: { audio in
                guard audio.track == track, let range = outputRange(audio, connected: audio.isConnected) else { return false }
                return range.start < end - 1e-9 && range.end > start + 1e-9
            }) { return track }
        }
        return audioTracks.count
    }

    @discardableResult
    mutating func addImportedAudio(file: String, atOutput time: Double, duration: Double, layer: String? = nil) -> UUID? {
        guard file.hasPrefix("media/"), !file.split(separator: "/").contains(".."),
              time.isFinite, time >= 0, duration.isFinite, duration >= 0.1 else { return nil }
        let before = self
        extendAudioClock(toOutput: time)
        let track = importedAudioTrack(start: time, end: time + duration)
        if track == audioTracks.count {
            var number = 1
            while audioTracks.contains(where: { $0.name == "Audio \(number)" }) { number += 1 }
            audioTracks.append(AudioTrack(name: "Audio \(number)"))
        }
        let start = TimeMap(clips).sourceTime(atOutput: time)
        let id = UUID()
        audioClips.append(AudioClip(id: id.uuidString, start: start, end: start + duration, file: file,
                                    track: track, link: layer == nil ? nil : .layer, layer: layer))
        audioClips.sort { $0.start < $1.start }
        guard checkInvariants(mediaDurations: [file: duration]) == nil else { self = before; return nil }
        return id
    }

    @discardableResult
    mutating func addLayer(kind: LayerBlock.Kind, file: String, atOutput time: Double, duration: Double,
                           rect: NormRect, hasAudio: Bool = false, track preferredTrack: Int = 0) -> UUID? {
        guard file.hasPrefix("media/"), !file.split(separator: "/").contains(".."), preferredTrack >= 0,
              time.isFinite, time >= 0, duration.isFinite, duration >= 0.5 else { return nil }
        let before = self
        let length = kind == .video ? min(duration, TimeMap(clips).outputDuration - time) : duration
        guard length >= 0.5 else { return nil }
        extendAudioClock(toOutput: time)
        var track = preferredTrack
        while layers.contains(where: { layer in
            guard layer.track == track, let range = outputRange(layer, connected: true) else { return false }
            return range.start < time + length - 1e-9 && range.end > time + 1e-9
        }) { track += 1 }
        let start = TimeMap(clips).sourceTime(atOutput: time)
        let id = UUID()
        layers.append(LayerBlock(id: id.uuidString, kind: kind, start: start, end: start + length, file: file, track: track, rect: rect))
        layers.sort { $0.start < $1.start }
        if kind == .video, hasAudio,
           addImportedAudio(file: file, atOutput: time, duration: length, layer: id.uuidString) == nil { self = before; return nil }
        guard checkInvariants(mediaDurations: kind == .video ? [file: duration] : [:]) == nil else { self = before; return nil }
        return id
    }

    func voiceoverDestination(atOutput time: Double, replacing range: TimeRange? = nil) -> (track: Int, name: String, stop: Double?) {
        func retained(_ audio: AudioClip) -> Bool {
            guard let range, audio.file.hasPrefix("voice/"), let interval = outputRange(audio, connected: audio.isConnected) else { return true }
            return interval.end <= range.start || interval.start >= range.end
        }
        for track in audioTracks.indices where audioTracks[track].name.hasPrefix("Voiceover ") {
            let intervals = audioClips.filter { $0.track == track && retained($0) }.compactMap { outputRange($0, connected: $0.isConnected) }
            if !intervals.contains(where: { $0.start <= time && $0.end > time }) {
                return (track, audioTracks[track].name, intervals.filter { $0.start > time }.map(\.start).min())
            }
        }
        var number = 1
        while audioTracks.contains(where: { $0.name == "Voiceover \(number)" }) { number += 1 }
        return (audioTracks.count, "Voiceover \(number)", nil)
    }

    @discardableResult
    mutating func addVoiceover(file: String, placement: Double, duration: Double, replacing id: UUID? = nil) -> UUID? {
        guard file.hasPrefix("voice/"), !file.split(separator: "/").contains(".."),
              placement.isFinite, duration.isFinite, duration > 0 else { return nil }
        let original = id.flatMap { id in audioClips.first { $0.id == id.uuidString } }
        guard id == nil || original != nil else { return nil }
        let replacement = original.flatMap { outputRange($0, connected: $0.isConnected) }
        let start = max(0, placement, replacement?.start ?? 0)
        let end = min(placement + duration, replacement?.end ?? .infinity)
        guard start.isFinite, end.isFinite, end - start >= 0.1 - 1e-9 else { return nil }
        let before = self
        let destination = voiceoverDestination(atOutput: start, replacing: replacement)
        let stop = min(end, destination.stop ?? end)
        guard stop - start >= 0.1 - 1e-9 else { return nil }
        extendAudioClock(toOutput: start)
        if let original, let audioID = UUID(uuidString: original.id) {
            let otherIDs = Set(audioClips.filter { $0.id != original.id }.map(\.id))
            _ = splitAudio(audioID, atOutput: start, propagate: false)
            if let middle = audioClips.first(where: { audio in
                guard !otherIDs.contains(audio.id), let range = outputRange(audio, connected: audio.isConnected) else { return false }
                return range.start <= start + 1e-9 && range.end > start
            }), let middleID = UUID(uuidString: middle.id) { _ = splitAudio(middleID, atOutput: stop, propagate: false) }
            for index in audioClips.indices where !otherIDs.contains(audioClips[index].id) {
                if let range = outputRange(audioClips[index], connected: audioClips[index].isConnected), range.start >= start - 1e-9 && range.end <= stop + 1e-9 {
                    audioClips[index].gain = 0
                }
            }
            let previousTakes = audioClips.filter { $0.file.hasPrefix("voice/") }
            audioClips.removeAll { $0.file.hasPrefix("voice/") }
            var retained = previousTakes.compactMap { connectedOnOutput($0) }
            applyLinkedEdit(&retained, in: start...stop, moveBy: nil)
            audioClips += retained.map { connectedFromOutput($0) }
        }
        if destination.track == audioTracks.count { audioTracks.append(AudioTrack(name: destination.name)) }
        let sourceStart = TimeMap(clips).sourceTime(atOutput: start)
        let take = AudioClip(start: sourceStart, end: sourceStart + stop - start, mediaStart: start - placement, file: file, track: destination.track)
        audioClips.append(take)
        audioClips.sort { $0.start < $1.start }
        guard checkInvariants(mediaDurations: [file: duration]) == nil else { self = before; return nil }
        return UUID(uuidString: take.id)
    }

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
        let before = self

        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips[i].mediaStart = clip.mediaStart
        clips[i].clockSpeed = clip.clockSpeed
        clips[i].fadeIn = clip.fadeIn
        var right = Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed)
        right.mediaStart = clip.mediaTime(atSource: s)
        right.clockSpeed = clip.clockSpeed
        right.fadeOut = clip.fadeOut
        clips.insert(right, at: i + 1)
        editLinkedLayers(in: s...s, moveBy: 0)
        settleConnected()
        guard checkInvariants() == nil else { self = before; return false }
        assert(checkInvariants() == nil)
        return true
    }

    private mutating func editLinkedLayers(in range: ClosedRange<Double>, moveBy delta: Double?) {
        editAudio(link: .screen, in: range, moveBy: delta)
        guard linkVideoEdits else { return }
        editCamera(in: range, moveBy: delta)
        applyLinkedEdit(&zooms, in: range, moveBy: delta)
        applyLinkedEdit(&keystrokeClips, in: range, moveBy: delta)
        applyLinkedEdit(&layouts, in: range, moveBy: delta)
        applyLinkedEdit(&masks, in: range, moveBy: delta)
        applyLinkedEdit(&texts, in: range, moveBy: delta)
        applyLinkedEdit(&windowShots, in: range, moveBy: delta)
    }

    private mutating func editAudio(link: AudioClip.Link, in range: ClosedRange<Double>, moveBy delta: Double?, layer: String? = nil) {
        let selected = audioClips.filter { $0.link == link && (link != .layer || $0.layer == layer) }
        audioClips.removeAll { $0.link == link && (link != .layer || $0.layer == layer) }
        for track in Set(selected.map(\.track)).sorted() {
            var blocks = selected.filter { $0.track == track }
            applyLinkedEdit(&blocks, in: range, moveBy: delta, overwrite: false)
            audioClips += blocks
        }
        audioClips.sort { $0.start < $1.start }
    }

    private mutating func editCamera(in range: ClosedRange<Double>, moveBy delta: Double?) {
        applyLinkedEdit(&cameraClips, in: range, moveBy: delta)
        editAudio(link: .camera, in: range, moveBy: delta)
    }

    private mutating func resizeLinkedAudio(_ link: AudioClip.Link, from old: ClosedRange<Double>, to changed: ClosedRange<Double>) {
        if changed.lowerBound > old.lowerBound { editAudio(link: link, in: old.lowerBound...changed.lowerBound, moveBy: nil) }
        if changed.upperBound < old.upperBound { editAudio(link: link, in: changed.upperBound...old.upperBound, moveBy: nil) }
        for index in audioClips.indices where audioClips[index].link == link {
            if changed.lowerBound < old.lowerBound, abs(audioClips[index].start - old.lowerBound) < 1e-9 {
                audioClips[index].advanceMedia(by: changed.lowerBound - old.lowerBound)
                audioClips[index].start = changed.lowerBound
            }
            if changed.upperBound > old.upperBound, abs(audioClips[index].end - old.upperBound) < 1e-9 {
                audioClips[index].end = changed.upperBound
            }
        }
    }

    mutating func settleConnected() {
        guard !clips.isEmpty, audioClips.allSatisfy({ audioTracks.indices.contains($0.track) }) else { return }
        let timeline = clips, map = TimeMap(clips)
        func settleAnchor<Block: TimedBlock>(_ block: inout Block) {
            guard block.start.isFinite, map.outputTime(atSource: block.start) == nil else { return }
            let length = block.end - block.start
            block.start = timeline.first(where: { $0.sourceStart > block.start })?.sourceStart ?? timeline.last!.sourceEnd
            block.end = block.start + length
        }
        for index in layers.indices { settleAnchor(&layers[index]) }
        for index in audioClips.indices where audioClips[index].isConnected { settleAnchor(&audioClips[index]) }

        func settle<Block: TimedBlock>(_ blocks: inout [Block], track: WritableKeyPath<Block, Int>, ranges: [TimeRange?],
                                      candidates: (Block) -> [Int], create: (Block) -> Int) {
            let order = blocks.indices.sorted {
                let first = ranges[$0]?.start ?? .infinity, second = ranges[$1]?.start ?? .infinity
                return first == second ? $0 < $1 : first < second
            }
            var ends: [Int: Double] = [:]
            for index in order {
                guard let range = ranges[index] else { continue }
                let original = blocks[index][keyPath: track]
                if range.start < (ends[original] ?? -.infinity) - 1e-9 {
                    let available = candidates(blocks[index]).first { candidate in
                        blocks.indices.allSatisfy { other in
                            guard other != index, blocks[other][keyPath: track] == candidate, let occupied = ranges[other] else { return true }
                            return occupied.end <= range.start + 1e-9 || occupied.start >= range.end - 1e-9
                        }
                    }
                    blocks[index][keyPath: track] = available ?? create(blocks[index])
                }
                ends[blocks[index][keyPath: track]] = range.end
            }
            blocks.sort { $0.start < $1.start }
        }

        var tracks = audioTracks
        let audioRanges = audioClips.map { outputRange($0, connected: $0.isConnected) }
        settle(&audioClips, track: \.track, ranges: audioRanges, candidates: { audio in
            let original = tracks[audio.track]
            return tracks.indices.filter {
                $0 > audio.track && tracks[$0].name != "Mic" && tracks[$0].name != "System"
                    && tracks[$0].volume == original.volume && tracks[$0].muted == original.muted
            }
        }, create: { audio in
            let original = tracks[audio.track]
            let prefix = original.name.hasPrefix("Voiceover ") ? "Voiceover" : "Audio"
            var number = 1
            while tracks.contains(where: { $0.name == "\(prefix) \(number)" }) { number += 1 }
            tracks.append(AudioTrack(name: "\(prefix) \(number)", volume: original.volume, muted: original.muted))
            return tracks.count - 1
        })
        audioTracks = tracks

        var layerTracks = Set(layers.map(\.track)).sorted()
        let layerRanges = layers.map { outputRange($0, connected: true) }
        settle(&layers, track: \.track, ranges: layerRanges, candidates: { layer in
            layerTracks.filter { $0 > layer.track }
        }, create: { _ in
            let track = (layerTracks.last ?? -1) + 1
            layerTracks.append(track)
            return track
        })
    }

    /// Lift video without changing the timing of any other lane.
    mutating func liftClip(_ i: Int, propagate: Bool = true) {
        guard clips.indices.contains(i), !clips[i].isEmpty else { return }
        let before = self
        if propagate { editLinkedLayers(in: clips[i].sourceStart...clips[i].sourceEnd, moveBy: nil) }
        clips[i].isGap = true
        settleConnected()
        if checkInvariants() != nil { self = before }
    }

    /// Delete uses the two independent timeline modes. Keep one gap when deleting all video.
    mutating func deleteClips(_ indices: Set<Int>, propagate: Bool = true) {
        let before = self
        for i in indices.sorted(by: >) where clips.indices.contains(i) && !clips[i].isEmpty {
            liftClip(i, propagate: propagate)
            if rippleDelete && clips.count > 1 && clips[i].isEmpty { clips.remove(at: i) }
        }
        settleConnected()
        if checkInvariants() != nil { self = before }
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
        var linkedAudio = audioClips.filter { !$0.isConnected }
        var connectedAudio = audioClips.filter(\.isConnected)
        retimeMedia(&linkedAudio, rate: \.mediaRate)
        for index in connectedAudio.indices {
            let length = connectedAudio[index].end - connectedAudio[index].start
            connectedAudio[index].start = output(connectedAudio[index].start)
            connectedAudio[index].end = connectedAudio[index].start + length
        }
        audioClips = (linkedAudio + connectedAudio).sorted { $0.start < $1.start }
        for index in layers.indices {
            let length = layers[index].end - layers[index].start
            layers[index].start = output(layers[index].start)
            layers[index].end = layers[index].start + length
        }
        retime(&zooms); retime(&layouts); retime(&masks); retime(&texts); retime(&windowShots) // ponytail: caption word offsets keep source seconds, not rescaled by speed
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
        settleConnected()
    }

    /// Clipboard content uses output seconds relative to the selection, with media in-points
    /// frozen. Reuse Project's track arrays/settings; no second serialization model is needed.
    func copySelection(clips indices: Set<Int>, blocks ids: Set<UUID>) -> Project? {
        let selected = indices.filter { clips.indices.contains($0) && !clips[$0].isEmpty }
        let blockIDs = Set(ids.map(\.uuidString))
        func mergedRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
            ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
                if let last = merged.last, last.upperBound >= range.lowerBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else { merged.append(range) }
            }
        }
        let selectedAudio = audioClips.filter { blockIDs.contains($0.id) }
        let videoRanges = selected.sorted().map { clips[$0].sourceStart...clips[$0].sourceEnd }
            + selectedAudio.filter { $0.link == .screen }.map { $0.start...$0.end }
        let ranges = mergedRanges(videoRanges)
        func selectedBlocks<T: TimedBlock>(_ blocks: [T], linkedRanges: [ClosedRange<Double>]? = nil) -> [T] {
            blocks.flatMap { block -> [T] in
                if blockIDs.contains(block.id) { return [block] }
                guard linkedRanges != nil || linkVideoEdits else { return [] }
                return (linkedRanges ?? ranges).compactMap { range in
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
        let cameraRanges = mergedRanges((linkVideoEdits ? ranges : []) + selectedAudio.filter { $0.link == .camera }.map { $0.start...$0.end })
        copied.cameraClips = selectedBlocks(cameraClips, linkedRanges: cameraRanges)
        var layerOrigins: [String: String] = [:]
        copied.layers = layers.flatMap { layer -> [LayerBlock] in
            if blockIDs.contains(layer.id) { layerOrigins[layer.id] = layer.id; return [layer] }
            guard let output = connectedOnOutput(layer) else { return [] }
            let ranges = mergedRanges(selectedAudio.filter { $0.link == .layer && $0.layer == layer.id }.compactMap { audio in
                outputRange(audio, connected: true).map { $0.start...$0.end }
            })
            return ranges.compactMap { range in
                let lower = max(output.start, range.lowerBound), upper = min(output.end, range.upperBound)
                guard upper > lower else { return nil }
                var part = output
                part.id = UUID().uuidString; part.advanceMedia(by: lower - output.start)
                part.start = lower; part.end = upper
                layerOrigins[part.id] = layer.id
                return connectedFromOutput(part)
            }
        }
        copied.audioClips = audioClips.flatMap { audio -> [AudioClip] in
            if audio.link == .screen { return selectedBlocks([audio], linkedRanges: ranges) }
            if audio.link == .camera { return selectedBlocks([audio], linkedRanges: copied.cameraClips.map { $0.start...$0.end }) }
            if audio.link == .layer {
                if blockIDs.contains(audio.id) || audio.layer.map(blockIDs.contains) == true {
                    var part = audio
                    part.layer = copied.layers.first { layerOrigins[$0.id] == audio.layer }?.id ?? audio.layer
                    return [part]
                }
                guard let output = connectedOnOutput(audio) else { return [] }
                return copied.layers.filter { layerOrigins[$0.id] == audio.layer }.compactMap { layer in
                    guard let range = outputRange(layer, connected: true) else { return nil }
                    let lower = max(output.start, range.start), upper = min(output.end, range.end)
                    guard upper > lower else { return nil }
                    var part = output
                    if lower != output.start { part.id = UUID().uuidString }
                    part.advanceMedia(by: lower - output.start)
                    part.start = lower; part.end = upper; part.layer = layer.id
                    return connectedFromOutput(part)
                }
            }
            return blockIDs.contains(audio.id) ? [audio] : []
        }
        copied.zooms = selectedBlocks(zooms)
        copied.keystrokeClips = selectedBlocks(keystrokeClips)
        copied.layouts = selectedBlocks(layouts)
        copied.masks = selectedBlocks(masks)
        copied.texts = selectedBlocks(texts)
        copied.windowShots = selectedBlocks(windowShots)
        copied.useOutputClock()
        copied.clips = zip(clips, copied.clips).flatMap { original, output in
            ranges.compactMap { range -> Clip? in
                let lower = max(original.sourceStart, range.lowerBound), upper = min(original.sourceEnd, range.upperBound)
                guard !original.isEmpty, upper > lower else { return nil }
                var part = output
                part.sourceStart = output.sourceStart + (lower - original.sourceStart) / original.timeScale
                part.sourceEnd = output.sourceStart + (upper - original.sourceStart) / original.timeScale
                part.mediaStart = original.mediaTime(atSource: lower)
                if lower > original.sourceStart { part.fadeIn = nil }
                if upper < original.sourceEnd { part.fadeOut = nil }
                return part
            }
        }
        let starts = copied.clips.map(\.sourceStart) + copied.cameraClips.map(\.start) + copied.zooms.map(\.start) + copied.audioClips.map(\.start) + copied.layers.map(\.start)
            + copied.keystrokeClips.map(\.start) + copied.layouts.map(\.start) + copied.masks.map(\.start) + copied.texts.map(\.start) + copied.windowShots.map(\.start)
        guard let origin = starts.min() else { return nil }
        func offset<T: TimedBlock>(_ blocks: inout [T]) {
            for i in blocks.indices { blocks[i].start -= origin; blocks[i].end -= origin }
        }
        for i in copied.clips.indices { copied.clips[i].sourceStart -= origin; copied.clips[i].sourceEnd -= origin }
        offset(&copied.cameraClips); offset(&copied.zooms); offset(&copied.keystrokeClips)
        offset(&copied.layouts); offset(&copied.masks); offset(&copied.texts); offset(&copied.windowShots)
        offset(&copied.audioClips); offset(&copied.layers)
        guard copied.layers.allSatisfy({ $0.end - $0.start >= 0.5 - 1e-9 }) else { return nil }
        return copied
    }

    /// Insert video at the playhead, shifting existing content to keep it intact. Layer-only
    /// pastes replace their own lane's overlapping range, retaining both outside pieces.
    /// Returns the pasted selection; refuses cuts that would leave invalid video slivers.
    mutating func pasteSelection(_ copied: Project, atOutput time: Double) -> (clips: Set<Int>, blocks: Set<UUID>)? {
        guard time.isFinite, time >= 0 else { return nil }
        var result = self
        result.useOutputClock()
        var audioRoutes: [Int: Int] = [:]
        for track in Set(copied.audioClips.map(\.track)).sorted() {
            guard copied.audioTracks.indices.contains(track) else { return nil }
            let settings = copied.audioTracks[track]
            if let existing = result.audioTracks.firstIndex(where: { $0.id == settings.id }) { audioRoutes[track] = existing }
            else { audioRoutes[track] = result.audioTracks.count; result.audioTracks.append(settings) }
        }
        let incomingAudio = copied.audioClips.map { audio -> AudioClip in
            var part = audio; part.track = audioRoutes[audio.track]!
            return part
        }
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
        var pastedLinks: [String: String] = [:]
        func paste<T: TimedBlock>(_ incoming: [T], into blocks: inout [T], shift: Bool = true) {
            if shift && insertDuration > 0 {
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
                pastedLinks[block.id] = pasted.id
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
        paste(copied.texts, into: &result.texts)
        paste(copied.windowShots, into: &result.windowShots)
        for index in result.layers.indices where insertDuration > 0 && result.layers[index].start >= replaceEnd {
            result.layers[index].start += insertDuration; result.layers[index].end += insertDuration
        }
        for track in Set(copied.layers.map(\.track)) {
            var lane = result.layers.filter { $0.track == track }
            paste(copied.layers.filter { $0.track == track }, into: &lane, shift: false)
            result.layers.removeAll { $0.track == track }
            result.layers += lane
        }
        result.layers.sort { $0.start < $1.start }
        var audioByTrack: [AudioClip] = []
        for track in result.audioTracks.indices {
            var linked = result.audioClips.filter { $0.track == track && !$0.isConnected }
            paste([], into: &linked)
            audioByTrack += linked
        }
        for var audio in result.audioClips where audio.isConnected {
            if insertDuration > 0 && audio.start >= replaceEnd { audio.start += insertDuration; audio.end += insertDuration }
            audioByTrack.append(audio)
        }
        for track in result.audioTracks.indices {
            var clips = audioByTrack.filter { $0.track == track }
            let incoming = incomingAudio.filter { $0.track == track }.map { audio in
                var part = audio
                if let layer = part.layer { part.layer = pastedLinks[layer] ?? layer }
                return part
            }
            paste(incoming, into: &clips, shift: false)
            audioByTrack.removeAll { $0.track == track }
            audioByTrack += clips
        }
        result.audioClips = audioByTrack.sorted { $0.start < $1.start }

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
        ends += result.texts.map(\.end)
        ends += result.windowShots.map(\.end)
        ends += result.audioClips.map { $0.isConnected ? $0.start : $0.end }
        ends += result.layers.map(\.start)
        let end = ends.max() ?? 0
        let videoEnd = result.clips.last?.sourceEnd ?? 0
        if end > videoEnd {
            var gap = Clip(sourceStart: videoEnd, sourceEnd: end); gap.isGap = true
            result.clips.append(gap)
        }
        result.settleConnected()
        guard !pastedClips.isEmpty || !pastedIDs.isEmpty, result.checkInvariants() == nil else { return nil }
        self = result
        return (pastedClips, pastedIDs)
    }

    /// Move a selection as one unit, retaining the spacing between its clips.
    /// The same collision constraints as a single move apply to the whole selection.
    @discardableResult
    mutating func moveClips(_ indices: Set<Int>, byOutput requested: Double, propagate: Bool = true) -> Set<Int> {
        let selected = indices.sorted().filter { clips.indices.contains($0) && !clips[$0].isEmpty }
        guard !selected.isEmpty, requested.isFinite, abs(requested) > 1e-8 else { return Set(selected) }
        let before = self
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
                          end: clip.sourceEnd + delta * clip.timeScale, moving: true, propagate: propagate)
        }
        guard checkInvariants() == nil else { self = before; return Set(selected) }
        return Set(selected.compactMap { i in
            let old = original[i]
            return clips.firstIndex { !$0.isEmpty && abs($0.sourceStart - old.sourceStart - delta * old.timeScale) < 1e-8 && $0.mediaIn == old.mediaIn }
        })
    }

    /// Only explicit per-clip fades affect opacity; gaps never enable a transition automatically.
    func videoOpacity(atOutput time: Double) -> Double {
        guard let i = clipIndex(atOutput: time), !clips[i].isEmpty else { return 0 }
        let clip = clips[i]
        let elapsed = time - clips[..<i].reduce(0) { $0 + $1.outputDuration }
        func ramp(_ distance: Double, _ seconds: Double?) -> Double {
            guard let seconds, seconds.isFinite, seconds > 0 else { return 1 }
            let t = min(1, max(0, distance / min(seconds, clip.outputDuration)))
            return t * t * (3 - 2 * t)
        }
        return min(ramp(elapsed, clip.fadeIn), ramp(clip.outputDuration - elapsed, clip.fadeOut))
    }

    /// Trim/move only within adjacent free space. Gap pieces retain the clock mapping, so
    /// camera, keys and effects stay at exactly the same output times.
    @discardableResult
    mutating func placeClip(_ i: Int, start: Double, end: Double, moving: Bool = false, propagate: Bool = true) -> Int {
        guard clips.indices.contains(i), !clips[i].isEmpty, start.isFinite, end.isFinite else { return i }
        let before = self
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
        if propagate {
            if moving, abs(a - old.sourceStart) > 1e-8 {
                editLinkedLayers(in: old.sourceStart...old.sourceEnd, moveBy: a - old.sourceStart)
                if linkVideoEdits {
                    let movedLayers = Set(layers.filter { $0.start >= old.sourceStart && $0.start < old.sourceEnd }.map(\.id))
                    for index in layers.indices where movedLayers.contains(layers[index].id) {
                        layers[index].start += a - old.sourceStart; layers[index].end += a - old.sourceStart
                    }
                    for index in audioClips.indices where audioClips[index].isConnected {
                        let audio = audioClips[index]
                        let carried = audio.link == .layer ? audio.layer.map { movedLayers.contains($0) } ?? false
                            : audio.start >= old.sourceStart && audio.start < old.sourceEnd
                        if carried {
                            audioClips[index].start += a - old.sourceStart; audioClips[index].end += a - old.sourceStart
                        }
                    }
                }
            } else if !moving {
                if a > old.sourceStart { editLinkedLayers(in: old.sourceStart...a, moveBy: nil) }
                if b < old.sourceEnd { editLinkedLayers(in: b...old.sourceEnd, moveBy: nil) }
                resizeLinkedAudio(.screen, from: old.sourceStart...old.sourceEnd, to: a...b)
                if linkVideoEdits { resizeLinkedAudio(.camera, from: old.sourceStart...old.sourceEnd, to: a...b) }
            }
        }
        settleConnected()
        guard checkInvariants() == nil else { self = before; return i }
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

    mutating func moveCamera(_ id: UUID, toStart s: Double, propagate: Bool = true) {
        guard s.isFinite, let old = cameraClips.first(where: { $0.id == id.uuidString }) else { return }
        let before = self
        cameraClips.moveBlock(id: id.uuidString, toStart: s, duration: timelineSourceDuration)
        if propagate, let changed = cameraClips.first(where: { $0.id == id.uuidString }) {
            editAudio(link: .camera, in: old.start...old.end, moveBy: changed.start - old.start)
        }
        if checkInvariants() != nil { self = before }
    }
    mutating func resizeCamera(_ id: UUID, edge: Edge, to s: Double, propagate: Bool = true) {
        guard s.isFinite, let i = cameraClips.firstIndex(where: { $0.id == id.uuidString }) else { return }
        let before = self
        let old = cameraClips[i]
        let lower = old.start - old.mediaStart / (old.mediaRate ?? 1)
        let upper = old.start + (source.duration - old.mediaStart) / (old.mediaRate ?? 1)
        cameraClips.resizeBlock(id: id.uuidString, edge: edge, to: min(upper, max(lower, s)), duration: timelineSourceDuration, minLength: Self.minClipLength)
        cameraClips[i].mediaStart += (cameraClips[i].start - old.start) * (old.mediaRate ?? 1)
        if propagate { resizeLinkedAudio(.camera, from: old.start...old.end, to: cameraClips[i].start...cameraClips[i].end) }
        if checkInvariants() != nil { self = before }
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
    mutating func splitBlock(_ id: UUID, atSource s: Double, propagate: Bool = true) -> Bool {
        guard s.isFinite else { return false }
        let before = self
        if let camera = cameraClips.first(where: { $0.id == id.uuidString }) {
            guard s - camera.start >= Self.minClipLength, camera.end - s >= Self.minClipLength else { return false }
            if propagate { editCamera(in: s...s, moveBy: 0) }
            else { applyLinkedEdit(&cameraClips, in: s...s, moveBy: 0) }
            guard checkInvariants() == nil else { self = before; return false }
            return true
        }
        if let layer = layers.first(where: { $0.id == id.uuidString }), let range = outputRange(layer, connected: true),
           let output = TimeMap(clips).outputTime(atSource: s) {
            guard output - range.start >= 0.5, range.end - output >= 0.5 else { return false }
            editLayer(layer, in: output...output, moveBy: 0, propagate: propagate)
            guard checkInvariants() == nil else { self = before; return false }
            return true
        }
        if let audio = audioClips.first(where: { $0.id == id.uuidString }),
           let range = outputRange(audio, connected: audio.isConnected), let output = TimeMap(clips).outputTime(atSource: s) {
            guard output - range.start >= 0.1, range.end - output >= 0.1 else { return false }
            if propagate, audio.link == .screen {
                guard self.split(atOutput: output) else { return false }
            } else if propagate, audio.link == .camera { editCamera(in: s...s, moveBy: 0) }
            else if propagate, audio.link == .layer, let layer = layers.first(where: { $0.id == audio.layer }),
                    let layerRange = outputRange(layer, connected: true) {
                guard output - layerRange.start >= 0.5, layerRange.end - output >= 0.5 else { return false }
                editLayer(layer, in: output...output, moveBy: 0, propagate: true)
            } else {
                var pieces = [audio.isConnected ? connectedOnOutput(audio)! : audio]
                let cut = audio.isConnected ? output : s
                applyLinkedEdit(&pieces, in: cut...cut, moveBy: 0)
                audioClips.removeAll { $0.id == audio.id }
                audioClips += audio.isConnected ? pieces.map { connectedFromOutput($0) } : pieces
                audioClips.sort { $0.start < $1.start }
            }
            guard checkInvariants() == nil else { self = before; return false }
            return true
        }
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
        if split(&zooms) { return true }
        if split(&keystrokeClips) { return true }
        if split(&layouts) { return true }
        if split(&masks) { return true }
        if split(&texts) { return true }
        return split(&windowShots)
    }

    private func outputRange<Block: TimedBlock>(_ block: Block, connected: Bool) -> TimeRange? {
        let map = TimeMap(clips)
        if connected {
            guard let start = map.outputTime(atSource: block.start) else { return nil }
            return TimeRange(start: start, end: start + block.end - block.start)
        }
        var output = 0.0, first: Double?, end: Double?
        for clip in clips {
            let lower = max(block.start, clip.sourceStart), upper = min(block.end, clip.sourceEnd)
            if upper > lower {
                if first == nil { first = output + (lower - clip.sourceStart) / clip.timeScale }
                end = output + (upper - clip.sourceStart) / clip.timeScale
            }
            output += clip.outputDuration
        }
        guard let first, let end else { return nil }
        return TimeRange(start: first, end: end)
    }

    private func connectedOnOutput<Block: TimedBlock>(_ block: Block) -> Block? {
        guard let range = outputRange(block, connected: true) else { return nil }
        var result = block
        result.start = range.start; result.end = range.end
        return result
    }

    private func connectedFromOutput<Block: TimedBlock>(_ block: Block) -> Block {
        var result = block
        result.start = TimeMap(clips).sourceTime(atOutput: block.start)
        result.end = result.start + block.end - block.start
        return result
    }

    private mutating func editLayer(_ layer: LayerBlock, in range: ClosedRange<Double>, moveBy delta: Double?, propagate: Bool) {
        guard let output = connectedOnOutput(layer) else { return }
        var pieces = [output]
        applyLinkedEdit(&pieces, in: range, moveBy: delta)
        let partners = audioClips.filter { $0.link == .layer && $0.layer == layer.id }
        if propagate {
            var audio = partners.compactMap { connectedOnOutput($0) }
            if pieces.isEmpty { audio = [] }
            else if let delta, delta != 0, range.lowerBound <= output.start, range.upperBound >= output.end {
                let lower = min(output.start, audio.map(\.start).min() ?? output.start)
                let upper = max(output.end, audio.map(\.end).max() ?? output.end)
                applyLinkedEdit(&audio, in: lower...upper, moveBy: delta)
            } else { applyLinkedEdit(&audio, in: range, moveBy: delta) }
            audioClips.removeAll { $0.link == .layer && $0.layer == layer.id }
            for var part in audio {
                guard let partner = pieces.last(where: { $0.start <= part.start }) ?? pieces.first else { continue }
                part.layer = partner.id
                audioClips.append(connectedFromOutput(part))
            }
        } else if pieces.isEmpty {
            for index in audioClips.indices where audioClips[index].layer == layer.id {
                audioClips[index].link = nil; audioClips[index].layer = nil
            }
        }
        layers.removeAll { $0.id == layer.id }
        layers += pieces.map { connectedFromOutput($0) }
        layers.sort { $0.start < $1.start }
        audioClips.sort { $0.start < $1.start }
    }

    mutating func moveLayer(_ id: UUID, toStart source: Double, propagate: Bool = true) {
        guard source.isFinite, let output = TimeMap(clips).outputTime(atSource: source) else { return }
        moveLayer(id, toOutput: output, propagate: propagate)
    }

    mutating func moveLayer(_ id: UUID, toOutput requested: Double, track: Int? = nil, propagate: Bool = true) {
        guard requested.isFinite, requested >= 0, var layer = layers.first(where: { $0.id == id.uuidString }),
              let range = outputRange(layer, connected: true), track == nil || track! >= 0 else { return }
        let destination = track ?? layer.track
        let neighbours = layers.filter { $0.track == destination && $0.id != layer.id }.compactMap { outputRange($0, connected: true) }
        let lower = neighbours.filter { $0.end <= range.start + 1e-9 }.map(\.end).max() ?? 0
        let upper = (neighbours.filter { $0.start >= range.end - 1e-9 }.map(\.start).min() ?? .infinity) - (range.end - range.start)
        let start = min(max(requested, lower), upper)
        guard abs(start - range.start) > 1e-9 || destination != layer.track else { return }
        let before = self
        extendAudioClock(toOutput: start)
        layer.track = destination
        editLayer(layer, in: range.start...range.end, moveBy: start - range.start, propagate: propagate)
        if checkInvariants() != nil { self = before }
    }

    mutating func resizeLayer(_ id: UUID, edge: Edge, to source: Double, mediaDuration: Double? = nil, propagate: Bool = true) {
        guard source.isFinite, let output = TimeMap(clips).outputTime(atSource: source) else { return }
        resizeLayer(id, edge: edge, toOutput: output, mediaDuration: mediaDuration, propagate: propagate)
    }

    mutating func resizeLayer(_ id: UUID, edge: Edge, toOutput requested: Double, mediaDuration: Double? = nil, propagate: Bool = true) {
        guard requested.isFinite, requested >= 0, let layer = layers.first(where: { $0.id == id.uuidString }),
              let range = outputRange(layer, connected: true) else { return }
        let neighbours = layers.filter { $0.track == layer.track && $0.id != layer.id }.compactMap { outputRange($0, connected: true) }
        let before = self
        var changed = connectedOnOutput(layer)!
        switch edge {
        case .leading:
            let lower = max(neighbours.filter { $0.end <= range.start + 1e-9 }.map(\.end).max() ?? 0,
                            layer.kind == .video ? range.start - layer.mediaStart : 0)
            changed.start = min(max(requested, lower), range.end - 0.5)
            changed.advanceMedia(by: changed.start - range.start)
        case .trailing:
            let upper = min(neighbours.filter { $0.start >= range.end - 1e-9 }.map(\.start).min() ?? .infinity,
                            layer.kind == .video ? range.start + (mediaDuration ?? .infinity) - layer.mediaStart : .infinity)
            changed.end = max(min(requested, upper), range.start + 0.5)
        }
        extendAudioClock(toOutput: changed.start)
        if propagate {
            if changed.start > range.start { editLayer(layer, in: range.start...changed.start, moveBy: nil, propagate: true) }
            if changed.end < range.end, let current = layers.first(where: { $0.id == layer.id }) {
                editLayer(current, in: changed.end...range.end, moveBy: nil, propagate: true)
            }
            for index in audioClips.indices where audioClips[index].link == .layer && audioClips[index].layer == layer.id {
                guard var audio = connectedOnOutput(audioClips[index]) else { continue }
                if changed.start < range.start, abs(audio.start - range.start) < 1e-9 {
                    audio.advanceMedia(by: changed.start - range.start)
                    audio.start = changed.start
                }
                if changed.end > range.end, abs(audio.end - range.end) < 1e-9 { audio.end = changed.end }
                audioClips[index] = connectedFromOutput(audio)
            }
        }
        layers[layers.firstIndex(where: { $0.id == layer.id })!] = connectedFromOutput(changed)
        audioClips.sort { $0.start < $1.start }
        layers.sort { $0.start < $1.start }
        if checkInvariants(mediaDurations: mediaDuration.map { [layer.file: $0] } ?? [:]) != nil { self = before }
    }

    @discardableResult
    mutating func unlinkAudio(_ id: UUID) -> Bool {
        guard let original = audioClips.first(where: { $0.id == id.uuidString }), original.link != nil else { return false }
        let before = self
        var pieces = [original]
        if !original.isConnected {
            for boundary in Set(clips.flatMap { [$0.sourceStart, $0.sourceEnd] }).sorted() {
                applyLinkedEdit(&pieces, in: boundary...boundary, moveBy: 0)
            }
        }
        var detached: [AudioClip] = []
        for var piece in pieces {
            guard let range = outputRange(piece, connected: original.isConnected), range.end > range.start else { self = before; return false }
            if !original.isConnected {
                piece.mediaRate = (piece.end - piece.start) * (piece.mediaRate ?? 1) / (range.end - range.start)
                piece.end = piece.start + range.end - range.start
            }
            piece.link = nil; piece.layer = nil
            detached.append(piece)
        }
        audioClips.removeAll { $0.id == original.id }
        audioClips += detached
        audioClips.sort { $0.start < $1.start }
        guard checkInvariants() == nil else { self = before; return false }
        return true
    }

    @discardableResult
    mutating func linkAudio(_ id: UUID, to link: AudioClip.Link) -> Bool {
        guard audioClips.contains(where: { $0.id == id.uuidString }) else { return false }
        let before = self
        let otherIDs = Set(audioClips.filter { $0.id != id.uuidString }.map(\.id))
        if audioClips.first(where: { $0.id == id.uuidString })?.isConnected == false, !unlinkAudio(id) { return false }
        let incoming = audioClips.filter { !otherIDs.contains($0.id) }
        var linked: [AudioClip] = []
        for audio in incoming {
            guard let output = connectedOnOutput(audio), link == .layer || output.end <= TimeMap(clips).outputDuration + 1e-9 else { self = before; return false }
            let targets: [(TimeRange, String?)]
            switch link {
            case .screen:
                targets = clips.filter { !$0.isEmpty }.compactMap {
                    guard let start = TimeMap(clips).outputTime(atSource: $0.sourceStart) else { return nil }
                    return (TimeRange(start: start, end: start + $0.outputDuration), nil)
                }
            case .camera: targets = cameraClips.compactMap { camera in outputRange(camera, connected: false).map { ($0, nil) } }
            case .layer: targets = layers.filter { $0.kind == .video && $0.file == audio.file }.compactMap { layer in
                outputRange(layer, connected: true).map { ($0, layer.id) }
            }
            }
            var pieces = [output]
            let boundaries = targets.flatMap { [$0.0.start, $0.0.end] }
                + (link == .layer ? [] : clips.compactMap { TimeMap(clips).outputTime(atSource: $0.sourceStart) })
            for boundary in Set(boundaries).sorted() { applyLinkedEdit(&pieces, in: boundary...boundary, moveBy: 0) }
            for var piece in pieces {
                let partner = targets.first { $0.0.start <= piece.start + 1e-9 && $0.0.end >= piece.end - 1e-9 }
                piece.link = partner == nil ? nil : link
                piece.layer = partner?.1
                if piece.link == .screen || piece.link == .camera {
                    let start = TimeMap(clips).sourceTime(atOutput: piece.start)
                    let end = clips.first { clip in
                        guard let outputStart = TimeMap(clips).outputTime(atSource: clip.sourceStart) else { return false }
                        return piece.start >= outputStart - 1e-9 && piece.start < outputStart + clip.outputDuration - 1e-9
                    }.map { start + (piece.end - piece.start) * $0.timeScale }
                    guard let end, end > start else { self = before; return false }
                    piece.mediaRate = (piece.mediaRate ?? 1) * (piece.end - piece.start) / (end - start)
                    piece.start = start; piece.end = end
                } else { piece = connectedFromOutput(piece) }
                linked.append(piece)
            }
        }
        guard linked.contains(where: { $0.link == link }) else { self = before; return false }
        audioClips.removeAll { !otherIDs.contains($0.id) }
        audioClips += linked
        audioClips.sort { $0.start < $1.start }
        guard checkInvariants() == nil else { self = before; return false }
        return true
    }

    func syncOffset(_ audio: AudioClip) -> Double? {
        guard !audio.file.hasPrefix("voice/") else { return nil }
        guard let range = outputRange(audio, connected: audio.isConnected) else {
            guard audio.link == .camera, let camera = cameraClips.first(where: { $0.start < audio.end && $0.end > audio.start }) else { return nil }
            let sample = max(audio.start, camera.start)
            let scale = clips.first(where: { $0.sourceEnd >= sample })?.timeScale ?? clips.last?.timeScale ?? 1
            let reference = camera.mediaStart + (sample - camera.start) * (camera.mediaRate ?? 1)
            let media = audio.mediaStart + (sample - audio.start) * (audio.mediaRate ?? 1)
            let rate = (camera.mediaRate ?? 1) * scale
            return rate > 0 && rate.isFinite ? (reference - media) / rate : nil
        }
        let map = TimeMap(clips)
        let link = audio.link ?? (audio.file == "mic.m4a" ? (source.hasCamera ? .camera : .screen) : audio.file == "system.m4a" ? .screen : .layer)
        var sample = range.start
        let referenceMedia: Double, referenceRate: Double
        switch link {
        case .screen:
            guard let clip = clips.first(where: { clip in
                guard !clip.isEmpty, let start = map.outputTime(atSource: clip.sourceStart) else { return false }
                return start < range.end && start + clip.outputDuration > range.start
            }), let start = map.outputTime(atSource: clip.sourceStart) else { return nil }
            sample = max(sample, start)
            referenceMedia = clip.mediaIn + (sample - start) * clip.speed; referenceRate = clip.speed
        case .camera:
            guard let camera = cameraClips.first(where: { camera in
                guard let interval = outputRange(camera, connected: false) else { return false }
                return interval.start < range.end && interval.end > range.start
            }), let interval = outputRange(camera, connected: false), let index = clipIndex(atOutput: max(sample, interval.start)) else { return nil }
            let start = interval.start
            sample = max(sample, start)
            referenceMedia = camera.mediaStart + (map.sourceTime(atOutput: sample) - camera.start) * (camera.mediaRate ?? 1)
            referenceRate = (camera.mediaRate ?? 1) * clips[index].timeScale
        case .layer:
            guard let layer = layers.first(where: { layer in
                guard layer.kind == .video, let interval = outputRange(layer, connected: true) else { return false }
                return audio.link == .layer ? layer.id == audio.layer : layer.file == audio.file && interval.start < range.end && interval.end > range.start
            }), let start = map.outputTime(atSource: layer.start) else { return nil }
            referenceMedia = layer.mediaStart + sample - start; referenceRate = 1
        }
        let media = audio.mediaStart + (audio.isConnected ? sample - range.start : map.sourceTime(atOutput: sample) - audio.start) * (audio.mediaRate ?? 1)
        guard referenceRate.isFinite, referenceRate > 0 else { return nil }
        return (referenceMedia - media) / referenceRate
    }

    mutating func moveIntoSync(_ id: UUID) {
        guard let audio = audioClips.first(where: { $0.id == id.uuidString }), let offset = syncOffset(audio),
              let range = outputRange(audio, connected: audio.isConnected) else { return }
        moveAudio(id, toStart: TimeMap(clips).sourceTime(atOutput: range.start - offset), propagate: false)
    }

    private mutating func extendAudioClock(toOutput time: Double) {
        let duration = TimeMap(clips).outputDuration
        guard time > duration, let last = clips.last else { return }
        var gap = Clip(sourceStart: last.sourceEnd, sourceEnd: last.sourceEnd + time - duration)
        gap.isGap = true
        clips.append(gap)
    }

    mutating func splitAudio(_ id: UUID, atOutput time: Double, propagate: Bool = true) -> Bool {
        guard time.isFinite, time >= 0, let audio = audioClips.first(where: { $0.id == id.uuidString }) else { return false }
        let before = self
        if audio.isConnected { extendAudioClock(toOutput: time + 0.1) }
        let changed = splitBlock(id, atSource: TimeMap(clips).sourceTime(atOutput: time), propagate: propagate)
        if !changed { self = before }
        return changed
    }

    mutating func moveAudio(_ id: UUID, toOutput time: Double, propagate: Bool = true) {
        guard time.isFinite, time >= 0, let audio = audioClips.first(where: { $0.id == id.uuidString }) else { return }
        let before = self
        if audio.isConnected { extendAudioClock(toOutput: time) }
        moveAudio(id, toStart: TimeMap(clips).sourceTime(atOutput: time), propagate: propagate)
        if audioClips.first(where: { $0.id == audio.id }) == audio { self = before }
    }

    mutating func moveAudio(_ id: UUID, toStart source: Double, propagate: Bool = true) {
        guard source.isFinite, let audio = audioClips.first(where: { $0.id == id.uuidString }),
              let range = outputRange(audio, connected: audio.isConnected), let requested = TimeMap(clips).outputTime(atSource: source) else { return }
        let neighbours = audioClips.filter { $0.track == audio.track && $0.id != audio.id }.compactMap { outputRange($0, connected: $0.isConnected) }
        let length = range.end - range.start
        let lower = neighbours.filter { $0.end <= range.start + 1e-9 }.map(\.end).max() ?? 0
        let upper = min(TimeMap(clips).outputDuration - (audio.isConnected ? 0 : length),
                        (neighbours.filter { $0.start >= range.end - 1e-9 }.map(\.start).min() ?? .infinity) - length)
        let start = min(max(requested, lower), upper)
        guard abs(start - range.start) > 1e-9 else { return }
        let before = self
        if propagate, audio.link == .screen {
            splitClip(atSource: audio.start); splitClip(atSource: audio.end)
            let indices = Set(clips.indices.filter { !clips[$0].isEmpty && clips[$0].sourceStart >= audio.start && clips[$0].sourceEnd <= audio.end })
            _ = moveClips(indices, byOutput: start - range.start)
        } else if propagate, audio.link == .camera {
            editCamera(in: audio.start...audio.end, moveBy: TimeMap(clips).sourceTime(atOutput: start) - audio.start)
        } else if propagate, audio.link == .layer, let layer = layers.first(where: { $0.id == audio.layer }),
                  let layerRange = outputRange(layer, connected: true), let layerID = UUID(uuidString: layer.id) {
            moveLayer(layerID, toStart: TimeMap(clips).sourceTime(atOutput: layerRange.start + start - range.start))
        } else if let index = audioClips.firstIndex(where: { $0.id == audio.id }) {
            var changed = audio
            changed.start = TimeMap(clips).sourceTime(atOutput: start)
            if audio.isConnected { changed.end = changed.start + length }
            else {
                changed.end = TimeMap(clips).sourceTime(atOutput: start + length)
                changed.mediaRate = (audio.end - audio.start) * (audio.mediaRate ?? 1) / (changed.end - changed.start)
            }
            audioClips[index] = changed
            audioClips.sort { $0.start < $1.start }
        }
        if checkInvariants() != nil { self = before }
    }

    mutating func resizeAudio(_ id: UUID, edge: Edge, to source: Double, mediaDuration: Double? = nil, propagate: Bool = true) {
        guard source.isFinite, let output = TimeMap(clips).outputTime(atSource: source) else { return }
        resizeAudio(id, edge: edge, toOutput: output, mediaDuration: mediaDuration, propagate: propagate)
    }

    mutating func resizeAudio(_ id: UUID, edge: Edge, toOutput requested: Double, mediaDuration: Double? = nil, propagate: Bool = true) {
        guard requested.isFinite, let audio = audioClips.first(where: { $0.id == id.uuidString }),
              let range = outputRange(audio, connected: audio.isConnected) else { return }
        let before = self
        if audio.isConnected, edge == .leading { extendAudioClock(toOutput: min(requested, range.end - 0.1)) }
        let neighbours = audioClips.filter { $0.track == audio.track && $0.id != audio.id }.compactMap { outputRange($0, connected: $0.isConnected) }
        let rate = (audio.end - audio.start) * (audio.mediaRate ?? 1) / (range.end - range.start)
        let duration = mediaDuration ?? (["mic.m4a", "system.m4a"].contains(audio.file) ? self.source.duration : .infinity)
        var changed = audio
        let target: Double
        switch edge {
        case .leading:
            let lower = max(neighbours.filter { $0.end <= range.start + 1e-9 }.map(\.end).max() ?? 0, range.start - audio.mediaStart / rate)
            target = min(max(requested, lower), range.end - 0.1, TimeMap(clips).outputDuration)
            changed.start = TimeMap(clips).sourceTime(atOutput: target)
            changed.mediaStart += audio.isConnected ? (target - range.start) * rate : (changed.start - audio.start) * (audio.mediaRate ?? 1)
            if audio.isConnected { changed.end = changed.start + range.end - target }
        case .trailing:
            let upper = min(neighbours.filter { $0.start >= range.end - 1e-9 }.map(\.start).min() ?? .infinity,
                            range.start + (duration - audio.mediaStart) / rate)
            target = max(min(requested, upper, audio.isConnected ? .infinity : TimeMap(clips).outputDuration), range.start + 0.1)
            changed.end = audio.isConnected ? changed.start + target - range.start : TimeMap(clips).sourceTime(atOutput: target)
        }
        if propagate, audio.link == .screen {
            splitClip(atSource: audio.start); splitClip(atSource: audio.end)
            let partners = clips.indices.filter { !clips[$0].isEmpty && clips[$0].sourceStart >= audio.start && clips[$0].sourceEnd <= audio.end }
            guard !partners.isEmpty else { self = before; return }
            for index in partners.reversed() {
                let clip = clips[index]
                let start = edge == .leading ? max(changed.start, clip.sourceStart == audio.start ? changed.start : clip.sourceStart) : clip.sourceStart
                let end = edge == .trailing ? min(changed.end, clip.sourceEnd == audio.end ? changed.end : clip.sourceEnd) : clip.sourceEnd
                if end <= start { liftClip(index) }
                else { _ = placeClip(index, start: start, end: end) }
            }
        } else if propagate, audio.link == .camera {
            if changed.start > audio.start { editCamera(in: audio.start...changed.start, moveBy: nil) }
            if changed.end < audio.end { editCamera(in: changed.end...audio.end, moveBy: nil) }
            if changed.start < audio.start || changed.end > audio.end {
                let partners = cameraClips.filter { $0.start < audio.end && $0.end > audio.start }
                for camera in partners {
                    guard let cameraID = UUID(uuidString: camera.id) else { continue }
                    if changed.start < audio.start, camera.start >= changed.start { resizeCamera(cameraID, edge: .leading, to: changed.start) }
                    if changed.end > audio.end, camera.end <= changed.end { resizeCamera(cameraID, edge: .trailing, to: changed.end) }
                }
            }
        } else if propagate, audio.link == .layer, let layer = layers.first(where: { $0.id == audio.layer }), let layerID = UUID(uuidString: layer.id) {
            resizeLayer(layerID, edge: edge, to: TimeMap(clips).sourceTime(atOutput: target), mediaDuration: mediaDuration)
            return
        }
        if let index = audioClips.firstIndex(where: { $0.id == audio.id }) { audioClips[index] = changed }
        audioClips.sort { $0.start < $1.start }
        if checkInvariants(mediaDurations: mediaDuration.map { [audio.file: $0] } ?? [:]) != nil { self = before }
    }

    /// Removes clip `i` entirely (its source range disappears from the output). Returns `false`
    /// if `i` is out of range or it is the last remaining clip.
    @discardableResult
    mutating func removeClip(_ i: Int, propagate: Bool = true) -> Bool {
        guard clips.indices.contains(i), clips.count > 1 else { return false }
        let before = self
        if propagate { editLinkedLayers(in: clips[i].sourceStart...clips[i].sourceEnd, moveBy: nil) }
        clips.remove(at: i)
        settleConnected()
        guard checkInvariants() == nil else { self = before; return false }
        assert(checkInvariants() == nil)
        return true
    }

    /// Drags clip `i`'s `edge` to source time `s`. Clamps so it never crosses the neighbouring
    /// clip's source boundary (never overlaps), never leaves `[0, source.duration]`, and never
    /// shrinks the clip below the minimum length.
    mutating func trimClip(_ i: Int, edge: Edge, toSource s: Double, propagate: Bool = true) {
        guard clips.indices.contains(i), s.isFinite else { return }
        let before = self
        let old = clips[i]
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
        clips[i].mediaStart = old.mediaTime(atSource: clips[i].sourceStart)
        if propagate {
            if clips[i].sourceStart > old.sourceStart { editLinkedLayers(in: old.sourceStart...clips[i].sourceStart, moveBy: nil) }
            if clips[i].sourceEnd < old.sourceEnd { editLinkedLayers(in: clips[i].sourceEnd...old.sourceEnd, moveBy: nil) }
            resizeLinkedAudio(.screen, from: old.sourceStart...old.sourceEnd, to: clips[i].sourceStart...clips[i].sourceEnd)
            if linkVideoEdits { resizeLinkedAudio(.camera, from: old.sourceStart...old.sourceEnd, to: clips[i].sourceStart...clips[i].sourceEnd) }
        }
        settleConnected()
        guard checkInvariants() == nil else { self = before; return }
        assert(checkInvariants() == nil)
    }

    /// Re-inserts the removed source range right after clip `i` (`i == -1` = the head, before
    /// the first clip). Merges into the neighbouring clip when there is only one side, or when
    /// both sides exist and their speeds match; otherwise inserts the restored range as its own
    /// clip at speed 1. No-op if there is no cut there.
    mutating func restoreCut(afterClip i: Int) {
        guard i >= -1 && i < clips.count else { return }
        defer { settleConnected(); assert(checkInvariants() == nil) }
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
    }

    private mutating func mergeContiguousVideo() {
        var i = 0
        while i + 1 < clips.count {
            let a = clips[i], b = clips[i + 1]
            if !a.isEmpty, !b.isEmpty, a.speed == b.speed, a.timeScale == b.timeScale,
               abs(a.sourceEnd - b.sourceStart) < 1e-8,
               abs(a.mediaIn + a.mediaDuration - b.mediaIn) < 1e-8,
               (a.fadeOut ?? 0) == 0, (b.fadeIn ?? 0) == 0 {
                clips[i].sourceEnd = b.sourceEnd
                clips[i].fadeOut = b.fadeOut
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
        let before = self
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
            editAudio(link: .screen, in: old.sourceStart...old.sourceStart, moveBy: 0)
            editAudio(link: .screen, in: old.sourceEnd...old.sourceEnd, moveBy: 0)
            let scale = (changed.sourceEnd - changed.sourceStart) / (old.sourceEnd - old.sourceStart)
            for index in audioClips.indices where audioClips[index].link == .screen
                && audioClips[index].start >= old.sourceStart && audioClips[index].end <= old.sourceEnd {
                audioClips[index].start = old.sourceStart + (audioClips[index].start - old.sourceStart) * scale
                audioClips[index].end = old.sourceStart + (audioClips[index].end - old.sourceStart) * scale
                audioClips[index].mediaRate = (audioClips[index].mediaRate ?? 1) / scale
            }
            audioClips.sort { $0.start < $1.start }
        }
        settleConnected()
        guard checkInvariants() == nil else { self = before; return }
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

    /// Edit ▸ Split at Pauses (T-625): splits clips at both edges of each silent SOURCE-time range
    /// (`silentRanges`, `Events.swift`). Never removes or retimes anything.
    mutating func splitAtPauses(_ ranges: [TimeRange]) {
        for range in ranges { splitClip(atSource: range.start); splitClip(atSource: range.end) }
        assert(checkInvariants() == nil)
    }

    /// Splits the clip containing SOURCE time `s` into two clips of the same speed. No-op if `s`
    /// isn't strictly inside a clip (in a gap, or within `minClipLength` of an edge/existing boundary).
    private mutating func splitClip(atSource s: Double) {
        guard let i = clips.firstIndex(where: { !$0.isEmpty && s > $0.sourceStart + Self.minClipLength && s < $0.sourceEnd - Self.minClipLength }) else { return }
        let before = self
        let clip = clips[i]
        clips[i] = Clip(sourceStart: clip.sourceStart, sourceEnd: s, speed: clip.speed)
        clips[i].mediaStart = clip.mediaStart
        clips[i].clockSpeed = clip.clockSpeed
        clips[i].fadeIn = clip.fadeIn
        var right = Clip(sourceStart: s, sourceEnd: clip.sourceEnd, speed: clip.speed)
        right.mediaStart = clip.mediaTime(atSource: s)
        right.clockSpeed = clip.clockSpeed
        right.fadeOut = clip.fadeOut
        clips.insert(right, at: i + 1)
        editLinkedLayers(in: s...s, moveBy: 0)
        settleConnected()
        if checkInvariants() != nil { self = before }
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
    func checkInvariants(mediaDurations: [String: Double] = [:]) -> String? {
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
        if let e = texts.blockInvariantError(kind: "text", duration: timelineSourceDuration) { return e }
        if let e = windowShots.blockInvariantError(kind: "window shot", duration: timelineSourceDuration) { return e }
        func mediaIsValid(file: String, start: Double, length: Double) -> Bool {
            guard start.isFinite, start >= 0, length.isFinite, length > 0 else { return false }
            let recordedDuration = ["mic.m4a", "system.m4a"].contains(file) ? source.duration : nil
            guard let duration = mediaDurations[file] ?? recordedDuration else { return true }
            return duration.isFinite && start + length <= duration + eps
        }
        func fadesAreValid(_ fadeIn: Double?, _ fadeOut: Double?) -> Bool {
            [fadeIn, fadeOut].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
        }
        for (index, track) in audioTracks.enumerated() {
            if !track.volume.isFinite || !(0...2).contains(track.volume) { return "audio track \(index) volume out of range" }
        }
        var audioEnds: [Int: Double] = [:]
        for (index, audioClip) in audioClips.enumerated() {
            guard audioTracks.indices.contains(audioClip.track) else { return "audio \(index) track out of range" }
            guard audioClip.start.isFinite, audioClip.start >= 0, audioClip.end.isFinite, audioClip.end > audioClip.start else { return "audio \(index) invalid interval" }
            let range = outputRange(audioClip, connected: audioClip.isConnected)
            if audioClip.isConnected && range == nil { return "audio \(index) invalid anchor" }
            if let range {
                guard range.end.isFinite, range.end - range.start >= 0.1 - eps else { return "audio \(index) shorter than 0.1s" }
                if let previous = audioEnds[audioClip.track], range.start < previous - eps { return "audio \(index) overlaps the previous audio clip" }
                audioEnds[audioClip.track] = range.end
            }
            if !audioClip.gain.isFinite || !(0...2).contains(audioClip.gain) { return "audio \(index) gain out of range" }
            if !fadesAreValid(audioClip.fadeIn, audioClip.fadeOut) { return "audio \(index) invalid fade" }
            let rate = audioClip.mediaRate ?? 1
            if !rate.isFinite || rate <= 0 || !mediaIsValid(file: audioClip.file, start: audioClip.mediaStart,
                                                         length: (audioClip.end - audioClip.start) * rate) {
                return "audio \(index) media range outside file"
            }
            if audioClip.link == .layer {
                guard let layer = audioClip.layer, layers.contains(where: { $0.id == layer && $0.kind == .video }) else {
                    return "audio \(index) dangling layer link"
                }
            } else if audioClip.layer != nil { return "audio \(index) layer without layer link" }
        }
        var layerEnds: [Int: Double] = [:]
        let map = TimeMap(clips)
        for (index, layer) in layers.enumerated() {
            guard layer.track >= 0 else { return "layer \(index) track out of range" }
            guard layer.start.isFinite, layer.end.isFinite, layer.end - layer.start >= 0.5 - eps,
                  let start = map.outputTime(atSource: layer.start) else { return "layer \(index) invalid interval" }
            let end = start + layer.end - layer.start
            guard end.isFinite else { return "layer \(index) invalid interval" }
            if let previous = layerEnds[layer.track], start < previous - eps { return "layer \(index) overlaps the previous layer" }
            layerEnds[layer.track] = end
            let rect = layer.rect
            if ![rect.x, rect.y, rect.w, rect.h].allSatisfy(\.isFinite) || rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0
                || rect.x + rect.w > 1 + eps || rect.y + rect.h > 1 + eps { return "layer \(index) rect outside canvas" }
            if !fadesAreValid(layer.fadeIn, layer.fadeOut) { return "layer \(index) invalid fade" }
            if layer.kind == .video && !mediaIsValid(file: layer.file, start: layer.mediaStart, length: layer.end - layer.start) {
                return "layer \(index) media range outside file"
            }
        }
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

private func applyLinkedEdit<Block: TimedBlock>(_ blocks: inout [Block], in range: ClosedRange<Double>, moveBy delta: Double?, overwrite: Bool = true) {
    let epsilon = 1e-9
    func slice(_ block: Block, _ start: Double, _ end: Double, newID: Bool) -> Block {
        var part = block
        part.advanceMedia(by: start - block.start)
        part.start = start; part.end = end
        if newID { part.id = UUID().uuidString }
        return part
    }
    var stationary: [Block] = [], moved: [Block] = []
    for block in blocks {
        let lower = max(block.start, range.lowerBound), upper = min(block.end, range.upperBound)
        guard lower <= upper + epsilon, block.end > range.lowerBound + epsilon, block.start < range.upperBound - epsilon else {
            stationary.append(block); continue
        }
        if block.start < lower - epsilon { stationary.append(slice(block, block.start, lower, newID: false)) }
        if upper < block.end - epsilon {
            stationary.append(slice(block, upper, block.end, newID: block.start < lower - epsilon || (upper > lower + epsilon && delta != nil)))
        }
        if upper > lower + epsilon, let delta {
            var part = slice(block, lower, upper, newID: block.start < lower - epsilon)
            part.start += delta; part.end += delta
            moved.append(part)
        }
    }
    for part in moved where overwrite && delta != 0 {
        stationary = stationary.flatMap { block -> [Block] in
            guard block.start < part.end - epsilon, block.end > part.start + epsilon else { return [block] }
            var pieces: [Block] = []
            if block.start < part.start - epsilon { pieces.append(slice(block, block.start, part.start, newID: false)) }
            if block.end > part.end + epsilon { pieces.append(slice(block, part.end, block.end, newID: block.start < part.start - epsilon)) }
            return pieces
        }
    }
    blocks = (stationary + moved).sorted { $0.start < $1.start }
}
extension Zoom: TimedBlock {}
extension Layout: TimedBlock {
    mutating func advanceMedia(by delta: Double) { if keys != nil { mediaStart = (mediaStart ?? start) + delta * (mediaRate ?? 1) } }
}
extension CameraClip: TimedBlock {
    mutating func advanceMedia(by delta: Double) { mediaStart += delta * (mediaRate ?? 1) }
}
extension AudioClip: TimedBlock {
    mutating func advanceMedia(by delta: Double) { mediaStart += delta * (mediaRate ?? 1) }
    fileprivate var isConnected: Bool { link != .screen && link != .camera }
}
extension LayerBlock: TimedBlock {
    mutating func advanceMedia(by delta: Double) { if kind == .video { mediaStart += delta } }
}
extension Mask: TimedBlock {}
extension TextBlock: TimedBlock {
    mutating func advanceMedia(by delta: Double) { if words != nil { words = words!.map { Word(text: $0.text, start: $0.start - delta, end: $0.end - delta) } } }
}
extension WindowShot: TimedBlock {}

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

    // MARK: - Window shots (SPEC "Windows as layers")

    /// Adds a shot of window `window` into the free gap containing source time `s`.
    @discardableResult
    mutating func addWindowShot(atSource s: Double, length: Double = 3, window: Int) -> UUID? {
        addBlock(atSource: s, length: length, in: \.windowShots) { id, start, end in WindowShot(id: id, start: start, end: end, window: window) }
    }
    mutating func moveWindowShot(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.windowShots, toStart: s) }
    mutating func resizeWindowShot(_ id: UUID, edge: Edge, to s: Double) { resizeBlock(id, in: \.windowShots, edge: edge, to: s) }
    func previewWindowShotPlacement(atSource s: Double, length: Double = 3) -> (start: Double, end: Double)? {
        var trial = self
        guard let id = trial.addWindowShot(atSource: s, length: length, window: 0),
              let shot = trial.windowShots.first(where: { $0.id == id.uuidString }) else { return nil }
        return (shot.start, shot.end)
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

    // MARK: - Text

    /// Replaces every Caption-style block with `captions`; a new caption that would overlap a surviving block or leave
    /// `[0, duration]` is dropped (ponytail: drop rather than trim).
    mutating func replaceCaptions(_ captions: [TextBlock]) {
        texts.removeAll { $0.style == .caption }
        for c in captions where c.end <= timelineSourceDuration + 1e-9 && !texts.contains(where: { c.start < $0.end && c.end > $0.start }) {
            texts.append(c)
        }
        texts.sort { $0.start < $1.start }
        assert(checkInvariants() == nil)
    }

    @discardableResult
    mutating func addText(atSource s: Double, length: Double = 3, style: TextBlock.Style = .title, text: String = "Text") -> UUID? {
        addBlock(atSource: s, length: length, in: \.texts) { id, start, end in TextBlock(id: id, start: start, end: end, text: text, style: style) }
    }
    mutating func moveText(_ id: UUID, toStart s: Double) { moveBlock(id, in: \.texts, toStart: s) }
    mutating func resizeText(_ id: UUID, edge: Edge, to s: Double) { resizeBlock(id, in: \.texts, edge: edge, to: s) }

    /// Removes the zoom, layout, mask or text block with `id`, whichever track it's in.
    mutating func removeBlock(_ id: UUID, propagate: Bool = true) {
        let key = id.uuidString
        let before = self
        if let audio = audioClips.first(where: { $0.id == key }) {
            if propagate, audio.link == .screen {
                splitClip(atSource: audio.start); splitClip(atSource: audio.end)
                deleteClips(Set(clips.indices.filter { !clips[$0].isEmpty && clips[$0].sourceStart >= audio.start && clips[$0].sourceEnd <= audio.end }))
            } else if propagate, audio.link == .camera { editCamera(in: audio.start...audio.end, moveBy: nil) }
            else if propagate, audio.link == .layer, let layer = layers.first(where: { $0.id == audio.layer }),
                    let range = outputRange(audio, connected: true) {
                editLayer(layer, in: range.start...range.end, moveBy: nil, propagate: true)
            } else { audioClips.removeAll { $0.id == key } }
            if audioClips.contains(where: { $0.id == key }) || checkInvariants() != nil { self = before }
            return
        }
        if let layer = layers.first(where: { $0.id == key }), let range = outputRange(layer, connected: true) {
            editLayer(layer, in: range.start...range.end, moveBy: nil, propagate: propagate)
            if checkInvariants() != nil { self = before }
            return
        }
        if let camera = cameraClips.first(where: { $0.id == key }), propagate {
            editCamera(in: camera.start...camera.end, moveBy: nil)
            if checkInvariants() != nil { self = before }
            return
        }
        if !keystrokeClips.removeBlock(id: key), !cameraClips.removeBlock(id: key), !zooms.removeBlock(id: key), !layouts.removeBlock(id: key), !masks.removeBlock(id: key) {
            if !texts.removeBlock(id: key) { windowShots.removeBlock(id: key) }
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
        } else if let text = texts.first(where: { $0.id == key }) {
            guard texts.addBlock(atSource: text.end, length: text.end - text.start, duration: timelineSourceDuration, minLength: Self.minBlockLength, make: { start, end in
                var copy = text; copy.id = newID.uuidString; copy.start = start; copy.end = end; return copy
            }) != nil else { return nil }
        } else {
            return nil
        }
        assert(checkInvariants() == nil)
        return newID
    }

    /// T-632 "Highlight this zoom": a highlight mask over the zoom's target rect (`1/scale` of the frame
    /// around `center`, kept inside it) with the zoom's timing. `nil` if `id` isn't a zoom or a mask already sits there.
    @discardableResult
    mutating func highlightZoom(_ id: UUID) -> UUID? {
        guard let zoom = zooms.first(where: { $0.id == id.uuidString }) else { return nil }
        let size = 1 / max(zoom.scale, 1)
        let rect = NormRect(x: min(max(zoom.center.x - size / 2, 0), 1 - size), y: min(max(zoom.center.y - size / 2, 0), 1 - size), w: size, h: size)
        let newID = UUID()
        guard masks.addBlock(atSource: zoom.start, length: zoom.end - zoom.start, duration: timelineSourceDuration, minLength: Self.minBlockLength, make: { start, end in
            Mask(id: newID.uuidString, start: start, end: end, kind: .highlight, rect: rect, opacity: 0.6)
        }) != nil else { return nil }
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
