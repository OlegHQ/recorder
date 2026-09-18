import Foundation
import Testing
@testable import RecorderCore

private func click(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
    InputEvent(t: t, k: .down, x: x, y: y, b: 0)
}

/// Zoom equality without `id` (fresh per call) for comparing generated zooms.
private func stripID(_ z: Zoom) -> Zoom {
    var z = z
    z.id = "x"
    return z
}

@Test func clusterByTimeAndDistance() {
    // Close in both time (< 3 s) and distance (< 0.25) -> one cluster -> one zoom spanning
    // first click - 0.4 s to last click + 1.5 s (clamped to 0 at the low end).
    let together = generateAutoZooms(clicks: [click(0, 0.1, 0.1), click(1.0, 0.15, 0.12)], duration: 20)
    #expect(together.map(stripID) == [Zoom(start: 0, end: 2.5, scale: 2.0, mode: .auto)].map(stripID))

    // Same time gap, but far apart in space (>= 0.25) -> two clusters. The clicks are spaced
    // 2.95 s apart so the two raw zoom windows are still >= 1.0 s apart and rule 4 won't re-merge
    // them, isolating the clustering decision.
    let farApart = generateAutoZooms(clicks: [click(0, 0.1, 0.1), click(2.95, 0.9, 0.9)], duration: 20)
    #expect(farApart.map(stripID) == [
        Zoom(start: 0, end: 1.5, scale: 2.0, mode: .auto),
        Zoom(start: 2.95 - 0.4, end: 2.95 + 1.5, scale: 2.0, mode: .auto),
    ].map(stripID))

    // Close in space, but 3 s apart (the "< 3 s" boundary is exclusive) -> two clusters.
    let farInTime = generateAutoZooms(clicks: [click(0, 0.1, 0.1), click(3.0, 0.12, 0.11)], duration: 20)
    #expect(farInTime.map(stripID) == [
        Zoom(start: 0, end: 1.5, scale: 2.0, mode: .auto),
        Zoom(start: 2.6, end: 4.5, scale: 2.0, mode: .auto),
    ].map(stripID))
}

@Test func mergeCloseZooms() {
    // Two separate clusters (far apart in space, so distance forces a split despite the 2.5 s
    // time gap) whose raw zoom windows end up < 1.0 s apart -> merged into one zoom.
    let merged = generateAutoZooms(clicks: [click(0, 0.1, 0.1), click(2.5, 0.9, 0.9)], duration: 10)
    #expect(merged.map(stripID) == [Zoom(start: 0, end: 4.0, scale: 2.0, mode: .auto)].map(stripID))

    // Same shape, but spaced further apart so the raw gap is >= 1.0 s -> stays as two zooms.
    let unmerged = generateAutoZooms(clicks: [click(0, 0.1, 0.1), click(5.0, 0.9, 0.9)], duration: 10)
    #expect(unmerged.map(stripID) == [
        Zoom(start: 0, end: 1.5, scale: 2.0, mode: .auto),
        Zoom(start: 4.6, end: 6.5, scale: 2.0, mode: .auto),
    ].map(stripID))
}

@Test func dropShortAndClamp() {
    // A click near the very end of the recording: its zoom window overshoots `duration` and,
    // once clamped, is left shorter than 1.0 s -> dropped entirely.
    let dropped = generateAutoZooms(clicks: [click(4.6, 0.5, 0.5)], duration: 5.0)
    #expect(dropped.isEmpty)

    // A click near the very start: its window goes negative but clamping to 0 still leaves
    // >= 1.0 s -> kept, clamped.
    let clamped = generateAutoZooms(clicks: [click(0.1, 0.5, 0.5)], duration: 10.0)
    #expect(clamped.map(stripID) == [Zoom(start: 0, end: 1.6, scale: 2.0, mode: .auto)].map(stripID))
}

@Test func outputSortedNonOverlappingDeterministic() {
    // Three well-separated clusters, given out of chronological order.
    let clicks = [
        click(8.3, 0.92, 0.88),
        click(0.2, 0.10, 0.10),
        click(20.0, 0.50, 0.50),
        click(8.0, 0.90, 0.90),
        click(0.5, 0.12, 0.11),
    ]
    let a = generateAutoZooms(clicks: clicks, duration: 30)
    let b = generateAutoZooms(clicks: clicks, duration: 30)

    let expected = [
        Zoom(start: 0, end: 2.0, scale: 2.0, mode: .auto),
        Zoom(start: 7.6, end: 9.8, scale: 2.0, mode: .auto),
        Zoom(start: 19.6, end: 21.5, scale: 2.0, mode: .auto),
    ]
    let expectedStripped = expected.map(stripID)
    #expect(a.map(stripID) == expectedStripped)
    #expect(b.map(stripID) == expectedStripped)

    // Sorted by start, and no overlaps.
    #expect(a == a.sorted { $0.start < $1.start })
    for i in 1..<a.count { #expect(a[i].start >= a[i - 1].end) }

    // Deterministic: identical apart from (fresh) ids.
    #expect(a.map(stripID) == b.map(stripID))
}
