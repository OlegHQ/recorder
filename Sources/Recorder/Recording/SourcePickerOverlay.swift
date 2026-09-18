import AppKit
import SwiftUI
import ScreenCaptureKit

/// Display picker (SPEC §4.3) and window picker (SPEC §4.4): one borderless full-screen overlay panel
/// per `NSScreen`, shown/closed together. `ToolbarController.selectMode(_:)` is the one place that sets
/// the mode and calls `show(mode:)` — reused by the toolbar buttons, the status menu (T-207b) and
/// hotkeys (T-204). Area mode has its own overlay (`AreaSelectionOverlay`); `show`/`close` route to it.
enum SourcePickerOverlay {
    private static var windows: [SourcePickerWindow] = []
    private static var state: SourcePickerState?
    private static var refreshTimer: Timer?

    /// Whether a display/window picker is currently up. Used by `ToolbarController.handleEscape()` to
    /// decide whether `Esc` should close the overlay or the toolbar (AC-TB-4).
    static var isOpen: Bool { !windows.isEmpty }

    /// Shows one overlay per screen for `.display`/`.window`; routes to `AreaSelectionOverlay` for `.area`.
    static func show(mode: RecordingSettings.Mode) {
        close()
        guard mode == .display || mode == .window else {
            if mode == .area { AreaSelectionOverlay.show() }
            return
        }

        let state = SourcePickerState()
        state.activeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        self.state = state

        windows = NSScreen.screens.map { SourcePickerWindow(screen: $0, mode: mode, state: state) }
        windows.forEach { $0.orderFrontRegardless() }
        state.activeScreen.flatMap { active in windows.first { $0.targetScreen === active } }?.makeKeyAndOrderFront(nil)

        refreshContent(into: state)
        // Windows open/close/move while the picker is up (SPEC AC-WIN-1 "tracks the front-most window");
        // a one-time fetch goes stale. A 1 s poll is simple and cheap next to a live window-list
        // subscription, which ScreenCaptureKit doesn't offer.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in refreshContent(into: state) }
    }

    static func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        state = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        AreaSelectionOverlay.close()
    }

    /// `Start recording` hook (button or `Return`). T-111 will point this at
    /// `RecordingController.shared.begin(target:)`; until then it just closes the pickers and logs.
    static func startRecording(target: CaptureTarget) {
        close()
        NSLog("Recorder: start recording target=\(target)")
    }

    // `fileprivate`, not `private`: also called by `SourcePickerWindow` after a resize (T-206) so the
    // picker's highlighted frame/size line re-reads the window's new frame (AC-WIN-2), and by `show`'s
    // 1 s poll (AC-WIN-1) so the list doesn't go stale while the picker is up.
    fileprivate static func refreshContent(into state: SourcePickerState) {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            state.displays = content.displays
            state.windows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100
                    && !FloatingPanel.allWindowIDs.contains($0.windowID)
            }
            if let id = state.hoveredWindow?.windowID { state.hoveredWindow = state.windows.first { $0.windowID == id } }
        }
    }

    /// Converts a top-left-origin **global** rect (the `SCWindow.frame`/`SCDisplay.frame` convention)
    /// into `screen`'s local, bottom-left-origin view coordinates. Reused by `EventRecorder` (T-109).
    static func flip(_ r: CGRect, in screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens[0].frame.height
        let globalMinY = primaryTop - r.maxY // AppKit-global (bottom-left) y of the rect's bottom edge
        return CGRect(x: r.minX - screen.frame.minX, y: globalMinY - screen.frame.minY, width: r.width, height: r.height)
    }

    /// AppKit-global (bottom-left-origin, primary-screen-based — `NSEvent.mouseLocation`'s convention)
    /// point → CG-global (top-left-origin — `SCWindow.frame`'s convention) point. The point half of `flip`.
    static func cgGlobalPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y)
    }

    /// Front-to-back on-screen window IDs from the window server. `SCShareableContent.windows` is *not*
    /// z-ordered, which was the root cause of the window picker highlighting whichever overlapping window
    /// happened to come first in that unordered list instead of the one actually under the cursor
    /// (AC-WIN-1). Matched against `SCWindow`s by `windowID` in `frontmostWindow(at:order:frames:)`.
    static func frontToBackWindowIDs() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// The front-most window (by `order`) whose frame contains `point`, or `nil`. Pure so the `pickers`
    /// selftest can exercise it with synthetic data instead of a live window-server call.
    static func frontmostWindow(at point: CGPoint, order: [CGWindowID], frames: [CGWindowID: CGRect]) -> CGWindowID? {
        order.first { frames[$0]?.contains(point) ?? false }
    }
}

/// Shared, live-updated state for every picker window (one `SourcePickerState` per `show(mode:)` call).
/// `@Observable` so all screens' SwiftUI content redraw together as the mouse moves.
@Observable private final class SourcePickerState {
    var displays: [SCDisplay] = []
    var windows: [SCWindow] = []
    var activeScreen: NSScreen?   // display mode: the screen under the mouse
    var hoveredWindow: SCWindow?  // window mode: front-most window under the mouse
}

/// One per `NSScreen`. Borderless, non-activating, one level below `FloatingPanel` (SPEC §4 window/panel
/// rule), excluded from capture via `FloatingPanel.register`.
private final class SourcePickerWindow: NSPanel {
    // Not named `screen`: NSWindow already declares that property (its "best screen for this window").
    let targetScreen: NSScreen
    private let mode: RecordingSettings.Mode
    private let state: SourcePickerState

    init(screen: NSScreen, mode: RecordingSettings.Mode, state: SourcePickerState) {
        self.targetScreen = screen
        self.mode = mode
        self.state = state
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 2) // one below FloatingPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)

        let hostingView = SourcePickerHostingView(rootView: SourcePickerContentView(
            screen: screen, mode: mode, state: state,
            onStart: { [weak self] in self?.start() },
            onResize: { [weak self] in self?.showResizeMenu() }
        ))
        hostingView.onReturn = { [weak self] in self?.start() }
        hostingView.onEnter = { [weak self] in self?.enter() }
        hostingView.onExit = { [weak self] in self?.exit() }
        hostingView.onMove = { [weak self] in self?.moved() }
        contentView = hostingView

        FloatingPanel.register(self)
    }

    override var canBecomeKey: Bool { true }

    // Same fix, same reason, as `FloatingPanel.makeKeyAndOrderFront` (see its comment): `contentView` was
    // never `initialFirstResponder`, so without this override first responder stayed the window itself,
    // which has no `cancelOperation` — a mode switch made this overlay key but `Esc` reached nothing
    // (AC-TB-4).
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        if let contentView { makeFirstResponder(contentView) }
    }

    private func enter() {
        if mode == .display { state.activeScreen = targetScreen }
        makeKeyAndOrderFront(nil)
    }

    private func exit() {
        if mode == .display, state.activeScreen === targetScreen { state.activeScreen = nil }
    }

    /// Highlights the front-most on-screen window under the mouse (AC-WIN-1). Uses `NSEvent.mouseLocation`
    /// directly (AppKit-global) rather than the tracking area's view-local point: `SourcePickerHostingView`
    /// is an `NSHostingView`, which SwiftUI always flips (top-left origin) — treating that local point as
    /// bottom-left AppKit coordinates (as the old code did) mirrored the hit-test point vertically within
    /// the screen, which is why hover picked "random" windows.
    private func moved() {
        guard mode == .window else { return }
        let cgPoint = SourcePickerOverlay.cgGlobalPoint(NSEvent.mouseLocation)
        let frames = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.windowID, $0.frame) })
        let order = SourcePickerOverlay.frontToBackWindowIDs()
        let id = SourcePickerOverlay.frontmostWindow(at: cgPoint, order: order, frames: frames)
        state.hoveredWindow = id.flatMap { i in state.windows.first { $0.windowID == i } }
    }

    private func start() {
        guard let target = currentTarget() else { return }
        SourcePickerOverlay.startRecording(target: target)
    }

    private func currentTarget() -> CaptureTarget? {
        switch mode {
        case .display:
            guard state.activeScreen === targetScreen, let id = targetScreen.displayID,
                  let display = state.displays.first(where: { $0.displayID == id }) else { return nil }
            return .display(display)
        case .window:
            return state.hoveredWindow.map { .window($0) }
        case .area:
            return nil
        }
    }

    // MARK: - Resize (T-206, SPEC §4.4 `[Resize]` menu, AC-WIN-2)

    private func showResizeMenu() {
        guard let window = state.hoveredWindow, let pid = window.owningApplication?.processID else { return }
        let screenSize = targetScreen.frame.size
        let menu = NSMenu()

        func item(_ title: String, _ size: CGSize) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(resizeToPreset(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = ResizeTarget(pid: pid, title: window.title, size: size)
            i.isEnabled = size.width <= screenSize.width && size.height <= screenSize.height // sizes bigger than the display are disabled
            return i
        }

        ResizePresets.quick.forEach { menu.addItem(item($0.0, $0.1)) }
        menu.addItem(.separator())
        for (ratio, sizes) in ResizePresets.ratios {
            let sub = NSMenu()
            sizes.forEach { sub.addItem(item($0.0, $0.1)) }
            let ratioItem = NSMenuItem(title: ratio, action: nil, keyEquivalent: "")
            ratioItem.submenu = sub
            menu.addItem(ratioItem)
        }

        let saved = SavedWindowSizes.all
        if !saved.isEmpty {
            menu.addItem(.separator())
            saved.forEach { menu.addItem(item("\(Int($0.width)) × \(Int($0.height))", $0)) }
        }
        menu.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save current size", action: #selector(saveCurrentSize(_:)), keyEquivalent: "")
        saveItem.target = self
        saveItem.representedObject = ResizeTarget(pid: pid, title: window.title, size: window.frame.size)
        menu.addItem(saveItem)

        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom…", action: #selector(showCustomSizeAlert(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.representedObject = ResizeTarget(pid: pid, title: window.title, size: window.frame.size)
        menu.addItem(customItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func resizeToPreset(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ResizeTarget else { return }
        WindowResizer.resize(pid: target.pid, windowTitle: target.title, to: target.size)
        SourcePickerOverlay.refreshContent(into: state)
    }

    @objc private func saveCurrentSize(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ResizeTarget else { return }
        SavedWindowSizes.add(target.size)
    }

    @objc private func showCustomSizeAlert(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ResizeTarget else { return }

        let widthLabel = NSTextField(labelWithString: "Width:")
        widthLabel.frame = NSRect(x: 0, y: 28, width: 55, height: 24)
        let widthField = NSTextField(string: "\(Int(target.size.width))")
        widthField.frame = NSRect(x: 60, y: 28, width: 120, height: 24)
        let heightLabel = NSTextField(labelWithString: "Height:")
        heightLabel.frame = NSRect(x: 0, y: 0, width: 55, height: 24)
        let heightField = NSTextField(string: "\(Int(target.size.height))")
        heightField.frame = NSRect(x: 60, y: 0, width: 120, height: 24)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 56))
        [widthLabel, widthField, heightLabel, heightField].forEach(accessory.addSubview)

        let alert = NSAlert()
        alert.messageText = "Custom Size"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn,
              let w = Double(widthField.stringValue), let h = Double(heightField.stringValue), w > 0, h > 0 else { return }
        let size = CGSize(width: w, height: h)
        WindowResizer.resize(pid: target.pid, windowTitle: target.title, to: size)
        SavedWindowSizes.add(size)
        SourcePickerOverlay.refreshContent(into: state)
    }
}

private struct ResizeTarget {
    let pid: pid_t
    let title: String?
    let size: CGSize
}

/// SPEC §4.4 `[Resize]` menu contents (window content sizes, points).
private enum ResizePresets {
    static let quick: [(String, CGSize)] = [
        ("1280 × 720", CGSize(width: 1280, height: 720)),
        ("1920 × 1080", CGSize(width: 1920, height: 1080)),
        ("2560 × 1440", CGSize(width: 2560, height: 1440)),
    ]

    static let ratios: [(String, [(String, CGSize)])] = [
        ("4:3", [("640 × 480", CGSize(width: 640, height: 480)),
                 ("800 × 600", CGSize(width: 800, height: 600)),
                 ("1024 × 768", CGSize(width: 1024, height: 768)),
                 ("1280 × 960", CGSize(width: 1280, height: 960)),
                 ("1600 × 1200", CGSize(width: 1600, height: 1200))]),
        ("9:16", [("360 × 640", CGSize(width: 360, height: 640)),
                  ("540 × 960", CGSize(width: 540, height: 960)),
                  ("720 × 1280", CGSize(width: 720, height: 1280)),
                  ("810 × 1440", CGSize(width: 810, height: 1440)),
                  ("1080 × 1920", CGSize(width: 1080, height: 1920))]),
        ("16:10", [("1280 × 800", CGSize(width: 1280, height: 800)),
                   ("1440 × 900", CGSize(width: 1440, height: 900)),
                   ("1680 × 1050", CGSize(width: 1680, height: 1050)),
                   ("1920 × 1200", CGSize(width: 1920, height: 1200)),
                   ("2560 × 1600", CGSize(width: 2560, height: 1600))]),
        ("Square", [("480 × 480", CGSize(width: 480, height: 480)),
                    ("600 × 600", CGSize(width: 600, height: 600)),
                    ("800 × 800", CGSize(width: 800, height: 800)),
                    ("1000 × 1000", CGSize(width: 1000, height: 1000)),
                    ("1200 × 1200", CGSize(width: 1200, height: 1200))]),
    ]
}

/// Saved custom sizes (SPEC §4.4 "(saved sizes…) / Save current size"), remembered across launches.
private enum SavedWindowSizes {
    private static let key = "WindowResizer.savedSizes"

    static var all: [CGSize] {
        (UserDefaults.standard.array(forKey: key) as? [[Double]] ?? []).compactMap {
            $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil
        }
    }

    static func add(_ size: CGSize) {
        var sizes = all
        guard !sizes.contains(size) else { return }
        sizes.append(size)
        UserDefaults.standard.set(sizes.map { [$0.width, $0.height] }, forKey: key)
    }
}

/// Routes AppKit mouse/key events (SwiftUI has no hover/keyDown hooks that fit the picker's needs) into
/// the closures `SourcePickerWindow` wires up.
private final class SourcePickerHostingView: NSHostingView<SourcePickerContentView> {
    var onReturn: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMove: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override var acceptsFirstResponder: Bool { true }
    // Esc: one shared handler, regardless of which of our windows is key (AC-TB-4) — see
    // `ToolbarController.handleEscape()`.
    override func cancelOperation(_ sender: Any?) { ToolbarController.shared.handleEscape() }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onReturn?() } else { super.keyDown(with: event) } // Return
    }
}

/// SPEC §4.3/§4.4 mockups: dim + (on the active screen / hovered window) title + size + Start button.
private struct SourcePickerContentView: View {
    let screen: NSScreen
    let mode: RecordingSettings.Mode
    var state: SourcePickerState
    var onStart: () -> Void
    var onResize: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(dimOpacity)
            switch mode {
            case .display: displayContent
            case .window: windowContent
            case .area: EmptyView()
            }
        }
        .frame(width: screen.frame.width, height: screen.frame.height)
    }

    private var dimOpacity: Double {
        mode == .display ? (state.activeScreen === screen ? 0.45 : 0.65) : 0.45
    }

    @ViewBuilder private var displayContent: some View {
        if state.activeScreen === screen {
            VStack(spacing: 16) {
                Text(screen.localizedName)
                    .font(Font(Theme.titleFont)).foregroundStyle(Theme.textPrimaryColor)
                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height)) · 60FPS")
                    .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                StartRecordingButton(action: onStart)
            }
        }
    }

    @ViewBuilder private var windowContent: some View {
        if let window = state.hoveredWindow {
            let local = swiftUIRect(for: window.frame)
            Rectangle()
                .fill(Theme.accentColor.opacity(0.25))
                .overlay(Rectangle().stroke(Theme.accentColor, lineWidth: 2))
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
                .onTapGesture(perform: onStart)

            VStack(spacing: 10) {
                if let icon = icon(for: window) {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
                Text(title(for: window))
                    .font(Font(Theme.titleFont)).foregroundStyle(Theme.textPrimaryColor)
                HStack(spacing: 8) {
                    Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                        .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                    Button("Resize", action: onResize)
                        .buttonStyle(.plain)
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.bgControlColor, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                StartRecordingButton(action: onStart)
            }
            .position(x: local.midX, y: local.midY)
            .allowsHitTesting(true)
        }
    }

    /// `window.frame` (CG top-left, global) → this screen's local SwiftUI (top-left) coordinates, via
    /// `SourcePickerOverlay.flip` (AppKit bottom-left local) plus one more flip for SwiftUI's own axis.
    private func swiftUIRect(for globalFrame: CGRect) -> CGRect {
        let appKitLocal = SourcePickerOverlay.flip(globalFrame, in: screen)
        return CGRect(x: appKitLocal.minX, y: screen.frame.height - appKitLocal.maxY,
                       width: appKitLocal.width, height: appKitLocal.height)
    }

    private func title(for window: SCWindow) -> String {
        window.owningApplication?.applicationName ?? window.title ?? "Window"
    }

    private func icon(for window: SCWindow) -> NSImage? {
        guard let pid = window.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// Accent "Start recording" button with a `⌄` countdown submenu (SPEC §4.3/§4.4). Reuses
/// `RecordingSettings.countdown`, the same setting the toolbar's gear menu edits. Not private:
/// reused by `AreaSelectionOverlay` (T-108).
struct StartRecordingButton: View {
    var action: () -> Void
    private let options: [(String, Int)] = [("Off", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)]

    var body: some View {
        HStack(spacing: 1) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "smallcircle.filled.circle")
                    Text("Start recording").fontWeight(.semibold)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(options, id: \.1) { title, value in
                    Button {
                        RecordingSettings.shared.countdown = value
                    } label: {
                        if RecordingSettings.shared.countdown == value { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").padding(.horizontal, 10).padding(.vertical, 10)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .background(Theme.accentColor)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

// Not private: reused by `AreaSelectionOverlay` (T-108).
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
