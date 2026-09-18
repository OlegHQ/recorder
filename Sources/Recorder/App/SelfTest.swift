import AVFoundation
import CoreMedia
import Darwin
import Dispatch
import Foundation
import Metal
import RecorderCore
import ScreenCaptureKit

/// Headless app checks, run instead of the GUI when launched with `--selftest <name> [args]`.
/// Cases are registered by later tasks: `SelfTest.cases["name"] = { args in … throws }`.
enum SelfTest {
    nonisolated(unsafe) static var cases: [String: ([String]) async throws -> Void] = [
        "metal": { _ in
            let device = MTLCreateSystemDefaultDevice()!
            _ = try device.makeLibrary(source: "kernel void k(uint2 g [[thread_position_in_grid]]) {}", options: nil)
        },
        "permissions": { _ in
            print("screen=\(Permissions.screen) accessibility=\(Permissions.accessibility)")
        },
        "render": { args in try Compositor.runRenderSelfTest(args) },
        "composition": { args in try await runCompositionSelfTest(args) },
        "library": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            func waitUntil(timeout: Double = 3, _ predicate: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(timeout)
                while !predicate() {
                    if Date() > deadline { throw Fail(description: "timed out waiting") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-library-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            func makePackage(_ title: String, modified: Date) throws -> URL {
                let url = tmp.appendingPathComponent("\(title).recorder")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let project = Project(title: title, clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
                try project.save(to: url.appendingPathComponent("project.json"))
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                return url
            }

            let now = Date()
            let urlA = try makePackage("Alpha", modified: now.addingTimeInterval(-200))
            let urlB = try makePackage("Bravo", modified: now.addingTimeInterval(-100))
            let urlC = try makePackage("Charlie", modified: now)

            _ = (urlA, urlB, urlC) // paths are re-derived through `store.items` below (tmp may be symlink-resolved by the scan)

            let store = ProjectStore(folder: tmp)
            try await waitUntil { store.items.count == 3 }
            guard store.items.map(\.title) == ["Charlie", "Bravo", "Alpha"] else {
                throw Fail(description: "order: \(store.items.map(\.title))")
            }
            guard store.items[0].duration == 10 else { throw Fail(description: "duration \(store.items[0].duration)") }
            guard let alphaURL = store.items.first(where: { $0.title == "Alpha" })?.id else {
                throw Fail(description: "alpha item missing")
            }
            guard let bravoURL = store.items.first(where: { $0.title == "Bravo" })?.id else {
                throw Fail(description: "bravo item missing")
            }

            try store.rename(alphaURL, to: "Alpha Renamed")
            try await waitUntil { store.items.contains { $0.title == "Alpha Renamed" } }
            guard let renamedURL = store.items.first(where: { $0.title == "Alpha Renamed" })?.id else {
                throw Fail(description: "renamed item missing")
            }

            try store.duplicate(renamedURL)
            try await waitUntil { store.items.count == 4 }
            guard store.items.contains(where: { $0.title == "Alpha Renamed copy" }) else {
                throw Fail(description: "duplicate missing: \(store.items.map(\.title))")
            }

            try store.trash(bravoURL)
            try await waitUntil { store.items.count == 3 }
            guard !fm.fileExists(atPath: bravoURL.path) else { throw Fail(description: "trash didn't remove the package") }
        },
        "model": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-model-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let projectURL = tmp.appendingPathComponent("project.json")
            let original = Project(title: "Original")
            try original.save(to: projectURL)

            let model = await EditorModel(packageURL: tmp, project: original, events: EventLog())

            // edit -> undo -> redo equality
            await model.edit("rename") { $0.title = "Changed" }
            let afterEdit = await model.project
            await model.undo()
            guard await model.project == original else { throw Fail(description: "undo didn't restore original") }
            await model.redo()
            guard await model.project == afterEdit else { throw Fail(description: "redo didn't restore edited state") }

            // a gesture with many updates is exactly one undo step
            let beforeGesture = await model.project
            await model.beginGesture()
            for i in 0..<10 { await model.update { $0.crop.x = Double(i) / 10 } }
            await model.commitGesture("crop")
            await model.undo()
            guard await model.project == beforeGesture else {
                throw Fail(description: "gesture undo didn't collapse to one step")
            }
            await model.redo()

            // autosave: file on disk updated ~0.5 s after the last change
            await model.edit("title2") { $0.title = "Persisted" }
            try await Task.sleep(nanoseconds: 700_000_000)
            let onDisk = try Project.load(from: projectURL)
            guard onDisk.title == "Persisted" else { throw Fail(description: "autosave didn't persist: \(onDisk.title)") }
        },
        "events": { args in
            let seconds = args.first.flatMap(Double.init) ?? 3
            guard let display = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).displays.first else {
                throw NSError(domain: "SelfTest.events", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display found (Screen Recording permission likely not granted to this terminal)"])
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-selftest-events-\(UUID().uuidString)")
            let cursorsDir = dir.appendingPathComponent("cursors")
            let recorder = EventRecorder(target: .display(display), cursorsDir: cursorsDir)
            recorder.start(t0HostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let log = recorder.stop()
            var counts: [String: Int] = [:]
            for e in log.events { counts[e.k.rawValue, default: 0] += 1 }
            print("SELFTEST events counts=\(counts)")
            let cursorFiles = (try? FileManager.default.contentsOfDirectory(atPath: cursorsDir.path)) ?? []
            guard cursorFiles.contains(where: { $0.hasSuffix(".png") }) else {
                throw NSError(domain: "SelfTest.events", code: 2, userInfo: [NSLocalizedDescriptionKey: "no cursor image written (need at least one)"])
            }
            try? FileManager.default.removeItem(at: dir)
        },
        "record": { args in
            let kind = args.first ?? "display"
            let seconds = args.count > 1 ? (Double(args[1]) ?? 3) : 3
            guard kind == "display" else {
                throw NSError(domain: "SelfTest.record", code: 1, userInfo: [NSLocalizedDescriptionKey: "only 'display' is supported by this selftest"])
            }
            guard let display = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).displays.first else {
                throw NSError(domain: "SelfTest.record", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display found (Screen Recording permission likely not granted to this terminal)"])
            }
            let target = CaptureTarget.display(display)
            let packageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("recorder-selftest-record-\(UUID().uuidString).recorder")
            let session = try await CaptureSession(target: target, settings: RecordingSettings.shared, packageURL: packageURL)
            try await session.start()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let source = try await session.finish()

            guard (2.5...3.5).contains(source.duration) else {
                throw NSError(domain: "SelfTest.record", code: 3, userInfo: [NSLocalizedDescriptionKey: "duration \(source.duration) out of range 2.5...3.5"])
            }
            let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "SelfTest.record", code: 4, userInfo: [NSLocalizedDescriptionKey: "screen.mov has no video track"])
            }
            let naturalSize = try await track.load(.naturalSize)
            let expected = target.pixelSize
            guard Int(naturalSize.width) == Int(expected.width), Int(naturalSize.height) == Int(expected.height) else {
                throw NSError(domain: "SelfTest.record", code: 5, userInfo: [NSLocalizedDescriptionKey: "size \(naturalSize) != expected \(expected)"])
            }
            guard FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("events.json").path) else {
                throw NSError(domain: "SelfTest.record", code: 6, userInfo: [NSLocalizedDescriptionKey: "events.json missing"])
            }
            print("SELFTEST record duration=\(source.duration) size=\(Int(naturalSize.width))x\(Int(naturalSize.height))")
            try? FileManager.default.removeItem(at: packageURL)
        },
        "waveform": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let path = args.first else { throw Fail(description: "usage: waveform <audiofile>") }
            let peaks = try Waveform.peaks(for: URL(fileURLWithPath: path))
            print("peaks=\(peaks.count) max=\(peaks.max() ?? 0)")
        },
    ]

    static func runIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--selftest") else { return }
        let name = CommandLine.arguments[safe: i + 1]
        let args = Array(CommandLine.arguments.dropFirst(i + 2))
        guard let name, let body = cases[name] else {
            print("SELFTEST \(name ?? "?") unknown case")
            exit(1)
        }
        Task {
            do {
                try await body(args)
                print("SELFTEST \(name) OK")
                exit(0)
            } catch {
                print("SELFTEST \(name) failed: \(error)")
                exit(1)
            }
        }
        // Pump the main run loop (instead of a plain semaphore wait) so cases that hop back to
        // `DispatchQueue.main` (autosave, folder watching, …) can actually run; `exit()` above ends the process.
        while true { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
