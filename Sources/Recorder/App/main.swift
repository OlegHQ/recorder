import AppKit

// Entry point. `--selftest <name>` runs a headless check instead of the GUI (see SelfTest.swift).
SelfTest.runIfRequested()
AppIdentity.migratePreferences()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
