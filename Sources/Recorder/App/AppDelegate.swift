import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App shell: dark appearance, main menu (SPEC §8), status item, background-app lifecycle.
/// Menu items with no app logic yet keep `action: nil`; later tasks (see SPEC §8, T-104, T-207, T-311…) wire them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    /// Tracks which of the two status menus (SPEC §8 idle / §4.7 recording) is currently installed, so
    /// `updateStatusItem` only rebuilds it on an actual state change instead of every tick.
    private var isShowingRecordingMenu = false

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = Self.buildMainMenu()
        statusItem = buildStatusItem()
        wireNewRecording()
        wireSettings()
        wireProjects()
        wireOpen()
        wireViewHelpItems()
        wireCopyStateSnapshot()
        Hotkeys.install()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }

        // AC-REC-3: recover any package left with a `screen.mov` but no `project.json` by a prior crash.
        Task { await RecordingRecovery.recoverOrphans(in: RecordingSettings.shared.projectsFolder) }

        // Dev/HUMAN entry point (T-306/T-307): `Recorder --open <package>` opens the editor for
        // that package directly, so it's reachable before the library (T-3xx, another lane) exists.
        if let i = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.indices.contains(i + 1) {
            EditorWindowController.open(package: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        } else if !Permissions.allGranted {
            showOnboarding()
        } else {
            Library.show() // shown alongside the toolbar on launch, SPEC §5.1
            ToolbarController.shared.show()
        }

        AppDelegate.applyShowInDockPolicy()
        NSApp.activate()
    }

    /// `application(_:open:)`: Finder double-click on a `.recorder` package (SPEC §5, AC-LIB-3).
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Library.open)
    }

    /// SPEC §5 "Autosave": "also on window close and applicationWillTerminate" (T-303) — window
    /// close is handled by `EditorWindowController.windowWillClose`; this covers quit.
    func applicationWillTerminate(_ n: Notification) {
        EditorWindowController.saveAllNow()
    }

    private func showOnboarding() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Recorder"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            Task { @MainActor in
                self?.window.close()
                ToolbarController.shared.show()
            }
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Reopening returns to documents; recording setup requires an explicit New Recording action.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ToolbarController.shared.close()
        guard Permissions.allGranted else { showOnboarding(); return true }
        if let document = (sender.orderedWindows + sender.windows).first(where: {
            ($0.windowController is EditorWindowController || $0 === Library.window)
                && ($0.isVisible || $0.isMiniaturized)
        }) {
            document.deminiaturize(nil)
            document.makeKeyAndOrderFront(nil)
        } else {
            Library.show()
        }
        return true
    }

    @MainActor @objc private func newRecording() {
        startRecordingFlow(mode: nil)
    }

    @MainActor @objc private func recordDisplay() { startRecordingFlow(mode: .display) }
    @MainActor @objc private func recordWindow() { startRecordingFlow(mode: .window) }
    @MainActor @objc private func recordArea() { startRecordingFlow(mode: .area) }

    /// SPEC §8 UX rule: "with permissions missing every recording item opens onboarding (§4.1) instead."
    /// `mode: nil` matches "New Recording…" — the toolbar opens in the last-used mode, unchanged.
    @MainActor private func startRecordingFlow(mode: RecordingSettings.Mode?) {
        guard Permissions.allGranted else { showOnboarding(); return }
        ToolbarController.shared.show()
        if let mode { ToolbarController.shared.selectMode(mode) }
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func showProjects() {
        Library.show()
    }

    /// "Show Recorder in Dock" (SPEC §8): persisted, applied immediately.
    @MainActor @objc private func toggleShowInDock() {
        AppDelegate.showInDock.toggle()
        AppDelegate.applyShowInDockPolicy()
    }

    @objc private func openLastProjectAction() {
        AppDelegate.openLastProject()
    }

    /// "File ▸ Open…": picks a `.recorder` package and routes it through `Library.open`, same as a
    /// Finder double-click (AC-LIB-3).
    @objc private func openDocument() {
        ToolbarController.shared.close()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: "sh.nexo.recorder.project")]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(Library.open)
    }

    @MainActor @objc private func finishRecording() {
        RecordingController.shared.finish()
    }

    @MainActor @objc private func togglePauseRecording() {
        let rc = RecordingController.shared
        rc.state == .paused ? rc.resume() : rc.pause()
    }

    @MainActor @objc private func restartRecording() {
        RecordingController.shared.restart()
    }

    @MainActor @objc private func deleteRecording() {
        RecordingController.shared.delete()
    }

    @MainActor @objc private func hideWidget() {
        RecordingWidgetPanel.hide()
    }

    /// SPEC §4.7 "Menu-bar item": status item title/icon and which of the two menus (SPEC §8 idle /
    /// §4.7 recording) is installed both track `RecordingController.shared.state`, polled once a
    /// second — cheaper than making `RecordingController` `@Observable` just for this.
    @MainActor private func updateStatusItem() {
        let rc = RecordingController.shared
        let recording = rc.state == .recording || rc.state == .paused
        if recording != isShowingRecordingMenu {
            statusItem.menu = recording ? buildRecordingStatusMenu() : buildIdleStatusMenu()
            isShowingRecordingMenu = recording
        } else if recording {
            // Pause/Resume is always index 1 in `buildRecordingStatusMenu` (Finish, Pause/Resume, …).
            statusItem.menu?.item(at: 1)?.title = rc.state == .paused ? "Resume" : "Pause"
        }
        if recording {
            let s = Int(rc.elapsed)
            statusItem.button?.title = String(format: " %02d:%02d", s / 60, s % 60)
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusItem.button?.title = ""
            statusItem.button?.contentTintColor = nil
        }
    }

    /// Wires the "File ▸ New Recording" item built by `buildMainMenu` to the same selector the status
    /// item's "New Recording…" uses (T-104; status item items are wired directly in `buildIdleStatusMenu`).
    private func wireNewRecording() {
        let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Recording")
        item?.target = self
        item?.action = #selector(newRecording)
    }

    /// Wires the "Recorder ▸ Settings…" item built by `buildMainMenu` (T-207).
    private func wireSettings() {
        let item = NSApp.mainMenu?.item(withTitle: "Recorder")?.submenu?.item(withTitle: "Settings…")
        item?.target = self
        item?.action = #selector(openSettings)
    }

    /// Wires "File ▸ Projects" (⇧⌘O) to the library window (T-302; the status item's own "Projects" is
    /// wired directly in `buildIdleStatusMenu`).
    private func wireProjects() {
        let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Projects")
        item?.target = self
        item?.action = #selector(showProjects)
    }

    /// Wires "File ▸ Open…" (T-302).
    private func wireOpen() {
        let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open…")
        item?.target = self
        item?.action = #selector(openDocument)
    }

    /// Wires "View ▸ Command Menu…"/"Keyboard Shortcuts" (T-607/T-608's menu bindings, T-311):
    /// always available (no editor needed), so — unlike the editor-scoped Edit/View items above,
    /// which stay `target = nil` for the responder chain — these are plain `AppDelegate` actions.
    private func wireViewHelpItems() {
        let view = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        let commandMenu = view?.item(withTitle: "Command Menu…")
        commandMenu?.target = self
        commandMenu?.action = #selector(showCommandMenu)
        let cheatSheet = view?.item(withTitle: "Keyboard Shortcuts")
        cheatSheet?.target = self
        cheatSheet?.action = #selector(showCheatSheet)
    }

    @MainActor @objc private func showCommandMenu() { CommandMenu.show() }
    @MainActor @objc private func showCheatSheet() { CheatSheet.show() }

    /// Wires "Recorder ▸ Copy State Snapshot" (T-610) — same pattern as `wireSettings`. The status
    /// item's own copy (idle + recording variants, `buildIdleStatusMenu`/`buildRecordingStatusMenu`)
    /// is wired directly, like every other status-menu item.
    private func wireCopyStateSnapshot() {
        let item = NSApp.mainMenu?.item(withTitle: "Recorder")?.submenu?.item(withTitle: "Copy State Snapshot")
        item?.target = self
        item?.action = #selector(copyStateSnapshotTapped)
    }

    @MainActor @objc private func copyStateSnapshotTapped() { StateSnapshot.dump() }

    /// T-610: transient confirmation for an action with no window of its own to show feedback in —
    /// flashes the status item's title for 2 s without stealing focus or a new window class, then
    /// lets the existing 1 s `statusTimer` poll (`updateStatusItem`) put it back.
    func flashStatusItem(_ text: String) {
        statusItem.button?.title = " \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateStatusItem() }
    }

    // MARK: - "Show Recorder in Dock" (SPEC §8) and "Open Last Project" (SPEC §4.7/§8)

    private static let showInDockKey = "app.showInDock"

    static var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showInDockKey) }
    }

    /// SPEC §8: "off = `.accessory` activation policy... it only takes effect while no editor/library
    /// window is open." No editor exists yet (M3); `Library`'s and onboarding's windows are both
    /// `.titled`, so this check covers them (and any future editor window) without either owning a
    /// public "is my window open" API. Never overrides T-205's recording-time hide (RecordingController
    /// calls this only once a recording has actually ended).
    // ponytail: applied only at launch, on toggle, and when a recording ends — not on every window
    // open/close — so an editor window closing on its own won't retract the dock icon until one of
    // those happens again. No observer layer for a case M2 doesn't need yet.
    @MainActor static func applyShowInDockPolicy() {
        let rc = RecordingController.shared
        guard rc.state != .recording, rc.state != .paused else { return }
        let hasDocumentWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        NSApp.setActivationPolicy(showInDock || hasDocumentWindow ? .regular : .accessory)
    }

    /// Newest `*.recorder` package by modification date in the projects folder, or `nil` if there is none.
    static func newestProjectURL() -> URL? {
        let fm = FileManager.default
        guard let packages = try? fm.contentsOfDirectory(at: RecordingSettings.shared.projectsFolder,
                                                           includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return packages.filter { $0.pathExtension == "recorder" }.max { a, b in
            let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil ?? Date.distantPast }
            return modified(a) < modified(b)
        }
    }

    /// "Open Last Project" (SPEC §4.7 ⌥⌘Z, §8): routes through `Library.open`, same as every other open
    /// path. Static so `Hotkeys.swift`'s global ⌥⌘Z handler can call it without an `AppDelegate` instance.
    static func openLastProject() {
        guard let url = newestProjectURL() else { return }
        Library.open(url)
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

    // Not `private`: the `menu-actions` selftest builds the real main menu directly (same reason
    // `buildIdleStatusMenu`/`buildRecordingStatusMenu` below aren't private either).
    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Recorder")
        app.addItem(item("About", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", ","))
        app.addItem(item("Copy State Snapshot", "s", [.control, .option, .command]))
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
        file.addItem(item("Save", "s", action: #selector(EditorWindowController.saveDocument(_:))))
        file.addItem(item("Save As…", "s", [.command, .shift], action: #selector(EditorWindowController.saveDocumentAs(_:))))
        file.addItem(item("Show Raw Files", action: #selector(EditorWindowController.showRawFiles(_:))))
        file.addItem(item("Close", "w", action: #selector(NSWindow.performClose(_:))))
        main.addItem(item("File", submenu: file))

        // T-311: Edit/View items below target `nil` — AppKit resolves them through the key window's
        // responder chain to `EditorWindowController` (its actions + `validateMenuItem`), which
        // disables them automatically while no editor window is key. `Undo`/`Redo`'s titles are
        // rewritten with the edit name by that same `validateMenuItem`.
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", "z", action: #selector(EditorWindowController.performUndo(_:))))
        edit.addItem(item("Redo", "z", [.command, .shift], action: #selector(EditorWindowController.performRedo(_:))))
        edit.addItem(item("Split", "c", [], action: #selector(EditorWindowController.splitAtPlayhead(_:))))
        edit.addItem(item("Remove", "\u{8}", [], action: #selector(EditorWindowController.removeSelected(_:))))
        edit.addItem(item("Add Zoom", "z", [], action: #selector(EditorWindowController.addZoomAtPlayhead(_:))))
        edit.addItem(item("Regenerate Auto Zooms", action: #selector(EditorWindowController.regenerateAutoZooms(_:))))
        edit.addItem(item("Remove All Zooms", action: #selector(EditorWindowController.removeAllZooms(_:))))
        edit.addItem(item("Restore All Cuts", action: #selector(EditorWindowController.restoreAllCuts(_:))))
        edit.addItem(item("Speed Up Typing", action: #selector(EditorWindowController.speedUpTyping(_:))))
        edit.addItem(item("Hide Cursor in Selected Clip", action: #selector(EditorWindowController.hideCursorInSelectedClip(_:))))
        main.addItem(item("Edit", submenu: edit))

        let record = NSMenu(title: "Record")
        record.addItem(item("Start/Finish"))
        record.addItem(item("Pause"))
        record.addItem(item("Restart"))
        main.addItem(item("Record", submenu: record))

        // T-506/T-609: `target = nil`, resolved through the key window's responder chain to
        // `EditorWindowController`, same as the Edit/View items above — disabled automatically with
        // no editor window key.
        let export = NSMenu(title: "Export")
        export.addItem(item("Export…", "e", action: #selector(EditorWindowController.exportTapped(_:))))
        export.addItem(item("Copy Frame as Image", "c", [.command, .shift], action: #selector(EditorWindowController.copyFrameAsImage(_:))))
        main.addItem(item("Export", submenu: export))

        let view = NSMenu(title: "View")
        for n in 1...6 {
            let tabItem = item(InspectorView.Tab(rawValue: n - 1)!.title, "\(n)", [],
                                action: #selector(EditorWindowController.selectInspectorTab(_:)))
            tabItem.tag = n - 1
            view.addItem(tabItem)
        }
        view.addItem(.separator())
        view.addItem(item("Zoom In", "=", action: #selector(EditorWindowController.timelineZoomIn(_:))))
        view.addItem(item("Zoom Out", "-", action: #selector(EditorWindowController.timelineZoomOut(_:))))
        view.addItem(item("Fit", "z", [.shift], action: #selector(EditorWindowController.timelineFit(_:))))
        view.addItem(.separator())
        view.addItem(item("Crop…", action: #selector(EditorWindowController.cropTapped)))
        view.addItem(.separator())
        // SPEC §8's menu-bar list doesn't place these (there's no Help menu); T-311's Log records
        // that they were added here, in the View menu's last group, per the coordinator's instruction.
        view.addItem(item("Command Menu…", "k"))
        view.addItem(item("Keyboard Shortcuts", "/"))
        main.addItem(item("View", submenu: view))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", "m", action: #selector(NSWindow.miniaturize(_:))))
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(item("Window", submenu: windowMenu))
        // `NSApplication.shared`, not the bare `NSApp` global (same reason as the status menu's Quit
        // item below): `NSApp` is only set as a side effect of `.shared` having been touched, so it's
        // nil the first time anything calls `buildMainMenu()` headlessly (e.g. the `menu-actions`
        // selftest, which — unlike `applicationDidFinishLaunching` — never otherwise touches `.shared`
        // first).
        NSApplication.shared.windowsMenu = windowMenu

        return main
    }

    // MARK: - Status item (always present; SPEC §8 idle menu, SPEC §4.7 recording menu)

    private func buildStatusItem() -> NSStatusItem {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        si.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recorder")
        si.menu = buildIdleStatusMenu()
        return si
    }

    /// T-609: the key equivalent/modifiers `Hotkeys.table`'s current binding (override or default) for
    /// `hotkeyTitle` uses — so a Settings ▸ Shortcuts rebind is reflected here the next time either
    /// status menu is rebuilt (`updateStatusItem` rebuilds fresh each time it's opened).
    private func hotkeyKey(_ hotkeyTitle: String) -> (key: String, mods: NSEvent.ModifierFlags) {
        let b = Hotkeys.currentBinding(titled: hotkeyTitle)
        return (b.character, NSEvent.ModifierFlags(rawValue: b.modifiers))
    }

    /// SPEC §8 mockup, titles/order/SF Symbols normative (`reference/status-item-menu.png`); key
    /// equivalents mirror `Hotkeys.table`'s current bindings (T-609).
    /// Not `private`: the `menus` selftest builds both status menus directly to check them against SPEC.
    func buildIdleStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let newRecordingKey = hotkeyKey("New Recording")
        menu.addItem(statusMenuItem("New Recording…", symbol: "record.circle", key: newRecordingKey.key, mods: newRecordingKey.mods,
                                     action: #selector(newRecording)))
        menu.addItem(.separator())
        let displayKey = hotkeyKey("Record Display")
        menu.addItem(statusMenuItem("Record Display", symbol: "display", key: displayKey.key, mods: displayKey.mods,
                                     action: #selector(recordDisplay)))
        let windowKey = hotkeyKey("Record Window")
        menu.addItem(statusMenuItem("Record Window", symbol: "macwindow", key: windowKey.key, mods: windowKey.mods,
                                     action: #selector(recordWindow)))
        let areaKey = hotkeyKey("Record Area")
        menu.addItem(statusMenuItem("Record Area", symbol: "rectangle.dashed", key: areaKey.key, mods: areaKey.mods,
                                     action: #selector(recordArea)))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem("Settings…", key: ",", action: #selector(openSettings)))
        let snapshotKey = hotkeyKey("Copy State Snapshot")
        menu.addItem(statusMenuItem("Copy State Snapshot", key: snapshotKey.key, mods: snapshotKey.mods, action: #selector(copyStateSnapshotTapped)))
        let showInDock = statusMenuItem("Show Recorder in Dock", key: "d", action: #selector(toggleShowInDock))
        showInDock.state = AppDelegate.showInDock ? .on : .off
        menu.addItem(showInDock)
        menu.addItem(.separator())
        menu.addItem(statusMenuItem("Projects", key: "o", mods: [.command, .shift], action: #selector(showProjects)))
        menu.addItem(statusMenuItem("Open…", key: "o", action: #selector(openDocument)))
        let openLastKey = hotkeyKey("Open Last Project")
        let openLast = statusMenuItem("Open Last Project", key: openLastKey.key, mods: openLastKey.mods, action: #selector(openLastProjectAction))
        openLast.isEnabled = AppDelegate.newestProjectURL() != nil
        menu.addItem(openLast)
        menu.addItem(.separator())
        let quit = statusMenuItem("Quit Recorder", key: "q", action: #selector(NSApplication.terminate(_:)))
        // Not `self`: `terminate(_:)` is `NSApplication`'s, not ours. `.shared` (not the `NSApp` global,
        // which is only set as a side effect of `.shared` having been touched) so this is never nil even
        // if nothing has referenced the shared application yet (e.g. the `menus` selftest).
        quit.target = NSApplication.shared
        menu.addItem(quit)
        return menu
    }

    /// SPEC §4.7 "in-progress controls" menu, installed instead of the idle one while recording
    /// (`updateStatusItem`): Finish · Pause/Resume · Restart · Delete · ─ · Hide widget. Same
    /// `RecordingController` methods the widget's buttons call (T-203) — one implementation each; key
    /// equivalents mirror `Hotkeys.table`'s current bindings (T-609).
    @MainActor func buildRecordingStatusMenu() -> NSMenu {
        let paused = RecordingController.shared.state == .paused
        let menu = NSMenu()
        let finishKey = hotkeyKey("Start/Finish Recording")
        menu.addItem(statusMenuItem("Finish", key: finishKey.key, mods: finishKey.mods, action: #selector(finishRecording)))
        let pauseKey = hotkeyKey("Pause/Resume")
        menu.addItem(statusMenuItem(paused ? "Resume" : "Pause", key: pauseKey.key, mods: pauseKey.mods,
                                         action: #selector(togglePauseRecording)))
        menu.addItem(statusMenuItem("Restart", action: #selector(restartRecording)))
        menu.addItem(statusMenuItem("Delete", action: #selector(deleteRecording)))
        menu.addItem(.separator())
        // T-610: allowed while recording (the global hotkey is `alwaysActive`, same as ⌃⌥⌘R/⌃⌥⌘P) —
        // exactly the moment "the UI is misbehaving" is most likely to matter.
        let snapshotKey = hotkeyKey("Copy State Snapshot")
        menu.addItem(statusMenuItem("Copy State Snapshot", key: snapshotKey.key, mods: snapshotKey.mods, action: #selector(copyStateSnapshotTapped)))
        menu.addItem(statusMenuItem("Hide widget", action: #selector(hideWidget)))
        return menu
    }

    /// Status-menu item builder: unlike `item(_:_:_:action:)` (main menu, wired later by the `wire*`
    /// methods), this sets `target = self` and the action immediately — the status menus are rebuilt
    /// fresh by `updateStatusItem` rather than wired once at launch.
    private func statusMenuItem(_ title: String, symbol: String? = nil, key: String = "",
                             mods: NSEvent.ModifierFlags = [.command], action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }
}
