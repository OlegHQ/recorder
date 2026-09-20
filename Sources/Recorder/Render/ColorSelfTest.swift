import AppKit
import AVFoundation
import CoreImage
import Metal
import RecorderCore
import ScreenCaptureKit

/// Real GPU/codec regression: asymmetric sRGB swatches, P3 conversion, H.264,
/// HEVC and GIF. Optional --capture checks an actual window through ScreenCaptureKit.
enum ColorSelfTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let width = 192, height = 128
    static let swatches: [[UInt8]] = [[0, 0, 0], [128, 128, 128], [255, 255, 255],
                                     [210, 60, 40], [40, 180, 80], [50, 90, 210]]

    @MainActor static func run(_ args: [String]) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure(description: "Metal device required for export validation")
        }
        let context = CIContext(mtlDevice: device)
        let compositor = try Compositor(device: device)
        let cache = TextureCache(device: device)
        var project = Project(title: "Color regression", source: Source(kind: .display,
            pixelWidth: width, pixelHeight: height, scale: 1, duration: 0.5),
            clips: [Clip(sourceStart: 0, sourceEnd: 0.5)])
        project.frame.enabled = false
        project.background = Background(kind: .color, color: "#000000")

        func render(_ buffer: CVPixelBuffer) async throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let target = device.makeTexture(descriptor: descriptor),
                  let command = queue.makeCommandBuffer(), let texture = cache.texture(from: buffer) else {
                throw Failure(description: "render resources unavailable")
            }
            let state = FrameState(outputSize: CGSize(width: width, height: height), screen: texture, project: project)
            compositor.render(state, to: target, commandBuffer: command)
            try await command.commitAndWait()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&pixels, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }

        let source = try buffer(colorSpace: VideoColor.space)
        try check(try await render(source), width: width, height: height, expected: swatches, tolerance: 2, label: "sRGB GPU preview")
        for name in [CGColorSpace.displayP3, CGColorSpace.itur_709] {
            let space = CGColorSpace(name: name)!
            let expected = swatches.map { rgb -> [UInt8] in
                let color = CGColor(colorSpace: space, components: rgb.map { CGFloat($0) / 255 } + [1])!
                    .converted(to: VideoColor.space, intent: .relativeColorimetric, options: nil)!
                return color.components!.prefix(3).map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
            }
            try check(try await render(buffer(colorSpace: space)), width: width, height: height,
                      expected: expected, tolerance: 3, label: "\(name) → sRGB GPU preview")
        }

        if args.contains("--capture") {
            let image = context.createCGImage(CIImage(cvPixelBuffer: source), from: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8, colorSpace: VideoColor.space)!
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = NSImageView(frame: window.contentView!.bounds)
            view.image = NSImage(cgImage: image, size: view.bounds.size)
            window.contentView = view
            window.level = .floating
            window.orderFrontRegardless()
            window.displayIfNeeded()
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw Failure(description: "capture fixture window unavailable")
            }
            let config = CaptureTarget.window(target).configuration(settings: RecordingSettings.shared)
            config.width = width; config.height = height
            config.captureMicrophone = false; config.capturesAudio = false
            let sample = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            guard let captured = CMSampleBufferGetImageBuffer(sample) else { throw Failure(description: "no capture buffer") }
            try check(try await render(captured), width: width, height: height,
                      expected: swatches, tolerance: 5, label: "live screen capture → preview")
        }

        let movie = directory.appendingPathComponent("screen.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColor.properties])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<15 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error! }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(source, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        try project.save(to: directory.appendingPathComponent("project.json"))
        let model = EditorModel(packageURL: directory, project: project, events: EventLog())

        for settings in [ExportSettings(shortEdge: height, quality: .studio, codec: .h264),
                         ExportSettings(shortEdge: height, quality: .studio, codec: .hevc),
                         ExportSettings(format: .gif, fps: 10)] {
            let url = directory.appendingPathComponent("\(settings.codec.rawValue).\(settings.format.rawValue)")
            try await Exporter(model: model, settings: settings, destination: url).run()
            let image: CGImage
            if settings.format == .gif {
                guard let gif = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(gif) == 5,
                      let frame = CGImageSourceCreateImageAtIndex(gif, 0, nil) else { throw Failure(description: "invalid GIF frames") }
                image = frame
            } else {
                let asset = AVURLAsset(url: url)
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let description = try await track.load(.formatDescriptions).first!
                let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                guard transfer == (kCVImageBufferTransferFunction_sRGB as String) else {
                    throw Failure(description: "wrong export transfer function: \(transfer ?? "missing")")
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                reader.add(output)
                guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                      let decoded = CMSampleBufferGetImageBuffer(sample) else { throw Failure(description: "export did not decode") }
                let ciImage = CIImage(cvPixelBuffer: decoded)
                image = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: VideoColor.space)!
                reader.cancelReading()
            }
            let pixels = imageBytes(image)
            try check(pixels, width: image.width, height: image.height, expected: swatches, tolerance: 8,
                      label: "\(settings.codec.rawValue) \(settings.format.rawValue) encode/decode")
        }
    }

    static func buffer(colorSpace: CGColorSpace) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw Failure(description: "no pixel buffer") }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = swatches[(y / 64) * 3 + x / 64]
                let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                data[i] = rgb[2]; data[i + 1] = rgb[1]; data[i + 2] = rgb[0]; data[i + 3] = 255
            }
        }
        return buffer
    }

    static func imageBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: VideoColor.space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func check(_ pixels: [UInt8], width: Int, height: Int, expected: [[UInt8]], tolerance: Int, label: String) throws {
        var maximum = 0
        for index in 0..<6 {
            let x = (index % 3 * 2 + 1) * width / 6
            let y = (index / 3 * 2 + 1) * height / 4
            let offset = (y * width + x) * 4
            let rgb = [pixels[offset + 2], pixels[offset + 1], pixels[offset]]
            let delta = zip(rgb, expected[index]).map { abs(Int($0) - Int($1)) }.max()!
            maximum = max(maximum, delta)
            guard delta <= tolerance else { throw Failure(description: "\(label) swatch \(index): \(rgb), expected \(expected[index]), delta \(delta)") }
        }
        print("\(label): maximum channel error \(maximum)/255")
    }
}
