import Foundation

/// Smallest circular corner mask that excludes the native window's transparent corner pixels.
/// Returns pixels, independent of window size, display scale, or application identity.
public func detectedWindowCornerRadius(width: Int, height: Int,
                                       alpha: (Int, Int) -> UInt8) -> Double? {
    guard width > 1, height > 1, alpha(width / 2, 0) >= 128,
          alpha(0, height / 2) >= 128, alpha(width - 1, height / 2) >= 128,
          alpha(width / 2, height - 1) >= 128 else { return nil }
    let limit = min(width, height) / 2
    var radius = 0.0
    // ponytail: the renderer has one circular radius. Enclose all four native corners;
    // per-corner masks would preserve asymmetric or non-circular edges without a small trim.
    for right in [false, true] {
        for bottom in [false, true] {
            for y in 0..<limit {
                let py = bottom ? height - 1 - y : y
                if alpha(right ? width - 1 : 0, py) >= 128 { break }
                for x in 0..<limit {
                    if alpha(right ? width - 1 - x : x, py) >= 128 { break }
                    // Invert (r-x)^2 + (r-y)^2 = r^2, using pixel centres.
                    let dx = Double(x) + 0.5, dy = Double(y) + 0.5
                    radius = max(radius, dx + dy + sqrt(2 * dx * dy))
                }
            }
        }
    }
    // One pixel of clearance hides the flattened antialiasing fringe and chroma bleed.
    return min(Double(limit), radius > 0 ? radius + 1 : 0)
}
