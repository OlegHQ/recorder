import AppKit
import SwiftUI

// Skeleton only: proves the SwiftPM -> .app -> /Applications pipeline. Real entry point is specified in docs/SPEC.md §4.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Recorder"
        window.contentView = NSHostingView(rootView: Text("Recorder").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
