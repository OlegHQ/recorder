import Testing
@testable import RecorderCore
import Foundation

/// 5-line LCG (deterministic, no Foundation randomness) for reproducible property tests.
/// Shared by `randomOpsKeepInvariants` and `zoomsNeverOverlap`.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }
}

@Test func splitProducesTwoClipsSameSpeed() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 2)])
    let ok = p.split(atOutput: 2)
    #expect(ok)
    #expect(p.clips.count == 2)
    #expect(p.clips[0].sourceStart == 0)
    #expect(p.clips[0].sourceEnd == 4)   // 2 output seconds at 2x = 4 source seconds
    #expect(p.clips[0].speed == 2)
    #expect(p.clips[1].sourceStart == 4)
    #expect(p.clips[1].sourceEnd == 10)
    #expect(p.clips[1].speed == 2)
    #expect(p.checkInvariants() == nil)
}

@Test func splitNearEdgeRefused() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
    let leadOk = p.split(atOutput: 0.01)     // within 2 frames (1/30 s) of the leading edge at 60fps
    let trailOk = p.split(atOutput: 9.99)    // within 2 frames of the trailing edge
    #expect(!leadOk)
    #expect(!trailOk)
    #expect(p.clips.count == 1)
}

@Test func removeLastClipRefused() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
    let ok = p.removeClip(0)
    #expect(!ok)
    #expect(p.clips.count == 1)
}

@Test func trimClampsToNeighbour() {
    var p = Project(source: Source(duration: 10), clips: [
        Clip(sourceStart: 0, sourceEnd: 5, speed: 1),
        Clip(sourceStart: 6, sourceEnd: 10, speed: 1),
    ])
    // Extending clip 1's leading edge past clip 0's trailing edge clamps to it.
    p.trimClip(1, edge: .leading, toSource: 0)
    #expect(p.clips[1].sourceStart == 5)
    // Extending clip 0's trailing edge past clip 1's leading edge clamps to it.
    p.trimClip(0, edge: .trailing, toSource: 100)
    #expect(p.clips[0].sourceEnd == 5)
    // Shrinking below the minimum clip length clamps to it instead.
    p.trimClip(0, edge: .leading, toSource: 4.99)
    #expect(p.clips[0].sourceStart == 4.9)
    #expect(p.checkInvariants() == nil)
}

@Test func splitRemoveRestoreIsIdentity() {
    let original = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)])
    var p = original
    let splitOk = p.split(atOutput: 8)
    #expect(splitOk)
    #expect(p.clips.count == 2)
    let removeOk = p.removeClip(1)
    #expect(removeOk)
    #expect(p.clips.count == 1)
    p.restoreCut(afterClip: 0)
    #expect(p == original)
}

@Test func randomOpsKeepInvariants() {
    var rng = LCG(state: 1)
    var p = Project(source: Source(duration: 60), clips: [Clip(sourceStart: 0, sourceEnd: 60, speed: 1)])

    p.linkVideoEdits = true
    for _ in 0..<1000 {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0:
            p.split(atOutput: Double.random(in: 0...60, using: &rng))
        case 1:
            p.removeClip(Int.random(in: 0..<p.clips.count, using: &rng))
        case 2:
            let edge: Edge = Bool.random(using: &rng) ? .leading : .trailing
            p.trimClip(Int.random(in: 0..<p.clips.count, using: &rng), edge: edge,
                       toSource: Double.random(in: 0...60, using: &rng))
        case 3:
            p.restoreCut(afterClip: Int.random(in: -1..<p.clips.count, using: &rng))
        case 4:
            p.restoreAllCuts()
        default:
            p.setSpeed(Int.random(in: 0..<p.clips.count, using: &rng), Double.random(in: 0...20, using: &rng))
        }
        #expect(p.checkInvariants() == nil)
    }
}

@Test func zoomsNeverOverlap() {
    var rng = LCG(state: 2)
    var p = Project(source: Source(duration: 60), clips: [Clip(sourceStart: 0, sourceEnd: 60, speed: 1)])
    // Seed a handful of non-overlapping zooms spread across the source.
    for start in stride(from: 0.0, to: 60, by: 10) {
        #expect(p.addZoom(atSource: start + 1, length: 3, mode: .manual) != nil)
    }
    #expect(p.zooms.count == 6)

    for _ in 0..<1000 {
        guard let target = p.zooms.randomElement(using: &rng), let id = UUID(uuidString: target.id) else { continue }
        if Bool.random(using: &rng) {
            p.moveZoom(id, toStart: Double.random(in: -10...70, using: &rng))
        } else {
            let edge: Edge = Bool.random(using: &rng) ? .leading : .trailing
            p.resizeZoom(id, edge: edge, to: Double.random(in: -10...70, using: &rng))
        }
        #expect(p.checkInvariants() == nil)
    }
}

@Test func addZoomFitsGap() {
    var p = Project(source: Source(duration: 10), clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])

    // Empty lane: the whole [0, duration] is free; the block starts at s.
    let id1 = p.addZoom(atSource: 5, length: 3, mode: .manual)
    #expect(id1 != nil)
    #expect(p.zooms.count == 1)
    #expect(p.zooms[0].start == 5)
    #expect(p.zooms[0].end == 8)

    // Only [0, 5) is free now; a request longer than the gap clamps to it.
    let id2 = p.addZoom(atSource: 1, length: 10, mode: .manual)
    #expect(id2 != nil)
    let z2 = p.zooms.first { $0.id == id2!.uuidString }
    #expect(z2?.start == 0)
    #expect(z2?.end == 5)
    #expect(p.checkInvariants() == nil)

    // A gap under the minimum block length (0.5 s) refuses the add.
    p.zooms = [Zoom(id: UUID().uuidString, start: 0, end: 9.8)]
    let id3 = p.addZoom(atSource: 9.9, length: 1, mode: .manual)
    #expect(id3 == nil)
    #expect(p.zooms.count == 1)

    // Clicking inside an existing block (not a gap) also refuses.
    let id4 = p.addZoom(atSource: 5, length: 1, mode: .manual)
    #expect(id4 == nil)
    #expect(p.zooms.count == 1)
}

@Test func speedUpTypingKeepsInvariants() {
    // One 20 s clip; a typing range in the middle (5...9) gets split out and doubled, a range that
    // already sits exactly on a clip boundary (12...16, after a manual pre-cut) doesn't need a split
    // on that edge, and a range that only partly survives an earlier cut (18...25, but the source
    // only runs to 20) still speeds up whatever clip remains inside it.
    var p = Project(source: Source(duration: 20), clips: [
        Clip(sourceStart: 0, sourceEnd: 12, speed: 1),
        Clip(sourceStart: 12, sourceEnd: 20, speed: 1),
    ])
    p.linkVideoEdits = true
    p.speedUpTyping([TimeRange(start: 5, end: 9), TimeRange(start: 12, end: 16), TimeRange(start: 18, end: 25)])

    #expect(p.checkInvariants() == nil)
    // The 5...9 range became its own clip at 2×.
    guard let sped1 = p.clips.first(where: { $0.sourceStart == 5 && $0.sourceEnd == 9 }) else {
        #expect(Bool(false), "expected a 5...9 clip, got \(p.clips)")
        return
    }
    #expect(sped1.speed == 2)
    // The clips right before/after it are untouched (still 1×).
    #expect(p.clips.first(where: { $0.sourceStart == 0 && $0.sourceEnd == 5 })?.speed == 1)
    #expect(p.clips.first(where: { $0.sourceStart == 9 && $0.sourceEnd == 12 })?.speed == 1)
    // 12...16 already started exactly on a clip boundary; only the trailing edge needed a split.
    guard let sped2 = p.clips.first(where: { $0.sourceStart == 12 && $0.sourceEnd == 16 }) else {
        #expect(Bool(false), "expected a 12...16 clip, got \(p.clips)")
        return
    }
    #expect(sped2.speed == 2)
    // 18...25 is clamped by the source's own 20 s duration; the remaining 18...20 clip still speeds up.
    guard let sped3 = p.clips.first(where: { $0.sourceStart == 18 && $0.sourceEnd == 20 }) else {
        #expect(Bool(false), "expected an 18...20 clip, got \(p.clips)")
        return
    }
    #expect(sped3.speed == 2)
}

@Test func snapPicksNearest() {
    let candidates = [1.0, 5.0, 5.4, 9.0]

    let hit = snap(5.3, candidates: candidates, threshold: 0.5)
    #expect(hit.snapped)
    #expect(hit.value == 5.4)   // nearer than 5.0 (0.1 vs 0.3 away)

    let tooFar = snap(5.3, candidates: candidates, threshold: 0.05)
    #expect(!tooFar.snapped)
    #expect(tooFar.value == 5.3)

    let exact = snap(9.0, candidates: candidates, threshold: 0.5)
    #expect(exact.snapped)
    #expect(exact.value == 9.0)
}
