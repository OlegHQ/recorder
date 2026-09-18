import Testing
@testable import RecorderCore

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
    // 5-line LCG (deterministic, no Foundation randomness) for a reproducible property test.
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            return state
        }
    }
    var rng = LCG(state: 1)
    var p = Project(source: Source(duration: 60), clips: [Clip(sourceStart: 0, sourceEnd: 60, speed: 1)])

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
