/// ponytail: only `ViewTransform` for now — `CameraPath` itself is T-412 (another lane is writing
/// the fuller file; this stub exists so `FrameState` (T-304) can reference the type). SPEC §6.3.
public struct ViewTransform: Sendable, Equatable { public var cx, cy, scale: Double; public static let identity = ViewTransform(cx: 0.5, cy: 0.5, scale: 1) }
