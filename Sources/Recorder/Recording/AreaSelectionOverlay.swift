import AppKit
import SwiftUI
import ScreenCaptureKit

/// Area selection overlay (SPEC §4.5): a full-screen overlay panel on the display under the mouse,
/// hosting `SelectionRectView` (T-105, shared with the crop sheet) plus the Start button below the
/// toolbar, and a small `FloatingPanel` with Size/Position fields. Shown/closed by
/// `SourcePickerOverlay.show(mode:)`/`close()` alongside the display/window pickers (T-107) — same
/// window level, `FloatingPanel.allWindowIDs` registration, and `Esc` order (AC-TB-4).
enum AreaSelectionOverlay {
    private static var window: AreaSelectionWindow?
    private static var fieldsPanel: FloatingPanel?

    static func show() {
        close()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let displayID = screen.displayID else { return }

        let saved = loadRect(for: displayID)
        let rect = saved.isEmpty ? CGRect.zero : flipped(saved, screenHeight: screen.frame.height)
        let state = AreaSelectionState(displayID: displayID, screenSize: screen.frame.size, rect: rect)

        let win = AreaSelectionWindow(screen: screen, state: state)
        win.makeKeyAndOrderFront(nil)
        window = win

        let panel = FloatingPanel(content: AreaFieldsHostingView(rootView: AreaFieldsView(state: state)), draggable: false)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                      y: screen.visibleFrame.minY + 40 + 56 + 12)) // above the toolbar (SPEC §4.5 mockup)
        panel.orderFrontRegardless()
        fieldsPanel = panel

        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            state.displays = content.displays
        }
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
        fieldsPanel?.orderOut(nil)
        fieldsPanel = nil
    }

    /// `Start recording` hook, mirroring `SourcePickerOverlay.startRecording(target:)`.
    fileprivate static func start(state: AreaSelectionState) {
        guard !state.rect.isEmpty, let display = state.displays.first(where: { $0.displayID == state.displayID }) else { return }
        SourcePickerOverlay.startRecording(target: .area(display, state.topLeft))
    }

    fileprivate static func saveRect(_ topLeft: CGRect, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(NSStringFromRect(topLeft), forKey: "area.rect.\(displayID)")
    }

    private static func loadRect(for displayID: CGDirectDisplayID) -> CGRect {
        guard let s = UserDefaults.standard.string(forKey: "area.rect.\(displayID)") else { return .zero }
        return NSRectFromString(s)
    }

    /// Top-left-origin rect (display points — `CaptureTarget.area`'s convention, same as
    /// `SourcePickerOverlay.flip`'s inputs) ↔ bottom-left-origin view coords (`SelectionRectView.rect`'s
    /// convention). Self-inverse, so one function does both directions.
    fileprivate static func flipped(_ r: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Bridges `SelectionRectView` (AppKit) and the SwiftUI Size/Position fields, and persists the rect.
@Observable private final class AreaSelectionState {
    let displayID: CGDirectDisplayID
    let screenSize: CGSize
    var rect: CGRect { didSet { AreaSelectionOverlay.saveRect(topLeft, for: displayID) } } // SelectionRectView coords
    var displays: [SCDisplay] = []
    /// Set by `AreaSelectionWindow` to `{ selectionView.rect = $0 }` so field edits go through the same
    /// clamp/min-size logic as mouse drags.
    var apply: (CGRect) -> Void = { _ in }

    init(displayID: CGDirectDisplayID, screenSize: CGSize, rect: CGRect) {
        self.displayID = displayID
        self.screenSize = screenSize
        self.rect = rect
    }

    /// Display-local, top-left-origin rect: SPEC §4.5 Position fields' convention and `CaptureTarget.area`'s.
    var topLeft: CGRect {
        get { AreaSelectionOverlay.flipped(rect, screenHeight: screenSize.height) }
        set { apply(AreaSelectionOverlay.flipped(newValue, screenHeight: screenSize.height)) }
    }
}

/// Full-screen overlay panel hosting `SelectionRectView` and the Start button. Mirrors
/// `SourcePickerWindow`'s window/panel rules (SPEC §4 window/panel rule).
private final class AreaSelectionWindow: NSPanel {
    private let selectionView: SelectionRectView

    init(screen: NSScreen, state: AreaSelectionState) {
        let view = SelectionRectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.limit = view.bounds
        view.rect = state.rect
        self.selectionView = view

        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 2) // one below FloatingPanel, matches SourcePickerWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)

        let button = NSHostingView(rootView: StartRecordingButton(action: { AreaSelectionOverlay.start(state: state) }))
        let buttonSize = button.fittingSize
        let toolbarY = screen.visibleFrame.minY + 40 - screen.frame.minY // local (bottom-left) coords
        button.frame = CGRect(x: (screen.frame.width - buttonSize.width) / 2,
                               y: max(0, toolbarY - 12 - buttonSize.height),
                               width: buttonSize.width, height: buttonSize.height)

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.addSubview(button)
        contentView = container

        view.onChange = { [weak state] r in state?.rect = r }
        state.apply = { [weak view] r in view?.rect = r }

        FloatingPanel.register(self)
    }

    override var canBecomeKey: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(selectionView)
    }

    /// `Esc`: close the overlay and re-key the toolbar so a second `Esc` reaches it — same order as the
    /// other pickers (`SourcePickerWindow.cancel`, AC-TB-4).
    override func cancelOperation(_ sender: Any?) {
        AreaSelectionOverlay.close()
        ToolbarController.shared.show()
    }
}

/// SPEC §4.5 mockup: Size/Position numeric fields, two-way bound to the rect via `AreaSelectionState.topLeft`.
private struct AreaFieldsView: View {
    var state: AreaSelectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Size", \.size.width, \.size.height, separator: "×")
            row("Position", \.origin.x, \.origin.y, separator: "")
        }
        .padding(16)
    }

    private func row(_ title: String, _ a: WritableKeyPath<CGRect, CGFloat>, _ b: WritableKeyPath<CGRect, CGFloat>,
                      separator: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
                .frame(width: 56, alignment: .leading)
            field(a)
            if !separator.isEmpty { Text(separator).foregroundStyle(Theme.textSecondaryColor) }
            field(b)
            Text("px").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private func field(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        TextField("", value: binding(keyPath), format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.textPrimaryColor)
            .padding(6)
            .frame(width: 52)
            .background(Theme.bgControlColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private func binding(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int(state.topLeft[keyPath: keyPath].rounded()) },
            set: { newValue in
                var r = state.topLeft
                r[keyPath: keyPath] = CGFloat(newValue)
                state.topLeft = r
            }
        )
    }
}

/// `Esc` while a field is focused closes the overlay too, same as the selection view (AC-TB-4).
private final class AreaFieldsHostingView: NSHostingView<AreaFieldsView> {
    override func cancelOperation(_ sender: Any?) {
        AreaSelectionOverlay.close()
        ToolbarController.shared.show()
    }
}
