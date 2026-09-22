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
    /// T-504 selftest seam: the live item's identity/`audioMix`, so `audio-mix` can assert a
    /// volume-only edit swaps `audioMix` without replacing the `AVPlayerItem` (no composition
    /// rebuild). Not `private` — read-only, used only by `AudioMixSelfTest.swift`.
    var currentItemForTest: AVPlayerItem? { player?.currentItem }
    private var screenOutput: AVPlayerItemVideoOutput?
    private var lastScreenPixelBuffer: CVPixelBuffer?
    private var statusObservation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?

    // T-502: camera.mov decode. `AVPlayerItemVideoOutput` has no per-track selection, so the camera
    // gets its own player over an `isolateTrack`-built single-track composition, kept in lockstep
    // with `player` (every seek/rate change mirrored) — see `FrameSource.isolateTrack`.
    private var cameraPlayer: AVPlayer?
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var lastCameraPixelBuffer: CVPixelBuffer?

    private var isSeeking = false
    private var pendingSeekTime: Double?
    private var lastCameraClips: [CameraClip] = []
    private var lastClips: [Clip]
    private var lastAudio: Audio

    // T-504: the live item's mic/system composition tracks, kept so volumes/mutes can rebuild just
    // the `AVAudioMix` (`refreshAudioMix`) without a composition rebuild/playback hiccup.
    private var liveMicTrack: AVMutableCompositionTrack?
    private var liveSystemTrack: AVMutableCompositionTrack?
    // T-504: SOURCE time of the last playback tick's click-sound check — reset on every play start
    // so a big seek/scrub never floods stale clicks (see `playClickSoundIfCrossed`).
    private var lastClickCheckSourceTime: Double?

    /// Bounds the "no frame yet" redraw retry below (SPEC §6.2: "paused always shows a frame").
    private var pendingFrameRetries = 0
    private static let maxFrameRetries = 30
    private var cameraDragActive = false
    private var cameraDragStart = CGPoint.zero
    private var cameraDragPosition = NormPoint(x: 0, y: 0)
    private var cameraDragLayoutID: String?
    private var cameraDidDrag = false

    // T-415: manual-zoom-target overlay — a `SelectionRectView` subview covering the whole preview,
    // shown only while a `.manual` zoom is selected (SPEC §6.6 "with a manual zoom selected, a
    // rectangle overlay shows the zoom target and can be dragged"). `PreviewView` overrides `hitTest`
    // (below) to keep routing every mouse event through its own `mouseDown`/`mouseDragged`/`mouseUp`
    // (same pattern as the camera-bubble drag) and forwards to `zoomTargetView` by calling its
    // handlers directly — that gives a `mouseUp`-time drag-end signal (`isDragging` just before the
    // forwarded call) without adding a second mouse-handling mechanism or subclassing
    // `SelectionRectView` (`final`).
    private let zoomTargetView = SelectionRectView(frame: .zero)
    private var zoomTargetContentRect: CGRect = .zero
    private var zoomTargetGestureActive = false

    // T-601: the mask-rect overlay — owned/created by `EditorWindowController` (`MaskRectOverlay`'s
    // own doc comment: "PreviewView belongs to another lane"), mounted here through this one settable
    // subview so its mouse events go through the same single dispatch point as `zoomTargetView`/the
    // camera-bubble drag below. Selection is exclusive to one lane (`TimelineView.selectBlock`), so
    // at most one of `zoomTargetView`/`maskOverlayView` is ever visible — they never fight over a
    // mouse event.
    var maskOverlayView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let maskOverlayView else { return }
            maskOverlayView.frame = bounds
            maskOverlayView.autoresizingMask = [.width, .height]
            addSubview(maskOverlayView)
        }
    }
    /// Fired from `setFrameSize` so the coordinator can keep `MaskRectOverlay`'s own geometry
    /// (`imageRect`/`selectionView.limit`) in sync — mirrors what `updateZoomTargetOverlay` already
    /// does for the zoom-target overlay, which this view owns outright.
    var onResize: ((CGSize) -> Void)?

    private let loadingLabel = NSTextField(wrappingLabelWithString: "Loading preview…")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let statusStack = NSStackView()
    private lazy var statusAction = TechAppKit.button("Retry preview", compact: true,
        target: self, action: #selector(recoverPreview))
    private var compositionRevision = 0


    init(model: EditorModel, preparedCompositor: Compositor? = nil) {
        self.model = model
        self.lastClips = model.project.clips
        self.lastAudio = model.project.audio
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("no Metal device")
        }
        compositor = try! preparedCompositor ?? Compositor(device: device, package: model.packageURL)
        textureCache = TextureCache(device: device)
        commandQueue = queue
        super.init(frame: .zero, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        colorspace = VideoColor.space

        zoomTargetView.allowsResize = false
        zoomTargetView.minSize = CGSize(width: 1, height: 1)
        zoomTargetView.isHidden = true
        zoomTargetView.autoresizingMask = [.width, .height]
        zoomTargetView.onChange = { [weak self] r in self?.zoomTargetRectChanged(r) }
        zoomTargetView.onKeyboardEditingChanged = { [weak self] editing in
            guard let self else { return }
            if editing {
                guard self.selectedManualZoom() != nil else { return }
                self.model.beginGesture()
                self.zoomTargetGestureActive = true
            } else { self.zoomTargetDragEnded() }
        }
        addSubview(zoomTargetView)

        loadingLabel.font = Theme.headingFont(24)
        loadingLabel.textColor = Theme.textPrimary
        loadingLabel.alignment = .center
        statusDetail.font = Theme.labelFont
        statusDetail.textColor = Theme.textSecondary
        statusDetail.alignment = .center
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 12
        statusStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        statusStack.wantsLayer = true
        statusStack.layer?.backgroundColor = Theme.bgPanel.cgColor
        statusStack.layer?.borderColor = Theme.stroke.cgColor
        statusStack.layer?.borderWidth = 1
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        for item in [loadingLabel, statusDetail, statusAction] { statusStack.addArrangedSubview(item) }
        statusAction.isHidden = true
        addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            statusStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualTo: statusStack.widthAnchor, constant: -40),
            statusDetail.widthAnchor.constraint(lessThanOrEqualTo: statusStack.widthAnchor, constant: -40),
        ])
        rebuildComposition()
        observeProject()
        observeSelection()
        observePlayhead()
        observePlayback()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { displayLink?.invalidate() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - T-610 state snapshot accessors (read-only; several fields the dump needs are private)

    var debugPlayerStatus: String {
        switch player?.currentItem?.status {
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        case .unknown, .none: return "unknown"
        @unknown default: return "unknown"
        }
    }
    var debugRate: Float { player?.rate ?? 0 }
    var debugCurrentTime: Double { player?.currentTime().seconds ?? 0 }
    var debugHasScreenPixelBuffer: Bool { lastScreenPixelBuffer != nil }
    var debugPendingFrameRetries: Int { pendingFrameRetries }
    var debugIsSeeking: Bool { isSeeking }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        updateZoomTargetOverlay()
        onResize?(newSize)
    }

    // MARK: - Transport (SPEC §7.3; `TransportBar` below calls these)

    /// AC-TL-7 (split-mode hover): OUTPUT seconds. Non-nil + paused ⇒ the preview shows that frame
    /// (a coalesced, zero-tolerance seek — same mechanism `seek(toOutput:)` uses) WITHOUT moving
    /// `model.playhead`; `nil` seeks back to the playhead frame. Ignored while playing (`draw`'s
    /// `displayTime` falls back to `model.playhead` then) — a live playhead already drives the
    /// player, and split mode only hovers a paused timeline. One-line coordinator hook:
    /// `timeline.onHoverTime = { [weak preview] in preview?.hoverTime = $0 }`.
    var hoverTime: Double? {
        didSet {
            guard hoverTime != oldValue else { return }
            needsDisplay = true
            guard !model.isPlaying else { return }
            performSeek(to: hoverTime ?? model.playhead)
        }
    }

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
        performSeek(to: clamped)
    }

    private func performSeek(to t: Double) {
        let clamped = min(max(t, 0), max(model.timeMap.outputDuration, 0))
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
        // Best-effort: the camera bubble only needs to be roughly in sync, not gate the main seek's
        // completion callback (AC-ED-2 parity is graded on the screen path; export reads camera
        // frame-accurately off its own reader, T-505).
        cameraPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func setRate(_ rate: Float) {
        guard rate != 0, let player else { pause(); return }
        // Timeline scrubs/clicks only move `model.playhead`, and a lingering hover seek leaves the
        // player elsewhere too — so play always resumes from the playhead (restart if parked at the end).
        if model.playhead >= model.timeMap.outputDuration - 1.0 / 60 { model.playhead = 0 }
        if hoverTime != nil || abs(player.currentTime().seconds - model.playhead) > 1.0 / 120 { performSeek(to: model.playhead) }
        lastClickCheckSourceTime = model.timeMap.sourceTime(atOutput: model.playhead)
        model.isPlaying = true
        player.rate = rate
        cameraPlayer?.rate = rate
        startDisplayLink()
    }

    private func pause() {
        player?.pause()
        cameraPlayer?.pause()
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
        guard !isSeeking, let player, let item = player.currentItem else { return }  // mid-seek time is stale
        let t = player.currentTime().seconds
        playClickSoundIfCrossed(outputTime: t)
        model.advancePlayback(to: t)
        if !model.isPlaying { pause(); return }
        if item.duration.isValid, t >= item.duration.seconds - 1.0 / 60 {
            pause()
            return
        }
        needsDisplay = true
    }

    /// T-504: "Mouse click sound" — preview plays it live via `NSSound` at each left `.down` event
    /// crossed during playback (export mixes it into the exported audio instead, `Exporter`'s
    /// `addClickTrack`). Instantiated fresh per play (cheap: `byReference: true` just holds the
    /// bundled URL) so back-to-back clicks each get their own playback instead of fighting over one
    /// shared, possibly-still-playing `NSSound`.
    private static let clickSoundURL = Bundle.main.url(forResource: "click", withExtension: "caf")

    private func playClickSoundIfCrossed(outputTime t: Double) {
        guard model.project.cursor.clickSound, let url = Self.clickSoundURL else { return }
        let sourceNow = model.timeMap.sourceTime(atOutput: t)
        defer { lastClickCheckSourceTime = sourceNow }
        guard let last = lastClickCheckSourceTime, sourceNow > last else { return }
        guard model.events.clicks().contains(where: { $0.t > last && $0.t <= sourceNow }) else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }

    // MARK: - Keys (SPEC §7.3): Space, ←/→, ⇧←/⇧→, Home/End, J/K/L

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53:
            if cameraDragActive { cancelOperation(nil) } else { super.keyDown(with: event) }
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
                self.updateZoomTargetOverlay()
                let clips = self.model.project.clips
                let audio = self.model.project.audio
                if clips != self.lastClips || self.model.project.cameraClips != self.lastCameraClips {
                    self.lastCameraClips = self.model.project.cameraClips
                    self.lastClips = clips
                    self.lastAudio = audio
                    self.rebuildComposition()
                } else {
                    // T-504: volumes/mutes → rebuild ONLY the `AVAudioMix` on the live item, not a
                    // full composition rebuild (no playback hiccup).
                    if audio != self.lastAudio {
                        self.lastAudio = audio
                        self.refreshAudioMix()
                    }
                    self.needsDisplay = true
                }
                self.observeProject()
            }
        }
    }

    // T-415: `model.selection` lives outside `project` (it's UI state, not saved), so it needs its
    // own `withObservationTracking` — same one-more-registration-per-fire pattern as `observeProject`.
    private func observeSelection() {
        withObservationTracking {
            _ = model.selection
            _ = model.inspectorShowsProject
            _ = model.previewShowsResult
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateZoomTargetOverlay()
                self.needsDisplay = true
                self.observeSelection()
            }
        }
    }

    // Timeline clicks/scrubs (and anything else) only write `model.playhead`; while paused the
    // player follows it here, so every writer gets the seek without calling `seek(toOutput:)`.
    private func observePlayback() {
        withObservationTracking {
            _ = model.isPlaying
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.window != nil {
                    if self.model.isPlaying {
                        // Keep an existing J/K/L playback rate; start only when currently paused.
                        if self.model.previewPlaybackEnd != nil || self.player?.rate == 0 { self.setRate(1) }
                    } else { self.pause() }
                }
                self.observePlayback()
            }
        }
    }

    private func observePlayhead() {
        withObservationTracking {
            _ = model.playhead
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.model.isPlaying, self.hoverTime == nil { self.performSeek(to: self.model.playhead) }
                self.observePlayhead()
            }
        }
    }

    @objc private func recoverPreview() {
        if model.project.clips.isEmpty { model.undo() }
        else { rebuildComposition() }
    }

    private func showPreviewStatus(_ title: String, detail: String, action: String? = nil) {
        loadingLabel.stringValue = title
        statusDetail.stringValue = detail
        statusAction.title = action ?? ""
        statusAction.isHidden = action == nil
        statusStack.isHidden = false
    }

    private func clearPreviewMedia() {
        pause()
        statusObservation = nil
        player = nil
        cameraPlayer = nil
        screenOutput = nil
        cameraOutput = nil
        lastScreenPixelBuffer = nil
        lastCameraPixelBuffer = nil
        needsDisplay = true
    }

    private func showUnavailablePreview() {
        clearPreviewMedia()
        showPreviewStatus("Preview unavailable", detail: "Check the recording’s media files, then retry.", action: "Retry preview")
    }

    private func rebuildComposition() {
        compositionRevision += 1
        let revision = compositionRevision
        let project = model.project
        if project.clips.isEmpty {
            clearPreviewMedia()
            showPreviewStatus("No video clips", detail: "The recording has no video intervals in this edit.",
                              action: model.undoName.map { "Undo " + $0 })
            return
        }
        showPreviewStatus("Loading preview…", detail: "Preparing the current edit.")
        let packageURL = model.packageURL
        let resumeSeconds = player?.currentTime().seconds ?? model.playhead
        Task { [weak self] in
            guard let self else { return }
            do {
                let (composition, audioMix, micTrack, systemTrack) = try await makeComposition(package: packageURL, project: project)
                await MainActor.run {
                    guard self.compositionRevision == revision else { return }
                    self.liveMicTrack = micTrack
                    self.liveSystemTrack = systemTrack
                    self.attach(composition: composition, audioMix: audioMix, resumeSeconds: resumeSeconds)
                }
            } catch {
                await MainActor.run {
                    guard self.compositionRevision == revision else { return }
                    self.showUnavailablePreview()
                }
            }
        }
    }

    /// T-504: volumes/mutes changed but `clips` didn't — swap the live item's `AVAudioMix` for a
    /// freshly built one over the SAME mic/system tracks (`makeAudioMix`, `FrameSource.swift`).
    /// `AVPlayerItem.audioMix` takes effect live, no `replaceCurrentItem`/decode restart.
    private func refreshAudioMix() {
        guard let item = player?.currentItem else { return }
        item.audioMix = makeAudioMix(project: model.project, micTrack: liveMicTrack, systemTrack: liveSystemTrack)
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
        pendingFrameRetries = 0

        attachCamera(from: composition)

        // A freshly attached item has no decoded frame yet — `copyPixelBuffer` returns nil until
        // one exists, so drawing right away (or on a bare `readyToPlay`, which doesn't guarantee the
        // output has a buffer for the resume time) shows only the background, with the screen pass
        // skipped entirely (T-306 fix: "paused at open" showed no screen quad). Only a *completed*
        // zero-tolerance seek guarantees the output has a frame ready to redraw with.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.player?.currentItem === item else { return }
                if item.status == .readyToPlay { self.seekToShowCurrentFrame(resumeSeconds: resumeSeconds) }
                if item.status == .failed { self.showUnavailablePreview() }
            }
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
        }
        needsDisplay = true
    }

    private func seekToShowCurrentFrame(resumeSeconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.needsDisplay = true
        }
        cameraPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// T-502: `composition`'s video track[1] (camera), isolated into its own single-track
    /// composition/player since `AVPlayerItemVideoOutput` can't select a track out of a shared item
    /// (`FrameSource.isolateTrack`). No-op when the project has no second video track.
    private func attachCamera(from composition: AVMutableComposition) {
        let videoTracks = composition.tracks(withMediaType: .video)
        guard videoTracks.count > 1 else {
            cameraPlayer = nil; cameraOutput = nil; lastCameraPixelBuffer = nil
            return
        }
        let cameraComposition = isolateTrack(videoTracks[1], duration: composition.duration)
        let item = AVPlayerItem(asset: cameraComposition)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        cameraOutput = output
        lastCameraPixelBuffer = nil
        if let cameraPlayer {
            cameraPlayer.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            newPlayer.volume = 0
            cameraPlayer = newPlayer
        }
    }

    // MARK: - Draw (SPEC §6.2 "Preview")

    override func draw(_ dirtyRect: NSRect) { _ = drawFrame() }

    private func drawFrame(capture: ((MTLTexture, MTLCommandBuffer) -> Void)? = nil) -> Bool {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let project = model.project
        let unit = compositor.outputSize(for: project, longEdge: 1000)   // aspect only
        let aspect = unit.width / unit.height
        let viewportRect = screenRect(output: drawableSize, cropAspect: aspect, padding: 0)

        let pixelBuffer = currentScreenPixelBuffer()
        if pixelBuffer != nil {
            statusStack.isHidden = true
            pendingFrameRetries = 0
        } else if !model.isPlaying {
            // `copyPixelBuffer(forItemTime:)` can still be nil for a beat right after a seek
            // completes — the item's decode pipeline hasn't caught up yet even though the seek
            // itself is done (T-306: "paused always shows a frame"). Nothing else re-triggers a
            // draw once we're paused and idle, so without this the screen quad stays missing
            // forever instead of just for the one dropped frame. Bounded so a package that really
            // has no screen video (see `rebuildComposition`'s catch) doesn't retry forever.
            scheduleFrameRetryIfNeeded()
        }
        let screenTexture = pixelBuffer.flatMap { textureCache.texture(from: $0) }
        let cameraTexture = currentCameraPixelBuffer().flatMap { textureCache.texture(from: $0) }
        // AC-TL-7: while paused, a non-nil `hoverTime` overrides what's DISPLAYED (`FrameState` is
        // still a pure function of this one output time — `model.playhead` itself is untouched).
        let displayTime = (!model.isPlaying ? hoverTime : nil) ?? model.playhead
        var state = makeFrameState(model: model, outputTime: displayTime, screen: screenTexture, camera: cameraTexture, size: viewportRect.size)

        // T-415/T-601: a `.manual` zoom OR a mask selected ⇒ show the UN-zoomed frame (SPEC §6.6) so
        // whichever overlay is live (`zoomTargetView`/`maskOverlayView`) is drawn against the same
        // un-zoomed content its rect is positioned over (`ZoomTargetMapping.contentRect` assumes no
        // zoom is applied). Preview-only override — `makeFrameState`/export are untouched.
        if selectedManualZoom() != nil || isMaskSelected() {
            state.view = .identity
            state.prevView = .identity
        }
        // Region editing must reveal the pixels being covered so its edges can be aligned.
        if isMaskSelected(), let id = model.selection.first {
            state.project.masks.removeAll { $0.id == id.uuidString }
        }

        compositor.render(state, to: drawable.texture, commandBuffer: commandBuffer, viewport: viewportRect)
        capture?(drawable.texture, commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    /// Copies the actual rendered drawable for gallery verification. Callers opt into readable
    /// drawables before presentation; ordinary editor playback keeps framebufferOnly enabled.
    func captureRenderedFrame() async throws -> CGImage {
        enum Failure: Error { case unavailable, copy, render, image }
        guard !framebufferOnly else { throw Failure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let rendered = drawFrame { texture, buffer in
                let width = texture.width, height = texture.height
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared
                guard let copy = texture.device.makeTexture(descriptor: descriptor),
                      let blit = buffer.makeBlitCommandEncoder() else {
                    continuation.resume(throwing: Failure.copy); return
                }
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: width, height: height, depth: 1), to: copy,
                          destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.endEncoding()
                buffer.addCompletedHandler { completed in
                    guard completed.status == .completed else {
                        continuation.resume(throwing: Failure.render); return
                    }
                    var bytes = [UInt8](repeating: 0, count: width * height * 4)
                    copy.getBytes(&bytes, bytesPerRow: width * 4,
                                  from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: VideoColor.space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                    else { continuation.resume(throwing: Failure.image); return }
                    continuation.resume(returning: image)
                }
            }
            if !rendered { continuation.resume(throwing: Failure.unavailable) }
        }
    }

    private func scheduleFrameRetryIfNeeded() {
        guard screenOutput != nil, pendingFrameRetries < Self.maxFrameRetries else { return }
        pendingFrameRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.needsDisplay = true
        }
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

    private func currentCameraPixelBuffer() -> CVPixelBuffer? {
        guard let output = cameraOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastCameraPixelBuffer = buffer
        }
        return lastCameraPixelBuffer
    }

    // MARK: - Manual zoom target (SPEC §6.6, T-415)

    /// The selected zoom, if it's the only selected block and its mode is `.manual` — the one state
    /// that shows the target overlay (SPEC §6.6: "with a manual zoom selected…").
    private func selectedManualZoom() -> Zoom? {
        guard !model.inspectorShowsProject, !model.previewShowsResult, model.selection.count == 1, let id = model.selection.first else { return nil }
        guard let zoom = model.project.zooms.first(where: { $0.id == id.uuidString }) else { return nil }
        return zoom.mode == .manual ? zoom : nil
    }

    /// T-601: mirrors `selectedManualZoom()` above for the mask-rect overlay's own selection test
    /// (`MaskRectOverlay.selectedMaskID`) — kept here too since `draw()`'s un-zoomed override needs
    /// it and `MaskRectOverlay` doesn't touch `PreviewView`'s drawing at all.
    private func isMaskSelected() -> Bool {
        guard !model.inspectorShowsProject, !model.previewShowsResult, model.selection.count == 1, let id = model.selection.first else { return false }
        return model.project.masks.contains(where: { $0.id == id.uuidString })
    }

    private func updateZoomTargetOverlay() {
        guard let zoom = selectedManualZoom() else {
            zoomTargetView.isHidden = true
            return
        }
        zoomTargetView.isHidden = false
        zoomTargetView.frame = bounds
        let content = ZoomTargetMapping.contentRect(viewBounds: bounds.size, project: model.project)
        zoomTargetContentRect = content
        zoomTargetView.limit = content
        zoomTargetView.aspect = content.height > 0 ? content.width / content.height : nil
        // Don't fight the mouse mid-drag (same guard `CropSheet`/`AreaSelectionOverlay` use for their
        // own field-commit races) — `zoomTargetRectChanged` is already updating `zoom.center` live.
        if !zoomTargetView.isDragging {
            zoomTargetView.rect = ZoomTargetMapping.rect(center: zoom.center, scale: zoom.scale, in: content)
        }
        needsDisplay = true
    }

    /// `zoomTargetView.onChange`: fires on every rect mutation, including `updateZoomTargetOverlay`'s
    /// own programmatic assignment above — only a real drag (bracketed by `beginGesture`/
    /// `commitGesture` in `zoomTargetDragEnded`) turns a change into a `Project` edit.
    private func zoomTargetRectChanged(_ r: CGRect) {
        guard let zoom = selectedManualZoom() else { return }
        if zoomTargetView.isDragging, !zoomTargetGestureActive {
            model.beginGesture()
            zoomTargetGestureActive = true
        }
        guard zoomTargetGestureActive else { return }
        let center = ZoomTargetMapping.center(fromRect: r, in: zoomTargetContentRect)
        let zoomID = zoom.id
        model.update { project in
            guard let idx = project.zooms.firstIndex(where: { $0.id == zoomID }) else { return }
            project.zooms[idx].center = center
        }
        needsDisplay = true
    }

    private func zoomTargetDragEnded() {
        guard zoomTargetGestureActive else { return }
        zoomTargetGestureActive = false
        model.commitGesture("Move Zoom Target")
    }

    // MARK: - Camera drag (SPEC §6.6 Camera tab, T-502)

    /// This view isn't flipped (AppKit default, bottom-left origin/y-up) — mouse points are
    /// converted straight from the event, and the camera-bubble geometry below is expressed in that
    /// same convention (unlike `Compositor`'s own top-left/y-down canvas space).
    private func viewportRectInBounds() -> CGRect {
        let unit = compositor.outputSize(for: model.project, longEdge: 1000)   // aspect only
        let aspect = unit.width / unit.height
        return screenRect(output: bounds.size, cropAspect: aspect, padding: 0)
    }

    private func cameraBubbleRectInBounds() -> CGRect {
        let viewport = viewportRectInBounds()
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        guard model.project.cameraClips.contains(where: { time >= $0.start && time < $0.end }) else { return .zero }
        let mix = layoutMix(layouts: model.project.layouts, atSource: time)
        if mix.kind == .hidden && mix.amount >= 0.99 { return .zero }
        let local = cameraOverlayRect(project: model.project, output: viewport.size, atSource: time,
                                      viewScale: selectedManualZoom() != nil || isMaskSelected() ? 1 : model.cameraPath.sample(atSource: time).scale)
        return CGRect(x: viewport.minX + local.minX, y: viewport.minY + viewport.height - local.maxY,
                      width: local.width, height: local.height)
    }

    // T-415: never let AppKit's default hit-testing hand events straight to `zoomTargetView` (it
    // would bypass everything below) — `self` stays the one dispatch point, same as the camera
    // bubble, which has no subview of its own at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !statusStack.isHidden, let hit = statusStack.hitTest(local) { return hit }
        return self
    }

    override func cancelOperation(_ sender: Any?) {
        guard cameraDragActive else { super.cancelOperation(sender); return }
        if cameraDidDrag { model.cancelGesture() }
        cameraDragActive = false
        cameraDidDrag = false
    }

    override func mouseDown(with event: NSEvent) {
        if let maskOverlayView, !maskOverlayView.isHidden {
            cameraDragActive = false
            maskOverlayView.mouseDown(with: event)
            return // The rectangle retains first responder for arrow nudges and Escape rollback.
        }
        let p = convert(event.locationInWindow, from: nil)
        if model.project.source.hasCamera, cameraBubbleRectInBounds().contains(p) {
            pause()
            cameraDragActive = true
            cameraDidDrag = false
            cameraDragStart = p
            let time = model.timeMap.sourceTime(atOutput: model.playhead)
            let block = model.project.layouts.first { $0.kind != .settings && time >= $0.start && time < $0.end }
            cameraDragLayoutID = block?.kind == .bubble ? block?.id : nil
            let camera = block?.kind == .bubble ? (block?.camera ?? model.project.camera) : model.project.camera
            cameraDragPosition = camera.position ?? NormPoint(
                x: camera.corner == .topLeft || camera.corner == .bottomLeft ? 0 : 1,
                y: camera.corner == .topLeft || camera.corner == .topRight ? 0 : 1)
            model.selectedClip = nil
            model.selection = block.flatMap { UUID(uuidString: $0.id) }.map { [$0] } ?? []
            model.cameraInspectorRequested = true
            window?.makeFirstResponder(self)
        } else {
            cameraDragActive = false
            guard zoomTargetView.isHidden else {
                zoomTargetView.mouseDown(with: event)
                window?.makeFirstResponder(self)   // keep Space/←/→ (SPEC §7.3) on the preview itself
                return
            }
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard cameraDragActive || zoomTargetView.isHidden else { zoomTargetView.mouseDragged(with: event); return }
        if !cameraDragActive, let maskOverlayView, !maskOverlayView.isHidden { maskOverlayView.mouseDragged(with: event); return }
        guard cameraDragActive else { super.mouseDragged(with: event); return }
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        if model.project.layouts.contains(where: { $0.kind != .bubble && $0.kind != .settings && time >= $0.start && time < $0.end }) { return }
        let p = convert(event.locationInWindow, from: nil)
        if !cameraDidDrag { model.beginGesture(); cameraDidDrag = true }
        let viewport = viewportRectInBounds()
        let block = model.project.layouts.first { $0.id == cameraDragLayoutID }
        let camera = block?.camera ?? model.project.camera
        let rect = cameraOverlayRect(camera: camera, output: viewport.size,
                                     viewScale: selectedManualZoom() != nil || isMaskSelected() ? 1 : model.cameraPath.sample(atSource: time).scale)
        let margin = min(0.02 * min(viewport.width, viewport.height),
                         max(0, (min(viewport.width, viewport.height) - max(rect.width, rect.height)) / 2))
        let position = NormPoint(
            x: min(max(cameraDragPosition.x + (p.x - cameraDragStart.x) / max(1, viewport.width - rect.width - 2 * margin), 0), 1),
            y: min(max(cameraDragPosition.y - (p.y - cameraDragStart.y) / max(1, viewport.height - rect.height - 2 * margin), 0), 1))
        model.update { project in
            if let id = cameraDragLayoutID, let i = project.layouts.firstIndex(where: { $0.id == id }) {
                var value = project.layouts[i].camera ?? project.camera
                value.position = position
                project.layouts[i].camera = value
            } else { project.camera.position = position }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard cameraDragActive || zoomTargetView.isHidden else {
            let wasDragging = zoomTargetView.isDragging
            zoomTargetView.mouseUp(with: event)
            if wasDragging { zoomTargetDragEnded() }
            return
        }
        if !cameraDragActive, let maskOverlayView, !maskOverlayView.isHidden {
            maskOverlayView.mouseUp(with: event)
            return
        }
        guard cameraDragActive else { super.mouseUp(with: event); return }
        cameraDragActive = false
        if cameraDidDrag { model.commitGesture("Camera position") }
        cameraDidDrag = false
    }
}

// MARK: - Selftest `hover-preview <package>` (AC-TL-7)

extension PreviewView {
    /// Drives the real `AVPlayer` seek path (not a mock) over a package with real media: `hoverTime`
    /// shows a different frame than `model.playhead` without moving it, and `nil` seeks back.
    @MainActor
    static func runHoverPreviewSelfTest(_ args: [String]) async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        guard let packagePath = args.first else { throw Fail(description: "usage: hover-preview <package>") }
        let packageURL = URL(fileURLWithPath: packagePath)
        let model = try loadEditorModel(package: packageURL)
        let playheadTime = min(0.4, model.timeMap.outputDuration / 2)
        model.playhead = playheadTime

        let view = PreviewView(model: model)
        view.setFrameSize(NSSize(width: 640, height: 360))

        func waitUntil(_ timeout: Double = 5, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() {
                guard Date() < deadline else { throw Fail(description: "timed out waiting") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func playerSeconds() -> Double { view.player?.currentTime().seconds ?? -1 }

        // Let the initial attach + seek-to-playhead settle.
        try await waitUntil { view.player?.currentItem?.status == .readyToPlay }
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - playheadTime) < 0.05 }

        let hoverTarget = min(1.0, model.timeMap.outputDuration - 0.1)
        guard hoverTarget > playheadTime + 0.05 else { throw Fail(description: "fixture too short for a distinct hover target") }

        view.hoverTime = hoverTarget
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - hoverTarget) < 0.05 }
        guard model.playhead == playheadTime else {
            throw Fail(description: "hoverTime moved model.playhead: \(model.playhead) != \(playheadTime)")
        }
        print("hover-preview: playhead=\(playheadTime) hoverTarget=\(hoverTarget) player=\(playerSeconds())")

        view.hoverTime = nil
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - playheadTime) < 0.05 }
        guard model.playhead == playheadTime else {
            throw Fail(description: "nil hoverTime changed model.playhead: \(model.playhead) != \(playheadTime)")
        }
        print("hover-preview OK: hover moved the player without touching model.playhead; nil restored the playhead frame")
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
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                transportButton("backward.end.fill", label: "Go to beginning") { preview.seek(toOutput: 0) }
                transportButton("backward.frame.fill", label: "Previous frame") { preview.stepFrame(-1.0 / 60) }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play", primary: true) { preview.togglePlayPause() }
                transportButton("forward.frame.fill", label: "Next frame") { preview.stepFrame(1.0 / 60) }
                transportButton("forward.end.fill", label: "Go to end") { preview.seek(toOutput: model.timeMap.outputDuration) }
            }
            Spacer(minLength: 16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.timecode(model.playhead)).font(Font(Theme.timecodeFont(16)))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text("/  " + Self.timecode(model.timeMap.outputDuration))
                    .font(Font(Theme.timecodeFont(11))).foregroundStyle(Theme.textSecondaryColor)
            }.fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .top) { Theme.strokeColor.frame(height: 1) }
    }

    private func transportButton(_ symbol: String, label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: primary ? 28 : 16, height: 28)
        }
        .buttonStyle(TechButtonStyle(kind: primary ? .primary : .quiet, compact: true))
        .help(label)
        .accessibilityLabel(label)
    }

    static func timecode(_ t: Double) -> String {
        let centiseconds = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }
}
