import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import Observation
import QuartzCore
import SwiftUI
import RecorderCore

/// Direct-manipulation video preview (SPEC §6.1, §6.2 "Preview"). Drives an `AVPlayer` over the
/// clip composition (`makeComposition`, T-305) and renders every displayed frame through the same
/// `Compositor` the exporter will use (`makeFrameState`, AC-ED-2). `draw` pulls the current pixel
/// buffer via `AVPlayerItemVideoOutput`, builds a `FrameState` and calls `Compositor.render`.
final class PreviewView: MTKView {
    let model: EditorModel

    private let compositor: Compositor
    private let textureCache: TextureCache
    private let commandQueue: MTLCommandQueue

    private var player: AVPlayer?
    private var screenOutput: AVPlayerItemVideoOutput?
    private var lastScreenPixelBuffer: CVPixelBuffer?
    private var statusObservation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?

    private var isSeeking = false
    private var pendingSeekTime: Double?
    private var lastClips: [Clip]

    init(model: EditorModel) {
        self.model = model
        self.lastClips = model.project.clips
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("no Metal device")
        }
        compositor = try! Compositor(device: device)
        textureCache = TextureCache(device: device)
        commandQueue = queue
        super.init(frame: .zero, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        rebuildComposition()
        observeProject()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { displayLink?.invalidate() }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: - Transport (SPEC §7.3; `TransportBar` below calls these)

    func togglePlayPause() {
        model.isPlaying ? pause() : setRate(1)
    }

    func stepFrame(_ deltaSeconds: Double) {
        pause()
        seek(toOutput: model.playhead + deltaSeconds)
    }

    /// Coalesced: never queues more than one pending seek (SPEC §6.2 "Scrub").
    func seek(toOutput t: Double) {
        let clamped = min(max(t, 0), max(model.timeMap.outputDuration, 0))
        model.playhead = clamped
        pendingSeekTime = clamped
        needsDisplay = true
        if !isSeeking { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let t = pendingSeekTime, let player else { pendingSeekTime = nil; return }
        pendingSeekTime = nil
        isSeeking = true
        let time = CMTime(seconds: t, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false
            self.needsDisplay = true
            if self.pendingSeekTime != nil { self.performPendingSeek() }
        }
    }

    private func setRate(_ rate: Float) {
        guard rate != 0, let player else { pause(); return }
        model.isPlaying = true
        player.rate = rate
        startDisplayLink()
    }

    private func pause() {
        player?.pause()
        model.isPlaying = false
        stopDisplayLink()
        needsDisplay = true
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let player, let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        model.playhead = t
        if item.duration.isValid, t >= item.duration.seconds - 1.0 / 60 {
            pause()
            return
        }
        needsDisplay = true
    }

    // MARK: - Keys (SPEC §7.3): Space, ←/→, ⇧←/⇧→, Home/End, J/K/L

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlayPause()                              // Space
        case 123: stepFrame(shift ? -1.0 : -1.0 / 60)            // ←
        case 124: stepFrame(shift ? 1.0 : 1.0 / 60)              // →
        case 115: pause(); seek(toOutput: 0)                     // Home
        case 119: pause(); seek(toOutput: model.timeMap.outputDuration) // End
        case 38: setRate(-1)                                     // J
        case 40: setRate(0)                                      // K
        case 37: setRate(1)                                      // L
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Composition (SPEC §6.2: rebuild on clip edits, keep playhead)

    private func observeProject() {
        withObservationTracking {
            _ = model.project
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let clips = self.model.project.clips
                if clips != self.lastClips {
                    self.lastClips = clips
                    self.rebuildComposition()
                } else {
                    self.needsDisplay = true
                }
                self.observeProject()
            }
        }
    }

    private func rebuildComposition() {
        let project = model.project
        let packageURL = model.packageURL
        let resumeSeconds = player?.currentTime().seconds ?? model.playhead
        Task { [weak self] in
            guard let self else { return }
            do {
                let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)
                await MainActor.run { self.attach(composition: composition, audioMix: audioMix, resumeSeconds: resumeSeconds) }
            } catch {
                // ponytail: a package whose screen.mov is missing/too short just shows an empty
                // preview; recording/onboarding never hands the editor a project without one.
            }
        }
    }

    private func attach(composition: AVMutableComposition, audioMix: AVAudioMix, resumeSeconds: Double) {
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        screenOutput = output
        lastScreenPixelBuffer = nil
        // ponytail: camera.mov's video output lands with the camera compositing pass (T-502/M4) —
        // nothing consumes FrameState.camera yet (Compositor doesn't draw a camera quad), and
        // AVPlayerItemVideoOutput has no per-track selection without a custom AVVideoComposition.

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.needsDisplay = true }
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
        }
        player?.seek(to: CMTime(seconds: resumeSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - Draw (SPEC §6.2 "Preview")

    override func draw(_ dirtyRect: NSRect) {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let project = model.project
        let unit = compositor.outputSize(for: project, longEdge: 1000)   // aspect only
        let aspect = unit.width / unit.height
        let viewportRect = screenRect(output: drawableSize, cropAspect: aspect, padding: 0)

        let screenTexture = currentScreenPixelBuffer().flatMap { textureCache.texture(from: $0) }
        let state = makeFrameState(model: model, outputTime: model.playhead, screen: screenTexture, camera: nil, size: viewportRect.size)

        compositor.render(state, to: drawable.texture, commandBuffer: commandBuffer, viewport: viewportRect)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// `copyPixelBuffer(forItemTime:)`, keeping the last buffer when a new one isn't ready (SPEC
    /// §6.2: "holds last frame for VFR gaps").
    private func currentScreenPixelBuffer() -> CVPixelBuffer? {
        guard let output = screenOutput else { return lastScreenPixelBuffer }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastScreenPixelBuffer = buffer
        }
        return lastScreenPixelBuffer
    }
}

// MARK: - Transport bar (SwiftUI, under the preview — SPEC §6.1 mockup)

/// `⏮ ◀❙ ▶ ❙▶ ⏭   00:12.40 / 01:33.00` — triggers `PreviewView`'s transport methods and mirrors
/// `model`'s playhead/duration (`EditorModel` is `@Observable`; reading its properties here is
/// enough for SwiftUI to re-render on change).
struct TransportBar: View {
    let model: EditorModel
    let preview: PreviewView

    var body: some View {
        HStack(spacing: 20) {
            transportButton("backward.end.fill") { preview.seek(toOutput: 0) }
            transportButton("backward.frame.fill") { preview.stepFrame(-1.0 / 60) }
            transportButton(model.isPlaying ? "pause.fill" : "play.fill") { preview.togglePlayPause() }
            transportButton("forward.frame.fill") { preview.stepFrame(1.0 / 60) }
            transportButton("forward.end.fill") { preview.seek(toOutput: model.timeMap.outputDuration) }
            Text("\(Self.timecode(model.playhead)) / \(Self.timecode(model.timeMap.outputDuration))")
                .font(Font(Theme.timecodeFont(13)))
                .foregroundStyle(Theme.textPrimaryColor)
        }
        .padding(.vertical, 10)
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.textPrimaryColor)
        }
        .buttonStyle(.plain)
    }

    static func timecode(_ t: Double) -> String {
        let clamped = max(0, t)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        let hundredths = Int(((clamped - clamped.rounded(.down)) * 100).rounded())
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}
