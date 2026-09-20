import AppKit
import AVFoundation
import SwiftUI
import RecorderCore

/// Disposable, labelled source media for the gallery. No user recordings or capture permissions.
@MainActor enum WorkspaceMedia {
    static func prepare(at directory: URL) async throws {
        for camera in [false, true] {
            let destination = directory.appendingPathComponent(camera ? "camera.mov" : "screen.mov")
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await writeMovie(to: temporary, camera: camera)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func writeMovie(to url: URL, camera: Bool) async throws {
        enum Failure: Error { case buffer, context, append, writer }
        let width = camera ? 320 : 960, height = camera ? 320 : 540
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        // Two source frames per second are sufficient for this labelled UI sample. Preview playback,
        // transitions and effects still use the production renderer's display clock.
        for frame in 0..<64 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? Failure.writer }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure.buffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { throw Failure.context }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                defer { NSGraphicsContext.restoreGraphicsState() }
                drawSample(camera: camera, frame: frame, size: CGSize(width: width, height: height))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else {
                throw writer.error ?? Failure.append
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.writer }
    }

    private static func drawSample(camera: Bool, frame: Int, size: CGSize) {
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = Theme.textPrimary) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color,
            ])
        }
        (camera ? Theme.layout : Theme.bgControl).setFill()
        CGRect(origin: .zero, size: size).fill()
        if camera {
            Theme.bgWindow.setFill()
            NSBezierPath(ovalIn: CGRect(x: 119, y: 160, width: 82, height: 82)).fill()
            NSBezierPath(roundedRect: CGRect(x: 67, y: 54, width: 186, height: 95), xRadius: 46, yRadius: 46).fill()
            text("Camera sample", x: 76, y: 272, size: 22, color: Theme.bgWindow)
        } else {
            text("Project walkthrough", x: 36, y: 465, size: 34)
            text("Sample recording · use the inspector to frame and emphasize this content", x: 36, y: 428, size: 16, color: Theme.textSecondary)
            let columns = ["Prepare", "Record", "Review"]
            for (index, title) in columns.enumerated() {
                let x = CGFloat(36 + index * 302)
                (index == (frame / 12) % 3 ? Theme.zoom : Theme.bgHover).setFill()
                CGRect(x: x, y: 135, width: 284, height: 254).fill()
                let ink = index == (frame / 12) % 3 ? Theme.bgWindow : Theme.textPrimary
                text(title, x: x + 20, y: 338, size: 27, color: ink)
                for line in 0..<4 {
                    ink.withAlphaComponent(0.25).setFill()
                    CGRect(x: x + 20, y: CGFloat(295 - line * 34), width: CGFloat(224 - line * 22), height: 8).fill()
                }
            }
            text(String(format: "Source time  %02d:%02d", frame / 120, frame / 2 % 60), x: 36, y: 56, size: 18, color: Theme.textSecondary)
        }
    }
}

struct WorkspaceLivePreview: NSViewRepresentable {
    let model: EditorModel
    var hoverTime: Double?
    func makeNSView(context: Context) -> WorkspacePreviewContainer { WorkspacePreviewContainer(model: model) }
    func updateNSView(_ view: WorkspacePreviewContainer, context: Context) { view.preview.hoverTime = hoverTime }
    static func dismantleNSView(_ view: WorkspacePreviewContainer, coordinator: ()) { view.model.isPlaying = false }
}

final class WorkspacePreviewContainer: NSView {
    let model: EditorModel
    let preview: PreviewView
    private let transport: NSHostingView<TransportBar>
    private let maskOverlay: MaskRectOverlay
    init(model: EditorModel) {
        self.model = model
        preview = PreviewView(model: model)
        preview.framebufferOnly = false
        transport = NSHostingView(rootView: TransportBar(model: model, preview: preview))
        maskOverlay = MaskRectOverlay(model: model)
        super.init(frame: .zero)
        preview.maskOverlayView = maskOverlay.view
        preview.onResize = { [weak maskOverlay] in maskOverlay?.layout(in: $0) }
        addSubview(preview)
        addSubview(transport)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        transport.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 44)
        preview.frame = CGRect(x: 0, y: 44, width: bounds.width, height: max(0, bounds.height - 44))
    }
}


extension WorkspacePreviewContainer {
    /// NSView.cacheDisplay omits Metal layers. Insert only the exact captured GPU frame while
    /// rasterizing the surrounding controls; the interactive gallery always uses the live view.
    func snapshotOverlay() async throws -> NSImageView {
        enum Failure: Error { case previewNotReady }
        for _ in 0..<200 {
            preview.draw(preview.bounds)
            if preview.debugHasScreenPixelBuffer && !preview.debugIsSeeking { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard preview.debugHasScreenPixelBuffer, !preview.debugIsSeeking else { throw Failure.previewNotReady }
        let frame = try await preview.captureRenderedFrame()
        let image = NSImageView(frame: preview.bounds)
        image.image = NSImage(cgImage: frame, size: preview.bounds.size)
        image.imageScaling = .scaleAxesIndependently
        preview.addSubview(image, positioned: .below, relativeTo: preview.subviews.first)
        return image
    }

    static func snapshot(in view: NSView) async throws -> NSImageView {
        enum Failure: Error { case missingPreview }
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            if let container = find(in: view) { return try await container.snapshotOverlay() }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.missingPreview
    }

    static func find(in view: NSView) -> WorkspacePreviewContainer? {
        if let preview = view as? WorkspacePreviewContainer { return preview }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
}
