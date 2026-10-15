import Foundation

/// One row of `events.json` (SPEC §4.8, §5): mouse/click/key/cursor activity in normalised
/// source coordinates, timestamped in the same "seconds since first screen frame" clock as the
/// media files. Optional fields are only present for the `Kind`s that use them.
public struct InputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, down, up, drag, scroll, key, typing, cursor }
    public var t: Double
    public var k: Kind
    public var x: Double?      // normalised 0…1, top-left origin
    public var y: Double?
    public var b: Int?         // button
    public var keyCode: Int?   // only for k == .key
    public var mods: UInt?     // only for k == .key
    public var id: String?     // cursor image hash for k == .cursor

    public init(t: Double, k: Kind, x: Double? = nil, y: Double? = nil, b: Int? = nil,
                keyCode: Int? = nil, mods: UInt? = nil, id: String? = nil) {
        self.t = t; self.k = k; self.x = x; self.y = y; self.b = b
        self.keyCode = keyCode; self.mods = mods; self.id = id
    }
}

public struct EventLog: Codable, Sendable {
    public var events: [InputEvent]
    public init(events: [InputEvent] = []) { self.events = events }

    /// Pointer motion, including drags (a drag is a move with a button held).
    public func moves() -> [InputEvent] { events.filter { $0.k == .move || $0.k == .drag } }
    /// Left-button presses.
    public func clicks() -> [InputEvent] { events.filter { $0.k == .down && $0.b == 0 } }
}

/// SPEC "Edit ▸ Speed Up Typing": runs of `.typing` events with a gap < 1 s between consecutive
/// events, kept only where the run spans > 3 s. `Edit ▸ Speed Up Typing` splits clips around these
/// ranges and sets them to 2x (not here).
public func typingRanges(events: [InputEvent]) -> [TimeRange] {
    let typing = events.filter { $0.k == .typing }.sorted { $0.t < $1.t }

    var ranges: [TimeRange] = []
    var runStart: Double?
    var runEnd: Double?
    for event in typing {
        if let end = runEnd, event.t - end < 1.0 {
            runEnd = event.t
        } else {
            if let start = runStart, let end = runEnd, end - start > 3.0 { ranges.append(TimeRange(start: start, end: end)) }
            runStart = event.t
            runEnd = event.t
        }
    }
    if let start = runStart, let end = runEnd, end - start > 3.0 { ranges.append(TimeRange(start: start, end: end)) }
    return ranges
}

/// SPEC "Voice": runs of `levels` (peaks, `perSecond` per second) below `threshold` lasting at least
/// `minDuration`, each shrunk by `pad` on both edges so cuts never clip a word. Mic time == source time.
public func silentRanges(levels: [Float], perSecond: Double, threshold: Float = 0.02, minDuration: Double = 0.6, pad: Double = 0.15) -> [TimeRange] {
    var ranges: [TimeRange] = []
    var runStart: Int?
    for i in 0...levels.count {
        if i < levels.count, levels[i] < threshold { runStart = runStart ?? i; continue }
        guard let s = runStart else { continue }
        runStart = nil
        let (a, b) = (Double(s) / perSecond, Double(i) / perSecond)
        if b - a >= minDuration, b - a > 2 * pad { ranges.append(TimeRange(start: a + pad, end: b - pad)) }
    }
    return ranges
}
