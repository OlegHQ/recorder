import CoreGraphics

/// Pure layout math for the render pipeline (SPEC §6.2 pass 2). No AppKit/AVFoundation/Metal —
/// just the rect the "screen" quad occupies inside the output frame.
/// (A free function, not a `Layout` type: `Project.swift` already has a `Layout` struct for
/// camera-layout timeline blocks.)
public func screenRect(output: CGSize, cropAspect: Double, padding: Double) -> CGRect {
    let inset = padding * min(output.width, output.height)
    let available = CGSize(width: max(0, output.width - 2 * inset), height: max(0, output.height - 2 * inset))
    var w = available.width
    var h = cropAspect > 0 ? w / cropAspect : available.height
    if h > available.height {
        h = available.height
        w = h * cropAspect
    }
    let x = (output.width - w) / 2
    let y = (output.height - h) / 2
    return CGRect(x: x, y: y, width: w, height: h)
}
