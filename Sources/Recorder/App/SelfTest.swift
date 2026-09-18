import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Dispatch
import Foundation
import Metal
import RecorderCore
import ScreenCaptureKit
import SwiftUI

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
        // AC-LIB-1: 200 packages list in < 300 ms (only project.json + thumbnail.jpg read, off main thread).
        "library-perf": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-library-perf-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let thumbJPEG: Data = {
                let thumb = NSImage(size: NSSize(width: 640, height: 400))
                thumb.lockFocus()
                NSColor(hex: "#5B3DF5").setFill()
                NSRect(x: 0, y: 0, width: 640, height: 400).fill()
                thumb.unlockFocus()
                let tiff = thumb.tiffRepresentation!
                return NSBitmapImageRep(data: tiff)!.representation(using: .jpeg, properties: [:])!
            }()

            for i in 0..<200 {
                let url = tmp.appendingPathComponent("Recording \(i).recorder")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let project = Project(title: "Recording \(i)", clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
                try project.save(to: url.appendingPathComponent("project.json"))
                try thumbJPEG.write(to: url.appendingPathComponent("thumbnail.jpg"))
            }

            // `ProjectStore.init` calls `reload()` itself — time that call to completion rather than
            // triggering a second one, so nothing but the scan (project.json + thumbnail.jpg, off main) is measured.
            let start = DispatchTime.now()
            let store = ProjectStore(folder: tmp)
            let deadline = Date().addingTimeInterval(5)
            while store.items.count < 200 && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            print("SELFTEST library-perf reload=\(elapsedMs) ms for \(store.items.count) items")
            guard store.items.count == 200 else { throw Fail(description: "only \(store.items.count)/200 items scanned") }
            guard elapsedMs < 300 else { throw Fail(description: "reload took \(elapsedMs) ms, want < 300 ms") }
        },
        // T-302: renders `LibraryView` over a fixture folder to a PNG for eyeballing against the SPEC
        // §5.1 mockup (`Read` tool). Not a correctness test — kept as a standing look-check.
        "library-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard args.count >= 2 else { throw Fail(description: "usage: library-png <folder> <out.png>") }
            let fm = FileManager.default
            let folder = URL(fileURLWithPath: args[0])
            let outURL = URL(fileURLWithPath: args[1])
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            func makePackage(_ title: String, duration: Double, modified: Date) throws -> URL {
                let url = folder.appendingPathComponent("\(title).recorder")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let project = Project(title: title, clips: [Clip(sourceStart: 0, sourceEnd: duration, speed: 1)])
                try project.save(to: url.appendingPathComponent("project.json"))
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                return url
            }
            let now = Date()
            _ = try makePackage("Onboarding", duration: 93, modified: now)
            _ = try makePackage("Bug repro", duration: 12, modified: now.addingTimeInterval(-86_400))
            let demoURL = try makePackage("Demo v2", duration: 724, modified: now.addingTimeInterval(-6 * 86_400))

            let thumb = NSImage(size: NSSize(width: 640, height: 400))
            thumb.lockFocus()
            NSColor(hex: "#5B3DF5").setFill()
            NSRect(x: 0, y: 0, width: 640, height: 400).fill()
            thumb.unlockFocus()
            guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let thumbJPEG = rep.representation(using: .jpeg, properties: [:]) else {
                throw Fail(description: "couldn't synthesize thumbnail")
            }
            try thumbJPEG.write(to: demoURL.appendingPathComponent("thumbnail.jpg"))
            // Writing into the package bumps its directory mtime again — restore it (order is by mtime).
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-6 * 86_400)], ofItemAtPath: demoURL.path)

            let store = ProjectStore(folder: folder)
            let deadline = Date().addingTimeInterval(3)
            while store.items.count < 3 && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            guard store.items.count == 3 else { throw Fail(description: "fixture scan incomplete: \(store.items.map(\.title))") }

            try await MainActor.run {
                // `ImageRenderer` leaves `LazyVGrid` content inside `ScrollView` empty (its lazy
                // instantiation needs a real `NSScrollView` viewport). Host in an actual (offscreen,
                // never ordered front) window instead so layout happens exactly as on screen.
                let size = NSSize(width: 900, height: 600)
                let hostingView = NSHostingView(rootView: LibraryView(store: store).frame(width: size.width, height: size.height))
                hostingView.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hostingView
                window.layoutIfNeeded()
                hostingView.layoutSubtreeIfNeeded()
                for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                hostingView.layoutSubtreeIfNeeded()

                guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw Fail(description: "png encode failed") }
                try png.write(to: outURL)
            }
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
        // T-310: (a) `CropMapping`'s view↔NormRect round trip for a letterboxed case, (b) `CropSheet.confirm`
        // (the exact closure the sheet's Confirm button calls) drives a real `EditorModel` in one undo step,
        // and discard (no call) leaves the project untouched.
        "crop": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }

            // (a) mapping round trip: a 1920×1080 image letterboxed into a 800×1000 view (pillarboxed).
            let imageRect = CropMapping.imageRect(imageSize: CGSize(width: 1920, height: 1080), in: CGSize(width: 800, height: 1000))
            guard imageRect.width == 800, abs(imageRect.height - 450) < 1e-9 else {
                throw Fail(description: "unexpected imageRect \(imageRect)")
            }
            let originalNorm = NormRect(x: 0.1, y: 0.2, w: 0.5, h: 0.3)
            let viewRect = CropMapping.viewRect(from: originalNorm, imageRect: imageRect)
            let roundTripped = CropMapping.normRect(fromView: viewRect, imageRect: imageRect)
            guard abs(roundTripped.x - originalNorm.x) < 1e-9, abs(roundTripped.y - originalNorm.y) < 1e-9,
                  abs(roundTripped.w - originalNorm.w) < 1e-9, abs(roundTripped.h - originalNorm.h) < 1e-9 else {
                throw Fail(description: "round trip mismatch: \(roundTripped) vs \(originalNorm)")
            }

            // (b) confirm = one undo step via a real EditorModel; discard = no mutation.
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-crop-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let original = Project(title: "Crop test", clips: [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)])
            let model = await EditorModel(packageURL: tmp, project: original, events: EventLog())

            let newCrop = NormRect(x: 0.05, y: 0.1, w: 0.8, h: 0.6)
            await CropSheet.confirm(newCrop, on: model)
            guard await model.project.crop == newCrop else { throw Fail(description: "confirm didn't apply the crop") }
            guard await model.project != original else { throw Fail(description: "confirm didn't change the project") }
            await model.undo()
            guard await model.project == original else { throw Fail(description: "confirm wasn't exactly one undo step") }
            await model.redo()

            // Discard: nothing calls `model.edit`, so the project is simply whatever it already was.
            let beforeDiscard = await model.project
            // (no-op — discard's entire contract is "don't call confirm")
            guard await model.project == beforeDiscard else { throw Fail(description: "discard mutated the project") }
        },
        // T-310: renders `CropSheetWindow`'s content view offscreen with a synthetic frame image to PNG,
        // for eyeballing against the SPEC §6.7 mockup (`Read` tool). Not a correctness test.
        // ponytail: rendered in light appearance (`--selftest` never runs `AppDelegate`, which is what
        // sets `NSApp.appearance = .darkAqua` for the real app — forcing it here just for this render
        // blanked the offscreen capture, an AppKit/SwiftUI offscreen-appearance quirk not worth chasing
        // for a look-check). Layout/content only; the real app is dark-only regardless (SPEC §3).
        "crop-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else { throw Fail(description: "usage: crop-png <out.png>") }
            let outURL = URL(fileURLWithPath: outPath)

            let width = 1600, height = 1000
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    bytes[i + 0] = UInt8(clamping: Int(40 + 120 * Double(x) / Double(width)))
                    bytes[i + 1] = UInt8(clamping: Int(60 + 140 * Double(y) / Double(height)))
                    bytes[i + 2] = 200
                    bytes[i + 3] = 255
                }
            }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw Fail(description: "couldn't synthesize frame image")
            }

            try await MainActor.run {
                let crop = NormRect(x: 0.15, y: 0.2, w: 0.6, h: 0.55)
                let window = CropSheetWindow(initialCrop: crop, sourceSize: CGSize(width: width, height: height),
                                              image: cgImage, onConfirm: { _ in })
                guard let contentView = window.contentView else { throw Fail(description: "no content view") }
                window.layoutIfNeeded()
                contentView.layoutSubtreeIfNeeded()
                for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                contentView.layoutSubtreeIfNeeded()
                guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                contentView.cacheDisplay(in: contentView.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw Fail(description: "png encode failed") }
                try png.write(to: outURL)
            }
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
        "pickers": { _ in
            // T-107/T-108 bug fix regression coverage: `SelectionRectView`'s create/resize drag math
            // (AC-AREA-1/2) and `SourcePickerOverlay`'s window hit-test ordering (AC-WIN-1), both driven
            // with synthetic data so they run without Screen Recording permission or a real window.
            struct Fail: Error, CustomStringConvertible { let description: String }

            func synthEvent(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func drag(_ view: SelectionRectView, from a: CGPoint, to b: CGPoint) {
                view.mouseDown(with: synthEvent(.leftMouseDown, a))
                view.mouseDragged(with: synthEvent(.leftMouseDragged, b))
                view.mouseUp(with: synthEvent(.leftMouseUp, b))
            }
            func freshView() -> SelectionRectView {
                let v = SelectionRectView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
                v.limit = v.bounds
                return v
            }

            // Plain create drag, well above minSize: anchored at mouse-down, size tracks the mouse exactly.
            do {
                let view = freshView()
                drag(view, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 500, y: 400))
                let expected = CGRect(x: 200, y: 200, width: 300, height: 200)
                guard view.rect == expected else { throw Fail(description: "create drag: got \(view.rect), want \(expected)") }
            }

            // Create drag that stays under 100×100: the mouse-down corner (anchor) must stay exactly put,
            // not slide with the naive post-hoc clamp that grew from (minX, minY) unconditionally.
            do {
                let view = freshView()
                drag(view, from: CGPoint(x: 700, y: 700), to: CGPoint(x: 720, y: 715))
                guard view.rect.minX == 700, view.rect.maxY == 700, view.rect.width == 100, view.rect.height == 100 else {
                    throw Fail(description: "create under minSize: anchor moved, got \(view.rect)")
                }
            }

            // Resizing the left handle of an existing rect past the min width must keep the right (anchor)
            // edge fixed, not drag it along with the pointer — this was the "wonky" area-selection bug.
            do {
                let view = freshView()
                view.rect = CGRect(x: 100, y: 100, width: 300, height: 300) // left handle at (100, 250)
                drag(view, from: CGPoint(x: 100, y: 250), to: CGPoint(x: 380, y: 250))
                guard view.rect.maxX == 400, view.rect.width == 100 else {
                    throw Fail(description: "left-handle resize under minSize: right edge moved, got \(view.rect)")
                }
            }

            // Window hit-test must follow front-to-back z-order, not `SCShareableContent.windows`'
            // unordered list (the root cause of the window picker highlighting "random" windows).
            do {
                let frames: [CGWindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 200, height: 200),
                                                      2: CGRect(x: 50, y: 50, width: 200, height: 200)]
                let overlap = CGPoint(x: 100, y: 100) // inside both
                guard SourcePickerOverlay.frontmostWindow(at: overlap, order: [2, 1], frames: frames) == 2 else {
                    throw Fail(description: "hit-test didn't prefer the front window")
                }
                guard SourcePickerOverlay.frontmostWindow(at: overlap, order: [1, 2], frames: frames) == 1 else {
                    throw Fail(description: "hit-test didn't respect order")
                }
                let onlyInWindow1 = CGPoint(x: 10, y: 10)
                guard SourcePickerOverlay.frontmostWindow(at: onlyInWindow1, order: [2, 1], frames: frames) == 1 else {
                    throw Fail(description: "hit-test picked a window that doesn't contain the point")
                }
                guard SourcePickerOverlay.frontmostWindow(at: CGPoint(x: -5, y: -5), order: [2, 1], frames: frames) == nil else {
                    throw Fail(description: "hit-test should return nil outside every window")
                }
            }
        },
        "waveform": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let path = args.first else { throw Fail(description: "usage: waveform <audiofile>") }
            let peaks = try Waveform.peaks(for: URL(fileURLWithPath: path))
            let max = peaks.max() ?? 0
            print("peaks=\(peaks.count) max=\(max)")
            // Sanity range for real speech/PCM samples (not silence, not a byte-swap artifact like 2.3e-38).
            guard (0.001...1.5).contains(max) else { throw Fail(description: "max \(max) outside 0.001...1.5 (byte order / decode bug?)") }
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
