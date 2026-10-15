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

/// Multi-window recordings (SPEC "Windows as layers"): window `i`'s frame in global screen points
/// (top-left origin) from time `t` on. Samples are written only when a frame changes.
public struct WindowFrame: Codable, Equatable, Sendable {
    public var t: Double
    public var i: Int
    public var x, y, w, h: Double
    public init(t: Double, i: Int, x: Double, y: Double, w: Double, h: Double) {
        self.t = t; self.i = i; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct EventLog: Codable, Sendable {
    public var events: [InputEvent]
    /// Non-nil only for multi-window recordings, whose pointer events then carry *global points*
    /// instead of 0…1 values (normalised per visible window at render time).
    public var windowFrames: [WindowFrame]?
    public init(events: [InputEvent] = [], windowFrames: [WindowFrame]? = nil) { self.events = events; self.windowFrames = windowFrames }

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
