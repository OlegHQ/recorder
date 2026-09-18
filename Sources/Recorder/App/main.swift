import AppKit

// Entry point. `--selftest <name>` headless checks are added by T-004 (SelfTest.runIfRequested()) —
// until then this always runs the app.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
