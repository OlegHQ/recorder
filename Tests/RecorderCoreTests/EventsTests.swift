import Foundation
import Testing
@testable import RecorderCore

private func typing(_ t: Double) -> InputEvent { InputEvent(t: t, k: .typing) }

@Test func typingRunOverThresholdKept() {
    // Events 0.5 s apart (< 1 s gap) spanning 4 s total (> 3 s) -> one range.
    let events = stride(from: 0.0, through: 4.0, by: 0.5).map(typing)
    #expect(typingRanges(events: events) == [TimeRange(start: 0, end: 4.0)])
}

@Test func shortRunDropped() {
    // Consecutive gaps of 0.9 s (< 1 s, so it's one run), but the run only spans 1.8 s (<= 3 s) -> dropped.
    let events = [typing(0), typing(0.9), typing(1.8)]
    #expect(typingRanges(events: events).isEmpty)

    // Boundary: a run spanning exactly 3.0 s is not "> 3 s" -> also dropped.
    let exactly3 = [typing(0), typing(0.9), typing(1.8), typing(3.0)]
    #expect(typingRanges(events: exactly3).isEmpty)
}

@Test func gapAtOrAboveOneSecondSplitsRuns() {
    // First run: 0, 0.9, 1.8, 2.7, 3.5 - internal gaps < 1 s, spans 3.5 s (> 3 s) -> kept.
    // Gap to the next event is exactly 1.0 s ("< 1 s" is exclusive) -> starts a new run.
    // Second run: 4.5, 5.4, 6.3, 7.2, 8.0 - internal gaps < 1 s, spans 3.5 s (> 3 s) -> kept.
    let events = [typing(0), typing(0.9), typing(1.8), typing(2.7), typing(3.5),
                  typing(4.5), typing(5.4), typing(6.3), typing(7.2), typing(8.0)]
    #expect(typingRanges(events: events) == [
        TimeRange(start: 0, end: 3.5),
        TimeRange(start: 4.5, end: 8.0),
    ])
}

@Test func nonTypingEventsIgnoredAndInputNeedNotBeSorted() {
    let events = [
        InputEvent(t: 10, k: .move, x: 0.1, y: 0.1),
        typing(3.6),
        typing(0.0),
        InputEvent(t: 2.0, k: .key, keyCode: 36),
        typing(1.8),
        typing(0.9),
        typing(2.7),
    ]
    // Sorted typing events: 0.0, 0.9, 1.8, 2.7, 3.6 - gaps of 0.9 s (< 1 s) -> one run spanning 3.6 s (> 3 s).
    #expect(typingRanges(events: events) == [TimeRange(start: 0, end: 3.6)])
}

@Test func noTypingEventsIsEmpty() {
    #expect(typingRanges(events: []).isEmpty)
    #expect(typingRanges(events: [InputEvent(t: 0, k: .move, x: 0, y: 0)]).isEmpty)
}
