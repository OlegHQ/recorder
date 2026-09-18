import AppKit
import SwiftUI
import ScreenCaptureKit

/// Display picker (SPEC §4.3) and window picker (SPEC §4.4): one borderless full-screen overlay panel
/// per `NSScreen`, shown/closed together. `ToolbarController.selectMode(_:)` is the one place that sets
/// the mode and calls `show(mode:)` — reused by the toolbar buttons, the status menu (T-207b) and
/// hotkeys (T-204). Area mode has its own overlay (`AreaSelectionOverlay`, T-108).
enum SourcePickerOverlay {
    private static var windows: [SourcePickerWindow] = []
    private static var state: SourcePickerState?

    /// Shows one overlay per screen for `.display`/`.window`. No-op for `.area` (T-108's overlay).
    static func show(mode: RecordingSettings.Mode) {
        close()
        guard mode == .display || mode == .window else { return }

        let state = SourcePickerState()
        state.activeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        self.state = state

        windows = NSScreen.screens.map { SourcePickerWindow(screen: $0, mode: mode, state: state) }
        windows.forEach { $0.orderFrontRegardless() }
        state.activeScreen.flatMap { active in windows.first { $0.targetScreen === active } }?.makeKeyAndOrderFront(nil)

        refreshContent(into: state)
    }

    static func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        state = nil
    }

    /// `Start recording` hook (button or `Return`). T-111 will point this at
    /// `RecordingController.shared.begin(target:)`; until then it just closes the pickers and logs.
    static func startRecording(target: CaptureTarget) {
        close()
        NSLog("Recorder: start recording target=\(target)")
    }

    // ponytail: the window list is fetched once when the picker opens, not re-polled while it's open
    // (SPEC only asks for live *hover* tracking, not a live window list). Upgrade path: re-fetch on an
    // interval if windows opening/closing while the picker is up turns out to matter.
    private static func refreshContent(into state: SourcePickerState) {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            state.displays = content.displays
            state.windows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100
                    && !FloatingPanel.allWindowIDs.contains($0.windowID)
            }
        }
    }

    /// Converts a top-left-origin **global** rect (the `SCWindow.frame`/`SCDisplay.frame` convention)
    /// into `screen`'s local, bottom-left-origin view coordinates. Reused by `EventRecorder` (T-109).
    static func flip(_ r: CGRect, in screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens[0].frame.height
        let globalMinY = primaryTop - r.maxY // AppKit-global (bottom-left) y of the rect's bottom edge
        return CGRect(x: r.minX - screen.frame.minX, y: globalMinY - screen.frame.minY, width: r.width, height: r.height)
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
            screen: screen, mode: mode, state: state, onStart: { [weak self] in self?.start() }
        ))
        hostingView.onCancel = { [weak self] in self?.cancel() }
        hostingView.onReturn = { [weak self] in self?.start() }
        hostingView.onEnter = { [weak self] in self?.enter() }
        hostingView.onExit = { [weak self] in self?.exit() }
        hostingView.onMove = { [weak self] point in self?.moved(to: point) }
        contentView = hostingView

        FloatingPanel.register(self)
    }

    override var canBecomeKey: Bool { true }

    private func enter() {
        if mode == .display { state.activeScreen = targetScreen }
        makeKeyAndOrderFront(nil)
    }

    private func exit() {
        if mode == .display, state.activeScreen === targetScreen { state.activeScreen = nil }
    }

    private func moved(to localPoint: NSPoint) {
        guard mode == .window else { return }
        let primaryTop = NSScreen.screens[0].frame.height
        let global = NSPoint(x: targetScreen.frame.minX + localPoint.x, y: targetScreen.frame.minY + localPoint.y)
        let cgPoint = CGPoint(x: global.x, y: primaryTop - global.y) // AppKit-global → CG-global (top-left)
        state.hoveredWindow = state.windows.first { $0.frame.contains(cgPoint) }
    }

    private func cancel() {
        SourcePickerOverlay.close()
        ToolbarController.shared.show() // re-key the toolbar so a second Esc reaches it (AC-TB-4)
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
}

/// Routes AppKit mouse/key events (SwiftUI has no hover/keyDown hooks that fit the picker's needs) into
/// the closures `SourcePickerWindow` wires up.
private final class SourcePickerHostingView: NSHostingView<SourcePickerContentView> {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }

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
                Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                    .font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
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
/// `RecordingSettings.countdown`, the same setting the toolbar's gear menu edits.
private struct StartRecordingButton: View {
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

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
