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

    /// Renames the package directory and updates `project.title` to match.
    func rename(_ url: URL, to title: String) throws {
        let fm = FileManager.default
        let newURL = url.deletingLastPathComponent().appendingPathComponent("\(title).recorder")
        if newURL != url { try fm.moveItem(at: url, to: newURL) }
        let projectURL = newURL.appendingPathComponent("project.json")
        var project = try Project.load(from: projectURL)
        project.title = title
        try project.save(to: projectURL)
        reload()
    }

    func duplicate(_ url: URL) throws {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent("\(base) copy.recorder")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) copy \(n).recorder")
            n += 1
        }
        try fm.copyItem(at: url, to: candidate)
        let projectURL = candidate.appendingPathComponent("project.json")
        var project = try Project.load(from: projectURL)
        project.id = UUID().uuidString
        project.title = candidate.deletingPathExtension().lastPathComponent
        try project.save(to: projectURL)
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
