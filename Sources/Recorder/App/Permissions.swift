import ApplicationServices
import CoreGraphics

enum Permissions {
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestScreen() { CGRequestScreenCaptureAccess() }
    static func requestAccessibility() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    static var allGranted: Bool { screen && accessibility }
}
