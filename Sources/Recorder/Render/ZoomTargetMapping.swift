import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import RecorderCore

/// T-415: pure geometry for the manual-zoom-target overlay in `PreviewView` — where the draggable
/// accent rectangle sits, and how a dragged rectangle maps back to `Zoom.center`. Kept as one pure
/// function pair (same pattern as `CropSheet.CropMapping`) so the letterbox/padding math lives
/// exactly once and is covered by the `zoom-target` selftest's round trip.
///
/// Two nested insets separate a view point from a `Zoom.center`:
/// 1. `PreviewView`'s own viewport inside its bounds — the view's aspect may not match the output
///    canvas's, so the canvas is letterboxed inside the view (SPEC §6.1 "letterboxed").
/// 2. The frame's `padding` inside that canvas — the "screen" quad itself is inset
///    (`RecorderCore.screenRect(output:cropAspect:padding:)`, the same function `Compositor.render`'s
///    pass 2 uses for `rectPx`).
/// `contentRect(viewBounds:project:)` composes both into the one rect `Zoom.center`/`scale` are
/// expressed against (AppKit bottom-left/y-up points, matching `SelectionRectView`'s convention).
enum ZoomTargetMapping {
    /// The un-zoomed screen content rect inside a view of size `viewBounds` (bottom-left/y-up
    /// points) — `PreviewView`'s own letterboxed viewport, then the frame's padding inside it.
    static func contentRect(viewBounds: CGSize, project: Project) -> CGRect {
        let cropW = Double(project.source.pixelWidth) * project.crop.w
        let cropH = Double(project.source.pixelHeight) * project.crop.h
        let aspect = cropH > 0 ? cropW / cropH : 16.0 / 9.0
        let viewport = screenRect(output: viewBounds, cropAspect: aspect, padding: 0)
        let content = screenRect(output: viewport.size, cropAspect: aspect, padding: project.frame.padding)
        return CGRect(x: viewport.minX + content.minX, y: viewport.minY + content.minY,
                       width: content.width, height: content.height)
    }

    /// `Zoom.center`/`scale` → the target rect (view points, bottom-left origin), sized `1/scale` of
    /// `contentRect` on each axis (SPEC §6.3's viewport `[c − 0.5/scale, c + 0.5/scale]`, applied to
    /// both `x`/`y`). `center` is normalised 0…1 top-left/y-down (`NormPoint`, matching
    /// `Compositor.cropUV`'s `view.cx/cy` — 0…1 *within* `contentRect`, not the full source), so `y`
    /// is flipped into AppKit's bottom-left/y-up convention.
    static func rect(center: NormPoint, scale: Double, in contentRect: CGRect) -> CGRect {
        let s = max(scale, 0.0001)
        let w = contentRect.width / s
        let h = contentRect.height / s
        let cx = contentRect.minX + center.x * contentRect.width
        let cy = contentRect.minY + (1 - center.y) * contentRect.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Inverse of `rect(center:scale:in:)`: the target rect's centre → `Zoom.center` (`scale` is
    /// unaffected by a move drag, so it isn't recovered here).
    static func center(fromRect r: CGRect, in contentRect: CGRect) -> NormPoint {
        guard contentRect.width > 0, contentRect.height > 0 else { return NormPoint() }
        let x = (r.midX - contentRect.minX) / contentRect.width
        let y = 1 - (r.midY - contentRect.minY) / contentRect.height
        return NormPoint(x: x, y: y)
    }
}

// MARK: - Selftests `zoom-target` and `zoom-target-png` (T-415)

extension ZoomTargetMapping {
    /// (a) the mapping round trip through a letterboxed view + real frame padding — both insets the
    /// task calls out. (b) a synthetic drag on the real `PreviewView` overlay moves `zoom.center` by
    /// the expected amount, as exactly one undo step, and a drag far outside the frame stays clamped
    /// (`SelectionRectView.limit`, SPEC §6.3's viewport-never-leaves-source-frame rule).
    @MainActor
    static func runSelfTest(_ args: [String]) throws {
        // (a) round trip: a 640×360 (16:9) source, 8% padding, inside a 500×1000 (portrait —
        // pillarboxed AND letterboxed by the aspect mismatch) view.
        var project = Project(source: Source(kind: .display, pixelWidth: 640, pixelHeight: 360, scale: 1, duration: 4))
        project.frame.padding = 0.08
        let viewSize = CGSize(width: 500, height: 1000)
        let content = contentRect(viewBounds: viewSize, project: project)
        guard content.width > 0, content.height > 0, content.width <= viewSize.width, content.height <= viewSize.height else {
            throw SelfTestArgError.usage("unexpected contentRect \(content)")
        }
        let originalCenter = NormPoint(x: 0.3, y: 0.65)
        let scale = 2.5
        let targetRect = rect(center: originalCenter, scale: scale, in: content)
        guard abs(targetRect.width - content.width / scale) < 1e-9, abs(targetRect.height - content.height / scale) < 1e-9 else {
            throw SelfTestArgError.usage("unexpected target size \(targetRect) for scale \(scale) in \(content)")
        }
        let roundTripped = center(fromRect: targetRect, in: content)
        guard abs(roundTripped.x - originalCenter.x) < 1e-9, abs(roundTripped.y - originalCenter.y) < 1e-9 else {
            throw SelfTestArgError.usage("round trip mismatch: \(roundTripped) vs \(originalCenter)")
        }

        // (b) synthetic drag on a real `PreviewView`, over a fixture with a selected manual zoom —
        // same synthesized-`NSEvent` technique the `camera-drag`/`pickers` selftests use (no window,
        // no TCC; `convert(_:from:nil)` treats the event location as already being view-local).
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-zoom-target-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var fixture = Project(title: "Zoom Target",
                               source: Source(kind: .display, pixelWidth: 640, pixelHeight: 360, scale: 1, duration: 4))
        fixture.clips = [Clip(sourceStart: 0, sourceEnd: 4, speed: 1)]
        let zoom = Zoom(start: 0.5, end: 3, scale: 2, mode: .manual, center: NormPoint(x: 0.5, y: 0.5))
        fixture.zooms = [zoom]
        try fixture.save(to: tmp.appendingPathComponent("project.json"))

        let model = try loadEditorModel(package: tmp)
        model.selection = [UUID(uuidString: zoom.id)!]
        let view = PreviewView(model: model)
        view.setFrameSize(NSSize(width: 960, height: 540))

        let fixtureContent = contentRect(viewBounds: view.bounds.size, project: model.project)
        let before = rect(center: zoom.center, scale: zoom.scale, in: fixtureContent)
        guard fixtureContent.contains(CGPoint(x: before.midX, y: before.midY)) else {
            throw SelfTestArgError.usage("fixture target rect \(before) isn't inside contentRect \(fixtureContent)")
        }

        func synthEvent(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        let undoCountBefore = model.undoStepCount
        let start = CGPoint(x: before.midX, y: before.midY)
        let delta = CGPoint(x: 40, y: -25)
        let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        view.mouseDown(with: synthEvent(.leftMouseDown, start))
        view.mouseDragged(with: synthEvent(.leftMouseDragged, end))
        view.mouseUp(with: synthEvent(.leftMouseUp, end))

        guard model.undoStepCount == undoCountBefore + 1 else {
            throw SelfTestArgError.usage("drag should be exactly one undo step, got \(model.undoStepCount - undoCountBefore)")
        }
        guard let moved = model.project.zooms.first(where: { $0.id == zoom.id }) else {
            throw SelfTestArgError.usage("zoom disappeared")
        }
        let expectedCenter = center(fromRect: before.offsetBy(dx: delta.x, dy: delta.y), in: fixtureContent)
        guard abs(moved.center.x - expectedCenter.x) < 1e-6, abs(moved.center.y - expectedCenter.y) < 1e-6 else {
            throw SelfTestArgError.usage("center \(moved.center) != expected \(expectedCenter)")
        }
        guard moved.center != zoom.center else { throw SelfTestArgError.usage("drag didn't move the center") }

        model.undo()
        guard model.project.zooms.first(where: { $0.id == zoom.id })?.center == zoom.center else {
            throw SelfTestArgError.usage("undo didn't restore the original center")
        }
        model.redo()

        // Clamped: a drag far outside the frame leaves the target rect inside `fixtureContent`
        // (`SelectionRectView.limit`, wired in `PreviewView.updateZoomTargetOverlay`).
        let currentRect = rect(center: moved.center, scale: zoom.scale, in: fixtureContent)
        let farStart = CGPoint(x: currentRect.midX, y: currentRect.midY)
        let farEnd = CGPoint(x: 100_000, y: 100_000)
        view.mouseDown(with: synthEvent(.leftMouseDown, farStart))
        view.mouseDragged(with: synthEvent(.leftMouseDragged, farEnd))
        view.mouseUp(with: synthEvent(.leftMouseUp, farEnd))
        guard let clamped = model.project.zooms.first(where: { $0.id == zoom.id }) else {
            throw SelfTestArgError.usage("zoom disappeared")
        }
        let clampedRect = rect(center: clamped.center, scale: zoom.scale, in: fixtureContent)
        guard fixtureContent.insetBy(dx: -0.5, dy: -0.5).contains(clampedRect) else {
            throw SelfTestArgError.usage("clamped rect \(clampedRect) escaped contentRect \(fixtureContent)")
        }
        print("zoom-target OK: mapping round trip, drag moved center by expected amount (1 undo step), far drag clamped")
    }

    /// Renders the un-zoomed frame (same override `PreviewView.draw` applies while a manual zoom is
    /// selected) through the real Compositor decode path, then composites the accent-rect overlay
    /// (`SelectionRectView`, rendered offscreen via `cacheDisplay` — plain vector drawing, no Metal,
    /// so it captures fine unlike the MTKView itself) on top, for eyeballing against SPEC §6.6
    /// (`Read` tool). Not a correctness test.
    @MainActor
    static func runPNGSelfTest(_ args: [String]) async throws {
        guard args.count >= 2 else { throw SelfTestArgError.usage("zoom-target-png <package> <out.png>") }
        let packageURL = URL(fileURLWithPath: args[0])
        let outURL = URL(fileURLWithPath: args[1])
        let model = try loadEditorModel(package: packageURL)
        let project = model.project
        guard let zoom = project.zooms.first(where: { $0.mode == .manual }) else {
            throw SelfTestArgError.usage("fixture needs a manual zoom")
        }
        let sourceTime = (zoom.start + zoom.end) / 2
        let outputTime = model.timeMap.outputTime(atSource: sourceTime) ?? sourceTime

        let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
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
        let time = CMTime(seconds: outputTime, preferredTimescale: 600)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cont.resume() }
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            throw SelfTestArgError.usage("no decoded pixel buffer at t=\(outputTime)")
        }

        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTestArgError.usage("no Metal device") }
        let compositor = try Compositor(device: device, package: packageURL)
        let textureCache = TextureCache(device: device)
        guard let screenTexture = textureCache.texture(from: pixelBuffer) else {
            throw SelfTestArgError.usage("CVPixelBuffer -> MTLTexture failed")
        }
        let outputSize = compositor.outputSize(for: project, longEdge: 960)
        let width = Int(outputSize.width), height = Int(outputSize.height)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor),
              let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
            throw SelfTestArgError.usage("failed to set up Metal resources")
        }
        var state = makeFrameState(model: model, outputTime: outputTime, screen: screenTexture, camera: nil, size: outputSize)
        state.view = .identity   // T-415: the un-zoomed frame, same override `PreviewView.draw` applies
        state.prevView = .identity
        compositor.render(state, to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let baseImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SelfTestArgError.usage("couldn't build the base frame image")
        }

        let content = contentRect(viewBounds: outputSize, project: project)
        let selectionView = SelectionRectView(frame: CGRect(origin: .zero, size: outputSize))
        selectionView.allowsResize = false
        selectionView.minSize = CGSize(width: 1, height: 1)
        selectionView.limit = content
        selectionView.rect = rect(center: zoom.center, scale: zoom.scale, in: content)
        guard let overlayRep = selectionView.bitmapImageRepForCachingDisplay(in: selectionView.bounds) else {
            throw SelfTestArgError.usage("no overlay bitmap rep")
        }
        selectionView.cacheDisplay(in: selectionView.bounds, to: overlayRep)
        guard let overlayImage = overlayRep.cgImage else { throw SelfTestArgError.usage("no overlay CGImage") }

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw SelfTestArgError.usage("couldn't create a compositing context")
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(baseImage, in: full)
        ctx.draw(overlayImage, in: full)
        guard let composited = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestArgError.usage("couldn't composite/write the PNG")
        }
        CGImageDestinationAddImage(dest, composited, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestArgError.usage("png write failed") }
        print("wrote \(outURL.path)")
    }
}
