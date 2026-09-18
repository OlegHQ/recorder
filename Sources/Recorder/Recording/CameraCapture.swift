import AVFoundation
import CoreMedia
import Foundation

/// One `AVCaptureSession` (preset `.high`) for the selected camera (SPEC §4.6): its
/// `AVCaptureVideoPreviewLayer` feeds `CameraBubblePanel` as soon as a camera is picked (before
/// recording starts), and its `AVCaptureVideoDataOutput` feeds a fourth `TrackWriter` for `camera.mov`
/// once `startWriting` attaches a `CaptureSession` clock — every buffer is retimed onto that session's
/// shared `t0`/`pausedSoFar`/`isPaused` (SPEC §4.8) so `camera.mov` stays in sync with `screen.mov`
/// (AC-CAM-2). Buffers before `t0`, or captured while paused, are dropped.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "CameraCapture.output")

    let previewLayer: AVCaptureVideoPreviewLayer

    private var clock: CaptureSession?
    private var packageURL: URL?
    private var writer: TrackWriter?

    /// Resolves camera TCC before opening the device: camera access is its own authorization (separate
    /// from `Permissions.swift`'s screen-recording/accessibility pair, gated per SPEC §4.1 before the
    /// toolbar even shows). Never blocks — `requestAccess`'s callback always fires, so a denied/restricted
    /// device just calls back `nil` instead of hanging or throwing.
    static func request(deviceID: String, completion: @escaping (CameraCapture?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(CameraCapture(deviceID: deviceID))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted ? CameraCapture(deviceID: deviceID) : nil) }
            }
        case .denied, .restricted:
            completion(nil)
        @unknown default:
            completion(nil)
        }
    }

    private init?(deviceID: String) {
        guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); return nil }
        session.addInput(input)
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(dataOutput) { session.addOutput(dataOutput) }
        session.commitConfiguration()

        dataOutput.connection(with: .video)?.isVideoMirrored = true
        if let previewConnection = previewLayer.connection {
            previewConnection.automaticallyAdjustsVideoMirroring = false
            previewConnection.isVideoMirrored = true
        }

        queue.async { [session] in session.startRunning() }
    }

    /// Attaches the recording's shared clock: from here on, frames are retimed and written to
    /// `camera.mov` inside `packageURL`.
    func startWriting(packageURL: URL, clock: CaptureSession) {
        self.packageURL = packageURL
        self.clock = clock
    }

    /// Stops the session (preview and writing) and finishes or discards `camera.mov`.
    func stop(cancelled: Bool) async {
        queue.async { [session] in session.stopRunning() }
        if cancelled { writer?.cancel() } else { await writer?.finish() }
    }

    // ponytail: reads `clock.t0`/`isPaused`/`pausedSoFar` from this session's own queue, not
    // `CaptureSession`'s `outputQueue` that mutates them — a benign race (values only ever move forward /
    // become non-nil), matching the project's language-mode-5 stance on AVFoundation callback concurrency.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let clock, let packageURL, let t0 = clock.t0, !clock.isPaused else { return }
        let offset = sampleBuffer.presentationTimeStamp - t0 - clock.pausedSoFar
        guard offset >= .zero else { return }

        if writer == nil {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(imageBuffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(imageBuffer),
            ]
            writer = try? TrackWriter(url: packageURL.appendingPathComponent("camera.mov"), videoSettings: videoSettings)
        }
        writer?.append(sampleBuffer, offset: offset)
    }
}
