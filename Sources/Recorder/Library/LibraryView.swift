import SwiftUI
import AppKit

/// Project library window (SPEC §5.1 mockup): search + adaptive grid of recordings, inline rename,
/// per-card context menu, empty state, "New Recording". Hosted by `Library.show()`.
struct LibraryView: View {
    let store: ProjectStore

    @State private var search = ""
    @State private var selection: URL?
    @State private var renamingID: URL?
    @State private var renameText = ""

    private var filtered: [ProjectStore.Item] {
        search.isEmpty ? store.items : store.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 20) {
                        ForEach(filtered) { card($0) }
                    }
                    .padding(20)
                }
            }
        }
        .background(Theme.bgWindowColor)
        .frame(minWidth: 640, minHeight: 400)
        .focusable()
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            Library.open(selection)
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Projects")
                .font(Font(Theme.titleFont))
                .foregroundStyle(Theme.textPrimaryColor)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondaryColor)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.bgControlColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .frame(width: 220)

            Button(action: { ToolbarController.shared.show() }) {
                Label("New Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentColor)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("No recordings yet")
                .font(Font(Theme.bodyFont))
                .foregroundStyle(Theme.textSecondaryColor)
            Button(action: { ToolbarController.shared.show() }) {
                Label("New Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ item: ProjectStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.bgPanelColor)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay {
                        if let thumbnail = item.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                        }
                    }
                Text(Self.durationLabel(item.duration))
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.bgWindowColor.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            if renamingID == item.id {
                TextField("Title", text: $renameText, onCommit: { commitRename(item) })
                    .textFieldStyle(.plain)
                    .font(Font(Theme.bodyFont))
                    .onExitCommand { renamingID = nil }
            } else {
                Text(item.title)
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                    .lineLimit(1)
                    .onTapGesture { renameText = item.title; renamingID = item.id }
            }
            Text(Self.modifiedLabel(item.modified))
                .font(Font(Theme.captionFont))
                .foregroundStyle(Theme.textSecondaryColor)
        }
        .padding(8)
        .background(selection == item.id ? Theme.bgHoverColor : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Library.open(item.id) }
        .onTapGesture { selection = item.id }
        .contextMenu {
            Button("Open") { Library.open(item.id) }
            Button("Rename") { renameText = item.title; renamingID = item.id }
            Button("Duplicate") { try? store.duplicate(item.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.id]) }
            Divider()
            Button("Move to Trash", role: .destructive) { try? store.trash(item.id) }
        }
    }

    private func commitRename(_ item: ProjectStore.Item) {
        defer { renamingID = nil }
        guard !renameText.isEmpty, renameText != item.title else { return }
        try? store.rename(item.id, to: renameText)
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func modifiedLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today " + date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Owns the library window and is the single chokepoint every project-open path routes through
/// (double-click, Return, File ▸ Open…, `application(_:open:)`, ⇧⌘O).
enum Library {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Recorder"
            w.minSize = NSSize(width: 640, height: 400)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView(store: ProjectStore(folder: RecordingSettings.shared.projectsFolder)))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens a `.recorder` package. This is the ONLY place that decides what "open" means; wire every
    /// open path (this file, `AppDelegate`) through it.
    ///
    /// ponytail: EditorWindowController hasn't landed yet (parallel lane) — for now this just reveals
    /// the package in Finder.
    // TODO(coordinator): replace the line below with `EditorWindowController.open(package: package)`
    // once Editor/EditorWindowController.swift exists (it also owns "already-open → focus its window").
    static func open(_ package: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([package])
    }
}
