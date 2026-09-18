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

/// The output canvas size for `project.output.aspect` (SPEC §5, §6.1 `Auto ▾` popup):
/// `.auto` keeps the (cropped) source's own aspect; any fixed ratio ignores the source and uses
/// that ratio instead — `screenRect` then letterboxes the source inside it. `longEdge` sets the
/// larger dimension; both dimensions are even (video encoders require it, SPEC §6.8).
public func outputSize(aspect: Output.Aspect, croppedSource: CGSize, longEdge: Int) -> CGSize {
    let ratio: Double
    switch aspect {
    case .auto: ratio = croppedSource.height > 0 ? croppedSource.width / croppedSource.height : 1
    case .r16x9: ratio = 16.0 / 9.0
    case .r9x16: ratio = 9.0 / 16.0
    case .r1x1: ratio = 1.0
    case .r4x3: ratio = 4.0 / 3.0
    case .r16x10: ratio = 16.0 / 10.0
    }
    let long = Double(longEdge)
    let (w, h) = ratio >= 1 ? (long, long / ratio) : (long * ratio, long)
    func evenRound(_ v: Double) -> Double { 2 * (v / 2).rounded() }
    return CGSize(width: evenRound(w), height: evenRound(h))
}
