import AppKit
import SwiftUI

/// Command menu (⌘K, SPEC §8): a searchable list over the existing `NSMenu` items — walks
/// `NSApp.mainMenu` recursively and performs the picked item's action. No separate command registry
/// (T-607 ponytail rule). ONE entry point — `CommandMenu.show()` — bound to ⌘K by the coordinator later.
enum CommandMenu {
    fileprivate static var window: CommandMenuWindow?

    @MainActor
    static func show() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let commands = flatten(mainMenu)
        window?.close()
        let w = CommandMenuWindow(commands: commands)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    /// Depth-first walk of `menu`, collecting every performable leaf item: skips separators,
    /// disabled items, and items that only open a submenu (those aren't commands themselves —
    /// their children are what get listed, with this item's title prefixed to `path`).
    static func flatten(_ menu: NSMenu, path: [String] = []) -> [Command] {
        var out: [Command] = []
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if let submenu = item.submenu {
                out += flatten(submenu, path: path + [item.title])
                continue
            }
            guard item.isEnabled, item.action != nil else { continue }
            out.append(Command(title: item.title, path: path, keyEquivalent: Self.displayKey(item), item: item))
        }
        return out
    }

    /// Performs `command`'s underlying menu item exactly as AppKit would if it had been clicked.
    /// Shared by the UI (`CommandMenuView.perform`) and the `command-menu` selftest.
    @discardableResult
    static func perform(_ command: Command) -> Bool {
        guard let action = command.item.action else { return false }
        // `NSApplication.shared`, not the bare `NSApp` global: `NSApp` is only set as a side effect of
        // touching `.shared`, so it's nil under `--selftest` (which never runs `NSApplication.shared.run()`).
        return NSApplication.shared.sendAction(action, to: command.item.target, from: command.item)
    }

    private static func displayKey(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mods = item.keyEquivalentModifierMask
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch item.keyEquivalent {
        case "\r": s += "↩"
        case "\u{8}", "\u{7f}": s += "⌫"
        case "\u{1b}": s += "⎋"
        default: s += item.keyEquivalent.uppercased()
        }
        return s
    }
}

/// One flattened, performable `NSMenuItem`: its title, the chain of submenu titles above it, a
/// display-ready key equivalent, and the item itself (to perform).
struct Command: Identifiable {
    let id = UUID()
    let title: String
    let path: [String]
    let keyEquivalent: String
    let item: NSMenuItem

    var pathString: String { path.joined(separator: " ▸ ") }

    /// Case-insensitive substring-or-subsequence match against "path + title".
    /// // ponytail: naive scoring (substring, else in-order subsequence) — no fuzzy ranking; fine
    /// for a menu of a few dozen items, revisit if the command list grows into the hundreds.
    func matches(_ lowercasedQuery: String) -> Bool {
        guard !lowercasedQuery.isEmpty else { return true }
        let hay = (path + [title]).joined(separator: " ").lowercased()
        if hay.contains(lowercasedQuery) { return true }
        var qi = lowercasedQuery.startIndex
        for c in hay {
            guard qi < lowercasedQuery.endIndex else { break }
            if c == lowercasedQuery[qi] { qi = lowercasedQuery.index(after: qi) }
        }
        return qi == lowercasedQuery.endIndex
    }
}

/// Not `private`: the `command-menu-png` selftest renders it directly, offscreen.
struct CommandMenuView: View {
    let commands: [Command]
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [Command] {
        let q = query.lowercased()
        return commands.filter { $0.matches(q) }
    }

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            TextField("Search commands…", text: $query)
                .textFieldStyle(.plain)
                .font(Font(Theme.bodyFont))
                .foregroundStyle(Theme.textPrimaryColor)
                .padding(12)
                .focused($searchFocused)
                .onChange(of: query) { selected = 0 }
            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == selected)
                            .onTapGesture { selected = index; perform(rows) }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 480)
        .background(Theme.bgPanelColor)
        .onAppear { searchFocused = true }
        .onKeyPress(.upArrow) { move(-1, rows.count); return .handled }
        .onKeyPress(.downArrow) { move(1, rows.count); return .handled }
        .onKeyPress(.return) { perform(rows); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ command: Command, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                if !command.path.isEmpty {
                    Text(command.pathString)
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                }
            }
            Spacer()
            if !command.keyEquivalent.isEmpty {
                Text(command.keyEquivalent)
                    .font(Font(Theme.timecodeFont(11)))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.bgHoverColor : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = max(0, min(count - 1, selected + delta))
    }

    private func perform(_ rows: [Command]) {
        guard rows.indices.contains(selected) else { onClose(); return }
        let command = rows[selected]
        onClose()
        CommandMenu.perform(command)
    }
}

/// Plain borderless window (not `FloatingPanel`), `Theme` colours, Esc closes.
private final class CommandMenuWindow: NSWindow {
    init(commands: [Command]) {
        var closeAction: () -> Void = {}
        let hosting = NSHostingView(rootView: CommandMenuView(commands: commands, onClose: { closeAction() }))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                    styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = Theme.bgPanel
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: 480, height: hosting.fittingSize.height))
        center()
        closeAction = { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        if CommandMenu.window === self { CommandMenu.window = nil }
    }
}
