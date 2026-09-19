import AppKit
import AVFoundation
import Metal
import MetalKit
import MetalPerformanceShaders
import ImageIO
import UniformTypeIdentifiers
import RecorderCore

/// Byte-layout-identical to the MSL `Uniforms` struct in `Shaders.swift` (16-byte-aligned float4s
/// first, keeps the whole thing a multiple of 16 bytes).
private struct Uniforms {
    var rectNDC = SIMD4<Float>(-1, 1, 1, -1)
    var uvRect = SIMD4<Float>(0, 0, 1, 1)
    var prevUvRect = SIMD4<Float>(0, 0, 1, 1)
    var color = SIMD4<Float>(0, 0, 0, 1)
    var color2 = SIMD4<Float>(0, 0, 0, 1)
    var pixelSize = SIMD2<Float>(1, 1)
    var contentSize = SIMD2<Float>(1, 1)
    var contentOffset = SIMD2<Float>(0, 0)
    var prevContentOffset = SIMD2<Float>(0, 0)
    var radius: Float = 0
    var shadowAlpha: Float = 0
    var shadowBlur: Float = 1
    var gradientAngle: Float = 0
    var globalAlpha: Float = 1
    var mode: Int32 = 0
    var rotation: Float = 0
}

/// `Compositor.render` draws `FrameState` → `target` with the single shader library in
/// `shaderSource` (SPEC §6.2). It never reads `EditorModel`; both the preview `MTKView` and the
/// exporter call this same code so their output is pixel-identical (AC-ED-2).
final class Compositor {
    enum CompositorError: Error { case missingFunction, pngWriteFailed }

    /// One loaded cursor image (SPEC §6.5 hi-res stored representation, AC-CUR-2): `hotX`/`hotY`
    /// are pixels in the *image's own* pixel grid (`cursors/<id>.json`, written by
    /// `EventRecorder.writeCursorImage`), `scale` is that grid's pixels-per-point.
    private struct CursorImage {
        let texture: MTLTexture
        let hotX: Double
        let hotY: Double
        let scale: Double
    }
    private struct CursorMeta: Decodable { let hotX: Double; let hotY: Double; let scale: Double }

    private let device: MTLDevice
    private let package: URL?
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let dummyTexture: MTLTexture
    private lazy var textureLoader = MTKTextureLoader(device: device)
    private var backgroundCache: [String: MTLTexture] = [:]
    private var cursorImageCache: [String: CursorImage] = [:]
    // T-602: chip label -> its rendered texture (rounded background + Core-Text-drawn label baked
    // in together, straight alpha) — cached per string so a repeated shortcut doesn't re-render.
    private var keyChipTextureCache: [String: MTLTexture] = [:]

    /// `package` is the project's `.recorder` directory, for `cursors/<id>.png`/`.json` (T-413);
    /// `nil` for the synthetic `render` selftest, which never sets `FrameState.cursor`.
    init(device: MTLDevice, package: URL? = nil) throws {
        self.device = device
        self.package = package
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let vertexFn = library.makeFunction(name: "vertexMain"),
              let fragmentFn = library.makeFunction(name: "fragmentMain") else {
            throw CompositorError.missingFunction
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        let dummyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyTexture = device.makeTexture(descriptor: dummyDescriptor)!
    }

    /// Aspect: `auto` = the cropped source's own aspect; otherwise the picked ratio. Long edge in
    /// pixels; rounded to even dimensions (video encoder friendliness). T-309: delegates to the Core
    /// function so preview and export share the exact same math.
    func outputSize(for project: Project, longEdge: Int) -> CGSize {
        RecorderCore.outputSize(aspect: project.output.aspect, croppedSource: CGSize(width: Double(project.source.pixelWidth) * project.crop.w, height: Double(project.source.pixelHeight) * project.crop.h), longEdge: longEdge)
    }

    /// `viewport`, when given (pixel rect, top-left origin — matches `NSView`/`screenRect`
    /// convention), restricts drawing to that sub-rect of `target` and letterboxes the rest with
    /// `Theme.bgWindow` (SPEC §6.1 preview: "letterboxed"); `nil` draws over the whole target (the
    /// `render` selftest, and the exporter, which has no letterbox — the target IS the output).
    func render(_ s: FrameState, to target: MTLTexture, commandBuffer: MTLCommandBuffer, viewport: CGRect? = nil) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let bg = Theme.bgWindow
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.redComponent), green: Double(bg.greenComponent), blue: Double(bg.blueComponent), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(dummyTexture, index: 0)
        encoder.setFragmentTexture(dummyTexture, index: 1)
        if let viewport {
            encoder.setViewport(MTLViewport(originX: Double(viewport.minX), originY: Double(viewport.minY),
                                             width: Double(viewport.width), height: Double(viewport.height),
                                             znear: 0, zfar: 1))
        }

        // Pass 1: background.
        drawBackground(s.project.background, outputSize: s.outputSize, encoder: encoder)

        // T-503: the active layout block (if any) and its 0…1 cross-fade amount at this instant —
        // `cameraFull` fades the screen out as the camera grows to fill the canvas, `hidden` fades
        // the camera bubble out (screen unaffected). Gaps between blocks ⇒ `kind == nil`, amount 0.
        let (layoutKind, layoutAmount) = (s.layoutKind, s.layoutAmount)
        let screenAlpha = layoutKind == .cameraFull ? 1 - layoutAmount : 1

        // Pass 2: screen (rounded rect + shadow + crop/zoom UV + motion blur, SPEC §6.2 pass 2,
        // T-501). Pass 3 (cursor) shares the same content rect + crop/zoom UV mapping so it lands
        // in "screen space" and zooms with the content (SPEC §6.2 pass 3, T-413).
        if let screen = s.screen, screenAlpha > 0 {
            let rectPx = screenRect(output: s.outputSize, cropAspect: cropAspect(s.project), padding: s.project.frame.padding)
            let contentUV = cropUV(s.project.crop, view: s.view)
            let prevContentUV = motionBlurContentUV(project: s.project, view: s.view, prevView: s.prevView, contentUV: contentUV, rectPx: rectPx)
            // Zoom scales the whole frame (corners, shadow, clip), not just the UVs inside a fixed one;
            // cursor/masks map through `frameRect` + the un-zoomed crop — the same linear mapping.
            let frameRect = zoomedScreenRect(base: rectPx, view: s.view)
            let frameUV = cropUV(s.project.crop, view: .identity)
            drawScreen(screen, project: s.project, rectPx: rectPx, frameRect: frameRect, contentUV: contentUV, prevContentUV: prevContentUV,
                       alpha: screenAlpha, outputSize: s.outputSize, encoder: encoder)
            if let cursor = s.cursor, cursor.alpha > 0 {
                drawCursor(cursor, project: s.project, rectPx: frameRect, contentUV: frameUV,
                           alphaMultiplier: screenAlpha, outputSize: s.outputSize, encoder: encoder)
            }

            // T-601: masks/highlights active at this frame's SOURCE time (SPEC §7.1 lane, §6.6 Mask
            // panel) — same rectPx/contentUV as the cursor above, so a mask zooms/pans with the
            // content instead of staying fixed to the canvas.
            let activeMasks = s.project.masks.filter { s.sourceTime >= $0.start && s.sourceTime <= $0.end }
            if !activeMasks.isEmpty {
                drawMasks(activeMasks, texture: screen, sourceTime: s.sourceTime, rectPx: frameRect, contentUV: frameUV, alphaMultiplier: screenAlpha,
                          outputSize: s.outputSize, encoder: encoder)
            }
        }

        // Pass 4: camera (rounded-rect SDF quad, SPEC §6.2 pass 4, §6.6 Camera, T-502) — bubble in
        // its corner, or cross-faded into a full-canvas quad while a `cameraFull` layout is active.
        if let camera = s.camera {
            let cameraAlpha = layoutKind == .hidden ? 1 - layoutAmount : 1
            if cameraAlpha > 0 {
                let rectPx = cameraOverlayRect(project: s.project, output: s.outputSize,
                                               atSource: s.sourceTime, viewScale: s.view.scale)
                var cameraProject = s.project
                cameraProject.camera = overlayCamera(project: s.project, atSource: s.sourceTime)
                drawCamera(camera, project: cameraProject, rectPx: rectPx, alpha: cameraAlpha, outputSize: s.outputSize, encoder: encoder)
            }
        }

        // Pass 5: keyboard-shortcut chip (SPEC §6.2 pass 4 "key overlay", §6.6 Keys tab, T-602) —
        // bottom-centre of the whole canvas (not "screen space": like the camera bubble, it doesn't
        // zoom/pan with the content).
        if let chip = s.keyChip {
            drawKeyChip(chip, keys: overlayKeys(project: s.project, atSource: s.sourceTime), outputSize: s.outputSize, encoder: encoder)
        }

        encoder.endEncoding()
    }

    // MARK: - Pass 1: background

    private func drawBackground(_ bg: Background, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        var u = Uniforms()
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        switch bg.kind {
        case .color:
            u.mode = 0
            u.color = colorSIMD(bg.color)
        case .gradient:
            u.mode = 1
            u.color = colorSIMD(bg.gradient.first ?? "#5B3DF5")
            u.color2 = colorSIMD(bg.gradient.count > 1 ? bg.gradient[1] : "#E0567A")
            u.gradientAngle = Float(bg.gradientAngle * .pi / 180)
        case .wallpaper, .image:
            if let texture = backgroundTexture(bg, outputSize: outputSize) {
                u.mode = 2
                encoder.setFragmentTexture(texture, index: 0)
            } else {
                // ponytail: `image` needs the project package URL, which `FrameState` doesn't carry
                // yet. Fall back to a flat fill.
                u.mode = 0
                u.color = colorSIMD(bg.color)
            }
        }
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
    }

    /// T-308 fix: `bg.wallpaper` is either a bundled id (the wallpaper grid's own JPEGs, `"01"`…
    /// `"12"`) or an absolute path to a system wallpaper the Background tab's grid also offers
    /// (`/System/Library/Desktop Pictures/*.heic`) — load both, instead of only bundled ids.
    private func backgroundTexture(_ bg: Background, outputSize: CGSize) -> MTLTexture? {
        guard bg.kind == .wallpaper else { return nil }
        let key = "wallpaper-\(bg.wallpaper)-blur\(bg.blur)-\(Int(outputSize.width))x\(Int(outputSize.height))"
        if let cached = backgroundCache[key] { return cached }
        var texture: MTLTexture?
        if bg.wallpaper.hasPrefix("/") {
            texture = loadAbsoluteWallpaper(path: bg.wallpaper, downscaleTo: outputSize)
        } else if let url = Bundle.main.url(forResource: bg.wallpaper, withExtension: "jpg", subdirectory: "Wallpapers") {
            texture = try? textureLoader.newTexture(URL: url, options: [.SRGB: false])
        }
        guard var texture else { return nil }
        if bg.blur > 0, let blurred = blurred(texture, amount: bg.blur) { texture = blurred }
        backgroundCache[key] = texture
        return texture
    }

    /// System wallpapers can be many thousands of pixels square; `MTKTextureLoader.newTexture(URL:)`
    /// doesn't reliably decode HEIC, so decode + downscale through `CGImageSource` (ImageIO handles
    /// HEIC) first, then hand the loader the already-small `CGImage`.
    private func loadAbsoluteWallpaper(path: String, downscaleTo outputSize: CGSize) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(max(outputSize.width, outputSize.height)), 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return try? textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false])
    }

    private func blurred(_ texture: MTLTexture, amount: Double) -> MTLTexture? {
        guard let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let out = device.makeTexture(descriptor: descriptor) else { return nil }
        MPSImageGaussianBlur(device: device, sigma: Float(amount * 40)).encode(commandBuffer: cb, sourceTexture: texture, destinationTexture: out)
        cb.commit()
        cb.waitUntilCompleted()
        return out
    }

    // MARK: - Pass 2: screen

    /// Draws the "screen" quad as a full-canvas pass (not one sized to the content rect) so the
    /// shadow — computed by the fragment shader's SDF, offset to the content rect — can bleed
    /// outward into the padding (SPEC §6.2 pass 2: "quad is enlarged by blurPx"; a full-canvas
    /// quad is the simplest way to give it room on every side without a second uniform set).
    private func drawScreen(_ texture: FrameState.Texture, project: Project, rectPx: CGRect, frameRect: CGRect, contentUV: SIMD4<Float>, prevContentUV: SIMD4<Float>, alpha: Double, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        var u = Uniforms()
        u.rectNDC = SIMD4(-1, 1, 1, -1)
        u.uvRect = extrapolatedUV(contentUV, contentRect: rectPx, to: outputSize)
        u.prevUvRect = extrapolatedUV(prevContentUV, contentRect: rectPx, to: outputSize)
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        u.contentSize = SIMD2(Float(frameRect.width), Float(frameRect.height))
        u.contentOffset = SIMD2(Float(frameRect.midX - outputSize.width / 2), Float(frameRect.midY - outputSize.height / 2))
        u.radius = Float(project.frame.cornerRadius * min(frameRect.width, frameRect.height))
        u.shadowAlpha = Float(project.frame.shadow)
        // 20 pt (the native window shadow's sigma) in output px, so the shadow scales with the window.
        let sourcePointsWide = project.crop.w * Double(max(project.source.pixelWidth, 1)) / max(project.source.scale, 0.0001)
        u.shadowBlur = Float(20 * frameRect.width / sourcePointsWide)
        u.globalAlpha = Float(alpha)
        u.mode = texture.chroma != nil ? 4 : 3   // biplanar YCbCr (real capture) vs already-RGB (fixtures)
        encoder.setFragmentTexture(texture.luma, index: 0)
        encoder.setFragmentTexture(texture.chroma ?? dummyTexture, index: 1)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
        encoder.setFragmentTexture(dummyTexture, index: 1)
    }

    /// SPEC §6.2 pass 2, T-501: the UV rect the screen quad should blur towards — `prevView` warped
    /// by only the axes `animation.blurZoom`/`blurPan` actually gate (scale vs centre), scaled by
    /// `animation.motionBlur`, and zeroed below a 0.5 output-px delta (SPEC's own threshold). Kept
    /// pre-extrapolation (like `contentUV`) since `extrapolatedUV` is linear — blending before or
    /// after it gives the same result, and `drawScreen` already extrapolates both the same way.
    private func motionBlurContentUV(project: Project, view: ViewTransform, prevView: ViewTransform, contentUV: SIMD4<Float>, rectPx: CGRect) -> SIMD4<Float> {
        let animation = project.animation
        guard animation.motionBlur > 0, animation.blurZoom || animation.blurPan else { return contentUV }
        var blurTarget = view
        if animation.blurZoom { blurTarget.scale = prevView.scale }
        if animation.blurPan { blurTarget.cx = prevView.cx; blurTarget.cy = prevView.cy }
        guard blurTarget != view else { return contentUV }
        let blurUV = cropUV(project.crop, view: blurTarget)
        let dx = Double(blurUV.x - contentUV.x) * rectPx.width
        let dy = Double(blurUV.y - contentUV.y) * rectPx.height
        guard (dx * dx + dy * dy).squareRoot() > 0.5 else { return contentUV }
        let amount = Float(min(max(animation.motionBlur, 0), 1))
        return contentUV + (blurUV - contentUV) * amount
    }

    // MARK: - Pass 3: cursor (SPEC §6.2 pass 3, §6.5, T-413)

    /// Positions the cursor quad in **screen space**: `cursor.x/y` (normalised source coords) are
    /// mapped through the same crop/zoom UV rect `drawScreen` used, so the cursor lands in the
    /// right place on the (possibly zoomed) content and moves/scales with it. Size = the cursor
    /// image's own point size (`hotX/hotY/scale` from `cursors/<id>.json`) × `cursor.size` ×
    /// output-pixels-per-source-pixel (crop + zoom combined) × `clickScale`; offset by the hotspot
    /// so the recorded point lands under the hotspot, not the image's centre.
    private func drawCursor(_ cursor: CursorSample, project: Project, rectPx: CGRect, contentUV: SIMD4<Float>, alphaMultiplier: Double, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        guard let image = cursorImage(id: cursor.imageID) else { return }
        let u0 = Double(contentUV.x), v0 = Double(contentUV.y), u1 = Double(contentUV.z), v1 = Double(contentUV.w)
        guard u1 > u0, v1 > v0 else { return }

        let px = rectPx.minX + (cursor.x - u0) / (u1 - u0) * rectPx.width
        let py = rectPx.minY + (cursor.y - v0) / (v1 - v0) * rectPx.height
        let prevPx = rectPx.minX + (cursor.prevX - u0) / (u1 - u0) * rectPx.width
        let prevPy = rectPx.minY + (cursor.prevY - v0) / (v1 - v0) * rectPx.height

        let sourceW = Double(max(project.source.pixelWidth, 1)), sourceH = Double(max(project.source.pixelHeight, 1))
        let outputPxPerSourcePxX = rectPx.width / ((u1 - u0) * sourceW)
        let outputPxPerSourcePxY = rectPx.height / ((v1 - v0) * sourceH)
        let pointToOutputPxX = outputPxPerSourcePxX * project.source.scale
        let pointToOutputPxY = outputPxPerSourcePxY * project.source.scale

        let imagePointW = Double(image.texture.width) / max(image.scale, 0.0001)
        let imagePointH = Double(image.texture.height) / max(image.scale, 0.0001)
        let drawW = imagePointW * project.cursor.size * pointToOutputPxX * cursor.clickScale
        let drawH = imagePointH * project.cursor.size * pointToOutputPxY * cursor.clickScale
        guard drawW > 0, drawH > 0 else { return }

        // `hotX`/`hotY` are `NSCursor.hotSpot` scaled to pixels. `hotSpot` is already top-left/y-down
        // (pointingHand reports (13, 8) in 32×32 — fingertip at the top), same as the PNG, so no flip.
        let hotFracX = image.hotX / Double(image.texture.width)
        let hotFracY = image.hotY / Double(image.texture.height)
        let centerX = px + (0.5 - hotFracX) * drawW
        let centerY = py + (0.5 - hotFracY) * drawH
        let prevCenterX = prevPx + (0.5 - hotFracX) * drawW
        let prevCenterY = prevPy + (0.5 - hotFracY) * drawH

        var u = Uniforms()
        u.rectNDC = SIMD4(-1, 1, 1, -1)
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        u.contentSize = SIMD2(Float(drawW), Float(drawH))
        u.contentOffset = SIMD2(Float(centerX - outputSize.width / 2), Float(centerY - outputSize.height / 2))
        u.prevContentOffset = motionBlurCursorOffset(project: project, current: u.contentOffset,
                                                       currentCenter: (centerX, centerY), prevCenter: (prevCenterX, prevCenterY),
                                                       outputSize: outputSize)
        u.color = SIMD4(0, 0, 0, Float(cursor.alpha * alphaMultiplier))
        u.rotation = Float(cursor.rotation * .pi / 180)
        u.mode = 5
        encoder.setFragmentTexture(image.texture, index: 0)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
    }

    /// SPEC §6.2 pass 3, T-501: the cursor quad's centre one render frame earlier, scaled by
    /// `animation.motionBlur` and gated by `blurCursor` + the same 0.5 output-px threshold as the
    /// screen pass. Equal to `current` (no blur) when off — the shader's tap loop then collapses to
    /// a no-op average.
    private func motionBlurCursorOffset(project: Project, current: SIMD2<Float>, currentCenter: (Double, Double), prevCenter: (Double, Double), outputSize: CGSize) -> SIMD2<Float> {
        let animation = project.animation
        guard animation.motionBlur > 0, animation.blurCursor else { return current }
        let dx = prevCenter.0 - currentCenter.0, dy = prevCenter.1 - currentCenter.1
        guard (dx * dx + dy * dy).squareRoot() > 0.5 else { return current }
        let amount = min(max(animation.motionBlur, 0), 1)
        let bx = currentCenter.0 + dx * amount, by = currentCenter.1 + dy * amount
        return SIMD2(Float(bx - outputSize.width / 2), Float(by - outputSize.height / 2))
    }

    // MARK: - Masks/highlights (SPEC §7.1 lane, §6.6 Mask panel, T-601)

    /// `mask` = a flat, opaque-black quad at `opacity` over the rect. `highlight` = the SAME
    /// dimming everywhere else INSIDE the screen content rect — four quads tiling the area outside
    /// the rect (a "donut"; mode 0 flat colour, reused, so no new shader mode is needed). Both map
    /// `mask.rect` (SPEC's "uncropped source coordinates", AC-CROP-2) through the exact
    /// `contentUV`/`rectPx` the screen/cursor passes use, so a mask zooms and pans with the content
    /// (`Compositor.drawCursor` maps `cursor.x/y` through the identical formula).
    /// Masks optionally use a smoothstep opacity envelope at both ends.
    /// `// ponytail: not clipped to the screen's own rounded corners/shadow SDF — a mask can bleed a
    /// hair past a heavily rounded corner; not worth a second SDF pass for a rare, subtle overlap.`
    private func drawMasks(_ masks: [Mask], texture: FrameState.Texture, sourceTime: Double, rectPx: CGRect, contentUV: SIMD4<Float>, alphaMultiplier: Double, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        let u0 = Double(contentUV.x), v0 = Double(contentUV.y), u1 = Double(contentUV.z), v1 = Double(contentUV.w)
        guard u1 > u0, v1 > v0 else { return }
        func screenPoint(_ sx: Double, _ sy: Double) -> CGPoint {
            CGPoint(x: rectPx.minX + (sx - u0) / (u1 - u0) * rectPx.width,
                    y: rectPx.minY + (sy - v0) / (v1 - v0) * rectPx.height)
        }
        for mask in masks {
            let alpha = mask.strength(at: sourceTime) * alphaMultiplier
            guard alpha > 0 else { continue }
            let color = SIMD4<Float>(0, 0, 0, Float(alpha))
            let a = screenPoint(mask.rect.x, mask.rect.y)
            let b = screenPoint(mask.rect.x + mask.rect.w, mask.rect.y + mask.rect.h)
            let hole = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).intersection(rectPx)

            guard !hole.isNull, !hole.isEmpty else { continue }
            switch mask.kind {
            case .blur:
                var u = Uniforms()
                u.rectNDC = ndcRect(hole, in: outputSize)
                func uv(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                    SIMD2(Float(u0 + (x - rectPx.minX) / rectPx.width * (u1 - u0)),
                          Float(v0 + (y - rectPx.minY) / rectPx.height * (v1 - v0)))
                }
                let lo = uv(hole.minX, hole.minY), hi = uv(hole.maxX, hole.maxY)
                u.uvRect = SIMD4(lo.x, lo.y, hi.x, hi.y)
                u.globalAlpha = Float(alpha)
                u.mode = texture.chroma == nil ? 6 : 7
                encoder.setFragmentTexture(texture.luma, index: 0)
                encoder.setFragmentTexture(texture.chroma ?? dummyTexture, index: 1)
                draw(u, encoder: encoder)
                encoder.setFragmentTexture(dummyTexture, index: 0)
                encoder.setFragmentTexture(dummyTexture, index: 1)
            case .mask:
                fillRect(hole, color: color, outputSize: outputSize, encoder: encoder)
            case .highlight:
                let bands = [
                    CGRect(x: rectPx.minX, y: rectPx.minY, width: rectPx.width, height: hole.minY - rectPx.minY),             // top
                    CGRect(x: rectPx.minX, y: hole.maxY, width: rectPx.width, height: rectPx.maxY - hole.maxY),               // bottom
                    CGRect(x: rectPx.minX, y: hole.minY, width: hole.minX - rectPx.minX, height: hole.height),               // left
                    CGRect(x: hole.maxX, y: hole.minY, width: rectPx.maxX - hole.maxX, height: hole.height),                 // right
                ]
                for band in bands { fillRect(band, color: color, outputSize: outputSize, encoder: encoder) }
            }
        }
    }

    /// A flat-colour (mode 0) quad at an arbitrary pixel rect — `drawMasks`' one shared draw call.
    private func fillRect(_ rect: CGRect, color: SIMD4<Float>, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        guard rect.width > 0, rect.height > 0 else { return }
        var u = Uniforms()
        u.rectNDC = ndcRect(rect, in: outputSize)
        u.color = color
        u.mode = 0
        draw(u, encoder: encoder)
    }

    // MARK: - Pass 4: camera (SPEC §6.2 pass 4, §6.6 Camera, T-502)

    /// Draws the camera texture in a rounded-rect SDF quad (reusing modes 3/4, same as the screen
    /// pass) — cover-cropped to the animated destination, mirrored when `camera.mirror`.
    /// No motion blur (SPEC §6.2 only asks for it on the screen/cursor passes): `prevUvRect ==
    /// uvRect` so the shared shader's tap loop is a no-op average.
    private func drawCamera(_ texture: FrameState.Texture, project: Project, rectPx: CGRect, alpha: Double, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        var u = Uniforms()
        u.rectNDC = SIMD4(-1, 1, 1, -1)
        let contentUV = cameraContentUV(texture: texture, destination: rectPx.size, mirror: project.camera.mirror)
        u.uvRect = extrapolatedUV(contentUV, contentRect: rectPx, to: outputSize)
        u.prevUvRect = u.uvRect
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        u.contentSize = SIMD2(Float(rectPx.width), Float(rectPx.height))
        u.contentOffset = SIMD2(Float(rectPx.midX - outputSize.width / 2), Float(rectPx.midY - outputSize.height / 2))
        u.radius = Float(project.camera.roundness * min(rectPx.width, rectPx.height) / 2)
        u.shadowAlpha = Float(project.camera.shadow)
        u.shadowBlur = Float(0.04 * min(outputSize.width, outputSize.height))
        u.globalAlpha = Float(alpha)
        u.mode = texture.chroma != nil ? 4 : 3
        encoder.setFragmentTexture(texture.luma, index: 0)
        encoder.setFragmentTexture(texture.chroma ?? dummyTexture, index: 1)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
        encoder.setFragmentTexture(dummyTexture, index: 1)
    }

    private func cameraContentUV(texture: FrameState.Texture, destination: CGSize, mirror: Bool) -> SIMD4<Float> {
        let crop = cameraCrop(source: CGSize(width: texture.luma.width, height: texture.luma.height), destination: destination)
        return SIMD4(Float(mirror ? crop.maxX : crop.minX), Float(crop.minY),
                     Float(mirror ? crop.minX : crop.maxX), Float(crop.maxY))
    }

    /// `id == nil` (or a load failure) falls back to the plain system arrow — AppKit already ships
    /// it, so there's no need to bundle our own default cursor asset. Cached per package + id.
    private func cursorImage(id: String?) -> CursorImage? {
        let key = id ?? "__default__"
        if let cached = cursorImageCache[key] { return cached }
        var loaded: CursorImage?
        if let id, let package { loaded = loadCursorImage(id: id, package: package) }
        if loaded == nil { loaded = loadDefaultArrowCursorImage() }
        if let loaded { cursorImageCache[key] = loaded }
        return loaded
    }

    private func loadCursorImage(id: String, package: URL) -> CursorImage? {
        let dir = package.appendingPathComponent("cursors")
        guard let texture = try? textureLoader.newTexture(URL: dir.appendingPathComponent("\(id).png"), options: [.SRGB: false]),
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")),
              let meta = try? JSONDecoder().decode(CursorMeta.self, from: data) else { return nil }
        return CursorImage(texture: texture, hotX: meta.hotX, hotY: meta.hotY, scale: meta.scale)
    }

    private func loadDefaultArrowCursorImage() -> CursorImage? {
        let cursor = NSCursor.arrow
        guard let rep = cursor.image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
              let cgImage = rep.cgImage,
              let texture = try? textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false]) else { return nil }
        let scale = cursor.image.size.width > 0 ? Double(rep.pixelsWide) / Double(cursor.image.size.width) : 1
        return CursorImage(texture: texture, hotX: cursor.hotSpot.x * scale, hotY: cursor.hotSpot.y * scale, scale: scale)
    }

    /// SPEC §6.2 pass 2: "crop + zoom applied as UV transform" — `center + (uv − 0.5) / scale`,
    /// inside the crop rect.
    private func cropUV(_ crop: NormRect, view: ViewTransform) -> SIMD4<Float> {
        let halfW = crop.w / (2 * max(view.scale, 0.0001))
        let halfH = crop.h / (2 * max(view.scale, 0.0001))
        let cx = crop.x + crop.w * view.cx
        let cy = crop.y + crop.h * view.cy
        return SIMD4(Float(cx - halfW), Float(cy - halfH), Float(cx + halfW), Float(cy + halfH))
    }

    /// `contentUV` is what the shader should sample at `contentRect`'s own edges; since the quad
    /// we actually draw spans the whole canvas, linearly extend that mapping out to the canvas's
    /// edges (padding pixels land outside 0…1 and get clamped by the sampler — harmless, they're
    /// always under `fillAlpha == 0`).
    private func extrapolatedUV(_ contentUV: SIMD4<Float>, contentRect: CGRect, to outputSize: CGSize) -> SIMD4<Float> {
        let tx0 = Float((0 - contentRect.minX) / contentRect.width)
        let tx1 = Float((outputSize.width - contentRect.minX) / contentRect.width)
        let ty0 = Float((0 - contentRect.minY) / contentRect.height)
        let ty1 = Float((outputSize.height - contentRect.minY) / contentRect.height)
        let u0 = contentUV.x + (contentUV.z - contentUV.x) * tx0
        let u1 = contentUV.x + (contentUV.z - contentUV.x) * tx1
        let v0 = contentUV.y + (contentUV.w - contentUV.y) * ty0
        let v1 = contentUV.y + (contentUV.w - contentUV.y) * ty1
        return SIMD4(u0, v0, u1, v1)
    }

    // MARK: - Pass 5: key chip (SPEC §6.2 pass 4, §6.6 Keys tab, T-602)

    /// Draws `chip`'s texture (`chipTexture`, below) as a straight quad, bottom-centre of the whole
    /// canvas, faded by age via mode 2's `globalAlpha` (`Shaders.swift`). SPEC gives the overlay
    /// 1.2 s ("for 1.2 s") but no fade curve, so a straightforward linear fade over the last 0.3 s
    /// of that hold is used here — `// ponytail: no eased fade curve; revisit only if a mockup asks
    /// for one.`
    private func drawKeyChip(_ chip: FrameState.KeyChipState, keys: (settings: Keys, opacity: Double), outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        guard let texture = chipTexture(label: chip.label) else { return }
        let hold = keys.settings.hold, fadeOut = min(0.3, hold)
        let alpha = chip.age > hold - fadeOut ? max(0, (hold - chip.age) / fadeOut) : 1.0
        guard alpha > 0 else { return }

        let shortEdge = min(outputSize.width, outputSize.height)
        let textureAspect = Double(texture.width) / Double(max(texture.height, 1))
        let height = min(0.07 * shortEdge * min(max(keys.settings.size, 0.5), 3), (outputSize.width - 0.1 * shortEdge) / textureAspect)
        let width = height * textureAspect
        let marginBottom = 0.05 * shortEdge
        let rectPx = CGRect(x: marginBottom + max(0, outputSize.width - 2 * marginBottom - width) * min(max(keys.settings.position.x, 0), 1),
                             y: marginBottom + max(0, outputSize.height - 2 * marginBottom - height) * min(max(keys.settings.position.y, 0), 1),
                             width: width, height: height)

        var u = Uniforms()
        u.rectNDC = ndcRect(rectPx, in: outputSize)
        u.uvRect = SIMD4(0, 0, 1, 1)
        u.mode = 2
        u.globalAlpha = Float(alpha * keys.opacity)
        encoder.setFragmentTexture(texture, index: 0)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
    }

    /// Renders `label` once to a straight-alpha RGBA texture — a rounded pill background (Core
    /// Graphics) with the text centred on it (Core Text, via `NSAttributedString.draw(at:)`) baked
    /// into the SAME bitmap, cached by `label` so a repeated shortcut is drawn once.
    private func chipTexture(label: String) -> MTLTexture? {
        if let cached = keyChipTextureCache[label] { return cached }
        let font = NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let textSize = text.size()
        let paddingX: CGFloat = 26, paddingY: CGFloat = 15
        let size = CGSize(width: max(1, ceil(textSize.width + paddingX * 2)), height: max(1, ceil(textSize.height + paddingY * 2)))
        let width = Int(size.width), height = Int(size.height)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let bgRect = CGRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: bgRect, xRadius: size.height / 2, yRadius: size.height / 2).addClip()
        NSColor.black.withAlphaComponent(0.72).setFill()
        bgRect.fill()
        text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage(),
              let texture = try? textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false]) else { return nil }
        keyChipTextureCache[label] = texture
        return texture
    }

    // MARK: - Shared helpers

    private func draw(_ uniforms: Uniforms, encoder: MTLRenderCommandEncoder) {
        var u = uniforms
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Pixel rect (top-left origin, y-down, matches `NormPoint`/`screenRect`) → clip-space
    /// (left, top, right, bottom); `vertexMain` mixes between the pair on each axis so the sign
    /// doesn't matter, only that top/bottom and left/right are consistent with `uvRect`.
    private func ndcRect(_ rect: CGRect, in outputSize: CGSize) -> SIMD4<Float> {
        let left = Float(rect.minX / outputSize.width) * 2 - 1
        let right = Float(rect.maxX / outputSize.width) * 2 - 1
        let top = 1 - Float(rect.minY / outputSize.height) * 2
        let bottom = 1 - Float(rect.maxY / outputSize.height) * 2
        return SIMD4(left, top, right, bottom)
    }

    private func colorSIMD(_ hex: String) -> SIMD4<Float> {
        let c = NSColor(hex: hex)
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }

    private func aspectRatio(for project: Project) -> Double {
        switch project.output.aspect {
        case .auto: return cropAspect(project)
        case .r16x9: return 16.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        case .r1x1: return 1
        case .r4x3: return 4.0 / 3.0
        case .r16x10: return 16.0 / 10.0
        }
    }

    private func cropAspect(_ project: Project) -> Double {
        let w = Double(project.source.pixelWidth) * project.crop.w
        let h = Double(project.source.pixelHeight) * project.crop.h
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }
}

// MARK: - Selftest `render <package> <out.png>` (SPEC §6.2, plan T-304)

extension Compositor {
    /// Renders output frame 0 at 1920 long edge to `out.png`. `screen.mov` decoding is
    /// `FrameSource`'s job (T-305) and the preview/export wiring is later still (T-306/T-413);
    /// this only exercises the compositor, so it stands in for the recorded frame with a
    /// synthetic gradient texture instead of decoding real media.
    /// `// ponytail: synthetic screen texture — swap for a real FrameSource.screen(at:) sample once one exists.`
    static func runRenderSelfTest(_ args: [String]) throws {
        guard args.count >= 2 else { throw SelfTestArgError.usage("render <package> <out.png>") }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let projectURL = packageURL.appendingPathComponent("project.json")
        let project = (try? Project.load(from: projectURL)) ?? Project()

        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTestArgError.usage("no Metal device") }
        let compositor = try Compositor(device: device)
        let outputSize = compositor.outputSize(for: project, longEdge: 1920)
        let width = Int(outputSize.width), height = Int(outputSize.height)

        let screenWidth = project.source.pixelWidth > 0 ? project.source.pixelWidth : 1280
        let screenHeight = project.source.pixelHeight > 0 ? project.source.pixelHeight : 720
        let screen = Self.syntheticScreenTexture(device: device, width: screenWidth, height: screenHeight)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw SelfTestArgError.usage("failed to set up Metal resources")
        }

        let state = FrameState(outputSize: outputSize, screen: FrameState.Texture(luma: screen), camera: nil, project: project)
        compositor.render(state, to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let i = (y * width + x) * 4
            return bytes[i..<i + 4]
        }
        guard pixel(width / 2, height / 2) != pixel(0, 0) else {
            throw SelfTestArgError.usage("centre pixel equals corner pixel")
        }

        try Self.writePNG(bytes: bytes, width: width, height: height, to: outURL)
    }

    private static func syntheticScreenTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                bytes[i + 0] = UInt8(clamping: Int(60 + 150 * fx))       // B
                bytes[i + 1] = UInt8(clamping: Int(180 + 60 * fy))       // G
                bytes[i + 2] = UInt8(clamping: Int(230 - 120 * fx))      // R
                bytes[i + 3] = 255                                       // A
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    private static func writePNG(bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CompositorError.pngWriteFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CompositorError.pngWriteFailed }
    }
}

enum SelfTestArgError: Error { case usage(String) }

// MARK: - Selftest `preview-frame <package> <t> <out.png>` (SPEC §6.1, §6.2 "Preview", plan T-306)

extension Compositor {
    /// Renders the frame at output time `t` through the actual PREVIEW path — `makeComposition` →
    /// `AVPlayerItemVideoOutput` (real 420v decode) → `TextureCache` → `makeFrameState` →
    /// `Compositor.render` — instead of `render`'s synthetic BGRA texture, so it exercises the
    /// YCbCr→RGB conversion (shader mode 4) `PreviewView.draw` uses.
    @MainActor
    static func runPreviewFrameSelfTest(_ args: [String]) async throws {
        guard args.count >= 3, let t = Double(args[1]) else {
            throw SelfTestArgError.usage("preview-frame <package> <t> <out.png>")
        }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[2])
        let model = try loadEditorModel(package: packageURL)
        let project = model.project

        let (composition, audioMix, _, _) = try await makeComposition(package: packageURL, project: project)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)

        while item.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
        guard item.status == .readyToPlay else {
            throw SelfTestArgError.usage("item failed to load: \(String(describing: item.error))")
        }

        let time = CMTime(seconds: t, preferredTimescale: 600)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cont.resume() }
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            throw SelfTestArgError.usage("no decoded pixel buffer at t=\(t)")
        }

        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTestArgError.usage("no Metal device") }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)
        guard let screenTexture = textureCache.texture(from: pixelBuffer) else {
            throw SelfTestArgError.usage("CVPixelBuffer -> MTLTexture failed")
        }

        // T-502: camera, decoded the same way `PreviewView.attachCamera` does — `isolateTrack` since
        // `AVPlayerItemVideoOutput` can't select a track out of the shared composition.
        var cameraTexture: FrameState.Texture?
        let videoTracks = composition.tracks(withMediaType: .video)
        if videoTracks.count > 1 {
            let cameraComposition = isolateTrack(videoTracks[1], duration: composition.duration)
            let cameraItem = AVPlayerItem(asset: cameraComposition)
            let cameraOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            cameraItem.add(cameraOutput)
            let cameraPlayer = AVPlayer(playerItem: cameraItem)
            while cameraItem.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
            if cameraItem.status == .readyToPlay {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    cameraPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cont.resume() }
                }
                if let cameraPixelBuffer = cameraOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    cameraTexture = textureCache.texture(from: cameraPixelBuffer)
                }
            }
        }

        let outputSize = compositor.outputSize(for: project, longEdge: 1920)
        let width = Int(outputSize.width), height = Int(outputSize.height)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw SelfTestArgError.usage("failed to set up Metal resources")
        }

        let state = makeFrameState(model: model, outputTime: t, screen: screenTexture, camera: cameraTexture, size: outputSize)
        compositor.render(state, to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let i = (y * width + x) * 4
            return bytes[i..<i + 4]
        }
        guard pixel(width / 2, height / 2) != pixel(0, 0) else {
            throw SelfTestArgError.usage("centre pixel equals corner pixel")
        }

        try Self.writePNG(bytes: bytes, width: width, height: height, to: outURL)
    }
}
