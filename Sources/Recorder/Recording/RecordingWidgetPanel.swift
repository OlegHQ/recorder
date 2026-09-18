import AppKit
import SwiftUI

/// SPEC §4.7 in-progress controls: bottom-centre, draggable, excluded from capture (`FloatingPanel`
/// already handles that). Shown by `RecordingController.start(target:)` while recording, hidden by
/// `reset()` (finish/cancel) — right-click also hides it early ("Hide widget", same as the status menu's
/// item, SPEC §8). Finish/Pause⇄Resume/Restart/Delete call `RecordingController`'s one implementation
/// each, the same methods the status-item menu (T-207b) calls.
@MainActor enum RecordingWidgetPanel {
    private static var panel: FloatingPanel?
    private static var timer: Timer?
    private static var state = WidgetState()

    static func show() {
        hide()
        tick()
        let view = WidgetHostingView(rootView: RecordingWidgetView(state: state))
        let p = FloatingPanel(content: view, draggable: true)
        position(p)
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
        timer?.invalidate()
        timer = nil
    }

    private static func tick() {
        let rc = RecordingController.shared
        state.elapsed = rc.elapsed
        state.isPaused = rc.state == .paused
    }

    /// Bottom-centre of the display under the mouse, 40 pt above the Dock — same placement as the toolbar.
    private static func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40))
    }
}

@Observable private final class WidgetState {
    var elapsed: Double = 0
    var isPaused = false
}

/// SPEC §4.7 mockup: `● 00:42 │ ■ Finish  ❙❙  ↺  🗑`.
private struct RecordingWidgetView: View {
    var state: WidgetState

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(Theme.dangerColor).frame(width: 8, height: 8)
                Text(timecode).font(Font(Theme.timecodeFont(15))).foregroundStyle(Theme.textPrimaryColor)
            }
            divider
            HStack(spacing: 16) {
                Button { RecordingController.shared.finish() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("Finish")
                    }
                }
                .buttonStyle(.plain)
                button(state.isPaused ? "play.fill" : "pause.fill", label: state.isPaused ? "Resume" : "Pause") {
                    state.isPaused ? RecordingController.shared.resume() : RecordingController.shared.pause()
                }
                button("arrow.counterclockwise", label: "Restart") { RecordingController.shared.restart() }
                button("trash", label: "Delete") { RecordingController.shared.delete() }
            }
        }
        .foregroundStyle(Theme.textPrimaryColor)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .fixedSize()
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help(label)
    }

    private var divider: some View {
        Rectangle().fill(Theme.strokeColor).frame(width: 1, height: 20)
    }

    private var timecode: String {
        let s = Int(state.elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Right-click → Hide (SPEC §4.7).
private final class WidgetHostingView: NSHostingView<RecordingWidgetView> {
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Hide", action: #selector(hideAction), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func hideAction() { RecordingWidgetPanel.hide() }
}
