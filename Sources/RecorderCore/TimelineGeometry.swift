import Foundation

/// Output-time ↔ x-coordinate mapping for `TimelineView`, plus the adaptive ruler tick spacing.
/// Pure geometry, no AppKit — the x-axis is *output* time (SPEC §7, §7.1). `TimelineView` owns one
/// of these and mutates it in response to scroll/pinch/fit gestures.
public struct TimelineGeometry: Sendable {
    public var pxPerSecond: Double
    public var scrollX: Double   // content x (in points, at pxPerSecond) currently at the view's left edge
    public var width: Double     // visible width in points

    public init(pxPerSecond: Double = 60, scrollX: Double = 0, width: Double = 0) {
        self.pxPerSecond = pxPerSecond; self.scrollX = scrollX; self.width = width
    }

    /// View-local x for output time `t`.
    public func x(forOutput t: Double) -> Double { t * pxPerSecond - scrollX }

    /// Output time under view-local x.
    public func output(forX x: Double) -> Double { (x + scrollX) / pxPerSecond }

    /// Scales `pxPerSecond` by `factor`, keeping the output time under `anchorX` fixed on screen
    /// (AC-TL-4). Clamped to `[minPxPerSecond, maxPxPerSecond]`.
    public mutating func zoom(by factor: Double, anchorX: Double, minPxPerSecond: Double, maxPxPerSecond: Double) {
        let anchorTime = output(forX: anchorX)
        pxPerSecond = min(max(pxPerSecond * factor, minPxPerSecond), maxPxPerSecond)
        scrollX = anchorTime * pxPerSecond - anchorX
    }

    /// Adaptive tick spacing (seconds) so labels land >= 70 pt apart at the current zoom.
    public func tickInterval() -> Double {
        let steps: [Double] = [1.0 / 60, 1.0 / 10, 0.5, 1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600]
        let minPx = 70.0
        for step in steps where step * pxPerSecond >= minPx { return step }
        return steps.last!
    }
}
