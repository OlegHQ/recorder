import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Project library window (SPEC §5.1 mockup): search + adaptive grid of recordings, inline rename,
/// per-card context menu, empty state, "New Recording". Hosted by `Library.show()`.
struct LibraryView: View {
    let store: ProjectStore
    static let dropTypes: [UTType] = [.fileURL]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var hoveredID: URL?
    @State private var columns = 3
    @State private var search = ""
    @State private var selection: URL?
    @State private var renamingID: URL?
    @State private var renameText = ""
    @State private var importState: ImportState = .idle
    @FocusState private var libraryFocused: Bool

    private enum ImportState: Equatable {
        case idle, importing(String), failed(String)
    }

    private var filtered: [ProjectStore.Item] {
        search.isEmpty ? store.items : store.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            searchBar
            importStatus
            if store.items.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                searchEmptyState
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: columns),
                                      alignment: .leading, spacing: 24) {
                                ForEach(filtered) { card($0).id($0.id) }
                            }
                            .padding(.horizontal, 28)
                            .padding(.top, 12).padding(.bottom, 28)
                        }
                        .onChange(of: selection) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                    .onGeometryChange(for: Int.self) { _ in
                        max(1, Int((geometry.size.width - 56 + 20) / 260))
                    } action: { columns = $0 }
                }
            }
            footer
        }
        .background(Theme.bgWindowColor)
        .signalWindow()
        .frame(minWidth: 640, minHeight: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($libraryFocused)
        .onMoveCommand(perform: moveSelection)
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            Library.open(selection)
            return .handled
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onDrop(of: Self.dropTypes, isTargeted: $dropTargeted, perform: handleDrop)
    }

    /// T-606, SPEC §5.1 "drag a video file in: import (M6)".
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        if case .importing = importState { return false }
        importState = .importing("video…")
        Task { @MainActor in
            var failures: [String] = []
            for provider in providers {
                var name = "dropped file"
                do {
                    let url = try await Self.droppedFileURL(provider)
                    name = url.lastPathComponent
                    importState = .importing(name)
                    _ = try await store.importMovie(url)
                } catch {
                    failures.append(name)
                }
            }
            importState = failures.isEmpty ? .idle : .failed("Couldn’t import \(failures.joined(separator: ", ")). Use a readable video file.")
        }
        return true
    }

    // Finder advertises public.file-url, not necessarily public.movie.
    static func droppedFileURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnsupportedScheme))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Projects").font(Font(Theme.headingFont(36)))
                Text("Your recordings, ready to edit.")
                    .font(Font(Theme.labelFont))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer()
            Button(action: { ToolbarController.shared.show() }) {
                Label("New capture", systemImage: "record.circle")
                    .padding(.horizontal, 4).padding(.vertical, 4)
            }
            .buttonStyle(TechButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Text(search.isEmpty ? "All projects · \(store.items.count)" : "Results · \(filtered.count)")
                .font(Font(Theme.labelFont))
            Spacer()
            Text("Recently modified")
                .font(Font(Theme.captionFont))
                .foregroundStyle(Theme.textTertiaryColor)
            TechSearchField(placeholder: "Search projects", text: $search, width: 190)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let item = filtered.first(where: { $0.id == selection }) {
                Text(item.title).lineLimit(1).help(item.title)
                Spacer(minLength: 12)
                Button("Open project") { Library.open(item.id) }
                    .buttonStyle(TechButtonStyle(kind: .secondary))
            } else {
                Label(dropTargeted ? "Release to import video" : "Drag a video into this window to import", systemImage: "arrow.down.doc")
                Spacer()
                Text("Click to open")
            }
        }
        .font(Font(Theme.captionFont))
        .foregroundStyle(Theme.textSecondaryColor)
        .padding(.horizontal, 28).frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack").font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(Theme.textSecondaryColor)
            Text("Your first project starts here").font(Font(Theme.headingFont(28)))
            Text("Start a capture or drop a video file into this window.")
                .foregroundStyle(Theme.textSecondaryColor)
            Button(action: { ToolbarController.shared.show() }) {
                Label("Start capture", systemImage: "record.circle")
            }
            .buttonStyle(TechButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiaryColor)
            Text("No projects match “\(search)”")
                .font(Font(Theme.headingFont(24)))
            Text("Try another title or clear the search.")
                .foregroundStyle(Theme.textSecondaryColor)
            Button("Clear search") { search = "" }
                .buttonStyle(TechButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var importStatus: some View {
        switch importState {
        case .idle:
            EmptyView()
        case .importing(let name):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Importing \(name)")
                Spacer()
            }
            .font(Font(Theme.labelFont))
            .padding(.horizontal, Theme.Space.lg).frame(height: 34)
            .background(Theme.bgControlColor)
        case .failed(let message):
            HStack(spacing: 10) {
                TechStatus(title: message, color: Theme.dangerColor)
                Spacer()
                Button("Dismiss") { importState = .idle }
                    .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            }
            .padding(.horizontal, Theme.Space.lg).frame(height: 34)
            .background(Theme.bgControlColor)
        }
    }

    private func card(_ item: ProjectStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(Theme.bgPanelColor)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        GeometryReader { preview in
                            if let thumbnail = item.thumbnail {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: preview.size.width, height: preview.size.height)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "film").font(.system(size: 24, weight: .ultraLight))
                                    Text("No preview").font(Font(Theme.captionFont))
                                }
                                .foregroundStyle(Theme.textTertiaryColor)
                                .frame(width: preview.size.width, height: preview.size.height)
                            }
                        }
                    }
                    .clipped()
                Text(Self.durationLabel(item.duration))
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.bgWindowColor.opacity(0.92))
                    .overlay(Rectangle().stroke(Theme.strokeStrongColor))
                    .padding(7)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    if renamingID == item.id {
                        TextField("Title", text: $renameText, onCommit: { commitRename(item) })
                            .textFieldStyle(TechFieldStyle())
                            .onExitCommand { renamingID = nil }
                    } else {
                        Text(item.title)
                            .font(Font(Theme.headingFont(18)))
                            .foregroundStyle(Theme.textPrimaryColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.title)
                    }
                    Spacer(minLength: 0)
                    Menu { projectActions(item) } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(item.title)")
                }
                Text("\(Self.modifiedLabel(item.modified)) · \(Self.durationLabel(item.duration))")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(selection == item.id ? Theme.bgSelectedColor :
                        (hoveredID == item.id ? Theme.bgControlColor : Theme.bgPanelColor))
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.hover), value: hoveredID == item.id)
        .onHover { hovering in hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .overlay(Rectangle().stroke(selection == item.id ? Theme.accentColor : Theme.strokeColor,
                                    lineWidth: selection == item.id ? 1.5 : 1))
        .overlay {
            if libraryFocused, selection == item.id {
                Rectangle().inset(by: 4)
                    .stroke(Theme.textPrimaryColor,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard renamingID != item.id else { return }
            selection = item.id
            Library.open(item.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityAction { Library.open(item.id) }
        .accessibilityAction(named: "Open") { Library.open(item.id) }
        .accessibilityValue("\(Self.durationLabel(item.duration)), modified \(Self.modifiedLabel(item.modified))")
        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
        .contextMenu { projectActions(item) }
    }

    @ViewBuilder private func projectActions(_ item: ProjectStore.Item) -> some View {
        Button("Open") { Library.open(item.id) }
        Button("Rename") { renameText = item.title; renamingID = item.id }
        Button("Duplicate") { try? store.duplicate(item.id) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.id]) }
        Divider()
        Button("Move to Trash", role: .destructive) { try? store.trash(item.id) }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let forward = direction == .right || direction == .down
        let current = selection.flatMap { selected in filtered.firstIndex { $0.id == selected } }
        if let next = Self.movedIndex(current: current, count: filtered.count, forward: forward, step: direction == .up || direction == .down ? columns : 1) {
            selection = filtered[next].id
        }
    }

    nonisolated static func movedIndex(current: Int?, count: Int, forward: Bool, step: Int = 1) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return min(max(current + (forward ? step : -step), 0), count - 1)
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
/// (click, Return, File ▸ Open…, `application(_:open:)`, ⇧⌘O).
enum Library {
    private(set) static var window: NSWindow?

    static func configure(_ window: NSWindow) {
        // The selected card draws focus; AppKit must not outline the entire hosting view.
        window.contentView?.focusRingType = .none
        window.title = "Recorder — Projects"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.bgWindow
        window.appearance = NSAppearance(named: .darkAqua)
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.contentMinSize = NSSize(width: 640, height: 480)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView(store: ProjectStore(folder: RecordingSettings.shared.projectsFolder)))
            configure(w)
            w.center()
            window = w
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens a `.recorder` package. This is the ONLY place that decides what "open" means; wire every
    /// open path (this file, `AppDelegate`) through it.
    static func open(_ package: URL) {
        EditorWindowController.open(package: package)
    }
}
