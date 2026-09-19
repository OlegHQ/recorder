import AppKit
import SwiftUI
import AVFoundation

/// Owns the recording toolbar panel (SPEC §4.2) and every native `NSMenu` it pops (camera, microphone,
/// system audio, settings gear). Shown on launch (permissions granted), `⌘N`, status item.
final class ToolbarController: NSObject {
    static let shared = ToolbarController()

    private var panel: FloatingPanel?
    private var deviceObservers: [NSObjectProtocol] = []
    /// Live while a camera is selected (SPEC §4.6): feeds `CameraBubblePanel`'s preview and, once
    /// recording actually starts, `camera.mov`. Retained here so its `AVCaptureSession` stays alive.
    private var cameraCapture: CameraCapture?
    private var deviceRequest = UUID()
    private var requestingDeviceAccess = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(documentBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        // TCC and other system UI agents can announce activation after their dialog callback.
        // Only a switch to a regular app represents leaving recording setup.
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !requestingDeviceAccess else { return }
        close()
    }

    @objc private func documentBecameKey(_ notification: Notification) {
        guard !requestingDeviceAccess, let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled) else { return }
        close()
    }

    @MainActor func show() {
        // Onboarding (T-102) owns this window while permissions are missing (AC-ONB-1).
        guard Permissions.allGranted, RecordingController.shared.state == .idle,
              NSApp.modalWindow == nil, !requestingDeviceAccess else { return }
        if panel != nil {
            presentPicker()
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

        let p = FloatingPanel(content: view, draggable: true)
        position(p)
        panel = p
        observeDevices()
        presentPicker()
        guard panel === p else { return }
        updateCameraBubble(deviceID: RecordingSettings.shared.cameraID) // reshow a previously-selected camera
    }

    private func presentPicker() {
        guard let panel, !requestingDeviceAccess else { return }
        SourcePickerOverlay.show(mode: RecordingSettings.shared.mode)
        // Ordering windows delivers focus notifications synchronously; close() may run inside it.
        guard self.panel === panel else { SourcePickerOverlay.close(); return }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    /// `ⓧ` or `Esc`: close the toolbar and any overlay; the app keeps running (SPEC §4.2, AC-TB-4).
    func close() {
        guard panel != nil || SourcePickerOverlay.isOpen || AreaSelectionOverlay.isOpen else { return }
        deviceRequest = UUID()
        requestingDeviceAccess = false
        SourcePickerOverlay.close()
        panel?.orderOut(nil)
        panel = nil
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers.removeAll()
        updateCameraBubble(deviceID: nil)
    }

    /// Sets the recording mode and shows its picker overlay (SPEC §4.2: "selecting a source mode
    /// immediately shows that mode's overlay"). The one entry point for mode selection — reused by the
    /// toolbar buttons here, the status-item menu (T-207b) and global hotkeys (T-204).
    @MainActor func selectMode(_ mode: RecordingSettings.Mode) {
        guard RecordingController.shared.state == .idle, NSApp.modalWindow == nil else { return }
        RecordingSettings.shared.mode = mode
        show()
    }

    /// `Esc`, from any of our windows — the toolbar panel or any overlay (`SourcePickerWindow`,
    /// `AreaSelectionWindow`, `AreaFieldsHostingView`) — routes here: closes the frontmost overlay first
    /// and re-keys the toolbar so a second `Esc` reaches it; with no overlay open, closes the toolbar
    /// (SPEC AC-TB-4). One shared handler instead of each window redoing the "close overlay, reshow
    /// toolbar" logic keeps the order correct no matter which window happened to be key. Re-keys the
    /// panel directly (not `show()`, which would also re-open the overlay we just closed).
    func handleEscape() {
        guard SourcePickerOverlay.isOpen || AreaSelectionOverlay.isOpen else { close(); return }
        SourcePickerOverlay.close()
        panel?.makeKeyAndOrderFront(nil)
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
        deviceObservers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let s = RecordingSettings.shared
            if s.cameraID == device.uniqueID {
                s.cameraID = nil
                self?.updateCameraBubble(deviceID: nil)
            }
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
        let id = sender.representedObject as? String
        RecordingSettings.shared.cameraID = id
        updateCameraBubble(deviceID: id)
    }

    /// Shows/hides `CameraBubblePanel` to match the current camera selection (SPEC §4.6): "When a camera
    /// is selected, a live preview bubble appears." Resolves TCC (and any device open failure) async;
    /// bails out gracefully, and drops a stale result if the selection changed again meanwhile.
    private func updateCameraBubble(deviceID: String?) {
        cameraCapture = nil
        CameraBubblePanel.hide()
        guard let deviceID else { return }
        requestDeviceAccess(.video) { [weak self] granted in
            guard let self, self.panel != nil, RecordingSettings.shared.cameraID == deviceID else { return }
            guard granted else {
                RecordingSettings.shared.cameraID = nil
                return
            }
            CameraCapture.request(deviceID: deviceID) { capture in
                guard let capture else {
                    RecordingSettings.shared.cameraID = nil
                    self.showDeviceError("The selected camera could not be opened. Check that it is connected and available.")
                    return
                }
                self.cameraCapture = capture
                CameraBubblePanel.show(previewLayer: capture.previewLayer)
            }
        }
    }

    /// Keep the permission transaction alive through window ordering, which re-enters observers.
    private func suspendForDeviceAccess() -> UUID {
        deviceRequest = UUID()
        requestingDeviceAccess = true
        SourcePickerOverlay.close()
        panel?.orderOut(nil)
        return deviceRequest
    }

    private func restoreAfterDeviceAccess(request: UUID, completion: @escaping () -> Void) {
        // Leave native menu tracking / permission-dialog dismissal before ordering our panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deviceRequest == request, let panel = self.panel else { return }
            SourcePickerOverlay.close()
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            guard self.deviceRequest == request, self.panel === panel else { return }
            // Do not reopen an input-intercepting picker after a system dialog. The visible
            // toolbar's mode buttons explicitly resume source selection.
            completion()
            if self.deviceRequest == request { self.requestingDeviceAccess = false }
        }
    }

    private func requestDeviceAccess(_ mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        if status == .authorized { completion(true); return }
        let request = suspendForDeviceAccess()
        let finish: (Bool) -> Void = { [weak self] granted in
            guard let self, self.deviceRequest == request, self.panel != nil else { return }
            if !granted {
                let alert = NSAlert()
                alert.messageText = "Recording device unavailable"
                alert.informativeText = "Allow \(mediaType == .video ? "Camera" : "Microphone") access for Recorder in System Settings → Privacy & Security, then select the device again."
                alert.runModal()
            }
            self.restoreAfterDeviceAccess(request: request) { completion(granted) }
        }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { finish(granted) }
            }
        } else {
            DispatchQueue.main.async { finish(false) }
        }
    }

    private func showDeviceError(_ message: String) {
        let request = suspendForDeviceAccess()
        let alert = NSAlert()
        alert.messageText = "Recording device unavailable"
        alert.informativeText = message
        alert.runModal()
        restoreAfterDeviceAccess(request: request) {}
    }

    // MARK: - Microphone menu

    private func showMicrophoneMenu() {
        let s = RecordingSettings.shared
        let menu = NSMenu()
        for device in AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices {
            menu.addItem(menuItem(device.localizedName, checked: s.micID == device.uniqueID,
                                   action: #selector(selectMicrophone(_:)), represented: device.uniqueID))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Reduce noise and normalize volume on export", checked: s.denoise, action: #selector(toggleDenoise)))
        let gain = NSMenuItem(title: "Microphone gain is controlled by macOS / your device", action: nil, keyEquivalent: "")
        menu.addItem(gain)
        menu.addItem(.separator())
        menu.addItem(menuItem("Don't record microphone", checked: s.micID == nil, action: #selector(selectMicrophone(_:))))
        popUp(menu)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        RecordingSettings.shared.micID = id
        guard let id else { return }
        requestDeviceAccess(.audio) { granted in
            if !granted, RecordingSettings.shared.micID == id { RecordingSettings.shared.micID = nil }
        }
    }

    @objc private func toggleDenoise() { RecordingSettings.shared.denoise.toggle() }

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

/// `Esc` routes to `ToolbarController.handleEscape()` (AC-TB-4) via the standard `cancelOperation(_:)`
/// responder action (`FloatingPanel` is `final`, so this lives on the content view instead of a panel subclass).
private final class ToolbarHostingView: NSHostingView<ToolbarView> {
    override func cancelOperation(_ sender: Any?) { ToolbarController.shared.handleEscape() }
}

// Exercises real panel ordering and re-entrant notifications without changing the user's TCC grants.
extension ToolbarController {
    @MainActor static func runPermissionReturnSelfTest() async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        let toolbar = ToolbarController()
        defer { toolbar.close() }
        for mode in [RecordingSettings.Mode.display, .window, .area] {
            let panel = FloatingPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 56)), draggable: true)
            toolbar.panel = panel
            panel.orderFrontRegardless()
            SourcePickerOverlay.show(mode: mode)
            let request = toolbar.suspendForDeviceAccess()
            guard !panel.isVisible, !SourcePickerOverlay.isOpen, !AreaSelectionOverlay.isOpen else {
                throw Fail(description: "permission prompt left recording controls or picker visible")
            }
            let dialog = NSAlert().window
            // A document can become key as the permission dialog disappears or the panel is ordered.
            var deliveredFocus = false
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: panel, queue: .main) { _ in
                deliveredFocus = true
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: dialog)
            }
            var restored = false
            toolbar.restoreAfterDeviceAccess(request: request) { restored = true }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            NotificationCenter.default.removeObserver(observer)
            guard deliveredFocus, restored, toolbar.panel === panel, panel.isVisible, !toolbar.requestingDeviceAccess,
                  !SourcePickerOverlay.isOpen, !AreaSelectionOverlay.isOpen else {
                throw Fail(description: "permission return lost toolbar or reopened a blocking picker (\(mode))")
            }
            toolbar.presentPicker()
            guard panel.isVisible, SourcePickerOverlay.isOpen || AreaSelectionOverlay.isOpen else {
                throw Fail(description: "source selection could not resume from restored toolbar")
            }
            // Closing setup before an outstanding callback arrives must never resurrect it.
            let cancelled = toolbar.suspendForDeviceAccess()
            toolbar.close()
            var staleCompletionRan = false
            toolbar.restoreAfterDeviceAccess(request: cancelled) { staleCompletionRan = true }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard toolbar.panel == nil, !panel.isVisible, !staleCompletionRan,
                  !SourcePickerOverlay.isOpen, !AreaSelectionOverlay.isOpen else {
                throw Fail(description: "cancelled permission callback resurrected setup")
            }
        }
        print("Permission return: toolbar visible, picker closed, re-entrant focus and cancellation handled in all modes")
    }
}
