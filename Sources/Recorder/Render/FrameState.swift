import Foundation
import Metal
import CoreGraphics
import RecorderCore

/// Everything `Compositor.render` needs to draw one output frame — built by pure code from
/// `TimeMap`/`CameraPath`/`CursorPath` sampling, never from `EditorModel` directly, so preview
/// and export (AC-ED-2, pixel parity) can build it from the same inputs. SPEC §6.2.
struct FrameState {
    /// One decoded video frame. `chroma == nil` ⇒ `luma` is already RGB (mode 3 — synthetic BGRA
    /// fixtures, e.g. the `render` selftest); `chroma != nil` ⇒ biplanar 4:2:0 YCbCr (real capture
    /// output, `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), converted to RGB in the shader
    /// (mode 4, BT.709 video range). SPEC §6.2.
    struct Texture {
        var luma: MTLTexture
        var chroma: MTLTexture?
        init(luma: MTLTexture, chroma: MTLTexture? = nil) { self.luma = luma; self.chroma = chroma }
    }

    /// T-602 Keys tab: the active chip label + its age (seconds since the key was pressed), or
    /// `nil` when `keys.show` is off or no `.key` event is within `activeKeyChip`'s hold window.
    struct KeyChipState {
        var label: String
        var age: Double
    }

    var outputSize: CGSize
    var screen: Texture?
    var camera: Texture?
    var view: ViewTransform = .identity
    var prevView: ViewTransform = .identity
    var cursor: CursorSample?              // nil until T-413
    var layoutKind: Layout.Kind?           // T-503: the active layout block, if any
    var layoutAmount: Double = 0           // T-503: its 0…1 cross-fade amount at this instant
    // T-601/T-602: `sourceTime` itself — `project.masks`/the key chip are both keyed by it, and
    // (unlike `view`/`cursor`) there's nothing to pre-sample into a table, so `Compositor` reads it
    // straight off `FrameState` instead of re-deriving it from `TimeMap` (which it has no access to).
    var videoOpacity: Double = 1
    var sourceTime: Double = 0
    var keyChip: KeyChipState?
    var project: Project
}

/// The one function that builds a `FrameState` for `outputTime` — called by both the preview
/// (`PreviewView.draw`, T-306) and the exporter (T-505) so their rendered pixels are identical
/// (AC-ED-2). `screen`/`camera` are already-decoded for this instant by the caller (an
/// `AVPlayerItemVideoOutput` in the preview, an `AVAssetReaderTrackOutput` in the exporter); `size`
/// is the render target's pixel size.
///
/// `view`/`prevView`/`cursor` come from `model`'s cached `CameraPath`/`CursorPath` (rebuilt on edit,
/// not here — T-413) sampled at `outputTime`'s SOURCE time via `TimeMap`, per SPEC §6.2's
/// `FrameState(t_out)` formula: `prevView` samples the camera path `1/60 s` earlier in source time
/// (for motion blur, T-501), not through `TimeMap` a second time.
@MainActor
func makeFrameState(model: EditorModel, outputTime: Double, screen: FrameState.Texture?, camera: FrameState.Texture?, size: CGSize) -> FrameState {
    let sourceTime = model.timeMap.sourceTime(atOutput: outputTime)
    let view = model.cameraPath.sample(atSource: sourceTime)
    let prevView = model.cameraPath.sample(atSource: sourceTime - 1.0 / 60)
    let clip = model.project.clipIndex(atOutput: outputTime).map { model.project.clips[$0] }
    let mediaTime = clip.map { $0.mediaTime(atSource: sourceTime) } ?? sourceTime
    let cursor = model.cursorPath.sample(atSource: mediaTime)
    let (layoutKind, layoutAmount) = layoutMix(layouts: model.project.layouts, atSource: sourceTime)
    // T-602: the active key chip, if the Keys tab's "Show keyboard shortcuts" is on and a `.key`
    // event is within `activeKeyChip`'s hold window (`RecorderCore/KeyChips.swift`, already merged).
    var keyChip: FrameState.KeyChipState?
    let keys = overlayKeys(project: model.project, atSource: sourceTime)
    let keysBlock = model.project.keystrokeClips.first { sourceTime >= $0.start && sourceTime < $0.end }
    let keyTime = keysBlock.map { ($0.mediaStart ?? $0.start) + (sourceTime - $0.start) * ($0.mediaRate ?? 1) } ?? sourceTime
    if keys.opacity > 0, let chip = activeKeyChip(events: model.events.events, atSource: keyTime, hold: keys.settings.hold, allKeys: keys.settings.allKeys) {
        keyChip = FrameState.KeyChipState(label: chip.label, age: chip.age)
    }
    let videoVisible = model.project.clipIndex(atOutput: outputTime).map { !model.project.clips[$0].isEmpty } ?? false
    let cameraVisible = model.project.cameraClips.contains { sourceTime >= $0.start && sourceTime < $0.end }
    return FrameState(outputSize: size, screen: videoVisible ? screen : nil, camera: cameraVisible ? camera : nil, view: view, prevView: prevView, cursor: cursor,
                       layoutKind: layoutKind, layoutAmount: layoutAmount, videoOpacity: model.project.videoOpacity(atOutput: outputTime), sourceTime: sourceTime, keyChip: keyChip,
                       project: model.project)
}

/// `project.json` + `events.json` (if present — a fresh/recovered package may not have one yet) →
/// an `EditorModel`, so `CursorPath`/`CameraPath` sample real recorded input. Shared by every path
/// that needs a real model to call `makeFrameState` with: the `preview-frame`/`export`/`parity`
/// selftests, and (via `EditorWindowController`, which loads events.json the same way) the app.
@MainActor
func loadEditorModel(package: URL) throws -> EditorModel {
    let project = try Project.load(from: package.appendingPathComponent("project.json"))
    let events = (try? Data(contentsOf: package.appendingPathComponent("events.json")))
        .flatMap { try? JSONDecoder().decode(EventLog.self, from: $0) } ?? EventLog()
    return EditorModel(packageURL: package, project: project, events: events)
}
