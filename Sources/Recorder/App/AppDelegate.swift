import AppKit
import SwiftUI

/// App shell: dark appearance, main menu (SPEC §8), status item, background-app lifecycle.
/// Menu items with no app logic yet keep `action: nil`; later tasks (see SPEC §8, T-104, T-207, T-311…) wire them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = Self.buildMainMenu()
        statusItem = Self.buildStatusItem()
        wireNewRecording()
        wireSettings()

        if !Permissions.allGranted {
            showOnboarding()
        } else {
            ToolbarController.shared.show()
        }

        NSApp.activate()
    }

    private func showOnboarding() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Recorder"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.window.close()
            ToolbarController.shared.show()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Dock-icon click (SPEC §4.2: toolbar opens "on dock-icon click").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ToolbarController.shared.show()
        return true
    }

    @objc private func newRecording() {
        ToolbarController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    /// Wires the "New Recording" items built by `buildMainMenu`/`buildStatusItem` to `ToolbarController` (T-104).
    private func wireNewRecording() {
        for item in [NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Recording"),
                     statusItem.menu?.item(withTitle: "New Recording")] {
            item?.target = self
            item?.action = #selector(newRecording)
        }
    }

    /// Wires the "Recorder ▸ Settings…" item built by `buildMainMenu` (T-207).
    private func wireSettings() {
        let item = NSApp.mainMenu?.item(withTitle: "Recorder")?.submenu?.item(withTitle: "Settings…")
        item?.target = self
        item?.action = #selector(openSettings)
    }

    // MARK: - Main menu (SPEC §8, titles/order/key equivalents normative)

    private static func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                              action: Selector? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func item(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        return i
    }

    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Recorder")
        app.addItem(item("About", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", ","))
        app.addItem(.separator())
        app.addItem(item("Quit", "q", action: #selector(NSApplication.terminate(_:))))
        main.addItem(item("Recorder", submenu: app))

        let file = NSMenu(title: "File")
        file.addItem(item("New Recording", "n"))
        file.addItem(item("Open…", "o"))
        let openRecent = item("Open Recent")
        openRecent.submenu = NSMenu(title: "Open Recent")
        file.addItem(openRecent)
        file.addItem(item("Projects", "o", [.command, .shift]))
        file.addItem(item("Save", "s"))
        file.addItem(item("Save As…", "s", [.command, .shift]))
        file.addItem(item("Show Raw Files"))
        file.addItem(item("Close", "w", action: #selector(NSWindow.performClose(_:))))
        main.addItem(item("File", submenu: file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", "z"))
        edit.addItem(item("Redo", "z", [.command, .shift]))
        edit.addItem(item("Split", "c", []))
        edit.addItem(item("Remove", "\u{8}", []))
        edit.addItem(item("Add Zoom", "z", []))
        edit.addItem(item("Regenerate Auto Zooms"))
        edit.addItem(item("Remove All Zooms"))
        edit.addItem(item("Restore All Cuts"))
        main.addItem(item("Edit", submenu: edit))

        let record = NSMenu(title: "Record")
        record.addItem(item("Start/Finish"))
        record.addItem(item("Pause"))
        record.addItem(item("Restart"))
        main.addItem(item("Record", submenu: record))

        let export = NSMenu(title: "Export")
        export.addItem(item("Export…", "e"))
        export.addItem(item("Copy Frame as Image", "c", [.command, .shift]))
        main.addItem(item("Export", submenu: export))

        let view = NSMenu(title: "View")
        for n in 1...6 { view.addItem(item("\(n)", "\(n)", [])) }
        view.addItem(.separator())
        view.addItem(item("Zoom In", "="))
        view.addItem(item("Zoom Out", "-"))
        view.addItem(item("Fit", "z", [.shift]))
        view.addItem(.separator())
        view.addItem(item("Crop…"))
        main.addItem(item("View", submenu: view))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", "m", action: #selector(NSWindow.miniaturize(_:))))
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(item("Window", submenu: windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    // MARK: - Status item (always present; SPEC §8)

    private static func buildStatusItem() -> NSStatusItem {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        si.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recorder")
        let menu = NSMenu()
        menu.addItem(item("New Recording"))
        menu.addItem(item("Projects"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(NSApplication.terminate(_:))))
        si.menu = menu
        return si
    }
}
