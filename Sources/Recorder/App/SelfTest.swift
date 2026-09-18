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

            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-timeline-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let model = await EditorModel(packageURL: tmp, project: project, events: EventLog())
            let outputDuration = await model.timeMap.outputDuration
            await MainActor.run { model.playhead = outputDuration / 2 }

            let zoom0ID = UUID(uuidString: project.zooms[0].id)!
            let layout0ID = UUID(uuidString: project.layouts[0].id)!

            let (png, hitErrors): (Data?, [String]) = await MainActor.run {
                let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: 160))
                view.model = model
                view.geometry.pxPerSecond = (view.frame.width - TimelineView.gutter) / (outputDuration + 3)
                view.needsDisplay = true

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
                expect(CGPoint(x: 200, y: 10), .ruler, "ruler")
                expect(CGPoint(x: 476, y: 18), .cutBubble(afterClip: 1), "cutBubble")
                if case .emptyLane(.zoom, _) = view.hitTest(at: CGPoint(x: 700, y: 80)) {} else {
                    errors.append("emptyLane: got \(view.hitTest(at: CGPoint(x: 700, y: 80)))")
                }

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
        "inspector-png": { args in
            struct Fail: Error, CustomStringConvertible { let description: String }
            guard let outPath = args.first else { throw Fail(description: "usage: inspector-png <out.png>") }
            try await MainActor.run {
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-inspector-png-\(UUID().uuidString)")
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmp) }
                var project = Project(title: "Inspector PNG")
                if let kind = args[safe: 1].flatMap(Background.Kind.init(rawValue:)) { project.background.kind = kind }
                try project.save(to: tmp.appendingPathComponent("project.json"))
                let model = EditorModel(packageURL: tmp, project: project, events: EventLog())

                let height: CGFloat = 760
                let hosting = NSHostingView(rootView: InspectorView(model: model))
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
        "recover": { _ in
            struct Fail: Error, CustomStringConvertible { let description: String }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-recover-\(UUID().uuidString)")
            let package = tmp.appendingPathComponent("Orphan.recorder")
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            // Synthesize a small, playable screen.mov with no capture/TCC involved, matching what
            // fragmented writing (T-110) leaves behind after a crash mid-recording.
            let width = 64, height = 48, fps: Int32 = 30, frameCount = 30
            let movURL = package.appendingPathComponent("screen.mov")
            let writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
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
            guard writer.status == .completed else { throw Fail(description: "writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")") }

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
        // T-407/408/409: drives a `TimelineView` + `EditorModel` over a synthetic project with
        // real (synthesized) `NSEvent`s — no window, no TCC — asserting the invariants CLAUDE.md
        // calls out: invariants hold after every op, each gesture is exactly one undo step, `Esc`
        // mid-drag/mid-split-mode reverts, split refuses near edges, snapping lands on/off candidates.
        "timeline-ops": { _ in try await runTimelineOpsSelfTest() },
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
private func makeTimelineOpsFixture() throws -> (model: EditorModel, view: TimelineView, px: (Double) -> CGFloat, py: (CGFloat) -> CGFloat, cleanup: () -> Void) {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("recorder-selftest-timeline-ops-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

    var project = Project(title: "Ops Fixture", source: Source(duration: 20))
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
    try runFitOnFirstLayoutSelfTest()
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
