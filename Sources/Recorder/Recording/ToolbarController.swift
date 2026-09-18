import AppKit
import SwiftUI
import AVFoundation

/// Owns the recording toolbar panel (SPEC §4.2) and every native `NSMenu` it pops (camera, microphone,
/// system audio, settings gear). Shown on launch (permissions granted), dock click, `⌘N`, status item.
final class ToolbarController: NSObject {
    static let shared = ToolbarController()

    private var panel: FloatingPanel?
    private var deviceObservers: [NSObjectProtocol] = []

    private override init() { super.init() }

    func show() {
        // Onboarding (T-102) owns this window while permissions are missing (AC-ONB-1).
        guard Permissions.allGranted else { return }
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            SourcePickerOverlay.show(mode: RecordingSettings.shared.mode)
            return
        }

        let view = ToolbarHostingView(rootView: ToolbarView(
            onClose: { [weak self] in self?.close() },
            onSelectMode: { [weak self] mode in self?.selectMode(mode) },
            onCamera: { [weak self] in self?.showCameraMenu() },
            onMicrophone: { [weak self] in self?.showMicrophoneMenu() },
            onSystemAudio: { [weak self] in self?.showSystemAudioMenu() },
            onSettings: { [weak self] in self?.showSettingsMenu() }
        ))
        view.onCancel = { [weak self] in self?.close() }

        let p = FloatingPanel(content: view, draggable: true)
        position(p)
        p.makeKeyAndOrderFront(nil)
        panel = p
        observeDevices()
        SourcePickerOverlay.show(mode: RecordingSettings.shared.mode)
    }

    /// `ⓧ` or `Esc`: close the toolbar and any overlay; the app keeps running (SPEC §4.2, AC-TB-4).
    func close() {
        SourcePickerOverlay.close()
        panel?.orderOut(nil)
        panel = nil
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers.removeAll()
    }

    /// Sets the recording mode and shows its picker overlay (SPEC §4.2: "selecting a source mode
    /// immediately shows that mode's overlay"). The one entry point for mode selection — reused by the
    /// toolbar buttons here, the status-item menu (T-207b) and global hotkeys (T-204).
    func selectMode(_ mode: RecordingSettings.Mode) {
        RecordingSettings.shared.mode = mode
        SourcePickerOverlay.show(mode: mode)
    }

    /// Bottom-centre of the display under the mouse, 40 pt above the Dock (`visibleFrame` already excludes it).
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Device change notifications (AC-TB-2/3)

    private func observeDevices() {
        let nc = NotificationCenter.default
        // Menus are rebuilt fresh from a live DiscoverySession every time they're opened, so a connect
        // needs no action here. A disconnect of the *selected* device must fall back to "Don't record…".
        deviceObservers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { _ in })
        deviceObservers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let s = RecordingSettings.shared
            if s.cameraID == device.uniqueID { s.cameraID = nil }
            if s.micID == device.uniqueID { s.micID = nil }
        })
    }

    // MARK: - Menu building helpers

    // Anchored to the toolbar, not the mouse (reference: menus open above the toolbar, never overlapping
    // it). Horizontal position follows the clicked button (mouse x); vertical position puts the menu's
    // bottom edge just above the panel's top edge.
    private func popUp(_ menu: NSMenu) {
        guard let panel else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let point = NSPoint(x: NSEvent.mouseLocation.x, y: panel.frame.maxY + menu.size.height)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private func menuItem(_ title: String, checked: Bool = false, key: String = "",
                           action: Selector, tag: Int = 0, represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = checked ? .on : .off
        i.tag = tag
        i.representedObject = represented
        return i
    }

    // MARK: - Camera menu

    private func showCameraMenu() {
        let s = RecordingSettings.shared
        let menu = NSMenu()
        for device in AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices {
            menu.addItem(menuItem(device.localizedName, checked: s.cameraID == device.uniqueID,
                                   action: #selector(selectCamera(_:)), represented: device.uniqueID))
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(menuItem("Don't record camera", checked: s.cameraID == nil, action: #selector(selectCamera(_:))))
        popUp(menu)
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        RecordingSettings.shared.cameraID = sender.representedObject as? String
    }

    // MARK: - Microphone menu

    private func showMicrophoneMenu() {
        let s = RecordingSettings.shared
        let menu = NSMenu()
        for device in AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices {
            menu.addItem(menuItem(device.localizedName, checked: s.micID == device.uniqueID,
                                   action: #selector(selectMicrophone(_:)), represented: device.uniqueID))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Reduce noise and normalize volume", checked: s.denoise, action: #selector(toggleDenoise)))
        menu.addItem(menuItem("Disable auto gain control", checked: s.disableAGC, action: #selector(toggleDisableAGC)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Don't record microphone", checked: s.micID == nil, action: #selector(selectMicrophone(_:))))
        popUp(menu)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        RecordingSettings.shared.micID = sender.representedObject as? String
    }

    @objc private func toggleDenoise() { RecordingSettings.shared.denoise.toggle() }
    @objc private func toggleDisableAGC() { RecordingSettings.shared.disableAGC.toggle() }

    // MARK: - System audio menu

    private func showSystemAudioMenu() {
        let s = RecordingSettings.shared
        let isAll: Bool = { if case .all = s.systemAudio { return true }; return false }()
        var selectedIDs: [String] { if case .apps(let ids) = s.systemAudio { return ids } else { return [] } }

        let menu = NSMenu()
        menu.addItem(menuItem("Record system audio from all apps", checked: isAll, action: #selector(selectSystemAudioAll)))

        let selectedApps = NSMenuItem(title: "Record system audio from selected apps", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            sub.addItem(menuItem(app.localizedName ?? bundleID, checked: selectedIDs.contains(bundleID),
                                  action: #selector(toggleSystemAudioApp(_:)), represented: bundleID))
        }
        selectedApps.submenu = sub
        menu.addItem(selectedApps)
        menu.addItem(.separator())
        menu.addItem(menuItem("Don't record system audio", checked: !isAll && selectedIDs.isEmpty, action: #selector(selectSystemAudioOff)))
        popUp(menu)
    }

    @objc private func selectSystemAudioAll() { RecordingSettings.shared.systemAudio = .all }
    @objc private func selectSystemAudioOff() { RecordingSettings.shared.systemAudio = .off }

    @objc private func toggleSystemAudioApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var ids: [String] = { if case .apps(let ids) = RecordingSettings.shared.systemAudio { return ids } else { return [] } }()
        if let i = ids.firstIndex(of: bundleID) { ids.remove(at: i) } else { ids.append(bundleID) }
        RecordingSettings.shared.systemAudio = ids.isEmpty ? .off : .apps(ids)
    }

    // MARK: - Settings (gear) menu

    private func showSettingsMenu() {
        let s = RecordingSettings.shared
        let menu = NSMenu()
        menu.addItem(menuItem("Hide desktop icons in recorded video", checked: s.hideDesktopIcons, action: #selector(toggleHideDesktopIcons)))
        menu.addItem(menuItem("Hide Recorder dock icon while recording", checked: s.hideDockIcon, action: #selector(toggleHideDockIcon)))
        menu.addItem(menuItem("Highlight recorded area during recording", checked: s.highlightArea, action: #selector(toggleHighlightArea)))
        menu.addItem(.separator())

        let countdown = NSMenuItem(title: "Recording countdown", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in [("Off", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)] {
            sub.addItem(menuItem(title, checked: s.countdown == value, action: #selector(selectCountdown(_:)), tag: value))
        }
        countdown.submenu = sub
        menu.addItem(countdown)
        menu.addItem(.separator())

        menu.addItem(menuItem("Settings…", key: ",", action: #selector(openSettingsWindow)))
        popUp(menu)
    }

    @objc private func toggleHideDesktopIcons() { RecordingSettings.shared.hideDesktopIcons.toggle() }
    @objc private func toggleHideDockIcon() { RecordingSettings.shared.hideDockIcon.toggle() }
    @objc private func toggleHighlightArea() { RecordingSettings.shared.highlightArea.toggle() }
    @objc private func selectCountdown(_ sender: NSMenuItem) { RecordingSettings.shared.countdown = sender.tag }
    @objc private func openSettingsWindow() { SettingsWindow.show() }
}

/// `Esc` closes the toolbar (AC-TB-4) via the standard `cancelOperation(_:)` responder action
/// (`FloatingPanel` is `final`, so this lives on the content view instead of a panel subclass).
private final class ToolbarHostingView: NSHostingView<ToolbarView> {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
