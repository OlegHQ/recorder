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
/// in. For short blocks the fade is capped at half the duration, so the target is reached. Pure lookup: the result doesn't depend on
/// `layouts`' array order.
public func layoutMix(layouts: [Layout], atSource t: Double, fade: Double? = nil) -> (kind: Layout.Kind?, amount: Double) {
    guard let active = layouts.first(where: { t >= $0.start && t <= $0.end }) else { return (nil, 0) }
    let duration = min(max(0, fade ?? active.transition), max(0, (active.end - active.start) / 2))
    let rampIn = layoutFadeRamp(t - active.start, fade: duration)
    let rampOut = layoutFadeRamp(active.end - t, fade: duration)
    return (active.kind, min(rampIn, rampOut))
}

/// 0 at `elapsed == 0`, rising through `Spring.focused`'s shape, 1 once `elapsed >= fade`.
private func layoutFadeRamp(_ elapsed: Double, fade: Double) -> Double {
    guard fade > 0 else { return elapsed >= 0 ? 1 : 0 }
    guard elapsed > 0 else { return 0 }
    guard elapsed < fade else { return 1 }
    return Spring.focused.value(at: elapsed) / Spring.focused.value(at: fade)
}

/// Normalized position is the fraction of available travel, keeping the bubble inside the canvas.
public func cameraOverlayRect(camera: Camera, output: CGSize, viewScale: Double = 1) -> CGRect {
    let short = min(output.width, output.height)
    let shrink = camera.shrinkWhenZoomed ? 1 - 0.3 * min(max(viewScale - 1, 0), 1) : 1
    let side = min(max(camera.size, 0.1), 1) * short * shrink
    let aspect = min(max(camera.aspect, 0.25), 4)
    let width = aspect >= 1 ? side : side * aspect
    let height = aspect >= 1 ? side / aspect : side
    let margin = min(0.02 * short, max(0, (short - side) / 2))
    let corner = camera.corner
    let position = camera.position ?? NormPoint(
        x: corner == .topLeft || corner == .bottomLeft ? 0 : 1,
        y: corner == .topLeft || corner == .topRight ? 0 : 1)
    return CGRect(x: margin + min(max(position.x, 0), 1) * max(0, output.width - 2 * margin - width),
                  y: margin + min(max(position.y, 0), 1) * max(0, output.height - 2 * margin - height),
                  width: width, height: height)
}

/// Shared by export, preview and mouse hit-testing; timeline blocks animate from/to the default bubble.
public func cameraOverlayRect(project: Project, output: CGSize, atSource t: Double, viewScale: Double = 1) -> CGRect {
    let base = cameraOverlayRect(camera: project.camera, output: output, viewScale: viewScale)
    guard let block = project.layouts.first(where: { t >= $0.start && t <= $0.end }) else { return base }
    let amount = layoutMix(layouts: project.layouts, atSource: t).amount
    let target: CGRect
    switch block.kind {
    case .cameraFull: target = CGRect(origin: .zero, size: output)
    case .hidden, .settings: target = base
    case .bubble: target = cameraOverlayRect(camera: block.camera ?? project.camera, output: output, viewScale: viewScale)
    }
    return CGRect(x: base.minX + (target.minX - base.minX) * amount,
                  y: base.minY + (target.minY - base.minY) * amount,
                  width: base.width + (target.width - base.width) * amount,
                  height: base.height + (target.height - base.height) * amount)
}

/// Centered cover crop, recalculated for the animated rectangle so faces never stretch.
public func cameraCrop(source: CGSize, destination: CGSize) -> CGRect {
    guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else {
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    let ratio = (source.width / source.height) / (destination.width / destination.height)
    let width = min(1, 1 / ratio), height = min(1, ratio)
    return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
}

/// Settings clips use the same source-time ranges as camera layouts.
public func overlayKeys(project: Project, atSource t: Double) -> (settings: Keys, opacity: Double) {
    let base = project.keys
    guard let block = project.layouts.first(where: { t >= $0.start && t <= $0.end }),
          let target = block.keys else { return (base, base.show ? 1 : 0) }
    let amount = layoutMix(layouts: project.layouts, atSource: t).amount
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
    var value = amount > 0 ? target : base
    value.size = mix(base.size, target.size)
    value.hold = mix(base.hold, target.hold)
    value.position = NormPoint(x: mix(base.position.x, target.position.x), y: mix(base.position.y, target.position.y))
    return (value, mix(base.show ? 1 : 0, target.show ? 1 : 0))
}

public func overlayCamera(project: Project, atSource t: Double) -> Camera {
    var value = project.camera
    guard let block = project.layouts.first(where: { t >= $0.start && t <= $0.end }),
          block.kind == .bubble, let target = block.camera else { return value }
    let amount = layoutMix(layouts: project.layouts, atSource: t).amount
    value.roundness += (target.roundness - value.roundness) * amount
    value.shadow += (target.shadow - value.shadow) * amount
    if amount > 0 { value.mirror = target.mirror }
    return value
}
