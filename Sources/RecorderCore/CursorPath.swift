/// ponytail: only `CursorSample` for now — `CursorPath` itself is T-411 (another lane is writing
/// the fuller file; this stub exists so `FrameState` (T-304) can reference the type). SPEC §6.5.
public struct CursorSample: Sendable { public var x, y, prevX, prevY: Double; public var imageID: String?; public var alpha, rotation, clickScale: Double }
