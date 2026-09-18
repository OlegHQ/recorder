import AppKit
import SwiftUI

/// Cheat sheet (⌘/, SPEC §7.3): a static grid of the editor keyboard map. ONE entry point —
/// `CheatSheet.show()` — bound to ⌘/ by the coordinator later (T-609 also touches shortcuts).
enum CheatSheet {
    private static var window: CheatSheetWindow?

    @MainActor
    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let w = CheatSheetWindow()
            window = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
    }
}

/// SPEC §7.3's table flattened to one key-combo per action — the source table packs several combos
/// into one cell (e.g. `⌘E ⌘S ⌘K ⌘/` → export/save/command menu/cheat sheet); flattened here so every
/// row reads as an unambiguous key → action pair. Order follows the spec table's left column then
/// right column, with that one multi-key cell expanded in place.
enum CheatSheetContent {
    struct Row: Identifiable {
        let id = UUID()
        let key: String
        let action: String
    }

    static let rows: [Row] = [
        Row(key: "Space", action: "play/pause"),
        Row(key: "← →", action: "±1 frame"),
        Row(key: "⇧← ⇧→", action: "±1 s"),
        Row(key: "J K L", action: "reverse/stop/forward shuttle"),
        Row(key: "Home End", action: "start/end"),
        Row(key: "↑ ↓", action: "prev/next edit point"),
        Row(key: "Esc", action: "cancel drag → exit split mode → deselect"),
        Row(key: "1 – 6", action: "inspector tabs"),
        Row(key: "C", action: "split at playhead"),
        Row(key: "⌥ hold / S", action: "split mode"),
        Row(key: "⌫", action: "remove selection"),
        Row(key: "Z", action: "add zoom at playhead"),
        Row(key: "⌘Z ⇧⌘Z", action: "undo/redo"),
        Row(key: "⌘= ⌘- ⇧Z", action: "timeline zoom in/out/fit"),
        Row(key: "⌘E", action: "export"),
        Row(key: "⌘S", action: "save"),
        Row(key: "⌘K", action: "command menu"),
        Row(key: "⌘/", action: "cheat sheet"),
        Row(key: "⌘D", action: "duplicate selected zoom/mask after itself"),
    ]
}

/// Not `private`: the `cheatsheet-png` selftest renders it directly, offscreen.
struct CheatSheetView: View {
    private static let columns = split(CheatSheetContent.rows)

    /// Two half-length columns (source table is two-up), read top-to-bottom then left-to-right.
    private static func split(_ rows: [CheatSheetContent.Row]) -> ([CheatSheetContent.Row], [CheatSheetContent.Row]) {
        let mid = (rows.count + 1) / 2
        return (Array(rows[0..<mid]), Array(rows[mid...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(Font(Theme.titleFont))
                .foregroundStyle(Theme.textPrimaryColor)
            HStack(alignment: .top, spacing: 32) {
                grid(Self.columns.0)
                grid(Self.columns.1)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.bgPanelColor)
    }

    private func grid(_ rows: [CheatSheetContent.Row]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .font(Font(Theme.timecodeFont(13)))
                        .foregroundStyle(Theme.accentTextColor)
                        .gridColumnAlignment(.trailing)
                    Text(row.action)
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textPrimaryColor)
                        .gridColumnAlignment(.leading)
                }
            }
        }
    }
}

/// Plain titled window (not `FloatingPanel` — this isn't a recording-flow surface), `Theme` colours,
/// Esc closes (`cancelOperation`, the same pattern as `CropSheetWindow`/`ToolbarController`).
private final class CheatSheetWindow: NSWindow {
    init() {
        let hosting = NSHostingView(rootView: CheatSheetView())
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        titlebarAppearsTransparent = true
        backgroundColor = Theme.bgPanel
        isReleasedWhenClosed = false
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        setContentSize(hosting.fittingSize)
        center()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}
