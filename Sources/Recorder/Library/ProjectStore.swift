import AppKit
import AVFoundation
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

    static func newProjectURL(in folder: URL) -> URL {
        let adjective = ["Amber", "Bright", "Calm", "Cool", "Coral", "Cozy", "Golden", "Gentle",
                         "Quiet", "Misty", "Silver", "Sunny", "Soft", "Wild", "Velvet", "Distant"].randomElement()!
        let noun = ["Aurora", "Brook", "Cloud", "Cove", "Dawn", "Forest", "Garden", "Harbor",
                    "Island", "Meadow", "Moon", "Ocean", "River", "Summit", "Valley", "Willow"].randomElement()!
        let base = "\(adjective) \(noun)"
        var url = folder.appendingPathComponent("\(base).recorder")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix).recorder")
            suffix += 1
        }
        return url
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

    enum ImportError: Error { case noVideoTrack }

    /// T-606, SPEC §5.1 "drag a video file in: import (M6)". Media is never modified after recording
    /// (SPEC §5), so `movieURL` is COPIED in verbatim as `screen.mov`; the package gets an empty
    /// `events.json`, a `thumbnail.jpg`, and a `project.json` with one clip spanning the whole asset
    /// and no zooms. Staged then moved, same as every other package-producing op here.
    func importMovie(_ movieURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ImportError.noVideoTrack }

        // Generate before staging so the package is still published in one synchronous move.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 0)
        let time = CMTime(seconds: duration > 1 ? 1 : 0, preferredTimescale: 600)
        let thumbnail = try? await generator.image(at: time).image

        let fm = FileManager.default
        let packageURL = Self.newProjectURL(in: folder)
        let name = packageURL.lastPathComponent

        let finalURL = try stageThenMove(named: name) { staged in
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            // ponytail: copies the source container as-is (any container AVFoundation can read plays
            // fine as `screen.mov` regardless of extension); re-encode only if a format shows up that
            // AVFoundation can't open.
            try fm.copyItem(at: movieURL, to: staged.appendingPathComponent("screen.mov"))
            try JSONEncoder().encode(EventLog()).write(to: staged.appendingPathComponent("events.json"), options: .atomic)

            let project = Project(
                title: packageURL.deletingPathExtension().lastPathComponent,
                source: Source(kind: .display, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                scale: 1, duration: duration, hasCamera: false, hasMic: false, hasSystemAudio: false),
                clips: [Clip(sourceStart: 0, sourceEnd: duration, speed: 1)],
                frame: Frame(enabled: true)
            )
            try project.save(to: staged.appendingPathComponent("project.json"))

            if let cgImage = thumbnail {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let data = rep.representation(using: .jpeg, properties: [:]) {
                    try? data.write(to: staged.appendingPathComponent("thumbnail.jpg"))
                }
            }
        }
        reload()
        return finalURL
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
