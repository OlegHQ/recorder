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
    var color = SIMD4<Float>(0, 0, 0, 1)
    var color2 = SIMD4<Float>(0, 0, 0, 1)
    var pixelSize = SIMD2<Float>(1, 1)
    var contentSize = SIMD2<Float>(1, 1)
    var contentOffset = SIMD2<Float>(0, 0)
    var radius: Float = 0
    var shadowAlpha: Float = 0
    var shadowBlur: Float = 1
    var gradientAngle: Float = 0
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
    /// pixels; rounded to even dimensions (video encoder friendliness).
    func outputSize(for project: Project, longEdge: Int) -> CGSize {
        let ratio = aspectRatio(for: project)
        let long = Double(max(longEdge, 2))
        let raw = ratio >= 1 ? CGSize(width: long, height: long / ratio) : CGSize(width: long * ratio, height: long)
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        return CGSize(width: even(raw.width), height: even(raw.height))
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

        // Pass 2: screen (rounded rect + shadow + crop/zoom UV, SPEC §6.2 pass 2). Pass 3 (cursor)
        // shares the same content rect + crop/zoom UV mapping so it lands in "screen space" and
        // zooms with the content (SPEC §6.2 pass 3, T-413).
        // ponytail: motion blur (N=8 taps along prevView→view, gated by animation.blur*) and pass 4
        // (camera/masks) land with T-501/T-502.
        if let screen = s.screen {
            let rectPx = screenRect(output: s.outputSize, cropAspect: cropAspect(s.project), padding: s.project.frame.padding)
            let contentUV = cropUV(s.project.crop, view: s.view)
            drawScreen(screen, project: s.project, rectPx: rectPx, contentUV: contentUV, outputSize: s.outputSize, encoder: encoder)
            if let cursor = s.cursor, cursor.alpha > 0 {
                drawCursor(cursor, project: s.project, rectPx: rectPx, contentUV: contentUV, outputSize: s.outputSize, encoder: encoder)
            }
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
            if let texture = backgroundTexture(bg) {
                u.mode = 2
                encoder.setFragmentTexture(texture, index: 0)
            } else {
                // ponytail: wallpaper JPEGs are bundled by T-308; `image` needs the project
                // package URL, which `FrameState` doesn't carry yet. Fall back to a flat fill.
                u.mode = 0
                u.color = colorSIMD(bg.color)
            }
        }
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
    }

    private func backgroundTexture(_ bg: Background) -> MTLTexture? {
        guard bg.kind == .wallpaper else { return nil }
        let key = "wallpaper-\(bg.wallpaper)-blur\(bg.blur)"
        if let cached = backgroundCache[key] { return cached }
        guard let url = Bundle.main.url(forResource: bg.wallpaper, withExtension: "jpg", subdirectory: "Wallpapers"),
              var texture = try? textureLoader.newTexture(URL: url, options: [.SRGB: false]) else { return nil }
        if bg.blur > 0, let blurred = blurred(texture, amount: bg.blur) { texture = blurred }
        backgroundCache[key] = texture
        return texture
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
    private func drawScreen(_ texture: FrameState.Texture, project: Project, rectPx: CGRect, contentUV: SIMD4<Float>, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        var u = Uniforms()
        u.rectNDC = SIMD4(-1, 1, 1, -1)
        u.uvRect = extrapolatedUV(contentUV, contentRect: rectPx, to: outputSize)
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        u.contentSize = SIMD2(Float(rectPx.width), Float(rectPx.height))
        u.contentOffset = SIMD2(Float(rectPx.midX - outputSize.width / 2), Float(rectPx.midY - outputSize.height / 2))
        u.radius = Float(project.frame.cornerRadius * min(rectPx.width, rectPx.height))
        u.shadowAlpha = Float(project.frame.shadow)
        u.shadowBlur = Float(0.04 * min(outputSize.width, outputSize.height))
        u.mode = texture.chroma != nil ? 4 : 3   // biplanar YCbCr (real capture) vs already-RGB (fixtures)
        encoder.setFragmentTexture(texture.luma, index: 0)
        encoder.setFragmentTexture(texture.chroma ?? dummyTexture, index: 1)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
        encoder.setFragmentTexture(dummyTexture, index: 1)
    }

    // MARK: - Pass 3: cursor (SPEC §6.2 pass 3, §6.5, T-413)

    /// Positions the cursor quad in **screen space**: `cursor.x/y` (normalised source coords) are
    /// mapped through the same crop/zoom UV rect `drawScreen` used, so the cursor lands in the
    /// right place on the (possibly zoomed) content and moves/scales with it. Size = the cursor
    /// image's own point size (`hotX/hotY/scale` from `cursors/<id>.json`) × `cursor.size` ×
    /// output-pixels-per-source-pixel (crop + zoom combined) × `clickScale`; offset by the hotspot
    /// so the recorded point lands under the hotspot, not the image's centre.
    private func drawCursor(_ cursor: CursorSample, project: Project, rectPx: CGRect, contentUV: SIMD4<Float>, outputSize: CGSize, encoder: MTLRenderCommandEncoder) {
        guard let image = cursorImage(id: cursor.imageID) else { return }
        let u0 = Double(contentUV.x), v0 = Double(contentUV.y), u1 = Double(contentUV.z), v1 = Double(contentUV.w)
        guard u1 > u0, v1 > v0 else { return }

        let px = rectPx.minX + (cursor.x - u0) / (u1 - u0) * rectPx.width
        let py = rectPx.minY + (cursor.y - v0) / (v1 - v0) * rectPx.height

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

        // `hotX`/`hotY` are `NSCursor.hotSpot` scaled to pixels — AppKit's coordinate system is
        // bottom-left/y-up, but the PNG (and our `localPos`/`uv` convention above) is top-left/
        // y-down, so only Y needs flipping.
        let hotFracX = image.hotX / Double(image.texture.width)
        let hotFracY = 1 - image.hotY / Double(image.texture.height)
        let centerX = px + (0.5 - hotFracX) * drawW
        let centerY = py + (0.5 - hotFracY) * drawH

        var u = Uniforms()
        u.rectNDC = SIMD4(-1, 1, 1, -1)
        u.pixelSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        u.contentSize = SIMD2(Float(drawW), Float(drawH))
        u.contentOffset = SIMD2(Float(centerX - outputSize.width / 2), Float(centerY - outputSize.height / 2))
        u.color = SIMD4(0, 0, 0, Float(cursor.alpha))
        u.rotation = Float(cursor.rotation * .pi / 180)
        u.mode = 5
        encoder.setFragmentTexture(image.texture, index: 0)
        draw(u, encoder: encoder)
        encoder.setFragmentTexture(dummyTexture, index: 0)
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

        let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)
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

        let state = makeFrameState(model: model, outputTime: t, screen: screenTexture, camera: nil, size: outputSize)
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
