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
