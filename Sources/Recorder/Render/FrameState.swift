import Metal
import CoreGraphics
import RecorderCore

/// Everything `Compositor.render` needs to draw one output frame — built by pure code from
/// `TimeMap`/`CameraPath`/`CursorPath` sampling, never from `EditorModel` directly, so preview
/// and export (AC-ED-2, pixel parity) can build it from the same inputs. SPEC §6.2.
struct FrameState {
    var outputSize: CGSize
    var screen: MTLTexture?
    var camera: MTLTexture?
    var view: ViewTransform = .identity
    var prevView: ViewTransform = .identity
    var cursor: CursorSample?              // nil until T-412/T-413
    var project: Project
}
