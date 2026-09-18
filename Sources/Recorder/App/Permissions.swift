import ApplicationServices
import AVFoundation
import CoreGraphics

enum Permissions {
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestScreen() { CGRequestScreenCaptureAccess() }
    static func requestAccessibility() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    static var allGranted: Bool { screen && accessibility }

    // T-610: camera/mic TCC are their own authorization (SPEC §4.1/§4.6), read-only here for the
    // state snapshot — `CameraCapture.request(deviceID:)` is the one place that actually prompts.
    static var camera: String { describe(AVCaptureDevice.authorizationStatus(for: .video)) }
    static var mic: String { describe(AVCaptureDevice.authorizationStatus(for: .audio)) }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
