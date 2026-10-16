import AppKit
@preconcurrency import AVFoundation
import ImageIO
import RecorderCore
import UniformTypeIdentifiers

extension EditorModel {
    var idleSlots: [TimeRange] {
        if let cached = idleSlotCache, cached.clips == project.clips, cached.layers == project.layers { return cached.ranges }
        var output = 0.0
        var slots: [TimeRange] = []
        for clip in project.clips {
            defer { output += clip.outputDuration }
            guard !clip.isEmpty else { continue }
            for idle in recordingIdleRanges {
                let lower = max(idle.start, clip.mediaIn), upper = min(idle.end, clip.mediaIn + clip.outputDuration * clip.speed)
                guard upper - lower >= 0.5 * clip.speed else { continue }
                var pieces = [TimeRange(start: output + (lower - clip.mediaIn) / clip.speed, end: output + (upper - clip.mediaIn) / clip.speed)]
                for layer in project.layers where layer.track == 0 {
                    guard let start = timeMap.outputTime(atSource: layer.start) else { continue }
                    let end = start + layer.end - layer.start
                    pieces = pieces.flatMap { range in
                        guard range.start < end, range.end > start else { return [range] }
                        return [TimeRange(start: range.start, end: min(start, range.end)), TimeRange(start: max(end, range.start), end: range.end)]
                            .filter { $0.end - $0.start >= 0.5 }
                    }
                }
                slots += pieces
            }
        }
        idleSlotCache = (project.clips, project.layers, slots)
        return slots
    }

    func chooseMedia(in window: NSWindow?, atOutput time: Double? = nil, slot: TimeRange? = nil, track: Int = 0, replacing: UUID? = nil) {
        guard !voiceover.isActive, mediaImportStatus == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = replacing != nil ? [.image, .movie] : slot == nil ? [.image, .movie, .audio] : [.image]
        panel.allowsMultipleSelection = slot == nil && replacing == nil
        panel.canChooseDirectories = false
        panel.prompt = replacing == nil ? "Add Media" : "Replace Media"
        let output = time ?? playhead
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.addMediaFiles(panel.urls, atOutput: output, slot: slot, track: track, window: window, replacing: replacing)
        }
    }

    func addMediaFiles(_ urls: [URL], atOutput time: Double, slot: TimeRange? = nil, track: Int = 0, window: NSWindow?, replacing: UUID? = nil) {
        Task { @MainActor in
            for url in urls {
                do { try await importMedia(url, atOutput: time, slot: slot, track: track, replacing: replacing) }
                catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t \(replacing == nil ? "add" : "replace with") \(url.lastPathComponent)"
                    alert.informativeText = error.localizedDescription
                    if let window, window.isVisible { await alert.beginSheetModal(for: window) }
                    else { NSLog("Media import failed: %@", url.lastPathComponent) }
                    break
                }
            }
        }
    }

    static func mediaFiles(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func canPasteMedia(_ pasteboard: NSPasteboard) -> Bool {
        !mediaFiles(on: pasteboard).isEmpty || NSImage.canInit(with: pasteboard)
    }

    @discardableResult
    func pasteMedia(_ pasteboard: NSPasteboard, window: NSWindow?) -> Bool {
        guard !voiceover.isActive, mediaImportStatus == nil else { return false }
        let files = Self.mediaFiles(on: pasteboard)
        if !files.isEmpty { addMediaFiles(files, atOutput: playhead, window: window); return true }
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: url); return false }
        let time = playhead
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: url) }
            do { try await importMedia(url, atOutput: time) }
            catch {
                let alert = NSAlert(); alert.messageText = "Couldn’t paste image"; alert.informativeText = error.localizedDescription
                if let window, window.isVisible { await alert.beginSheetModal(for: window) }
            }
        }
        return true
    }

    @discardableResult
    func importMedia(_ url: URL, atOutput time: Double, slot: TimeRange? = nil, track: Int = 0, replacing: UUID? = nil) async throws -> UUID {
        @Sendable func fail(_ message: String) -> NSError { NSError(domain: "Recorder.MediaImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard !voiceover.isActive, mediaImportStatus == nil else { throw fail("Finish the current recording or import first.") }
        guard !isEditingGesture else { throw fail("Finish or cancel the current drag before adding media.") }
        guard url.isFileURL, time.isFinite, time >= 0 else { throw fail("Choose a local media file and a valid timeline position.") }
        mediaImportStatus = "Importing \(url.lastPathComponent)…"
        defer { mediaImportStatus = nil }
        let package = packageURL
        let copied = try await Task.detached(priority: .userInitiated) { () -> (file: String, url: URL, kind: LayerBlock.Kind?, duration: Double, width: Double, height: Double, audio: Bool) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw fail("The file is unreadable or is not a regular file.") }
            var kind: LayerBlock.Kind?
            var duration = 0.0, width = 0.0, height = 0.0
            var audio = false
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) {
                kind = .image; width = Double(image.width); height = Double(image.height)
            } else {
                let asset = AVURLAsset(url: url)
                let videos = try await asset.loadTracks(withMediaType: .video)
                let audios = try await asset.loadTracks(withMediaType: .audio)
                duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0, try await asset.load(.isReadable) else { throw fail("The media cannot be decoded.") }
                audio = !audios.isEmpty
                if let video = videos.first {
                    kind = .video
                    let size = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: size).applying(transform)
                    width = Double(abs(oriented.width)); height = Double(abs(oriented.height))
                    guard width > 0, height > 0 else { throw fail("The video has no readable frames.") }
                    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                    _ = try await generator.image(at: .zero)
                } else {
                    guard let track = audios.first else { throw fail("No readable audio or video track was found.") }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    guard reader.canAdd(output) else { throw fail("The audio cannot be decoded.") }
                    reader.add(output)
                    guard reader.startReading(), output.copyNextSampleBuffer() != nil else { throw fail("The audio cannot be decoded.") }
                    reader.cancelReading()
                }
            }
            let root = package.standardizedFileURL.resolvingSymlinksInPath()
            let directory = package.appendingPathComponent("media", isDirectory: true)
            guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root else { throw fail("The package media folder points outside the project.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            let file = "media/" + UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
            let destination = package.appendingPathComponent(file)
            do { try FileManager.default.copyItem(at: url, to: destination) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            return (file, destination, kind, duration, width, height, audio)
        }.value
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: copied.url) } }
        guard !voiceover.isActive else { throw fail("Stop recording before adding media.") }
        guard !isEditingGesture else { throw fail("Finish or cancel the current drag before adding media.") }
        var trial = project
        let id: UUID?
        if let kind = copied.kind {
            let canvas = outputSize(aspect: project.output.aspect, croppedSource: CGSize(width: Double(project.source.pixelWidth) * project.crop.w, height: Double(project.source.pixelHeight) * project.crop.h), longEdge: 1000)
            let aspect = copied.width / copied.height
            if let replacing {
                guard let old = project.layers.first(where: { $0.id == replacing.uuidString }) else { throw fail("The layer no longer exists.") }
                var rect = old.rect
                if rect != NormRect() {
                    rect.h = min(1, rect.w * canvas.width / canvas.height / aspect)
                    rect.w = rect.h * canvas.height / canvas.width * aspect
                    rect.x = min(1 - rect.w, max(0, old.rect.x + (old.rect.w - rect.w) / 2))
                    rect.y = min(1 - rect.h, max(0, old.rect.y + (old.rect.h - rect.h) / 2))
                }
                id = trial.replaceLayerMedia(replacing, kind: kind, file: copied.file, duration: copied.duration, rect: rect, hasAudio: copied.audio) ? replacing : nil
            } else {
                let idle = slot ?? idleSlots.first { $0.start <= time && $0.end > time }
                let start = kind == .image ? idle?.start ?? time : time
                let length = kind == .image ? idle.map { $0.end - $0.start } ?? 4 : copied.duration
                id = trial.addLayer(kind: kind, file: copied.file, atOutput: start, duration: length,
                                    rect: layerPlacementRect(.card, aspect: aspect, canvas: canvas)!, hasAudio: copied.audio, track: track)
            }
        } else {
            guard replacing == nil else { throw fail("Choose an image or video to replace a layer.") }
            id = trial.addImportedAudio(file: copied.file, atOutput: time, duration: copied.duration)
        }
        guard let id else {
            if copied.kind == .video, project.videoLayerLanes.count >= 4 { throw fail("Only four layer lanes with video are supported. Choose a free range on an existing video lane.") }
            throw fail("There is not enough timeline or media duration at this position.")
        }
        edit(replacing == nil ? "Add Media" : "Replace Media") { $0 = trial }
        committed = true
        isPlaying = false; selectedClips = []; selection = [id]
        return id
    }
}
