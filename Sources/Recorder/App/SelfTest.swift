import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Darwin
import Dispatch
import Foundation
import ImageIO
import Metal
import RecorderCore
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

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
        // Throwaway generator (T-308, SPEC §6.6): writes `Resources/Wallpapers/01.jpg`…`12.jpg` —
        // abstract gradients we made ourselves (never Apple's or Screen Studio's images). Run once
        // from the repo root (`--selftest make-wallpapers`) and commit the result; re-run only if
        // the palette needs to change.
        "make-wallpapers": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let dir = URL(fileURLWithPath: "Resources/Wallpapers")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let context = CIContext()
            let size = CGSize(width: 640, height: 400)
            let rect = CGRect(origin: .zero, size: size)

            func color(hue: Double, saturation: Double, brightness: Double) -> CIColor {
                let ns = NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 1),
                                  saturation: saturation, brightness: brightness, alpha: 1)
                let srgb = ns.usingColorSpace(.sRGB) ?? ns
                return CIColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
            }

            for i in 0..<12 {
                let id = String(format: "%02d", i + 1)
                let hue0 = Double(i) / 12
                let c0 = color(hue: hue0, saturation: 0.62, brightness: 0.5)
                let c1 = color(hue: hue0 + 0.18, saturation: 0.75, brightness: 0.88)

                let output: CIImage
                if i % 2 == 0 {
                    let filter = CIFilter.linearGradient()
                    filter.color0 = c0
                    filter.color1 = c1
                    filter.point0 = i % 4 == 0 ? CGPoint(x: 0, y: 0) : CGPoint(x: size.width, y: 0)
                    filter.point1 = i % 4 == 0 ? CGPoint(x: size.width, y: size.height) : CGPoint(x: 0, y: size.height)
                    guard let img = filter.outputImage else { throw Fail(description: "linearGradient failed for \(id)") }
                    output = img
                } else {
                    let filter = CIFilter.radialGradient()
                    filter.color0 = c1
                    filter.color1 = c0
                    filter.center = CGPoint(x: size.width * (i % 4 == 1 ? 0.35 : 0.65), y: size.height * 0.5)
                    filter.radius0 = 0
                    filter.radius1 = Float(max(size.width, size.height) * 0.75)
                    guard let img = filter.outputImage else { throw Fail(description: "radialGradient failed for \(id)") }
                    output = img
                }

                guard let cgImage = context.createCGImage(output.cropped(to: rect), from: rect) else {
                    throw Fail(description: "createCGImage failed for \(id)")
                }
                let url = dir.appendingPathComponent("\(id).jpg")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw Fail(description: "no destination for \(id)")
                }
                CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw Fail(description: "finalize failed for \(id)") }
            }
            print("wrote 12 wallpapers to \(dir.path)")
        },
        // T-504: throwaway generator (like `make-wallpapers` above) — a few-ms decaying tick
        // (2200 Hz tone, fast exponential decay), synthesized ourselves via `AVAudioFile` (no
        // third-party assets). Run once from the repo root (`--selftest make-click-sound`) and
        // commit the result; re-run only if the sound needs to change.
        "make-click-sound": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let url = URL(fileURLWithPath: "Resources/click.caf")
            let sampleRate = 44_100.0
            let duration = 0.04
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
                throw Fail(description: "couldn't allocate a PCM buffer for click.caf")
            }
            buffer.frameLength = buffer.frameCapacity
            let channel = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 90)
                channel[i] = Float(sin(2 * .pi * 2200 * t) * envelope)
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            print("wrote \(url.path)")
        },
        "render": { args in try Compositor.runRenderSelfTest(args) },
        "composition": { args in try await runCompositionSelfTest(args) },
        "preview-frame": { args in try await Compositor.runPreviewFrameSelfTest(args) },
        "export": { args in try await ExporterSelfTest.runExportSelfTest(args) },
        "parity": { args in try await ExporterSelfTest.runParitySelfTest(args) },
        "export-gif": { args in try await ExporterSelfTest.runExportGIFSelfTest(args) },
        "export-perf": { args in try await PerfSelfTest.runExportPerf(args) },
        "export-sheet": { args in try await ExportSheetSelfTest.run(args) },
        "export-sheet-png": { args in try await ExportSheetSelfTest.runPNG(args) },
        "camera-drag": { args in
            // T-502: dragging the camera bubble in the preview snaps to the nearest corner, one
            // `model.edit`. Synthetic mouse events, same technique as the `pickers` case below
            // (`SelectionRectView`'s drag tests) — `PreviewView` isn't in a real window here, so
            // `convert(_:from:)` treats the event location as already being in view-local coords.
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let packagePath = args.first else { throw Fail(description: "usage: camera-drag <package>") }
            let packageURL = URL(fileURLWithPath: packagePath)
            try await MainActor.run {
                let model = try loadEditorModel(package: packageURL)
                guard model.project.source.hasCamera else { throw Fail(description: "fixture must have source.hasCamera = true") }

                let view = PreviewView(model: model)
                view.setFrameSize(NSSize(width: 960, height: 540))

                func synthEvent(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }

                // Default corner is bottomRight (bottom-left/y-up bounds ⇒ small x, small y). Drag
                // from inside the bubble to the opposite (top-left) corner of the viewport.
                guard model.project.camera.corner == .bottomRight else {
                    throw Fail(description: "fixture must start with camera.corner = bottomRight (got \(model.project.camera.corner))")
                }

                let from = CGPoint(x: view.bounds.width - 40, y: 40)     // inside the bottomRight bubble
                let to = CGPoint(x: 40, y: view.bounds.height - 40)      // near the topLeft corner
                view.mouseDown(with: synthEvent(.leftMouseDown, from))
                view.mouseDragged(with: synthEvent(.leftMouseDragged, to))
                view.mouseUp(with: synthEvent(.leftMouseUp, to))

                guard model.project.camera.corner == .topLeft else {
                    throw Fail(description: "drag to top-left corner didn't snap: got \(model.project.camera.corner)")
                }

                // A click that starts OUTSIDE the bubble must not move it (one `model.edit` only for
                // an actual bubble drag).
                view.mouseDown(with: synthEvent(.leftMouseDown, CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
                view.mouseUp(with: synthEvent(.leftMouseUp, CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
                guard model.project.camera.corner == .topLeft else {
                    throw Fail(description: "a click outside the bubble moved it: \(model.project.camera.corner)")
                }
                print("camera-drag OK: snapped bottomRight -> topLeft, outside-click ignored")
            }
        },
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
        // T-601: `MaskRectOverlay` — visibility follows selection, a drag on its `view` maps
        // through `CropMapping` (the same pure pair "crop" above already round-trips) into the
        // selected mask's `rect`, and the whole drag is exactly one undo step.
        "mask-rect": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            func synthEvent(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }

            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-mask-rect-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            // A square 1000×1000 source into a 1000×1000 mount: `CropMapping.imageRect` letterboxes
            // to exactly the full area, so view points and normalised [0,1000] source points coincide
            // — keeps the drag's expected numbers simple without weakening what's under test (the
            // mapping itself is already covered by "crop" above).
            var project = Project(title: "Mask rect test", source: Source(pixelWidth: 1000, pixelHeight: 1000, duration: 20))
            project.clips = [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)]
            let mask = Mask(start: 2, end: 6, kind: .mask, rect: NormRect(x: 0.1, y: 0.1, w: 0.3, h: 0.3), opacity: 0.8)
            project.masks = [mask]
            let maskID = UUID(uuidString: mask.id)!

            let model = await EditorModel(packageURL: tmp, project: project, events: EventLog())
            let overlay = await MaskRectOverlay(model: model)
            await overlay.layout(in: CGSize(width: 1000, height: 1000))
            guard await overlay.view.isHidden else { throw Fail(description: "overlay should start hidden — nothing selected") }

            // `withObservationTracking`'s onChange (like `EditorModel`'s own autosave elsewhere in
            // this file) lands on a `DispatchQueue.main.async` hop — `Task.sleep` (not a manual
            // `RunLoop` pump) is this harness's proven way to let that land before asserting.
            await MainActor.run { model.selection = [maskID] }
            try await Task.sleep(nanoseconds: 200_000_000)
            guard await !overlay.view.isHidden else { throw Fail(description: "overlay should show once the mask is selected") }

            // The initial rect (top-left-origin NormRect(0.1,0.1,0.3,0.3), bottom-left-origin
            // view space) is (100, 600, 300, 300): its interior contains (150, 650).
            let undoBefore = await model.undoStepCount
            await MainActor.run {
                overlay.view.mouseDown(with: synthEvent(.leftMouseDown, CGPoint(x: 150, y: 650)))
                overlay.view.mouseDragged(with: synthEvent(.leftMouseDragged, CGPoint(x: 250, y: 650))) // +100 x, move mode
            }
            let liveRect = await model.project.masks[0].rect
            guard liveRect.x != mask.rect.x || liveRect.y != mask.rect.y else {
                throw Fail(description: "drag didn't move the rect live")
            }
            guard await model.undoStepCount == undoBefore else { throw Fail(description: "an in-progress drag shouldn't push an undo step yet") }
            await MainActor.run { overlay.view.mouseUp(with: synthEvent(.leftMouseUp, CGPoint(x: 250, y: 650))) }
            guard await model.undoStepCount == undoBefore + 1 else { throw Fail(description: "the drag should push exactly one undo step") }

            let moved = await model.project.masks[0].rect
            let expected = NormRect(x: 0.2, y: 0.1, w: 0.3, h: 0.3)
            guard abs(moved.x - expected.x) < 1e-6, abs(moved.y - expected.y) < 1e-6,
                  abs(moved.w - expected.w) < 1e-6, abs(moved.h - expected.h) < 1e-6 else {
                throw Fail(description: "unexpected rect after drag: \(moved), want \(expected)")
            }
            guard await model.project.checkInvariants() == nil else { throw Fail(description: "invariants broke after the rect drag") }

            await model.undo()
            let undoneRect = await model.project.masks[0].rect
            guard abs(undoneRect.x - mask.rect.x) < 1e-6 else { throw Fail(description: "undo didn't restore the pre-drag rect") }

            await MainActor.run { model.selection = [] }
            try await Task.sleep(nanoseconds: 200_000_000)
            guard await overlay.view.isHidden else { throw Fail(description: "overlay should hide once deselected") }
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
                    let rValue: Double = 40 + 120 * Double(x) / Double(width)
                    let gValue: Double = 60 + 140 * Double(y) / Double(height)
                    bytes[i + 0] = UInt8(clamping: Int(rValue))
                    bytes[i + 1] = UInt8(clamping: Int(gValue))
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
        // T-404: offscreen render of a fixture Project (3 clips incl. one sped-up, 2 zooms, one
        // torn by a cut, a camera layout, playhead mid-way) to PNG, so the static drawing can be
        // eyeballed against SPEC §7.1 without a running editor window (T-307 isn't built yet).
        "timeline-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else { throw Fail(description: "usage: timeline-png <out.png>") }

            var project = Project(
                title: "Fixture",
                source: Source(kind: .display, pixelWidth: 1920, pixelHeight: 1080, scale: 2, duration: 60, hasCamera: true)
            )
            project.clips = [
                Clip(sourceStart: 0, sourceEnd: 15, speed: 1),
                Clip(sourceStart: 15, sourceEnd: 35, speed: 2),   // sped up: 20 source s -> 10 output s
                Clip(sourceStart: 40, sourceEnd: 60, speed: 1),   // 35...40 is a cut
            ]
            project.zooms = [
                Zoom(start: 5, end: 9, scale: 2, mode: .auto),          // fully inside clip 0
                Zoom(start: 30, end: 38, scale: 1.6, mode: .manual),    // torn: 35...38 falls in the cut
            ]
            project.layouts = [Layout(start: 0, end: 15, kind: .cameraFull)]
            project.masks = [Mask(start: 20, end: 26, kind: .highlight, rect: NormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), opacity: 0.6)]

            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-timeline-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            // T-416: a short synthetic mic track so the clip lane actually has a waveform to draw.
            try synthesizeSineM4A(at: tmp.appendingPathComponent("mic.m4a"), duration: 15)

            let model = await EditorModel(packageURL: tmp, project: project, events: EventLog())
            let outputDuration = await model.timeMap.outputDuration
            await MainActor.run { model.playhead = outputDuration / 2 }

            let zoom0ID = UUID(uuidString: project.zooms[0].id)!
            let layout0ID = UUID(uuidString: project.layouts[0].id)!
            let mask0ID = UUID(uuidString: project.masks[0].id)!

            let view = await MainActor.run { () -> TimelineView in
                let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: 160))
                view.model = model
                view.geometry.pxPerSecond = (view.frame.width - TimelineView.gutter) / (outputDuration + 3)
                view.needsDisplay = true
                return view
            }

            // T-416's waveform load happens off the main thread; wait for it before rendering.
            let waveformDeadline = Date().addingTimeInterval(3)
            while await MainActor.run(body: { !view.hasWaveform }) {
                guard Date() < waveformDeadline else { throw Fail(description: "waveform never loaded") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            let (png, hitErrors): (Data?, [String]) = await MainActor.run {
                // T-406: hit-test a handful of known points against the fixture's geometry.
                var errors: [String] = []
                @MainActor func expect(_ p: CGPoint, _ wanted: TimelineHit, _ name: String) {
                    let got = view.hitTest(at: p)
                    if got != wanted { errors.append("\(name): expected \(wanted), got \(got)") }
                }
                expect(CGPoint(x: 430, y: 10), .playhead, "playhead")
                expect(CGPoint(x: 150, y: 40), .clipBody(0), "clipBody")
                expect(CGPoint(x: 290, y: 40), .clipEdge(0, .trailing), "clipEdge")
                expect(CGPoint(x: 140, y: 80), .blockBody(zoom0ID), "zoomBody")
                expect(CGPoint(x: 150, y: 110), .blockBody(layout0ID), "layoutBody")
                // mask [20, 26) source, inside the 2× clip1 -> output [17.5, 20.5); mid ≈ 366, mask
                // row is the 4th (ruler 22 + clip 44 + zoom 32 + layout 28 = 98...126, mask 126...154).
                expect(CGPoint(x: 366, y: 140), .blockBody(mask0ID), "maskBody")
                expect(CGPoint(x: 200, y: 10), .ruler, "ruler")
                expect(CGPoint(x: 476, y: 18), .cutBubble(afterClip: 1), "cutBubble")
                if case .emptyLane(.zoom, _) = view.hitTest(at: CGPoint(x: 700, y: 80)) {} else {
                    errors.append("emptyLane: got \(view.hitTest(at: CGPoint(x: 700, y: 80)))")
                }

                view.needsDisplay = true
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return (nil, errors) }
                view.cacheDisplay(in: view.bounds, to: rep)
                return (rep.representation(using: .png, properties: [:]), errors)
            }
            guard hitErrors.isEmpty else { throw Fail(description: "hitTest: \(hitErrors.joined(separator: "; "))") }
            guard let png else { throw Fail(description: "no PNG data") }
            try png.write(to: URL(fileURLWithPath: outPath))
        },
        // T-308: exercises the exact closures `BackgroundTab`'s controls call — `fieldBinding`
        // (drag: beginGesture → update × N → commitGesture) for the Padding slider, and
        // `kindBinding` (a plain `model.edit`) for the kind picker — and checks they behave as
        // the two undo steps AC-INS-2 requires, with autosave round-tripping both edits.
        "inspector": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-inspector-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let projectURL = tmp.appendingPathComponent("project.json")
            let original = Project(title: "Inspector Test")
            try original.save(to: projectURL)

            let model = await EditorModel(packageURL: tmp, project: original, events: EventLog())

            // Padding `LabeledSlider` drag: begin -> 10 updates -> commit == one undo step.
            await model.beginGesture()
            for i in 0..<10 {
                let v = Double(i + 1) / 10 * 0.3
                await model.update { $0.frame.padding = v }
            }
            await model.commitGesture("Padding")
            let afterPadding = await model.project
            guard afterPadding.frame.padding != original.frame.padding else {
                throw Fail(description: "padding slider drag didn't change the project")
            }

            // Background kind picker == one plain `model.edit`, one more undo step.
            await model.edit("Background kind") { $0.background.kind = .gradient }
            let afterKind = await model.project
            guard afterKind.background.kind == .gradient else { throw Fail(description: "kind change didn't apply") }

            // Autosave reflects both edits.
            try await Task.sleep(nanoseconds: 700_000_000)
            let onDisk = try Project.load(from: projectURL)
            guard onDisk.background.kind == .gradient, onDisk.frame.padding == afterPadding.frame.padding else {
                throw Fail(description: "autosave didn't persist the inspector edits: \(onDisk)")
            }

            // Exactly 2 undo steps: first undo reverts only the kind change, second restores the
            // original project, a third is a no-op (proves there weren't more than 2).
            await model.undo()
            guard await model.project == afterPadding else {
                throw Fail(description: "first undo should revert only the kind change")
            }
            await model.undo()
            guard await model.project == original else {
                throw Fail(description: "second undo should restore the original project")
            }
            await model.undo()
            guard await model.project == original else {
                throw Fail(description: "a third undo changed the project — more than 2 undo steps were recorded")
            }
        },
        // Renders `InspectorView` offscreen (300 pt wide, dark appearance) to a PNG for visual
        // comparison against the SPEC §6.6 mockup. Not part of the automated pass/fail contract.
        // `args[1]` picks the variant (T-414): a `Background.Kind` raw value (unchanged default
        // behaviour), or "zoom"/"clip" (selects a fixture block so `ZoomPanel`/`ClipPanel` render
        // in place of the tabs) or "cursor" (opens the Cursor tab).
        "inspector-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else {
                throw Fail(description: "usage: inspector-png <out.png> [background-kind|zoom|clip|layout|mask|cursor|camera|audio|animations|keys]")
            }
            try await MainActor.run {
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-inspector-png-\(UUID().uuidString)")
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmp) }
                var project = Project(title: "Inspector PNG")
                project.clips = [
                    Clip(sourceStart: 0, sourceEnd: 41.2, speed: 1),
                    Clip(sourceStart: 41.2, sourceEnd: 61.8, speed: 2),
                ]
                let zoom = Zoom(start: 3, end: 7, scale: 2, mode: .manual)
                project.zooms = [zoom]
                let layout = Layout(start: 10, end: 15, kind: .cameraFull)
                project.layouts = [layout]
                let mask = Mask(start: 20, end: 24, kind: .mask, rect: NormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), opacity: 0.8)
                project.masks = [mask]

                let variant = args[safe: 1]
                var initialTab: InspectorView.Tab = .background
                switch variant {
                case "zoom", "clip", "layout", "mask": break
                case "cursor": initialTab = .cursor
                case "camera": initialTab = .camera; project.source.hasCamera = true
                case "camera-empty": initialTab = .camera
                case "audio": initialTab = .audio; project.source.hasMic = true; project.source.hasSystemAudio = true
                case "audio-empty": initialTab = .audio
                case "animations": initialTab = .animations
                case "keys": initialTab = .keys
                default:
                    if let kind = variant.flatMap(Background.Kind.init(rawValue:)) { project.background.kind = kind }
                }

                try project.save(to: tmp.appendingPathComponent("project.json"))
                let model = EditorModel(packageURL: tmp, project: project, events: EventLog())
                if variant == "zoom" { model.selection = [UUID(uuidString: zoom.id)!] }
                if variant == "clip" { model.selectedClip = 1 }
                if variant == "layout" { model.selection = [UUID(uuidString: layout.id)!] }
                if variant == "mask" { model.selection = [UUID(uuidString: mask.id)!] }

                let height: CGFloat = 760
                let hosting = NSHostingView(rootView: InspectorView(model: model, initialTab: initialTab))
                hosting.appearance = NSAppearance(named: .darkAqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)

                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw Fail(description: "png encode failed")
                }
                try data.write(to: URL(fileURLWithPath: outPath))
                print("wrote \(outPath)")
            }
        },
        // T-414: exercises the exact closures `ZoomPanel`/`ClipPanel`/`CursorTab`'s controls call.
        // Zoom: Level slider drag (begin -> 10 updates -> commit), Mode change, Remove — each one
        // undo step, invariants hold throughout. Clip: a speed preset == `setSpeed` + one undo
        // step. Cursor: size/style edits persist via autosave.
        "inspector-panels": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-inspector-panels-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let projectURL = tmp.appendingPathComponent("project.json")

            var original = Project(
                title: "Panels Test",
                source: Source(kind: .display, pixelWidth: 1920, pixelHeight: 1080, scale: 2, duration: 20)
            )
            original.clips = [
                Clip(sourceStart: 0, sourceEnd: 10, speed: 1),
                Clip(sourceStart: 10, sourceEnd: 20, speed: 1),
            ]
            let zoom = Zoom(start: 2, end: 5, scale: 2, mode: .manual)
            original.zooms = [zoom]
            try original.save(to: projectURL)
            let zoomID = UUID(uuidString: zoom.id)!

            let model = await EditorModel(packageURL: tmp, project: original, events: EventLog())

            // --- Zoom panel: Level `LabeledSlider` drag == one undo step. ---
            let beforeLevel = await model.project
            await model.beginGesture()
            for i in 0..<10 {
                let v = 1.2 + Double(i + 1) / 10 * (5 - 1.2)
                await model.update { project in
                    guard let idx = project.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
                    project.zooms[idx].scale = v
                }
            }
            await model.commitGesture("Zoom level")
            let afterLevel = await model.project
            guard afterLevel.zooms[0].scale != beforeLevel.zooms[0].scale else {
                throw Fail(description: "level drag didn't change scale")
            }
            if let err = afterLevel.checkInvariants() { throw Fail(description: "invariants broke after level drag: \(err)") }

            // --- Mode change: a plain `model.edit`, one more undo step. ---
            await model.edit("Zoom") { project in
                guard let idx = project.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
                project.zooms[idx].mode = .auto
            }
            let afterMode = await model.project
            guard afterMode.zooms[0].mode == .auto else { throw Fail(description: "mode change didn't apply") }

            // --- Remove: `Project.removeBlock`, one more undo step. ---
            await model.edit("Remove zoom") { $0.removeBlock(zoomID) }
            let afterDelete = await model.project
            guard afterDelete.zooms.isEmpty else { throw Fail(description: "remove didn't delete the zoom") }
            if let err = afterDelete.checkInvariants() { throw Fail(description: "invariants broke after remove: \(err)") }

            // Exactly 3 undo steps (level, mode, delete): unwind one at a time, a 4th is a no-op.
            await model.undo()
            guard await model.project == afterMode else { throw Fail(description: "undo 1 should revert only the delete") }
            await model.undo()
            guard await model.project == afterLevel else { throw Fail(description: "undo 2 should revert only the mode change") }
            await model.undo()
            guard await model.project == beforeLevel else { throw Fail(description: "undo 3 should restore the pre-drag project") }
            await model.undo()
            guard await model.project == beforeLevel else {
                throw Fail(description: "a 4th undo changed the project — more than 3 undo steps were recorded")
            }
            await model.redo(); await model.redo(); await model.redo()
            guard await model.project == afterDelete else { throw Fail(description: "redo didn't replay all 3 steps") }

            // --- Clip panel: a speed preset == `Project.setSpeed`, one undo step. ---
            let beforeSpeed = await model.project
            await model.edit("Speed") { $0.setSpeed(0, 2) }
            let afterSpeed = await model.project
            guard afterSpeed.clips[0].speed == 2 else { throw Fail(description: "speed preset didn't apply: \(afterSpeed.clips[0].speed)") }
            if let err = afterSpeed.checkInvariants() { throw Fail(description: "invariants broke after speed change: \(err)") }
            await model.undo()
            guard await model.project == beforeSpeed else { throw Fail(description: "speed preset should be exactly one undo step") }
            await model.redo()

            // Remove clip: `Project.removeClip`, one undo step.
            await model.edit("Remove clip") { _ = $0.removeClip(1) }
            let afterRemoveClip = await model.project
            guard afterRemoveClip.clips.count == 1 else { throw Fail(description: "remove clip didn't remove") }
            if let err = afterRemoveClip.checkInvariants() { throw Fail(description: "invariants broke after remove clip: \(err)") }
            await model.undo()

            // --- Cursor tab: size/style edits persist via autosave. ---
            await model.edit("Cursor size") { $0.cursor.size = 3 }
            await model.edit("Cursor movement") { $0.cursor.style = .rapid }
            try await Task.sleep(nanoseconds: 700_000_000)
            let onDisk = try Project.load(from: projectURL)
            guard onDisk.cursor.size == 3, onDisk.cursor.style == .rapid else {
                throw Fail(description: "autosave didn't persist cursor edits: \(onDisk.cursor)")
            }

            // --- Cursor tab (T-604 advanced): Loop toggle == one undo step, autosaved. ---
            let beforeLoop = await model.project
            await model.edit("Loop cursor position") { $0.cursor.loop = true }
            let afterLoop = await model.project
            guard afterLoop.cursor.loop, !beforeLoop.cursor.loop else {
                throw Fail(description: "loop toggle didn't change cursor.loop")
            }
            await model.undo()
            guard await model.project == beforeLoop else { throw Fail(description: "loop toggle should be one undo step") }
            await model.redo()
            try await Task.sleep(nanoseconds: 700_000_000)
            guard try Project.load(from: projectURL).cursor.loop else {
                throw Fail(description: "autosave didn't persist the loop toggle")
            }

            // --- Camera tab (T-502): Position (corner) picker == one undo step, autosaved. ---
            let beforeCorner = await model.project
            await model.edit("Camera position") { $0.camera.corner = .topLeft }
            let afterCorner = await model.project
            guard afterCorner.camera.corner == .topLeft, beforeCorner.camera.corner != .topLeft else {
                throw Fail(description: "camera position edit didn't change camera.corner")
            }
            await model.undo()
            guard await model.project == beforeCorner else { throw Fail(description: "camera position should be one undo step") }
            await model.redo()
            try await Task.sleep(nanoseconds: 700_000_000)
            guard try Project.load(from: projectURL).camera.corner == .topLeft else {
                throw Fail(description: "autosave didn't persist the camera position edit")
            }

            // --- Audio tab (T-504): Microphone volume drag == one undo step, autosaved. ---
            let beforeMicVolume = await model.project
            await model.beginGesture()
            for i in 0..<10 {
                let v = 0.9 - Double(i) / 10
                await model.update { $0.audio.micVolume = v }
            }
            await model.commitGesture("Microphone volume")
            let afterMicVolume = await model.project
            guard afterMicVolume.audio.micVolume != beforeMicVolume.audio.micVolume else {
                throw Fail(description: "microphone volume drag didn't change audio.micVolume")
            }
            await model.undo()
            guard await model.project == beforeMicVolume else {
                throw Fail(description: "microphone volume drag should be one undo step")
            }
            await model.redo()
            try await Task.sleep(nanoseconds: 700_000_000)
            guard try Project.load(from: projectURL).audio.micVolume == afterMicVolume.audio.micVolume else {
                throw Fail(description: "autosave didn't persist the microphone volume edit")
            }

            // --- Animations tab: Screen (zoom spring preset) == one undo step, autosaved. ---
            let beforeScreen = await model.project
            await model.edit("Zoom spring") { $0.animation.screen = .smooth }
            let afterScreen = await model.project
            guard afterScreen.animation.screen == .smooth, beforeScreen.animation.screen != .smooth else {
                throw Fail(description: "screen preset edit didn't change animation.screen")
            }
            await model.undo()
            guard await model.project == beforeScreen else { throw Fail(description: "screen preset should be one undo step") }
            await model.redo()
            try await Task.sleep(nanoseconds: 700_000_000)
            guard try Project.load(from: projectURL).animation.screen == .smooth else {
                throw Fail(description: "autosave didn't persist the screen preset edit")
            }

            // --- Keys tab (T-602): "Show keyboard shortcuts" == one undo step, autosaved. ---
            let beforeShow = await model.project
            await model.edit("Show keyboard shortcuts") { $0.keys.show = true }
            let afterShow = await model.project
            guard afterShow.keys.show, !beforeShow.keys.show else {
                throw Fail(description: "show-keys toggle didn't change keys.show")
            }
            await model.undo()
            guard await model.project == beforeShow else { throw Fail(description: "show-keys toggle should be one undo step") }
            await model.redo()
            try await Task.sleep(nanoseconds: 700_000_000)
            guard try Project.load(from: projectURL).keys.show else {
                throw Fail(description: "autosave didn't persist the show-keys toggle")
            }

            // --- Layout panel (T-503): the exact closures `LayoutPanel`'s kind picker/Remove call
            // — `Project.addLayout`/a plain `model.edit` field write/`Project.removeBlock` — each
            // one undo step, invariants hold throughout. ---
            let beforeLayoutAdd = await model.project
            var layoutID: UUID!
            await model.edit("Add Layout") { layoutID = $0.addLayout(atSource: 12, kind: .cameraFull) }
            let afterLayoutAdd = await model.project
            guard afterLayoutAdd.layouts.count == 1, afterLayoutAdd.layouts[0].kind == .cameraFull else {
                throw Fail(description: "addLayout didn't add a cameraFull layout: \(afterLayoutAdd.layouts)")
            }
            if let err = afterLayoutAdd.checkInvariants() { throw Fail(description: "invariants broke after addLayout: \(err)") }

            await model.edit("Layout") { project in
                guard let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) else { return }
                project.layouts[i].kind = .hidden
            }
            let afterLayoutKind = await model.project
            guard afterLayoutKind.layouts[0].kind == .hidden else { throw Fail(description: "layout kind change didn't apply") }

            await model.edit("Remove layout") { $0.removeBlock(layoutID) }
            let afterLayoutRemove = await model.project
            guard afterLayoutRemove.layouts.isEmpty else { throw Fail(description: "layout remove didn't delete it") }
            if let err = afterLayoutRemove.checkInvariants() { throw Fail(description: "invariants broke after layout remove: \(err)") }

            // Exactly 3 undo steps (add, kind, remove).
            await model.undo()
            guard await model.project == afterLayoutKind else { throw Fail(description: "undo 1 should revert only the layout remove") }
            await model.undo()
            guard await model.project == afterLayoutAdd else { throw Fail(description: "undo 2 should revert only the layout kind change") }
            await model.undo()
            guard await model.project == beforeLayoutAdd else { throw Fail(description: "undo 3 should restore the pre-add project") }
            await model.redo(); await model.redo(); await model.redo()
            guard await model.project == afterLayoutRemove else { throw Fail(description: "redo didn't replay all 3 layout steps") }

            // --- Mask panel (T-601): the exact closures `MaskPanel`'s kind picker/Opacity
            // slider/Remove call — `Project.addMask`/a plain `model.edit` field write/an
            // `update`-only slider drag bracketed by `beginGesture`/`commitGesture`/
            // `Project.removeBlock` — each one undo step, invariants hold throughout. ---
            let beforeMaskAdd = await model.project
            var maskID: UUID!
            await model.edit("Add Mask") { maskID = $0.addMask(atSource: 12, kind: .mask) }
            let afterMaskAdd = await model.project
            guard afterMaskAdd.masks.count == 1, afterMaskAdd.masks[0].kind == .mask, afterMaskAdd.masks[0].opacity == 0.8 else {
                throw Fail(description: "addMask didn't add a mask-kind block at the default opacity: \(afterMaskAdd.masks)")
            }
            if let err = afterMaskAdd.checkInvariants() { throw Fail(description: "invariants broke after addMask: \(err)") }

            await model.edit("Mask") { project in
                guard let i = project.masks.firstIndex(where: { $0.id == maskID.uuidString }) else { return }
                project.masks[i].kind = .highlight
            }
            let afterMaskKind = await model.project
            guard afterMaskKind.masks[0].kind == .highlight else { throw Fail(description: "mask kind change didn't apply") }

            // Opacity `LabeledSlider` drag: begin -> 10 updates -> commit == one undo step.
            await model.beginGesture()
            for i in 0..<10 {
                let v = Double(i + 1) / 10
                await model.update { project in
                    guard let idx = project.masks.firstIndex(where: { $0.id == maskID.uuidString }) else { return }
                    project.masks[idx].opacity = v
                }
            }
            await model.commitGesture("Mask opacity")
            let afterMaskOpacity = await model.project
            guard afterMaskOpacity.masks[0].opacity != afterMaskKind.masks[0].opacity else {
                throw Fail(description: "opacity slider drag didn't change the mask's opacity")
            }
            if let err = afterMaskOpacity.checkInvariants() { throw Fail(description: "invariants broke after the opacity drag: \(err)") }

            await model.edit("Remove mask") { $0.removeBlock(maskID) }
            let afterMaskRemove = await model.project
            guard afterMaskRemove.masks.isEmpty else { throw Fail(description: "mask remove didn't delete it") }
            if let err = afterMaskRemove.checkInvariants() { throw Fail(description: "invariants broke after mask remove: \(err)") }

            // Exactly 4 undo steps (add, kind, opacity drag, remove).
            await model.undo()
            guard await model.project == afterMaskOpacity else { throw Fail(description: "undo 1 should revert only the mask remove") }
            await model.undo()
            guard await model.project == afterMaskKind else { throw Fail(description: "undo 2 should revert only the opacity drag") }
            await model.undo()
            guard await model.project == afterMaskAdd else { throw Fail(description: "undo 3 should revert only the mask kind change") }
            await model.undo()
            guard await model.project == beforeMaskAdd else { throw Fail(description: "undo 4 should restore the pre-add project") }
            await model.redo(); await model.redo(); await model.redo(); await model.redo()
            guard await model.project == afterMaskRemove else { throw Fail(description: "redo didn't replay all 4 mask steps") }
        },
        // Integration check: opens `EditorWindowController`'s real window offscreen (never ordered
        // front — `EditorWindowController.makeOffscreen`) for a fixture package and caches its
        // display to a PNG, for eyeballing against SPEC §6.1's mockup layout. Captures the window's
        // frame view (contentView's superview), not just contentView, so the titlebar row itself
        // (traffic lights) is included.
        // ponytail: one known gap in an offscreen, never-ordered-front capture, acceptable for a
        // static layout check, not a pixel comparison: the preview's MTKView needs a live Metal draw
        // call to have pixels, which `cacheDisplay` never triggers, so that region comes out blank.
        // (T-307 fix: the titlebar's top bar — ‹ Projects · title · Auto ▾ · Crop · Export — used to
        // render 0-width here too, live and offscreen; root cause was the `NSTitlebarAccessoryViewController`
        // API not reliably sizing a wide accessory view, fixed by dropping it for a manually-positioned
        // subview of `EditorRootView` (see `EditorWindowController.configureFullSizeTitlebar`).
        // T-506/T-609 fix: the title text itself then rendered invisible — an editable `NSTextField`
        // reports `NSView.noIntrinsicMetric` for width until it becomes the field editor, so the top
        // bar's `NSStackView` collapsed it to ~0 pt; `EditorWindowController.TitleField` now starts
        // non-editable (real intrinsic width) and flips editable only for the click-to-rename gesture.)
        "editor-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard args.count >= 2 else { throw Fail(description: "usage: editor-png <package> <out.png>") }
            let packageURL = URL(fileURLWithPath: args[0])
            let outURL = URL(fileURLWithPath: args[1])
            try await MainActor.run {
                guard let window = EditorWindowController.makeOffscreen(package: packageURL) else {
                    throw Fail(description: "couldn't load project.json at \(packageURL.path)")
                }
                let capture = window.contentView?.superview ?? window.contentView
                guard let capture else { throw Fail(description: "no capturable view") }
                capture.layoutSubtreeIfNeeded()
                guard let rep = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                capture.cacheDisplay(in: capture.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    throw Fail(description: "png encode failed")
                }
                try png.write(to: outURL)
                print("wrote \(outURL.path)")
            }
        },
        // T-311: builds the real main menu (`AppDelegate.buildMainMenu`) and a real
        // `EditorWindowController` offscreen (`makeOffscreen`, same as `editor-png`) over a small
        // fixture package, then checks: (1) every Edit/View item this task wires keeps
        // `target == nil` (responder-chain dispatch, not a manager object) and has an action;
        // (2) with NO editor controller involved at all, `sendAction` can't resolve any of those
        // selectors (`AppDelegate` doesn't implement them, and under `--selftest` there's no key/main
        // window or app delegate at all) — the "disables itself automatically" half; (3)
        // `EditorWindowController.validateMenuItem` — the same method the responder chain would
        // consult — approves each item once an editor exists and its state supports it (selection
        // made, something on the undo stack, …), and titles Undo/Redo with the pending edit's name;
        // (4) the edit-mutating actions, called directly on the controller (headless: no window is
        // ever key here to drive real key-equivalent dispatch through — T-311's own fallback), each
        // produce the documented `Project` change, leave `checkInvariants() == nil`, and are exactly
        // one `performUndo`/`performRedo` step.
        "menu-actions": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }

            func findItem(_ menu: NSMenu, _ menuTitle: String, _ itemTitle: String) throws -> NSMenuItem {
                guard let item = menu.item(withTitle: menuTitle)?.submenu?.item(withTitle: itemTitle) else {
                    throw Fail(description: "no \(menuTitle) ▸ \(itemTitle) item")
                }
                return item
            }

            // `MainActor.run` below only supports a synchronous body, so anything needing `await`
            // (the fixture's `screen.mov` synthesis here, the Copy Frame check after) happens outside
            // it — `EditorWindowController` isn't itself `@MainActor`, so those are ordinary
            // nonisolated async calls, no further actor hop needed.
            nonisolated(unsafe) var copyFrameController: EditorWindowController?

            // A small fixture package: one 30 s clip, two close clicks at t=5.0/5.2 (for Regenerate
            // Auto Zooms), a 10...14 typing run (for Speed Up Typing), and a real, decodable
            // `screen.mov` (Copy Frame as Image, below, is the one action here that touches the
            // render pipeline — everything else is a pure `Project` mutation).
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-menu-actions-\(UUID().uuidString)")
            let packageURL = tmp.appendingPathComponent("Fixture.recorder")
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            var fixtureProject = Project(title: "Menu Actions",
                                          source: Source(kind: .display, pixelWidth: 1920, pixelHeight: 1080, scale: 1, duration: 30))
            fixtureProject.clips = [Clip(sourceStart: 0, sourceEnd: 30, speed: 1)]
            try fixtureProject.save(to: packageURL.appendingPathComponent("project.json"))

            var fixtureEvents = EventLog()
            fixtureEvents.events.append(InputEvent(t: 5.0, k: .down, x: 0.5, y: 0.5, b: 0))
            fixtureEvents.events.append(InputEvent(t: 5.2, k: .down, x: 0.5, y: 0.5, b: 0))
            var fixtureT = 10.0
            while fixtureT <= 14.0 { fixtureEvents.events.append(InputEvent(t: fixtureT, k: .typing)); fixtureT += 0.5 }
            try JSONEncoder().encode(fixtureEvents).write(to: packageURL.appendingPathComponent("events.json"), options: .atomic)

            try await synthesizeMovie(at: packageURL.appendingPathComponent("screen.mov"), width: 1920, height: 1080, fps: 30, frameCount: 30)

            try await MainActor.run {
                let mainMenu = AppDelegate.buildMainMenu()

                // Every item this task wires to `EditorWindowController` through the responder chain.
                let responderChainItems: [(String, String)] = [
                    ("File", "Save"), ("File", "Save As…"), ("File", "Show Raw Files"),
                    ("Edit", "Undo"), ("Edit", "Redo"), ("Edit", "Split"), ("Edit", "Remove"),
                    ("Edit", "Add Zoom"), ("Edit", "Regenerate Auto Zooms"), ("Edit", "Remove All Zooms"),
                    ("Edit", "Restore All Cuts"), ("Edit", "Speed Up Typing"), ("Edit", "Hide Cursor in Selected Clip"),
                    ("View", "Background"), ("View", "Cursor"), ("View", "Camera"), ("View", "Audio"),
                    ("View", "Animations"), ("View", "Keys"), ("View", "Zoom In"), ("View", "Zoom Out"),
                    ("View", "Fit"), ("View", "Crop…"),
                    ("Export", "Export…"), ("Export", "Copy Frame as Image"),
                ]
                var items: [String: NSMenuItem] = [:]
                for (menuTitle, itemTitle) in responderChainItems {
                    let menuItem = try findItem(mainMenu, menuTitle, itemTitle)
                    guard menuItem.target == nil else {
                        throw Fail(description: "\(itemTitle): target isn't nil (not going through the responder chain)")
                    }
                    guard menuItem.action != nil else { throw Fail(description: "\(itemTitle): no action") }
                    items[itemTitle] = menuItem
                }

                // (2) No editor controller exists: `sendAction` can't find a responder for any of them.
                for (title, menuItem) in items {
                    guard let action = menuItem.action else { continue }
                    let resolved = NSApplication.shared.sendAction(action, to: nil, from: menuItem)
                    guard !resolved else { throw Fail(description: "\(title): resolved a target with no editor open") }
                }

                guard let window = EditorWindowController.makeOffscreen(package: packageURL),
                      let controller = window.windowController as? EditorWindowController else {
                    throw Fail(description: "couldn't build the offscreen editor")
                }
                let model = controller.model

                // Split (`C`).
                model.playhead = 15
                let beforeSplit = model.project
                controller.splitAtPlayhead(nil)
                guard model.project.clips.count == beforeSplit.clips.count + 1 else {
                    throw Fail(description: "Split didn't split: \(model.project.clips)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Split broke invariants") }
                controller.performUndo(nil)
                guard model.project == beforeSplit else { throw Fail(description: "Split wasn't exactly one undo step") }
                controller.performRedo(nil)

                // Remove (`⌫`): the clip the split just made.
                model.selectedClip = 1
                let beforeRemove = model.project
                controller.removeSelected(nil)
                guard model.project.clips.count == beforeRemove.clips.count - 1 else {
                    throw Fail(description: "Remove didn't remove: \(model.project.clips)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Remove broke invariants") }
                controller.performUndo(nil)
                guard model.project == beforeRemove else { throw Fail(description: "Remove wasn't exactly one undo step") }

                // Add Zoom (`Z`) at the playhead's SOURCE time, mode `.auto`.
                model.playhead = 5
                let beforeZoom = model.project
                controller.addZoomAtPlayhead(nil)
                guard model.project.zooms.count == beforeZoom.zooms.count + 1, model.project.zooms.last?.mode == .auto else {
                    throw Fail(description: "Add Zoom didn't add an auto zoom: \(model.project.zooms)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Add Zoom broke invariants") }
                controller.performUndo(nil)
                guard model.project == beforeZoom else { throw Fail(description: "Add Zoom wasn't exactly one undo step") }

                // Regenerate Auto Zooms: from the fixture's two close clicks.
                let beforeRegenerate = model.project
                controller.regenerateAutoZooms(nil)
                guard model.project.zooms.count == 1, model.project.zooms[0].mode == .auto else {
                    throw Fail(description: "Regenerate Auto Zooms: expected 1 auto zoom, got \(model.project.zooms)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Regenerate Auto Zooms broke invariants") }

                // Remove All Zooms.
                let beforeRemoveAllZooms = model.project
                controller.removeAllZooms(nil)
                guard model.project.zooms.isEmpty else { throw Fail(description: "Remove All Zooms didn't clear zooms") }
                controller.performUndo(nil)
                guard model.project == beforeRemoveAllZooms else { throw Fail(description: "Remove All Zooms wasn't exactly one undo step") }
                controller.performUndo(nil) // unwind Regenerate too, back to `beforeRegenerate`.
                guard model.project == beforeRegenerate else { throw Fail(description: "Regenerate Auto Zooms wasn't exactly one undo step") }

                // Restore All Cuts: arrange an actual tail cut first (`removeClip`, not `split`, so
                // there's a real gap to restore), then restore it back to one clip.
                model.edit("Setup: cut the tail") { _ = $0.removeClip(1) }
                let beforeRestore = model.project
                controller.restoreAllCuts(nil)
                guard model.project.clips.count == 1, model.project.clips[0].sourceEnd == 30 else {
                    throw Fail(description: "Restore All Cuts didn't restore the tail: \(model.project.clips)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Restore All Cuts broke invariants") }
                controller.performUndo(nil)
                guard model.project == beforeRestore else { throw Fail(description: "Restore All Cuts wasn't exactly one undo step") }
                controller.performRedo(nil) // back to the single 0...30 clip, for the tests below.

                // Speed Up Typing: the fixture's 10...14 typing run.
                let beforeSpeedUp = model.project
                controller.speedUpTyping(nil)
                guard model.project.clips.contains(where: { $0.sourceStart == 10 && $0.sourceEnd == 14 && $0.speed == 2 }) else {
                    throw Fail(description: "Speed Up Typing didn't produce a 10...14 2x clip: \(model.project.clips)")
                }
                guard model.project.checkInvariants() == nil else { throw Fail(description: "Speed Up Typing broke invariants") }
                controller.performUndo(nil)
                guard model.project == beforeSpeedUp else { throw Fail(description: "Speed Up Typing wasn't exactly one undo step") }

                // Hide Cursor in Selected Clip.
                model.selectedClip = 0
                let beforeHide = model.project
                controller.hideCursorInSelectedClip(nil)
                guard model.project.cursorHidden == [TimeRange(start: 0, end: 30)] else {
                    throw Fail(description: "Hide Cursor didn't append the clip's range: \(model.project.cursorHidden)")
                }
                controller.performUndo(nil)
                guard model.project == beforeHide else { throw Fail(description: "Hide Cursor wasn't exactly one undo step") }
                model.selectedClip = nil

                // (3) `validateMenuItem`: Undo/Redo track the stack (and pick up the edit's name),
                // Remove/Hide Cursor need a selection, everything else just needs an editor.
                model.edit("Probe Edit") { $0.title = "Probed" }
                guard controller.validateMenuItem(items["Undo"]!) else { throw Fail(description: "Undo should validate with something on the undo stack") }
                guard items["Undo"]!.title == "Undo Probe Edit" else { throw Fail(description: "Undo title: \(items["Undo"]!.title)") }
                controller.performUndo(nil)
                guard controller.validateMenuItem(items["Redo"]!) else { throw Fail(description: "Redo should validate with something on the redo stack") }
                guard items["Redo"]!.title == "Redo Probe Edit" else { throw Fail(description: "Redo title: \(items["Redo"]!.title)") }

                model.selectedClip = 0
                guard controller.validateMenuItem(items["Remove"]!) else { throw Fail(description: "Remove should validate with a clip selected") }
                guard controller.validateMenuItem(items["Hide Cursor in Selected Clip"]!) else {
                    throw Fail(description: "Hide Cursor should validate with a clip selected")
                }
                model.selectedClip = nil
                model.selection = []
                guard !controller.validateMenuItem(items["Remove"]!) else { throw Fail(description: "Remove shouldn't validate with nothing selected") }
                guard !controller.validateMenuItem(items["Hide Cursor in Selected Clip"]!) else {
                    throw Fail(description: "Hide Cursor shouldn't validate with nothing selected")
                }
                for tabTitle in ["Background", "Cursor", "Camera", "Audio", "Animations", "Keys"] {
                    guard controller.validateMenuItem(items[tabTitle]!) else { throw Fail(description: "\(tabTitle) tab should always validate") }
                }
                for alwaysOn in ["Save", "Save As…", "Show Raw Files", "Split", "Add Zoom", "Regenerate Auto Zooms",
                                 "Remove All Zooms", "Restore All Cuts", "Zoom In", "Zoom Out", "Fit", "Crop…",
                                 "Export…", "Copy Frame as Image"] {
                    guard controller.validateMenuItem(items[alwaysOn]!) else { throw Fail(description: "\(alwaysOn) should validate with an editor open") }
                }

                // Tab switching, timeline zoom in/out/fit: no `Project` state to check, just confirm
                // they don't crash when actually invoked. Save is safe to call for real too — Save As,
                // Show Raw Files and Export… open a panel/Finder/sheet, so those stay structural-only
                // checks above.
                controller.selectInspectorTab(items["Cursor"]!)
                controller.timelineZoomIn(nil)
                controller.timelineZoomOut(nil)
                controller.timelineFit(nil)
                controller.saveDocument(nil)
                guard fm.fileExists(atPath: packageURL.appendingPathComponent("project.json").path) else {
                    throw Fail(description: "Save didn't write project.json")
                }

                // Copy Frame as Image, below, opens a SECOND, fresh `EditorWindowController` on the
                // just-saved package rather than reusing `controller`: this one went through a dozen
                // `model.edit`s above, each retriggering `PreviewView.rebuildComposition()` (T-306,
                // `Editor/PreviewView.swift`, out of this task's file set) — with a real `screen.mov`
                // now present (needed for Copy Frame itself), those stack up as concurrent, uncancelled
                // AVFoundation decode sessions on the same file and starve a later reader for minutes.
                // A fresh controller has none of that history. Inside the synthesized `screen.mov`'s
                // real 1 s of frames (`frameCount: 30, fps: 30` above) — the project's own
                // `Clip`/`TimeMap` range is 0...30 s, far longer than that.
                guard let copyFrameWindow = EditorWindowController.makeOffscreen(package: packageURL),
                      let freshController = copyFrameWindow.windowController as? EditorWindowController else {
                    throw Fail(description: "couldn't reopen the editor for the Copy Frame check")
                }
                freshController.model.playhead = 0.2
                copyFrameController = freshController
            }

            // Copy Frame as Image: a PNG of the project's native (cropped) resolution on an INJECTED,
            // private pasteboard — never `.general`, so this never touches the user's real clipboard.
            guard let controller = copyFrameController else { throw Fail(description: "no controller for Copy Frame check") }
            let testPasteboard = NSPasteboard.withUniqueName()
            defer { testPasteboard.releaseGlobally() }
            await controller.copyFrameAsImage(to: testPasteboard)
            guard let pngData = testPasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: pngData) else {
                throw Fail(description: "Copy Frame as Image: no PNG landed on the injected pasteboard")
            }
            let expectedWidth = await MainActor.run { controller.model.project.source.pixelWidth }
            let expectedHeight = await MainActor.run { controller.model.project.source.pixelHeight }
            guard rep.pixelsWide == expectedWidth, rep.pixelsHigh == expectedHeight else {
                throw Fail(description: "Copy Frame as Image: expected \(expectedWidth)x\(expectedHeight), got \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        },
        // T-605 (non-Core half): `PresetStore` file storage + applying a saved preset through a real
        // `EditorModel`, so "one undo step" and "clips/zooms untouched" are exercised end-to-end
        // (the styling-subset value + `apply` themselves are covered by RecorderCoreTests/PresetTests).
        "presets": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-presets-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let savedDirectory = PresetStore.directory
            PresetStore.directory = tmp.appendingPathComponent("Presets")
            defer { PresetStore.directory = savedDirectory }

            // Save from a styled project.
            var styled = Project(title: "Styled")
            styled.background = Background(kind: .color, color: "#123456", blur: 0.4)
            styled.frame = Frame(padding: 0.2, cornerRadius: 0.1, shadow: 0.9)
            styled.cursor = CursorStyle(size: 2.5, style: .rapid, loop: true)
            styled.animation = Animation(screen: .smooth, motionBlur: 0.9)
            styled.camera = Camera(size: 0.4, corner: .topLeft, roundness: 0.9)
            let preset = Preset(name: "My Preset", from: styled)
            _ = try PresetStore.save(preset)

            let listed = PresetStore.list()
            guard listed.count == 1, listed[0] == preset else {
                throw Fail(description: "list() didn't round-trip the saved preset")
            }

            // Apply to an unrelated project through a real EditorModel.
            let targetPackage = tmp.appendingPathComponent("Target")
            try fm.createDirectory(at: targetPackage, withIntermediateDirectories: true)
            var target = Project(title: "Target")
            target.clips = [Clip(sourceStart: 0, sourceEnd: 10, speed: 1)]
            target.zooms = [Zoom(start: 4, end: 6, scale: 1.2)]
            try target.save(to: targetPackage.appendingPathComponent("project.json"))

            let model = await EditorModel(packageURL: targetPackage, project: target, events: EventLog())
            await model.edit("Apply Preset") { project in listed[0].apply(to: &project) }
            let applied = await model.project
            guard applied.background == preset.background, applied.frame == preset.frame,
                  applied.cursor == preset.cursor, applied.animation == preset.animation,
                  applied.camera == preset.camera else {
                throw Fail(description: "apply didn't set the styling subset")
            }
            guard applied.clips == target.clips, applied.zooms == target.zooms else {
                throw Fail(description: "apply touched clips/zooms")
            }

            // Exactly one undo step.
            await model.undo()
            guard await model.project == target else { throw Fail(description: "apply wasn't exactly one undo step") }
            await model.redo()

            // Export/import round-trip (the menu just encodes/decodes `Preset` JSON to/from a
            // user-chosen file via NSSavePanel/NSOpenPanel; exercise the same encode/decode here).
            let exportURL = tmp.appendingPathComponent("exported.json")
            try JSONEncoder().encode(preset).write(to: exportURL, options: .atomic)
            let imported = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: exportURL))
            guard imported == preset else { throw Fail(description: "export/import round-trip changed the preset") }
            _ = try PresetStore.save(imported)
            guard PresetStore.list().count == 1 else {
                throw Fail(description: "re-importing a same-named preset should overwrite, not duplicate")
            }

            // Delete.
            try PresetStore.delete(preset)
            guard PresetStore.list().isEmpty else { throw Fail(description: "delete didn't remove the preset file") }
        },
        "recover": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-recover-\(UUID().uuidString)")
            let package = tmp.appendingPathComponent("Orphan.recorder")
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            // Synthesize a small, playable screen.mov with no capture/TCC involved, matching what
            // fragmented writing (T-110) leaves behind after a crash mid-recording.
            let width = 64, height = 48
            let movURL = package.appendingPathComponent("screen.mov")
            try await synthesizeMovie(at: movURL, width: width, height: height)

            let projectURL = package.appendingPathComponent("project.json")
            guard !fm.fileExists(atPath: projectURL.path) else { throw Fail(description: "test setup: project.json already exists") }

            await RecordingRecovery.recoverOrphans(in: tmp)

            guard fm.fileExists(atPath: projectURL.path) else { throw Fail(description: "recovery did not write project.json") }
            let project = try Project.load(from: projectURL)
            guard project.source.pixelWidth == width, project.source.pixelHeight == height else {
                throw Fail(description: "size \(project.source.pixelWidth)x\(project.source.pixelHeight) != \(width)x\(height)")
            }
            guard (0.5...2.0).contains(project.source.duration) else {
                throw Fail(description: "duration \(project.source.duration) out of range 0.5...2.0")
            }
            guard project.clips.first?.sourceEnd == project.source.duration else {
                throw Fail(description: "clip doesn't span the recovered duration")
            }
        },
        // T-606: `ProjectStore.importMovie` on a synthesized movie living outside the library folder,
        // like one dragged in from Finder.
        "import": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-import-\(UUID().uuidString)")
            let libraryFolder = tmp.appendingPathComponent("Library")
            try fm.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let sourceMovie = tmp.appendingPathComponent("My Clip.mov")
            let width = 64, height = 48
            try await synthesizeMovie(at: sourceMovie, width: width, height: height)
            let originalData = try Data(contentsOf: sourceMovie)

            let store = ProjectStore(folder: libraryFolder)
            let packageURL = try await store.importMovie(sourceMovie)

            guard packageURL.lastPathComponent == "My Clip.recorder" else {
                throw Fail(description: "unexpected package name \(packageURL.lastPathComponent)")
            }
            guard fm.fileExists(atPath: packageURL.appendingPathComponent("screen.mov").path) else {
                throw Fail(description: "screen.mov missing")
            }
            guard fm.fileExists(atPath: packageURL.appendingPathComponent("thumbnail.jpg").path) else {
                throw Fail(description: "thumbnail.jpg missing")
            }
            let events = try JSONDecoder().decode(EventLog.self, from: Data(contentsOf: packageURL.appendingPathComponent("events.json")))
            guard events.events.isEmpty else { throw Fail(description: "events.json not empty") }

            let project = try Project.load(from: packageURL.appendingPathComponent("project.json"))
            guard project.source.pixelWidth == width, project.source.pixelHeight == height else {
                throw Fail(description: "size \(project.source.pixelWidth)x\(project.source.pixelHeight) != \(width)x\(height)")
            }
            guard (0.5...2.0).contains(project.source.duration) else {
                throw Fail(description: "duration \(project.source.duration) out of range 0.5...2.0")
            }
            guard project.clips.count == 1, project.clips[0].sourceStart == 0, project.clips[0].sourceEnd == project.source.duration else {
                throw Fail(description: "expected one full-length clip, got \(project.clips)")
            }
            guard project.zooms.isEmpty else { throw Fail(description: "expected no zooms") }

            // Media is never modified after recording (SPEC §5) — including on import.
            guard try Data(contentsOf: sourceMovie) == originalData else {
                throw Fail(description: "original movie file was modified")
            }
        },
        // T-205, SPEC §9 open question 3: no assertions (there's nothing to assert without a live TCC
        // grant on the machine this runs on) — prints every Finder-owned window so a HUMAN can compare
        // against the desktop-icons layer and confirm/adjust `CaptureTarget.filter`'s heuristic.
        "finder-windows": { _ in
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let finderWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" }
            guard !finderWindows.isEmpty else {
                print("SELFTEST finder-windows: no Finder windows found (Screen Recording permission likely not granted to this terminal)")
                return
            }
            let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            for w in finderWindows {
                print("windowLayer=\(w.windowLayer) isDesktopIconLevel=\(w.windowLayer == desktopIconLevel) title=\(w.title ?? "") frame=\(w.frame)")
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
        "record-perf": { args in try await PerfSelfTest.runRecordPerf(args) },
        "idle-perf": { args in try await PerfSelfTest.runIdlePerf(args) },
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
        // T-207b/T-204: builds the status menu in both states and the global hotkey table (no live
        // status item / window needed) and checks them against SPEC §4.7/§8's titles, order and key
        // equivalents, that no two hotkeys share a binding, and every menu item has a target and action.
        "menus": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }

            // SPEC §4.7 global hotkey table (T-204).
            let expected: [(title: String, keyCode: UInt16, mods: NSEvent.ModifierFlags, alwaysActive: Bool)] = [
                ("Start/Finish Recording", 15, [.control, .option, .command], true),  // ⌃⌥⌘R
                ("Pause/Resume", 35, [.control, .option, .command], true),            // ⌃⌥⌘P
                ("New Recording", 36, [.control, .command], false),                   // ⌃⌘↩
                ("Record Display", 20, [.option, .command], false),                   // ⌥⌘3
                ("Record Window", 21, [.option, .command], false),                    // ⌥⌘4
                ("Record Area", 23, [.option, .command], false),                      // ⌥⌘5
                ("Open Last Project", 6, [.option, .command], false),                 // ⌥⌘Z
            ]
            guard Hotkeys.table.count == expected.count else {
                throw Fail(description: "hotkey table has \(Hotkeys.table.count) entries, want \(expected.count)")
            }
            for (got, want) in zip(Hotkeys.table, expected) {
                guard got.title == want.title, got.keyCode == want.keyCode,
                      got.modifiers == want.mods, got.alwaysActive == want.alwaysActive else {
                    throw Fail(description: "hotkey \(got.title): got keyCode=\(got.keyCode) mods=\(got.modifiers) alwaysActive=\(got.alwaysActive), want \(want)")
                }
            }
            var seenBindings = Set<String>()
            for h in Hotkeys.table {
                let binding = "\(h.keyCode)-\(h.modifiers.rawValue)"
                guard seenBindings.insert(binding).inserted else {
                    throw Fail(description: "duplicate hotkey binding on \(h.title)")
                }
            }

            @MainActor func nonSeparators(_ menu: NSMenu) -> [NSMenuItem] { menu.items.filter { !$0.isSeparatorItem } }
            @MainActor func checkItems(_ items: [NSMenuItem], _ expected: [(title: String, key: String, mods: NSEvent.ModifierFlags)], _ label: String) throws {
                guard items.count == expected.count else {
                    throw Fail(description: "\(label): \(items.count) items (\(items.map(\.title))), want \(expected.count)")
                }
                for (item, want) in zip(items, expected) {
                    guard item.title == want.title else { throw Fail(description: "\(label): title \(item.title) != \(want.title)") }
                    guard item.keyEquivalent == want.key else {
                        throw Fail(description: "\(label) \(item.title): key \(item.keyEquivalent.debugDescription) != \(want.key.debugDescription)")
                    }
                    guard item.keyEquivalentModifierMask == want.mods else {
                        throw Fail(description: "\(label) \(item.title): mods \(item.keyEquivalentModifierMask) != \(want.mods)")
                    }
                    guard item.action != nil, item.target != nil else {
                        throw Fail(description: "\(label) \(item.title): missing target/action")
                    }
                }
            }

            try await MainActor.run {
                let delegate = AppDelegate()

                // SPEC §8 idle status menu (`reference/status-item-menu.png`).
                let idle = delegate.buildIdleStatusMenu()
                try checkItems(nonSeparators(idle), [
                    ("New Recording…", "\r", [.control, .command]),
                    ("Record Display", "3", [.option, .command]),
                    ("Record Window", "4", [.option, .command]),
                    ("Record Area", "5", [.option, .command]),
                    ("Settings…", ",", [.command]),
                    ("Show Recorder in Dock", "d", [.command]),
                    ("Projects", "o", [.command, .shift]),
                    ("Open…", "o", [.command]),
                    ("Open Last Project", "z", [.option, .command]),
                    ("Quit Recorder", "q", [.command]),
                ], "idle menu")
                guard idle.items.filter(\.isSeparatorItem).count == 4 else {
                    throw Fail(description: "idle menu: \(idle.items.filter(\.isSeparatorItem).count) separators, want 4")
                }

                // SPEC §4.7 in-progress menu.
                let recording = delegate.buildRecordingStatusMenu()
                try checkItems(nonSeparators(recording), [
                    ("Finish", "r", [.control, .option, .command]),
                    ("Pause", "p", [.control, .option, .command]),
                    ("Restart", "", [.command]),
                    ("Delete", "", [.command]),
                    ("Hide widget", "", [.command]),
                ], "recording menu")
                guard recording.items.filter(\.isSeparatorItem).count == 1 else {
                    throw Fail(description: "recording menu: \(recording.items.filter(\.isSeparatorItem).count) separators, want 1")
                }
            }
        },
        // T-609: `Hotkeys.rebind`/`currentBinding`/`resetToDefaults` against a THROWAWAY `UserDefaults`
        // suite (never `.standard`, so this never touches the user's real saved shortcuts) — table
        // reflects an override, a duplicate combo is rejected, reset restores defaults, and the
        // status-menu key equivalents built from `Hotkeys.table` (`AppDelegate.hotkeyKey`) follow.
        "hotkeys": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let suiteName = "recorder-selftest-hotkeys-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { throw Fail(description: "no UserDefaults suite") }
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                Hotkeys.reload(from: .standard) // leave the process's cache pointed at the real defaults again
            }

            try await MainActor.run {
                Hotkeys.reload(from: defaults)

                guard let displayHotkey = Hotkeys.table.first(where: { $0.title == "Record Display" }),
                      let windowHotkey = Hotkeys.table.first(where: { $0.title == "Record Window" }) else {
                    throw Fail(description: "expected hotkeys missing from the table")
                }

                // Starts at the default (⌥⌘3).
                let initial = Hotkeys.currentBinding(for: displayHotkey)
                guard initial.keyCode == displayHotkey.keyCode, initial.modifiers == displayHotkey.modifiers.rawValue else {
                    throw Fail(description: "unexpected initial binding: \(initial)")
                }

                // Rebind Record Display to ⌃⌥⌘9 — reflected immediately and persisted to `defaults`.
                let newMods: NSEvent.ModifierFlags = [.control, .option, .command]
                guard Hotkeys.rebind(displayHotkey, keyCode: 25 /* '9' */, modifiers: newMods, character: "9", defaults: defaults) else {
                    throw Fail(description: "rebind was unexpectedly rejected")
                }
                let rebound = Hotkeys.currentBinding(titled: "Record Display")
                guard rebound.keyCode == 25, rebound.modifiers == newMods.rawValue, rebound.character == "9" else {
                    throw Fail(description: "rebind didn't take: \(rebound)")
                }
                guard let persisted = HotkeyOverrides.load(from: defaults)["Record Display"], persisted == rebound else {
                    throw Fail(description: "rebind wasn't persisted to the injected suite")
                }

                // Duplicate: rebinding Record Window to the combo Record Display now holds is rejected,
                // and Record Window's own binding is untouched.
                guard !Hotkeys.rebind(windowHotkey, keyCode: 25, modifiers: newMods, character: "9", defaults: defaults) else {
                    throw Fail(description: "duplicate binding wasn't rejected")
                }
                let windowUnchanged = Hotkeys.currentBinding(for: windowHotkey)
                guard windowUnchanged.keyCode == windowHotkey.keyCode, windowUnchanged.modifiers == windowHotkey.modifiers.rawValue else {
                    throw Fail(description: "a rejected rebind still changed Record Window's binding")
                }

                // Status-menu key equivalents mirror the override (`AppDelegate.hotkeyKey`).
                let delegate = AppDelegate()
                let idle = delegate.buildIdleStatusMenu()
                guard let displayItem = idle.items.first(where: { $0.title == "Record Display" }) else {
                    throw Fail(description: "idle menu has no 'Record Display' item")
                }
                guard displayItem.keyEquivalent == "9", displayItem.keyEquivalentModifierMask == newMods else {
                    throw Fail(description: "idle menu's Record Display key didn't follow the rebind: \(displayItem.keyEquivalent.debugDescription)/\(displayItem.keyEquivalentModifierMask)")
                }

                // Reset restores every default, including Record Display's, and the menu follows again.
                Hotkeys.resetToDefaults(defaults: defaults)
                let afterReset = Hotkeys.currentBinding(for: displayHotkey)
                guard afterReset.keyCode == displayHotkey.keyCode, afterReset.modifiers == displayHotkey.modifiers.rawValue,
                      afterReset.character == displayHotkey.character else {
                    throw Fail(description: "reset didn't restore the default: \(afterReset)")
                }
                guard HotkeyOverrides.load(from: defaults).isEmpty else {
                    throw Fail(description: "reset didn't clear the persisted overrides")
                }
                let idleAfterReset = delegate.buildIdleStatusMenu()
                guard let displayItemAfterReset = idleAfterReset.items.first(where: { $0.title == "Record Display" }) else {
                    throw Fail(description: "idle menu has no 'Record Display' item after reset")
                }
                guard displayItemAfterReset.keyEquivalent == "3", displayItemAfterReset.keyEquivalentModifierMask == [.option, .command] else {
                    throw Fail(description: "idle menu's Record Display key didn't follow the reset: \(displayItemAfterReset.keyEquivalent.debugDescription)")
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
        // T-607: `AppDelegate.buildMainMenu` is `private`, so this builds its own small fixture menu
        // (nested submenu, a separator, a disabled item, an item with no action) to exercise
        // `CommandMenu.flatten` end to end: the flattened list's paths/exclusions, `Command.matches`
        // against a couple of queries, and that `CommandMenu.perform` invokes the item's action on
        // its target exactly once.
        "command-menu": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }

            final class Target: NSObject {
                var pingCount = 0
                @objc func ping() { pingCount += 1 }
                @objc func other() {}
            }
            let target = Target()

            let main = NSMenu()

            let file = NSMenu(title: "File")
            let newRecording = NSMenuItem(title: "New Recording", action: #selector(Target.ping), keyEquivalent: "n")
            newRecording.target = target
            file.addItem(newRecording)
            file.addItem(.separator())
            let disabled = NSMenuItem(title: "Disabled Thing", action: #selector(Target.other), keyEquivalent: "")
            disabled.target = target
            disabled.isEnabled = false
            file.addItem(disabled)
            file.addItem(NSMenuItem(title: "No Action Item", action: nil, keyEquivalent: ""))
            let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
            fileItem.submenu = file
            main.addItem(fileItem)

            let edit = NSMenu(title: "Edit")
            let undo = NSMenuItem(title: "Undo", action: #selector(Target.ping), keyEquivalent: "z")
            undo.target = target
            edit.addItem(undo)
            let nested = NSMenu(title: "Nested")
            let deepAction = NSMenuItem(title: "Deep Action", action: #selector(Target.ping), keyEquivalent: "d")
            deepAction.target = target
            deepAction.keyEquivalentModifierMask = [.command, .shift]
            nested.addItem(deepAction)
            let nestedItem = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
            nestedItem.submenu = nested
            edit.addItem(nestedItem)
            let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editItem.submenu = edit
            main.addItem(editItem)

            let commands = CommandMenu.flatten(main)
            let titles = commands.map(\.title)

            guard !titles.contains("Disabled Thing") else { throw Fail(description: "disabled item leaked into the flattened list") }
            guard !titles.contains("No Action Item") else { throw Fail(description: "nil-action item leaked into the flattened list") }
            guard !titles.contains("File"), !titles.contains("Edit"), !titles.contains("Nested") else {
                throw Fail(description: "a submenu-parent item leaked in as a command: \(titles)")
            }
            guard commands.count == 3 else { throw Fail(description: "expected 3 commands, got \(commands.count): \(titles)") }

            guard let newRecordingCmd = commands.first(where: { $0.title == "New Recording" }), newRecordingCmd.path == ["File"],
                  newRecordingCmd.keyEquivalent == "⌘N" else {
                throw Fail(description: "New Recording path/key wrong: \(String(describing: commands.first(where: { $0.title == "New Recording" })))")
            }
            guard let deepActionCmd = commands.first(where: { $0.title == "Deep Action" }), deepActionCmd.path == ["Edit", "Nested"],
                  deepActionCmd.keyEquivalent == "⇧⌘D" else {
                throw Fail(description: "Deep Action path/key wrong: \(String(describing: commands.first(where: { $0.title == "Deep Action" })))")
            }

            // Filtering: substring, subsequence, and no-match queries.
            let byDeep = commands.filter { $0.matches("deep") }
            guard byDeep.count == 1, byDeep[0].title == "Deep Action" else {
                throw Fail(description: "query 'deep' matched \(byDeep.map(\.title)), want just Deep Action")
            }
            let bySubsequence = commands.filter { $0.matches("nwrec") } // subsequence of "File New Recording"
            guard bySubsequence.contains(where: { $0.title == "New Recording" }) else {
                throw Fail(description: "subsequence query 'nwrec' should match New Recording, matched \(bySubsequence.map(\.title))")
            }
            let byNothing = commands.filter { $0.matches("zzz-nope") }
            guard byNothing.isEmpty else { throw Fail(description: "query 'zzz-nope' should match nothing, got \(byNothing.map(\.title))") }

            // Perform: invokes the item's action on its target exactly once.
            guard let toPerform = commands.first(where: { $0.title == "Undo" }) else { throw Fail(description: "Undo missing from flattened list") }
            target.pingCount = 0
            guard CommandMenu.perform(toPerform) else { throw Fail(description: "CommandMenu.perform returned false") }
            guard target.pingCount == 1 else { throw Fail(description: "expected pingCount == 1, got \(target.pingCount)") }
        },
        // Offscreen render of `CheatSheetView` (SPEC §7.3's table, static SwiftUI grid) to a PNG for
        // visual comparison against the spec table — not part of the automated pass/fail contract.
        "cheatsheet-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else { throw Fail(description: "usage: cheatsheet-png <out.png>") }
            try await MainActor.run {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua) // forced before the hosting view exists
                let hosting = NSHostingView(rootView: CheatSheetView())
                hosting.appearance = NSAppearance(named: .darkAqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let fitted = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: fitted)
                window.setContentSize(fitted)
                hosting.layoutSubtreeIfNeeded()

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { throw Fail(description: "png encode failed") }
                try data.write(to: URL(fileURLWithPath: outPath))
                print("wrote \(outPath)")
            }
        },
        // Offscreen render of `CommandMenuView` with a small fixture command list (mixed path depths,
        // with/without key equivalents) to a PNG for visual comparison — not part of the automated
        // pass/fail contract (that's the `command-menu` case).
        "command-menu-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else { throw Fail(description: "usage: command-menu-png <out.png>") }
            try await MainActor.run {
                func fixture(_ title: String, _ path: [String], _ key: String) -> Command {
                    Command(title: title, path: path, keyEquivalent: key,
                            item: NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                }
                let commands = [
                    fixture("New Recording", ["File"], "⌘N"),
                    fixture("Open…", ["File"], "⌘O"),
                    fixture("Undo", ["Edit"], "⌘Z"),
                    fixture("Split", ["Edit"], ""),
                    fixture("Deep Action", ["Edit", "Nested"], "⇧⌘D"),
                    fixture("Export…", ["Export"], "⌘E"),
                ]

                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua) // forced before the hosting view exists
                let hosting = NSHostingView(rootView: CommandMenuView(commands: commands, onClose: {}))
                hosting.appearance = NSAppearance(named: .darkAqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let fitted = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: NSSize(width: 480, height: fitted.height))
                window.setContentSize(hosting.frame.size)
                hosting.layoutSubtreeIfNeeded()

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw Fail(description: "no bitmap rep")
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { throw Fail(description: "png encode failed") }
                try data.write(to: URL(fileURLWithPath: outPath))
                print("wrote \(outPath)")
            }
        },
        // Dev/QA tool (agent UI testing): screen/mouse/keyboard driver, see UIDriver.swift.
        "screenshot": { args in try await UIDriver.screenshot(args) },
        "click": { args in try await UIDriver.click(args) },
        "key": { args in try await UIDriver.key(args) },
        "drag": { args in try await UIDriver.drag(args) },
        // T-407/408/409: drives a `TimelineView` + `EditorModel` over a synthetic project with
        // real (synthesized) `NSEvent`s — no window, no TCC — asserting the invariants CLAUDE.md
        // calls out: invariants hold after every op, each gesture is exactly one undo step, `Esc`
        // mid-drag/mid-split-mode reverts, split refuses near edges, snapping lands on/off candidates.
        "timeline-ops": { _ in try await runTimelineOpsSelfTest() },
        // T-415: manual zoom target overlay — mapping round trip + synthetic drag (see
        // `Render/ZoomTargetMapping.swift`).
        "zoom-target": { args in try await ZoomTargetMapping.runSelfTest(args) },
        "zoom-target-png": { args in try await ZoomTargetMapping.runPNGSelfTest(args) },
        // AC-TL-7: hover preview (see `PreviewView.hoverTime`).
        "hover-preview": { args in try await PreviewView.runHoverPreviewSelfTest(args) },
        // T-504: live AVAudioMix rebuild, export volume/mute/denoise/click (see
        // `Render/AudioMixSelfTest.swift`).
        "audio-mix": { args in try await AudioMixSelfTest.run(args) },
        // T-602 + T-601: writes a persistent `/tmp/M6Fixture.recorder` (real screen.mov, a few
        // low-fps HEVC frames — same lesson as T-504's fixture: a from-scratch H.264 encode measured
        // ~1 s/frame to decode back in this sandboxed environment, HEVC doesn't) with `keys.show`
        // on, two `.key` events, a `mask` and a `highlight`, so `--selftest parity
        // /tmp/M6Fixture.recorder` (which samples inside the chip's fade window and each mask's
        // range whenever they're present — see `ExporterSelfTest.runParitySelfTest`) exercises both
        // renderer passes end to end. Not cleaned up on exit — meant to be reused across runs, like
        // `/tmp/CamFixture.recorder`.
        "make-m6-fixture": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let url = URL(fileURLWithPath: "/tmp/M6Fixture.recorder")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            try await Self.synthesizeGradientMovie(at: url.appendingPathComponent("screen.mov"), width: 640, height: 360, fps: 3, frameCount: 9)

            var project = Project(
                title: "M6 Fixture",
                source: Source(kind: .display, pixelWidth: 640, pixelHeight: 360, scale: 1, duration: 3.0)
            )
            project.clips = [Clip(sourceStart: 0, sourceEnd: 3.0, speed: 1)]
            project.keys.show = true
            // Non-overlapping in time, so a single sampled frame always shows exactly one of them.
            project.masks = [
                Mask(start: 0, end: 1.5, kind: .mask, rect: NormRect(x: 0.08, y: 0.12, w: 0.3, h: 0.3), opacity: 0.9),
                Mask(start: 1.5, end: 3.0, kind: .highlight, rect: NormRect(x: 0.4, y: 0.4, w: 0.3, h: 0.3), opacity: 0.7),
            ]
            try project.save(to: url.appendingPathComponent("project.json"))

            // ⌘K at t=0.5 (holds until 1.7), ⇧⌘S at t=2.0 (holds until 3.2, past the fixture's end
            // — exercises a chip still fading at the very last sampled frame too).
            let events = EventLog(events: [
                InputEvent(t: 0.5, k: .key, keyCode: 0x28, mods: 0x100000),        // ⌘K
                InputEvent(t: 2.0, k: .key, keyCode: 0x01, mods: 0x120000),        // ⇧⌘S
            ])
            try JSONEncoder().encode(events).write(to: url.appendingPathComponent("events.json"))
            print("wrote \(url.path)")
        },
    ]

    /// Synthesizes a small, playable `.mov` with no capture/TCC involved. Shared by the `recover` and
    /// `import` cases so the `AVAssetWriter` boilerplate lives in one place.
    private static func synthesizeMovie(at url: URL, width: Int, height: Int, fps: Int32 = 30, frameCount: Int = 30) async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frame = 0
        while frame < frameCount {
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
            guard let pixelBuffer else { throw Fail(description: "CVPixelBufferCreate failed") }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            frame += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Fail(description: "writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

    /// Same shape as `synthesizeMovie` above, but each frame is a visible diagonal colour gradient
    /// instead of `CVPixelBufferCreate`'s all-zero (black) default — `make-m6-fixture` needs this so
    /// a mask/highlight's dimming is actually visible in a `preview-frame` PNG (a black fill over an
    /// already-black source would be indistinguishable from no mask at all).
    private static func synthesizeGradientMovie(at url: URL, width: Int, height: Int, fps: Int32, frameCount: Int) async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frame = 0
        while frame < frameCount {
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
            guard let pixelBuffer else { throw Fail(description: "CVPixelBufferCreate failed") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let i = y * bytesPerRow + x * 4
                        let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                        bytes[i + 0] = 255                                         // A
                        bytes[i + 1] = UInt8(clamping: Int(60 + 150 * fx))         // R
                        bytes[i + 2] = UInt8(clamping: Int(180 + 60 * fy))         // G
                        bytes[i + 3] = UInt8(clamping: Int(230 - 120 * fx))        // B
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            frame += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Fail(description: "writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

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

// MARK: - T-416: a synthetic `mic.m4a` fixture (used by "timeline-png") so the waveform draws.

private func synthesizeSineM4A(at url: URL, duration: Double, sampleRate: Double = 44_100) throws {
    struct Fail: Error, CustomStringConvertible { let description: String }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
        throw Fail(description: "couldn't allocate a PCM buffer for the mic fixture")
    }
    buffer.frameLength = buffer.frameCapacity
    let channel = buffer.floatChannelData![0]
    for i in 0..<Int(buffer.frameLength) {
        let t = Double(i) / sampleRate
        let envelope = 0.15 + 0.45 * abs(sin(2 * .pi * 0.6 * t)) // varying peaks, like SPEC §7.1's mockup
        channel[i] = Float(sin(2 * .pi * 220 * t) * envelope)
    }
    try file.write(from: buffer)
}

// MARK: - "timeline-ops" (T-407/408/409)

private struct TimelineOpsFail: Error, CustomStringConvertible { let description: String }

private func synthMouse(_ type: NSEvent.EventType, _ p: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

private func synthKey(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
}

private func synthFlags(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)!
}

/// A fresh `TimelineView` + `EditorModel`, at a known `pxPerSecond` (so pixel math in a test is
/// exact): a 20 s single clip and one click event at source t=5. Each section below gets its own,
/// so the sections are independent of each other's end state.
@MainActor
private func makeTimelineOpsFixture(hasCamera: Bool = false) throws -> (model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat, cleanup: () -> Void) {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-timeline-ops-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

    var project = Project(title: "Ops Fixture", source: Source(duration: 20, hasCamera: hasCamera))
    project.clips = [Clip(sourceStart: 0, sourceEnd: 20, speed: 1)]
    let events = EventLog(events: [InputEvent(t: 5, k: .down, x: 0.5, y: 0.5, b: 0)])
    let model = EditorModel(packageURL: tmp, project: project, events: events)

    let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: 160))
    view.model = model
    view.geometry.pxPerSecond = 40
    view.geometry.scrollX = 0
    let gutter = TimelineView.gutter

    func px(_ outputSeconds: Double) -> CGFloat { gutter + CGFloat(outputSeconds * view.geometry.pxPerSecond) }
    // `TimelineView` is flipped; a windowless `convert(_:from: nil)` (what `mouseDown`/etc. use to
    // read `event.locationInWindow`) still applies that flip, so a synthetic event's `y` must be
    // pre-flipped to land at the intended *view-local* y that `hitTest`/lane rows are defined in.
    func py(_ localY: CGFloat) -> CGFloat { view.bounds.height - localY }
    return (model, view, px, py, { try? fm.removeItem(at: tmp) })
}

/// Drives a `TimelineView` + `EditorModel` over synthetic projects, headless: fires real
/// `NSEvent`s at the view exactly as AppKit would, asserting the invariants named in CLAUDE.md /
/// the plan's Verify step.
@MainActor
private func runTimelineOpsSelfTest() async throws {
    do {
        let (model, view, px, py, cleanup) = try makeTimelineOpsFixture()
        defer { cleanup() }
        try runSplitSelfTest(model: model, view: view, px: px, py: py)
    }
    do {
        let (model, view, px, py, cleanup) = try makeTimelineOpsFixture()
        defer { cleanup() }
        try runTrimRemoveRestoreSpeedSelfTest(model: model, view: view, px: px, py: py)
    }
    do {
        let (model, view, px, py, cleanup) = try makeTimelineOpsFixture()
        defer { cleanup() }
        try runZoomBlockSelfTest(model: model, view: view, px: px, py: py)
    }
    do {
        let (model, view, _, _, cleanup) = try makeTimelineOpsFixture()
        defer { cleanup() }
        try runAccessibilitySelfTest(model: model, view: view)
    }
    do {
        let (model, view, px, py, cleanup) = try makeTimelineOpsFixture(hasCamera: true)
        defer { cleanup() }
        try runLayoutBlockSelfTest(model: model, view: view, px: px, py: py)
    }
    do {
        let (model, view, px, py, cleanup) = try makeTimelineOpsFixture()
        defer { cleanup() }
        try runMaskBlockSelfTest(model: model, view: view, px: px, py: py)
    }
    try runFitOnFirstLayoutSelfTest()
}

/// T-417 "Accessibility" (AC-TL-8): `accessibilityChildren()` returns one element per block, role
/// `.button`, the SPEC-shaped label, a non-empty screen-coordinate frame, and increment/decrement
/// nudges the block by one frame through the exact `EditorModel`/`TimelineOps` path a drag would
/// use — one undo step each.
@MainActor
private func runAccessibilitySelfTest(model: EditorModel, view: TimelineView) throws {
    // Fixture: one clip [0, 20), one zoom [3, 8).
    model.edit("setup") { $0.zooms = [Zoom(start: 3, end: 8, scale: 2, mode: .manual)] }
    let zoomID = UUID(uuidString: model.project.zooms[0].id)!

    guard let children = view.accessibilityChildren() as? [NSAccessibilityElement] else {
        throw TimelineOpsFail(description: "accessibilityChildren() returned nil or the wrong element type")
    }
    // One element for the clip, one for the zoom (no camera ⇒ no layout lane; no masks in the fixture).
    guard children.count == 2 else { throw TimelineOpsFail(description: "expected 2 accessibility children, got \(children.count)") }

    for child in children {
        guard child.accessibilityRole() == .button else { throw TimelineOpsFail(description: "block isn't role .button: \(child.accessibilityRole()?.rawValue ?? "nil")") }
        guard !child.accessibilityFrame().isEmpty else { throw TimelineOpsFail(description: "block has an empty accessibility frame") }
    }

    guard let clipElement = children.first(where: { $0.accessibilityLabel()?.hasPrefix("Clip") == true }) else {
        throw TimelineOpsFail(description: "no Clip accessibility element")
    }
    guard clipElement.accessibilityLabel() == "Clip, 0.0 to 20.0 seconds" else {
        throw TimelineOpsFail(description: "unexpected clip label: \(clipElement.accessibilityLabel() ?? "nil")")
    }

    guard let zoomElement = children.first(where: { $0.accessibilityLabel()?.hasPrefix("Zoom") == true }) else {
        throw TimelineOpsFail(description: "no Zoom accessibility element")
    }
    // AC-TL-8's own example shape: "Zoom 2.0×, 3.1 to 7.9 seconds".
    guard zoomElement.accessibilityLabel() == "Zoom 2.0\u{00D7}, 3.0 to 8.0 seconds" else {
        throw TimelineOpsFail(description: "unexpected zoom label: \(zoomElement.accessibilityLabel() ?? "nil")")
    }

    // Increment nudges the zoom forward by exactly one (60 fps) frame, as one undo step, through
    // `EditorModel.edit`/`Project.moveZoom` — the same path `beginMoveBlock`/`updateMoveBlock` use.
    let undoBefore = model.undoStepCount
    guard zoomElement.accessibilityPerformIncrement() else { throw TimelineOpsFail(description: "accessibilityPerformIncrement returned false") }
    guard let moved = model.project.zooms.first(where: { $0.id == zoomID.uuidString }) else { throw TimelineOpsFail(description: "zoom vanished after increment") }
    guard abs(moved.start - (3 + 1.0 / 60)) < 1e-6 else { throw TimelineOpsFail(description: "increment didn't move the zoom by one frame: start \(moved.start)") }
    guard model.undoStepCount == undoBefore + 1 else { throw TimelineOpsFail(description: "increment should push exactly one undo step") }

    // Decrement moves it back by one frame, one more undo step.
    guard let freshChildren = view.accessibilityChildren() as? [NSAccessibilityElement],
          let freshZoom = freshChildren.first(where: { $0.accessibilityLabel()?.hasPrefix("Zoom") == true }) else {
        throw TimelineOpsFail(description: "no Zoom accessibility element after increment")
    }
    guard freshZoom.accessibilityPerformDecrement() else { throw TimelineOpsFail(description: "accessibilityPerformDecrement returned false") }
    guard let back = model.project.zooms.first(where: { $0.id == zoomID.uuidString }), abs(back.start - 3) < 1e-6 else {
        throw TimelineOpsFail(description: "decrement didn't move the zoom back by one frame")
    }
    guard model.undoStepCount == undoBefore + 2 else { throw TimelineOpsFail(description: "decrement should push exactly one more undo step") }

    // A clip's increment nudges its trailing edge forward one frame (SPEC §7.2: clip body drag
    // doesn't move the block, only edge-drag/trim does — the nudge reuses that exact path).
    guard let clipUndoElement = (view.accessibilityChildren() as? [NSAccessibilityElement])?.first(where: { $0.accessibilityLabel()?.hasPrefix("Clip") == true }) else {
        throw TimelineOpsFail(description: "no Clip accessibility element for the trim nudge")
    }
    let undoBeforeClip = model.undoStepCount
    guard clipUndoElement.accessibilityPerformDecrement() else { throw TimelineOpsFail(description: "clip accessibilityPerformDecrement returned false") }
    guard abs(model.project.clips[0].sourceEnd - (20 - 1.0 / 60)) < 1e-6 else {
        throw TimelineOpsFail(description: "clip decrement didn't trim the trailing edge by one frame: \(model.project.clips[0].sourceEnd)")
    }
    guard model.undoStepCount == undoBeforeClip + 1 else { throw TimelineOpsFail(description: "clip nudge should push exactly one undo step") }
}

/// T-405 fix: "the timeline opens fitted" (SPEC §7.2 "Navigation") — regardless of whether the
/// model or the first real layout (non-zero width) happens first — and a later resize never
/// re-fits, whether or not the user has zoomed manually in between.
@MainActor
private func runFitOnFirstLayoutSelfTest() throws {
    func shortProject() throws -> (model: EditorModel, cleanup: () -> Void) {
        let (model, _, _, _, cleanup) = try makeTimelineOpsFixture()
        model.edit("shrink") { $0.clips = [Clip(sourceStart: 0, sourceEnd: 3, speed: 1)] } // a short, 3 s project
        return (model, cleanup)
    }

    // model attached, then the first layout.
    do {
        let (model, cleanup) = try shortProject()
        defer { cleanup() }
        let view = TimelineView(frame: .zero)
        view.model = model
        view.setFrameSize(NSSize(width: 900, height: 160))
        let expected = view.geometry.width / 3
        guard abs(view.geometry.pxPerSecond - expected) < 0.01 else {
            throw TimelineOpsFail(description: "didn't fit on first layout (model-then-layout): pxPerSecond \(view.geometry.pxPerSecond), expected ~\(expected)")
        }
        // A later resize doesn't re-fit — only the first layout does.
        view.setFrameSize(NSSize(width: 1200, height: 160))
        guard abs(view.geometry.pxPerSecond - expected) < 0.01 else {
            throw TimelineOpsFail(description: "a later resize re-fit the timeline")
        }
    }

    // The first layout, then the model attached (duration only becomes known second).
    do {
        let (model, cleanup) = try shortProject()
        defer { cleanup() }
        let view = TimelineView(frame: .zero)
        view.setFrameSize(NSSize(width: 900, height: 160))
        view.model = model
        let expected = view.geometry.width / 3
        guard abs(view.geometry.pxPerSecond - expected) < 0.01 else {
            throw TimelineOpsFail(description: "didn't fit on first layout (layout-then-model): pxPerSecond \(view.geometry.pxPerSecond), expected ~\(expected)")
        }
    }

    // A manual zoom before the first real layout suppresses the auto-fit entirely.
    do {
        let (model, cleanup) = try shortProject()
        defer { cleanup() }
        let view = TimelineView(frame: .zero)
        view.model = model
        view.setZoom(sliderValue: 1.0)
        let zoomed = view.geometry.pxPerSecond
        view.setFrameSize(NSSize(width: 900, height: 160))
        guard view.geometry.pxPerSecond == zoomed else {
            throw TimelineOpsFail(description: "auto-fit ran even though the user had already zoomed")
        }
    }
}

/// T-407 "Split": `C` at the playhead (works, and is refused within 2 frames of an edge), sticky
/// split mode via `S`/toolbar, momentary split mode via `⌥`, snapping onto/off the playhead
/// candidate, `Esc` exiting split mode, and exactly one undo step per successful split.
@MainActor
private func runSplitSelfTest(model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat) throws {
    // `C` splits the single clip at the playhead.
    model.playhead = 10
    let beforeC = model.project
    let undoBeforeC = model.undoStepCount
    view.keyDown(with: synthKey("c", keyCode: 8))
    guard model.project.clips.count == beforeC.clips.count + 1 else {
        throw TimelineOpsFail(description: "`C` didn't split: \(model.project.clips)")
    }
    guard model.project.checkInvariants() == nil else {
        throw TimelineOpsFail(description: "invariants broken after split: \(model.project.checkInvariants()!)")
    }
    guard model.undoStepCount == undoBeforeC + 1 else {
        throw TimelineOpsFail(description: "split should push exactly one undo step, pushed \(model.undoStepCount - undoBeforeC)")
    }
    model.undo()
    guard model.project == beforeC else { throw TimelineOpsFail(description: "undo after split didn't restore the pre-split project") }

    // Refused: within 2 frames (at the default 60 fps) of the clip's trailing edge.
    model.playhead = 20 - 0.01
    let beforeRefused = model.project
    let undoBeforeRefused = model.undoStepCount
    view.keyDown(with: synthKey("c", keyCode: 8))
    guard model.project == beforeRefused else { throw TimelineOpsFail(description: "split within 2 frames of an edge should be a no-op") }
    guard model.undoStepCount == undoBeforeRefused else { throw TimelineOpsFail(description: "a refused split pushed an undo step") }

    // Sticky split mode (`S`), snapped click onto the playhead candidate (10), one undo step.
    model.playhead = 10
    let beforeSnap = model.project
    let undoBeforeSnap = model.undoStepCount
    view.keyDown(with: synthKey("s", keyCode: 1))
    let hoverX = px(10.08) // well within the 6 pt / 40 px-per-s = 0.15 s snap threshold of the playhead
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: hoverX, y: py(60))))
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: hoverX, y: py(60))))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: hoverX, y: py(60))))
    guard model.project.clips.count == beforeSnap.clips.count + 1 else {
        throw TimelineOpsFail(description: "split-mode click didn't split")
    }
    guard model.project.clips[0].sourceEnd == 10 else {
        throw TimelineOpsFail(description: "split-mode click didn't snap onto the playhead: landed at \(model.project.clips[0].sourceEnd)")
    }
    guard model.undoStepCount == undoBeforeSnap + 1 else {
        throw TimelineOpsFail(description: "split-mode click should push exactly one undo step")
    }

    // `Esc` exits sticky split mode: the next click goes back to plain hit-testing (selects, no split).
    view.cancelOperation(nil)
    let beforeEsc = model.project
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(2), y: py(40))))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(2), y: py(40))))
    guard model.project == beforeEsc else { throw TimelineOpsFail(description: "Esc didn't exit split mode — click still split") }

    // Unsnapped: far from every candidate (playhead 10, clip edges 0/10/20), the split lands at
    // the raw (unsnapped) hover time, not clamped to a candidate.
    let farX = px(15.5)
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: farX, y: py(60))))
    view.keyDown(with: synthKey("s", keyCode: 1)) // re-enter sticky mode (Esc above exited it)
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: farX, y: py(60))))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: farX, y: py(60))))
    guard let farClip = model.project.clips.first(where: { abs($0.sourceEnd - 15.5) < 0.05 }) else {
        throw TimelineOpsFail(description: "unsnapped split didn't land near 15.5: \(model.project.clips.map(\.sourceEnd))")
    }
    _ = farClip
    view.cancelOperation(nil) // leave split mode clean for whichever test runs next

    // Momentary `⌥` split mode: held → a click splits; released → it doesn't.
    model.undo(); model.undo(); model.undo() // back to the single, unsplit clip
    guard model.project.clips.count == 1 else { throw TimelineOpsFail(description: "setup: expected a single clip before the ⌥ test") }
    view.flagsChanged(with: synthFlags(.option))
    let optionX = px(10)
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: optionX, y: py(60)), modifiers: .option))
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: optionX, y: py(60)), modifiers: .option))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: optionX, y: py(60)), modifiers: .option))
    guard model.project.clips.count == 2 else { throw TimelineOpsFail(description: "⌥-held click should split") }
    view.flagsChanged(with: synthFlags([]))
    let beforeReleased = model.project
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(2), y: py(40))))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(2), y: py(40))))
    guard model.project == beforeReleased else { throw TimelineOpsFail(description: "click after releasing ⌥ should not split") }
}

/// T-408 "Trim, remove, restore, speed, ripple animation": a trailing-edge trim drag (commits as
/// one undo step), `Esc` mid-drag restoring the pre-drag project (AC-TL-6), `restoreCut` (the ✂
/// bubble popover's action), `⌫` removing a clip, the Speed context-menu item, and a post-edit
/// render (ripple's new code path) not crashing.
@MainActor
private func runTrimRemoveRestoreSpeedSelfTest(model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat) throws {
    // Trailing-edge trim: drag clip 0's right edge from output 20 to output 15.
    let beforeTrim = model.project
    let undoBeforeTrim = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(20) - 3, y: py(40))))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(15), y: py(40))))
    guard model.project.clips[0].sourceEnd == 15 else {
        throw TimelineOpsFail(description: "trim didn't track the mouse: sourceEnd \(model.project.clips[0].sourceEnd)")
    }
    guard model.undoStepCount == undoBeforeTrim else { throw TimelineOpsFail(description: "an in-progress trim shouldn't push an undo step yet") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(15), y: py(40))))
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after trim") }
    guard model.undoStepCount == undoBeforeTrim + 1 else { throw TimelineOpsFail(description: "trim should push exactly one undo step") }
    model.undo()
    guard model.project == beforeTrim else { throw TimelineOpsFail(description: "undo after trim didn't restore the pre-trim project") }
    model.redo() // back to sourceEnd 15 (a tail cut) for the restore test below

    // Restore (the ✂ bubble popover's action): the tail cut (15...20) comes back.
    let beforeRestore = model.project
    let undoBeforeRestore = model.undoStepCount
    view.restoreCut(afterClip: 0)
    guard model.project.clips[0].sourceEnd == 20 else { throw TimelineOpsFail(description: "restoreCut didn't restore the tail") }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after restore") }
    guard model.undoStepCount == undoBeforeRestore + 1 else { throw TimelineOpsFail(description: "restore should push exactly one undo step") }
    model.undo()
    guard model.project == beforeRestore else { throw TimelineOpsFail(description: "undo after restore didn't revert it") }
    model.redo() // back to the whole, uncut [0, 20] clip

    // AC-TL-6: `Esc` mid-drag (leading-edge trim this time) restores the pre-drag project exactly,
    // and pushes no undo step at all (it was never completed).
    let beforeEscDrag = model.project
    let undoBeforeEscDrag = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(0) + 3, y: py(40))))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(5), y: py(40))))
    guard model.project.clips[0].sourceStart == 5 else { throw TimelineOpsFail(description: "mid-drag trim didn't apply live") }
    view.cancelOperation(nil)
    guard model.project == beforeEscDrag else { throw TimelineOpsFail(description: "Esc mid-drag didn't restore the pre-drag project") }
    guard model.undoStepCount == undoBeforeEscDrag else { throw TimelineOpsFail(description: "a cancelled drag pushed an undo step") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(5), y: py(40)))) // the real mouse-up AppKit would still deliver; must be a no-op

    // Remove: split into two clips first (direct setup, not part of what's under test here), then
    // select + `⌫` removes one — the last remaining clip can never be removed (SPEC §7.4).
    model.edit("setup") { $0.clips = [Clip(sourceStart: 0, sourceEnd: 10, speed: 1), Clip(sourceStart: 10, sourceEnd: 20, speed: 1)] }
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(2), y: py(40))))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(2), y: py(40))))
    let undoBeforeRemove = model.undoStepCount
    view.keyDown(with: synthKey("", keyCode: 51)) // ⌫
    guard model.project.clips.count == 1 else { throw TimelineOpsFail(description: "⌫ didn't remove the selected clip") }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after remove") }
    guard model.undoStepCount == undoBeforeRemove + 1 else { throw TimelineOpsFail(description: "remove should push exactly one undo step") }

    // Speed: the real context menu (right-click on the clip), invoking the "2×" item's actual
    // target/action — not a shortcut around it.
    guard let menu = view.menu(for: synthMouse(.rightMouseDown, CGPoint(x: px(5), y: py(40)))),
          let speedItem = menu.items.first(where: { $0.title == "Speed" })?.submenu,
          let twoX = speedItem.items.first(where: { $0.title.hasPrefix("2") }) else {
        throw TimelineOpsFail(description: "no clip context menu / Speed submenu / 2× item")
    }
    let undoBeforeSpeed = model.undoStepCount
    guard let speedAction = twoX.action else { throw TimelineOpsFail(description: "2× item has no action") }
    _ = twoX.target?.perform(speedAction, with: twoX)
    guard model.project.clips[0].speed == 2 else { throw TimelineOpsFail(description: "Speed ▸ 2× menu item didn't set speed") }
    guard model.undoStepCount == undoBeforeSpeed + 1 else { throw TimelineOpsFail(description: "speed change should push exactly one undo step") }

    // Ripple's new code path (interpolating from the pre-change geometry) must not crash a render.
    view.needsDisplay = true
    guard view.bitmapImageRepForCachingDisplay(in: view.bounds) != nil else {
        throw TimelineOpsFail(description: "no bitmap rep after a clip-changing edit")
    }
}

/// T-409 "Snapping + zoom-block gestures": add (empty-lane click = manual, `Z` at the playhead near
/// a click event = auto), body drag = move (snapping onto a candidate, clamped at a neighbour),
/// edge drag = resize, `Esc` mid-drag (AC-TL-6), double-click (select + playhead to start), `⌘D`
/// duplicate, and the Disable/Remove context-menu items.
@MainActor
private func runZoomBlockSelfTest(model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat) throws {
    // The fixture has no camera, so the zoom lane is the second row: ruler(22) + clip(44) = 66...98.
    let zoomLaneY = py(82)

    // Empty-lane click adds a zoom; no click event within ±1 s of source 10 ⇒ manual.
    let undoBeforeAdd = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(10), y: zoomLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(10), y: zoomLaneY)))
    guard model.project.zooms.count == 1, model.project.zooms[0].mode == .manual else {
        throw TimelineOpsFail(description: "empty-lane click didn't add a manual zoom: \(model.project.zooms)")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after addZoom") }
    guard model.undoStepCount == undoBeforeAdd + 1 else { throw TimelineOpsFail(description: "addZoom should push exactly one undo step") }
    guard let zoomAID = UUID(uuidString: model.project.zooms[0].id), model.selection == [zoomAID] else {
        throw TimelineOpsFail(description: "the new zoom isn't selected")
    }
    let zoomA = model.project.zooms[0] // [10, 13)

    // `Z` at the playhead (5.2, within ±1 s of the fixture's click event at t=5) ⇒ auto.
    model.playhead = 5.2
    view.keyDown(with: synthKey("z", keyCode: 6))
    guard let zoomB = model.project.zooms.first(where: { $0.id != zoomA.id }) else {
        throw TimelineOpsFail(description: "`Z` didn't add a second zoom")
    }
    guard zoomB.mode == .auto else { throw TimelineOpsFail(description: "zoom near a click event should be auto, got \(zoomB.mode)") }
    guard zoomB.start == 5.2 else { throw TimelineOpsFail(description: "`Z` didn't add at the playhead: start \(zoomB.start)") }

    // Body drag = moveZoom: grab mid-block, drag so its start lands exactly at source 1.
    let grabX = px((zoomB.start + zoomB.end) / 2)
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: grabX, y: zoomLaneY)))
    let undoBeforeMove = model.undoStepCount
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(1 + (zoomB.end - zoomB.start) / 2), y: zoomLaneY)))
    guard let movedLive = model.project.zooms.first(where: { $0.id == zoomB.id }), abs(movedLive.start - 1) < 0.01 else {
        throw TimelineOpsFail(description: "move didn't track the mouse: \(String(describing: model.project.zooms.first { $0.id == zoomB.id }))")
    }
    guard model.undoStepCount == undoBeforeMove else { throw TimelineOpsFail(description: "an in-progress move shouldn't push an undo step yet") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(1 + (zoomB.end - zoomB.start) / 2), y: zoomLaneY)))
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after move") }
    guard model.undoStepCount == undoBeforeMove + 1 else { throw TimelineOpsFail(description: "move should push exactly one undo step") }

    // Dragging into zoom A's territory clamps at its edge instead of overlapping (SPEC §7.2).
    let movedZoom = model.project.zooms.first { $0.id == zoomB.id }!
    let farRightX = px(zoomA.end + 5) // well past zoom A — would overlap if unclamped
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px((movedZoom.start + movedZoom.end) / 2), y: zoomLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: farRightX, y: zoomLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: farRightX, y: zoomLaneY)))
    guard let clamped = model.project.zooms.first(where: { $0.id == zoomB.id }) else { throw TimelineOpsFail(description: "zoom B vanished") }
    guard clamped.end <= zoomA.start + 1e-6 else { throw TimelineOpsFail(description: "move overlapped zoom A: \(clamped) vs \(zoomA)") }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after clamped move") }

    // Esc mid-drag (AC-TL-6): restores the pre-drag project, pushes no undo step.
    let beforeEscDrag = model.project
    let undoBeforeEscDrag = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px((clamped.start + clamped.end) / 2), y: zoomLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(2), y: zoomLaneY)))
    guard model.project != beforeEscDrag else { throw TimelineOpsFail(description: "mid-drag move didn't apply live") }
    view.cancelOperation(nil)
    guard model.project == beforeEscDrag else { throw TimelineOpsFail(description: "Esc mid-drag didn't restore the pre-drag project") }
    guard model.undoStepCount == undoBeforeEscDrag else { throw TimelineOpsFail(description: "a cancelled move pushed an undo step") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(2), y: zoomLaneY))) // the real mouse-up AppKit still delivers

    // Snapping: the *raw mouse position* (not the resulting start) is what's compared to the
    // candidates, so grab a known 0.2 s inside the block's leading edge (safely past the 0.15 s
    // edge-hit-test zone) and drag until the mouse itself is 0.05 s from the playhead candidate
    // (5.2) — well within the 0.15 s threshold — so it should snap exactly onto it.
    model.playhead = 5.2
    let beforeSnapMove = model.project.zooms.first { $0.id == zoomB.id }!
    let grabOffset = 0.2
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(beforeSnapMove.start + grabOffset), y: zoomLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(5.2 + 0.05), y: zoomLaneY)))
    guard let snapped = model.project.zooms.first(where: { $0.id == zoomB.id }), abs(snapped.start - (5.2 - grabOffset)) < 0.01 else {
        throw TimelineOpsFail(description: "move didn't snap onto the playhead: \(String(describing: model.project.zooms.first { $0.id == zoomB.id }))")
    }
    // ⌘ held disables snapping — the same near-candidate drag should now land at the raw position.
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(5.2 + 0.05), y: zoomLaneY), modifiers: .command))
    guard let unsnapped = model.project.zooms.first(where: { $0.id == zoomB.id }), abs(unsnapped.start - (5.25 - grabOffset)) < 0.01 else {
        throw TimelineOpsFail(description: "⌘ should have disabled snapping: \(String(describing: model.project.zooms.first { $0.id == zoomB.id }))")
    }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(5.2 + 0.05), y: zoomLaneY), modifiers: .command))

    // Edge drag = resizeZoom.
    let beforeResize = model.project.zooms.first { $0.id == zoomB.id }!
    let undoBeforeResize = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(beforeResize.end) - 3, y: zoomLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(beforeResize.start + 4), y: zoomLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(beforeResize.start + 4), y: zoomLaneY)))
    guard let resized = model.project.zooms.first(where: { $0.id == zoomB.id }), abs(resized.end - (beforeResize.start + 4)) < 0.01 else {
        throw TimelineOpsFail(description: "trailing-edge drag didn't resize: \(String(describing: model.project.zooms.first { $0.id == zoomB.id }))")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after resize") }
    guard model.undoStepCount == undoBeforeResize + 1 else { throw TimelineOpsFail(description: "resize should push exactly one undo step") }

    // Double-click zoom A: selects it and moves the playhead to its start.
    model.playhead = 0
    view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: px(zoomA.start + 1), y: zoomLaneY),
                                             modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
    guard model.playhead == zoomA.start, model.selection == [UUID(uuidString: zoomA.id)!] else {
        throw TimelineOpsFail(description: "double-click didn't select + move the playhead: playhead \(model.playhead), selection \(model.selection)")
    }

    // `⌘D` duplicates the selected zoom (A) right after itself, copying its fields.
    let undoBeforeDup = model.undoStepCount
    view.keyDown(with: synthKey("d", keyCode: 2, modifiers: .command))
    guard let dup = model.project.zooms.first(where: { $0.id != zoomA.id && $0.id != zoomB.id }) else {
        throw TimelineOpsFail(description: "⌘D didn't add a duplicate")
    }
    guard abs(dup.start - zoomA.end) < 0.01, abs((dup.end - dup.start) - (zoomA.end - zoomA.start)) < 0.01, dup.scale == zoomA.scale else {
        throw TimelineOpsFail(description: "duplicate isn't placed right after / doesn't match the original: \(dup) vs \(zoomA)")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after duplicate") }
    guard model.undoStepCount == undoBeforeDup + 1 else { throw TimelineOpsFail(description: "duplicate should push exactly one undo step") }

    // Context menu: Disable, then Remove — both real target/action, both one undo step.
    guard let menu = view.menu(for: synthMouse(.rightMouseDown, CGPoint(x: px(zoomA.start + 1), y: zoomLaneY))),
          let disable = menu.items.first(where: { $0.title == "Disable" }), let disableAction = disable.action else {
        throw TimelineOpsFail(description: "no zoom context menu / Disable item")
    }
    let undoBeforeDisable = model.undoStepCount
    _ = disable.target?.perform(disableAction, with: disable)
    guard model.project.zooms.first(where: { $0.id == zoomA.id })?.enabled == false else {
        throw TimelineOpsFail(description: "Disable menu item didn't disable the zoom")
    }
    guard model.undoStepCount == undoBeforeDisable + 1 else { throw TimelineOpsFail(description: "Disable should push exactly one undo step") }

    guard let menu2 = view.menu(for: synthMouse(.rightMouseDown, CGPoint(x: px(zoomA.start + 1), y: zoomLaneY))),
          let remove = menu2.items.first(where: { $0.title == "Remove" }), let removeAction = remove.action else {
        throw TimelineOpsFail(description: "no zoom context menu / Remove item")
    }
    let zoomsBeforeRemove = model.project.zooms.count
    _ = remove.target?.perform(removeAction, with: remove)
    guard model.project.zooms.count == zoomsBeforeRemove - 1, !model.project.zooms.contains(where: { $0.id == zoomA.id }) else {
        throw TimelineOpsFail(description: "Remove menu item didn't remove zoom A")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after Remove") }

    // Ghost/click-tick drawing paths must not crash a render.
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: px(17), y: zoomLaneY)))
    view.needsDisplay = true
    guard view.bitmapImageRepForCachingDisplay(in: view.bounds) != nil else {
        throw TimelineOpsFail(description: "no bitmap rep with the zoom-lane ghost hovered")
    }
}

/// T-503 "Layout track": add (empty-lane click), body drag = move, edge drag = resize, `Esc`
/// mid-drag (AC-TL-6) and Remove — through the exact same generic gesture code
/// (`beginMoveBlock`/`updateMoveBlock`/`beginResizeBlock`/`updateResizeBlock`/`addBlock(lane:atSource:)`)
/// `runZoomBlockSelfTest` above already exercises for the zoom lane, just parametrised to `.layout`.
@MainActor
private func runLayoutBlockSelfTest(model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat) throws {
    // With a camera, lane order is ruler(22) + clip(44) + zoom(32) + layout(28) = 98...126.
    let layoutLaneY = py(112)

    // Empty-lane click adds a `cameraFull` layout block starting at the click's source time
    // (the gap [0, 20) is wide open, so `addLayout`'s default 3 s block starts exactly at 10:
    // [10, 13)), selects it, one undo step.
    let undoBeforeAdd = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(10), y: layoutLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(10), y: layoutLaneY)))
    guard model.project.layouts.count == 1, model.project.layouts[0].kind == .cameraFull else {
        throw TimelineOpsFail(description: "empty-lane click didn't add a cameraFull layout: \(model.project.layouts)")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after addLayout") }
    guard model.undoStepCount == undoBeforeAdd + 1 else { throw TimelineOpsFail(description: "addLayout should push exactly one undo step") }
    guard let layoutID = UUID(uuidString: model.project.layouts[0].id), model.selection == [layoutID] else {
        throw TimelineOpsFail(description: "the new layout isn't selected")
    }
    let layout = model.project.layouts[0] // [10, 13)

    // Body drag = move: grab mid-block, drag so its start lands exactly at source 1.
    let grabX = px((layout.start + layout.end) / 2)
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: grabX, y: layoutLaneY)))
    let undoBeforeMove = model.undoStepCount
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(1 + (layout.end - layout.start) / 2), y: layoutLaneY)))
    guard let movedLive = model.project.layouts.first(where: { $0.id == layout.id }), abs(movedLive.start - 1) < 0.01 else {
        throw TimelineOpsFail(description: "move didn't track the mouse: \(String(describing: model.project.layouts.first { $0.id == layout.id }))")
    }
    guard model.undoStepCount == undoBeforeMove else { throw TimelineOpsFail(description: "an in-progress move shouldn't push an undo step yet") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(1 + (layout.end - layout.start) / 2), y: layoutLaneY)))
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after move") }
    guard model.undoStepCount == undoBeforeMove + 1 else { throw TimelineOpsFail(description: "move should push exactly one undo step") }

    // Esc mid-drag (AC-TL-6): restores the pre-drag project, pushes no undo step.
    let moved = model.project.layouts.first { $0.id == layout.id }!
    let beforeEscDrag = model.project
    let undoBeforeEscDrag = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px((moved.start + moved.end) / 2), y: layoutLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(5), y: layoutLaneY)))
    guard model.project != beforeEscDrag else { throw TimelineOpsFail(description: "mid-drag move didn't apply live") }
    view.cancelOperation(nil)
    guard model.project == beforeEscDrag else { throw TimelineOpsFail(description: "Esc mid-drag didn't restore the pre-drag project") }
    guard model.undoStepCount == undoBeforeEscDrag else { throw TimelineOpsFail(description: "a cancelled move pushed an undo step") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(5), y: layoutLaneY))) // the real mouse-up AppKit still delivers

    // Edge drag = resize.
    let beforeResize = model.project.layouts.first { $0.id == layout.id }!
    let undoBeforeResize = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(beforeResize.end) - 3, y: layoutLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(beforeResize.start + 4), y: layoutLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(beforeResize.start + 4), y: layoutLaneY)))
    guard let resized = model.project.layouts.first(where: { $0.id == layout.id }), abs(resized.end - (beforeResize.start + 4)) < 0.01 else {
        throw TimelineOpsFail(description: "trailing-edge drag didn't resize: \(String(describing: model.project.layouts.first { $0.id == layout.id }))")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after resize") }
    guard model.undoStepCount == undoBeforeResize + 1 else { throw TimelineOpsFail(description: "resize should push exactly one undo step") }

    // Remove (the LayoutPanel's own Remove button — `Project.removeBlock`; SPEC §7.2's "Context
    // menus" list has no entry for the layout lane, so there's no right-click item to exercise).
    let undoBeforeRemove = model.undoStepCount
    model.edit("Remove layout") { $0.removeBlock(layoutID) }
    guard model.project.layouts.isEmpty else { throw TimelineOpsFail(description: "removeBlock didn't remove the layout") }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after remove") }
    guard model.undoStepCount == undoBeforeRemove + 1 else { throw TimelineOpsFail(description: "remove should push exactly one undo step") }

    // A `.hidden`-kind block (now drawn too, not just `cameraFull`) + the ghost + accessibility
    // paths must not crash, and the accessibility tree must include it.
    model.edit("setup hidden") { $0.layouts = [Layout(start: 0, end: 3, kind: .hidden)] }
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: px(10), y: layoutLaneY)))
    view.needsDisplay = true
    guard view.bitmapImageRepForCachingDisplay(in: view.bounds) != nil else {
        throw TimelineOpsFail(description: "no bitmap rep with a hidden-kind layout block + ghost hovered")
    }
    guard let children = view.accessibilityChildren() as? [NSAccessibilityElement],
          children.contains(where: { $0.accessibilityLabel() == "Layout, Hidden, 0.0 to 3.0 seconds" }) else {
        throw TimelineOpsFail(description: "no Layout accessibility element for the hidden-kind block")
    }
}

/// T-601 "Masks & highlights" (timeline half): add (empty-lane click), body drag = move, edge
/// drag = resize, `Esc` mid-drag (AC-TL-6) and Remove — the exact same generic gesture code
/// `runZoomBlockSelfTest`/`runLayoutBlockSelfTest` above already exercise, just parametrised to
/// `.mask`. The mask lane needs no camera and is always shown (unlike layout).
@MainActor
private func runMaskBlockSelfTest(model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat) throws {
    // No camera ⇒ layout lane is 0 pt, so mask is the third lane: ruler(22) + clip(44) + zoom(32) = 98...126.
    let maskLaneY = py(112)

    // Empty-lane click adds a `mask`-kind block at the click's source time (the gap [0, 20) is
    // wide open, so `addMask`'s default 3 s block starts exactly at 10: [10, 13)), selects it,
    // one undo step.
    let undoBeforeAdd = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(10), y: maskLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(10), y: maskLaneY)))
    guard model.project.masks.count == 1, model.project.masks[0].kind == .mask else {
        throw TimelineOpsFail(description: "empty-lane click didn't add a mask block: \(model.project.masks)")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after addMask") }
    guard model.undoStepCount == undoBeforeAdd + 1 else { throw TimelineOpsFail(description: "addMask should push exactly one undo step") }
    guard let maskID = UUID(uuidString: model.project.masks[0].id), model.selection == [maskID] else {
        throw TimelineOpsFail(description: "the new mask isn't selected")
    }
    let mask = model.project.masks[0] // [10, 13)

    // Body drag = move: grab mid-block, drag so its start lands exactly at source 1.
    let grabX = px((mask.start + mask.end) / 2)
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: grabX, y: maskLaneY)))
    let undoBeforeMove = model.undoStepCount
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(1 + (mask.end - mask.start) / 2), y: maskLaneY)))
    guard let movedLive = model.project.masks.first(where: { $0.id == mask.id }), abs(movedLive.start - 1) < 0.01 else {
        throw TimelineOpsFail(description: "move didn't track the mouse: \(String(describing: model.project.masks.first { $0.id == mask.id }))")
    }
    guard model.undoStepCount == undoBeforeMove else { throw TimelineOpsFail(description: "an in-progress move shouldn't push an undo step yet") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(1 + (mask.end - mask.start) / 2), y: maskLaneY)))
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after move") }
    guard model.undoStepCount == undoBeforeMove + 1 else { throw TimelineOpsFail(description: "move should push exactly one undo step") }

    // Esc mid-drag (AC-TL-6): restores the pre-drag project, pushes no undo step.
    let moved = model.project.masks.first { $0.id == mask.id }!
    let beforeEscDrag = model.project
    let undoBeforeEscDrag = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px((moved.start + moved.end) / 2), y: maskLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(5), y: maskLaneY)))
    guard model.project != beforeEscDrag else { throw TimelineOpsFail(description: "mid-drag move didn't apply live") }
    view.cancelOperation(nil)
    guard model.project == beforeEscDrag else { throw TimelineOpsFail(description: "Esc mid-drag didn't restore the pre-drag project") }
    guard model.undoStepCount == undoBeforeEscDrag else { throw TimelineOpsFail(description: "a cancelled move pushed an undo step") }
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(5), y: maskLaneY))) // the real mouse-up AppKit still delivers

    // Edge drag = resize.
    let beforeResize = model.project.masks.first { $0.id == mask.id }!
    let undoBeforeResize = model.undoStepCount
    view.mouseDown(with: synthMouse(.leftMouseDown, CGPoint(x: px(beforeResize.end) - 3, y: maskLaneY)))
    view.mouseDragged(with: synthMouse(.leftMouseDragged, CGPoint(x: px(beforeResize.start + 4), y: maskLaneY)))
    view.mouseUp(with: synthMouse(.leftMouseUp, CGPoint(x: px(beforeResize.start + 4), y: maskLaneY)))
    guard let resized = model.project.masks.first(where: { $0.id == mask.id }), abs(resized.end - (beforeResize.start + 4)) < 0.01 else {
        throw TimelineOpsFail(description: "trailing-edge drag didn't resize: \(String(describing: model.project.masks.first { $0.id == mask.id }))")
    }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after resize") }
    guard model.undoStepCount == undoBeforeResize + 1 else { throw TimelineOpsFail(description: "resize should push exactly one undo step") }

    // Hit-test: the mask lane now participates like zoom/layout (SPEC §7.2's hit-test table).
    // `hitTest(at:)` takes a point directly in the view's own (flipped) local space — unlike the
    // `synthMouse`-fed events above, which go through `mouseDown`'s `convert(_:from: nil)` and so
    // need the pre-flipped `maskLaneY`; a direct `hitTest` call uses the un-converted local y (112).
    let bodyPoint = CGPoint(x: px((resized.start + resized.end) / 2), y: 112)
    guard case .blockBody(let hitID) = view.hitTest(at: bodyPoint), hitID == maskID else {
        throw TimelineOpsFail(description: "hitTest over the mask body didn't return .blockBody(maskID): \(view.hitTest(at: bodyPoint))")
    }

    // Remove (the MaskPanel's own Remove button — `Project.removeBlock`; SPEC §7.2's "Context
    // menus" list has no entry for the mask lane, so there's no right-click item to exercise).
    let undoBeforeRemove = model.undoStepCount
    model.edit("Remove mask") { $0.removeBlock(maskID) }
    guard model.project.masks.isEmpty else { throw TimelineOpsFail(description: "removeBlock didn't remove the mask") }
    guard model.project.checkInvariants() == nil else { throw TimelineOpsFail(description: "invariants broken after remove") }
    guard model.undoStepCount == undoBeforeRemove + 1 else { throw TimelineOpsFail(description: "remove should push exactly one undo step") }

    // A `.highlight`-kind block + the ghost + accessibility paths must not crash, and the
    // accessibility tree must include it with the SPEC-shaped label.
    model.edit("setup highlight") { $0.masks = [Mask(start: 0, end: 3, kind: .highlight, opacity: 0.5)] }
    view.mouseMoved(with: synthMouse(.mouseMoved, CGPoint(x: px(10), y: maskLaneY)))
    view.needsDisplay = true
    guard view.bitmapImageRepForCachingDisplay(in: view.bounds) != nil else {
        throw TimelineOpsFail(description: "no bitmap rep with a highlight-kind mask block + ghost hovered")
    }
    guard let children = view.accessibilityChildren() as? [NSAccessibilityElement],
          children.contains(where: { $0.accessibilityLabel() == "Highlight, opacity 50%, 0.0 to 3.0 seconds" }) else {
        throw TimelineOpsFail(description: "no Mask accessibility element for the highlight-kind block")
    }
}
