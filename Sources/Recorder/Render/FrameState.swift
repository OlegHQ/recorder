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

    var outputSize: CGSize
    var screen: Texture?
    var camera: Texture?
    var view: ViewTransform = .identity
    var prevView: ViewTransform = .identity
    var cursor: CursorSample?              // nil until T-413
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
    let cursor = model.cursorPath.sample(atSource: sourceTime)
    return FrameState(outputSize: size, screen: screen, camera: camera, view: view, prevView: prevView, cursor: cursor, project: model.project)
}
