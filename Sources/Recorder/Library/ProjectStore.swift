import AppKit
import Dispatch
import Observation
import RecorderCore

/// Backs the project library window (SPEC §5.1). No database, no cache: scans `*.recorder`
/// packages under `folder` for their `project.json` header + `thumbnail.jpg`, off the main thread
/// (AC-LIB-1), and rescans on any change to the folder.
@Observable final class ProjectStore {
    struct Item: Identifiable {
        let id: URL
        var title: String
        var duration: Double
        var modified: Date
        var thumbnail: NSImage?
    }

    private(set) var items: [Item] = []
    var folder: URL { didSet { watch(); reload() } }

    private var watcher: DispatchSourceFileSystemObject?

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recorder")
    }

    init(folder: URL = ProjectStore.defaultFolder) {
        self.folder = folder
        watch()
        reload()
    }

    func reload() {
        let folder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let scanned: [Item] = urls.filter { $0.pathExtension == "recorder" }.compactMap { url in
                guard let project = try? Project.load(from: url.appendingPathComponent("project.json")) else { return nil }
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                let thumbURL = url.appendingPathComponent("thumbnail.jpg")
                let thumbnail = fm.fileExists(atPath: thumbURL.path) ? NSImage(contentsOf: thumbURL) : nil
                return Item(id: url, title: project.title, duration: TimeMap(project.clips).outputDuration,
                            modified: modified, thumbnail: thumbnail)
            }.sorted { $0.modified > $1.modified }
            DispatchQueue.main.async { self.items = scanned }
        }
    }

    /// A scratch directory on the same volume as `folder`, for building a package fully (copy/move +
    /// rewritten `project.json`) before it ever appears inside the watched folder — see `stageThenMove`.
    private func stagingDirectory() throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: folder, create: true)
    }

    /// Assembles a package in a staging directory (outside `folder`, so the folder watcher can't see it
    /// mid-write), lets `build` finish writing it (e.g. rewrite `project.json`'s title), then moves the
    /// finished package into `folder` in one filesystem op. Fixes T-301: doing the move first and the
    /// `project.json` rewrite after let the watcher's `reload()` race the rewrite and read a stale title,
    /// and since the watcher only fires on `folder` itself (not on writes to files inside a package it
    /// already contains), that stale title could stick until some unrelated folder-level change.
    private func stageThenMove(named name: String, build: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let staging = try stagingDirectory()
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(name)
        try build(staged)
        let finalURL = folder.appendingPathComponent(name)
        try fm.moveItem(at: staged, to: finalURL)
        return finalURL
    }

    /// Renames the package directory and updates `project.title` to match.
    func rename(_ url: URL, to title: String) throws {
        let newName = "\(title).recorder"
        if url.lastPathComponent == newName {
            let projectURL = url.appendingPathComponent("project.json")
            var project = try Project.load(from: projectURL)
            project.title = title
            try project.save(to: projectURL)
        } else {
            _ = try stageThenMove(named: newName) { staged in
                try FileManager.default.moveItem(at: url, to: staged)
                let projectURL = staged.appendingPathComponent("project.json")
                var project = try Project.load(from: projectURL)
                project.title = title
                try project.save(to: projectURL)
            }
        }
        reload()
    }

    func duplicate(_ url: URL) throws {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        var name = "\(base) copy.recorder"
        var n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) copy \(n).recorder"
            n += 1
        }
        _ = try stageThenMove(named: name) { staged in
            try fm.copyItem(at: url, to: staged)
            let projectURL = staged.appendingPathComponent("project.json")
            var project = try Project.load(from: projectURL)
            project.id = UUID().uuidString
            project.title = staged.deletingPathExtension().lastPathComponent
            try project.save(to: projectURL)
        }
        reload()
    }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
