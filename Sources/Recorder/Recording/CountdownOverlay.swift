import AppKit
import SwiftUI

/// SPEC §4.7: pre-recording countdown — a big number centred on the capture target, scaling and
/// fading each second; `Esc` cancels back to the picker. `RecordingController.begin` (not built yet)
/// will `await run(seconds:over:)` when `countdown > 0`.
enum CountdownOverlay {
    /// Counts down from `seconds` to 1, one second per number, in a `FloatingPanel` centred on `rect`
    /// (screen coordinates). Returns `false` if `Esc` cancelled it, `true` once it finishes normally.
    @MainActor
    static func run(seconds: Int, over rect: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        return await withCheckedContinuation { continuation in
            let state = CountdownState(remaining: seconds)
            let hosting = CountdownHostingView(rootView: CountdownView(state: state))
            let panel = FloatingPanel(content: hosting, draggable: false)
            panel.setFrameOrigin(NSPoint(x: rect.midX - panel.frame.width / 2, y: rect.midY - panel.frame.height / 2))

            var timer: Timer?
            var resumed = false
            @MainActor func finish(_ result: Bool) {
                guard !resumed else { return }
                resumed = true
                timer?.invalidate()
                panel.orderOut(nil)
                continuation.resume(returning: result)
            }

            hosting.onCancel = { finish(false) }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    guard !resumed else { return }
                    if state.remaining <= 1 {
                        finish(true)
                    } else {
                        state.remaining -= 1
                    }
                }
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor @Observable final class CountdownState {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

/// SPEC §4.7 mockup: 72 pt number, scaling and fading in/out as `remaining` ticks down each second.
struct CountdownView: View {
    var state: CountdownState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text("\(state.remaining)")
                .id(state.remaining)
                .font(Font(Theme.headingFont(80)))
                .foregroundStyle(Theme.textPrimaryColor)
                .transition(reduceMotion ? .opacity : .scale(scale: 1.18).combined(with: .opacity))
        }
        .frame(width: 160, height: 160)
        .signalWindow()
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.contextReveal), value: state.remaining)
    }
}

/// `Esc` cancels the countdown (SPEC §4.7), same pattern as `AreaFieldsHostingView`.
private final class CountdownHostingView: NSHostingView<CountdownView> {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
