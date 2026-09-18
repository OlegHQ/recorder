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

/// Zoom moves the whole framed screen, not just the pixels inside a fixed frame: `base` (the un-zoomed
/// `screenRect`) grown by `view.scale` and placed so the viewport `view` looks at lands exactly on
/// `base`. Mid-content the frame overflows the canvas (content fills it, background gone); with the
/// viewport clamped to a content edge (`CameraPath`) that edge sits on `base`'s, so padding returns.
public func zoomedScreenRect(base: CGRect, view: ViewTransform) -> CGRect {
    let w = base.width * view.scale, h = base.height * view.scale
    return CGRect(x: base.midX - view.cx * w, y: base.midY - view.cy * h, width: w, height: h)
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

/// SPEC §7.1 layout lane, §6.6 Camera/layout: the active `Project.Layout` block at source time `t`
/// and its 0…1 blend amount, cross-fading over `fade` seconds at each block edge (gaps between
/// blocks = the default layout, i.e. `nil`/`0`). `Spring.focused.value(at:)` shapes the ramp,
/// normalised over the fade window so it lands exactly on 0 at the edge and 1 once `fade` seconds
/// in. For blocks shorter than `2 · fade` the in/out ramps overlap (`min`), so the amount never
/// reaches 1 but stays continuous and symmetric. Pure lookup: the result doesn't depend on
/// `layouts`' array order.
public func layoutMix(layouts: [Layout], atSource t: Double, fade: Double = 0.3) -> (kind: Layout.Kind?, amount: Double) {
    guard let active = layouts.first(where: { t >= $0.start && t <= $0.end }) else { return (nil, 0) }
    let rampIn = layoutFadeRamp(t - active.start, fade: fade)
    let rampOut = layoutFadeRamp(active.end - t, fade: fade)
    return (active.kind, min(rampIn, rampOut))
}

/// 0 at `elapsed == 0`, rising through `Spring.focused`'s shape, 1 once `elapsed >= fade`.
private func layoutFadeRamp(_ elapsed: Double, fade: Double) -> Double {
    guard fade > 0 else { return elapsed >= 0 ? 1 : 0 }
    guard elapsed > 0 else { return 0 }
    guard elapsed < fade else { return 1 }
    return Spring.focused.value(at: elapsed) / Spring.focused.value(at: fade)
}
