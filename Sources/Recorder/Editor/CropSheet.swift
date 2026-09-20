import AppKit
import AVFoundation
import SwiftUI
import RecorderCore

/// Crop sheet (SPEC §6.7 mockup, ref `13.05.18.png`): the source frame at the playhead's SOURCE time
/// (via `TimeMap`) under a `SelectionRectView` (T-105, shared with area selection §4.5) — rule-of-thirds
/// guides, 8 handles, dim outside. Size/Position fields are source pixels; `Select…` picks an aspect
/// preset. Confirm = one `model.edit("Crop")`; Discard/Esc = no change.
///
/// ONE entry point: the not-yet-merged editor window's top-bar Crop button calls
/// `CropSheet.present(for:on:)` — that's the whole integration surface for T-307/T-311.
enum CropSheet {
    @MainActor
    static func present(for model: EditorModel, on window: NSWindow) {
        let project = model.project
        let sourceSize = CGSize(width: project.source.pixelWidth, height: project.source.pixelHeight)
        let sourceTime = frameTime(project: project, outputTime: model.playhead)
        let packageURL = model.packageURL

        Task { @MainActor in
            let image: CGImage?
            if let sourceTime { image = await Self.frame(at: sourceTime, in: packageURL) }
            else { image = nil }
            let sheet = CropSheetWindow(initialCrop: project.crop, sourceSize: sourceSize, image: image,
                                         onConfirm: { [weak model] newCrop in
                guard let model else { return }
                CropSheet.confirm(newCrop, on: model)
            })
            window.beginSheet(sheet) { _ in }
        }
    }

    /// Crop uses raw media, so an unlinked speed edit must map the timeline clock into media time.
    static func frameTime(project: Project, outputTime: Double) -> Double? {
        let time = TimeMap(project.clips).sourceTime(atOutput: outputTime)
        let clip = project.clips.first { time >= $0.sourceStart && time < $0.sourceEnd }
            ?? (outputTime >= TimeMap(project.clips).outputDuration ? project.clips.last : nil)
        guard let clip, !clip.isEmpty else { return nil }
        return clip.mediaTime(atSource: time)
    }

    /// The Confirm action, factored out so it can be driven directly (by tests, or anything else)
    /// without a real video asset or window — exactly what the sheet's "Confirm changes" button calls.
    /// One `EditorModel.edit` call = one undo step (AC-CROP-1).
    @MainActor
    static func confirm(_ newCrop: NormRect, on model: EditorModel) {
        model.edit("Crop") { $0.crop = newCrop }
    }

    /// Decodes the source frame nearest `sourceTime` from `screen.mov` (the raw, cursor-less capture —
    /// crop is defined against uncropped source pixels, AC-CROP-2). `nil` on any failure (missing
    /// media, e.g. a synthetic test package): callers fall back to a placeholder fill.
    private static func frame(at sourceTime: Double, in packageURL: URL) async -> CGImage? {
        let asset = AVURLAsset(url: packageURL.appendingPathComponent("screen.mov"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
        return await withCheckedContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                cont.resume(returning: image)
            }
        }
    }
}

// MARK: - Geometry

/// Pure mapping between `NormRect` (crop's storage: top-left origin, 0...1 of the *source* frame,
/// SPEC §5) and `SelectionRectView.rect` (bottom-left origin, view points — AppKit's convention),
/// given where the source image is letterboxed inside the view. Kept as one pure function pair (this
/// is where the bugs hide) and covered by the `crop` selftest's round-trip check.
enum CropMapping {
    /// The largest rect of `imageSize`'s aspect centred inside `viewSize` — bottom-left origin, matching
    /// `SelectionRectView`'s coordinate space so it can be used directly as the view's `limit`.
    static func imageRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// View rect → `NormRect`, normalised against `imageRect` (the letterboxed frame), flipping to
    /// top-left origin. Inverse of `viewRect(from:imageRect:)`.
    static func normRect(fromView r: CGRect, imageRect: CGRect) -> NormRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return NormRect() }
        return NormRect(x: (r.minX - imageRect.minX) / imageRect.width,
                         y: (imageRect.maxY - r.maxY) / imageRect.height,
                         w: r.width / imageRect.width,
                         h: r.height / imageRect.height)
    }

    /// `NormRect` → view rect inside `imageRect`. Inverse of `normRect(fromView:imageRect:)`.
    static func viewRect(from n: NormRect, imageRect: CGRect) -> CGRect {
        let width = n.w * imageRect.width
        let height = n.h * imageRect.height
        let x = imageRect.minX + n.x * imageRect.width
        let maxY = imageRect.maxY - n.y * imageRect.height
        return CGRect(x: x, y: maxY - height, width: width, height: height)
    }
}

// MARK: - Window

/// The sheet's own window: fixed-size, standard titlebar with the title hidden (traffic lights only,
/// matching the mockup), custom top/bottom bars (SwiftUI, hosted) around the image + `SelectionRectView`
/// (AppKit, same pairing as `AreaSelectionOverlay`).
final class CropSheetWindow: NSWindow {
    private let selectionView = SelectionRectView(frame: .zero)
    private let imageView = NSImageView()
    private let state: CropState
    private let onConfirm: (NormRect) -> Void

    private static let contentSize = NSSize(width: 920, height: 660)
    private static let topBarHeight: CGFloat = 100
    private static let bottomBarHeight: CGFloat = 60

    init(initialCrop: NormRect, sourceSize: CGSize, image: CGImage?, onConfirm: @escaping (NormRect) -> Void) {
        let size = Self.contentSize
        let state = CropState(sourceSize: sourceSize)
        self.state = state
        self.onConfirm = onConfirm

        super.init(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = Theme.bgPanel

        let imageAreaHeight = size.height - Self.topBarHeight - Self.bottomBarHeight
        let imageContainer = NSView(frame: NSRect(x: 0, y: Self.bottomBarHeight, width: size.width, height: imageAreaHeight))

        if let image { imageView.image = NSImage(cgImage: image, size: .zero) }
        else {
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = Theme.bgControl.cgColor
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = imageContainer.bounds
        imageView.autoresizingMask = [.width, .height]
        imageContainer.addSubview(imageView)

        selectionView.frame = imageContainer.bounds
        selectionView.autoresizingMask = [.width, .height]
        imageContainer.addSubview(selectionView)

        let displaySize = image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) } ?? sourceSize
        let imageRect = CropMapping.imageRect(imageSize: displaySize, in: imageContainer.bounds.size)
        state.imageRect = imageRect
        selectionView.limit = imageRect
        selectionView.minSize = CGSize(width: 20, height: 20)
        // Wire `onChange` before the initial `rect` assignment below, so `state.rect` (and the
        // SwiftUI fields bound to it) picks up the starting crop too, not just later drags/edits.
        selectionView.onChange = { [weak state] r in state?.rect = r }
        selectionView.rect = CropMapping.viewRect(from: initialCrop, imageRect: imageRect)

        // A field commit mid-drag can't fight the mouse — same guard `AreaSelectionOverlay` uses.
        state.apply = { [weak self] r in
            guard let self, !self.selectionView.isDragging else { return }
            self.selectionView.rect = r
        }
        state.applyAspect = { [weak self] ratio in
            guard let self else { return }
            self.selectionView.aspect = ratio
            guard let ratio else { return }
            var r = self.selectionView.rect
            r.size.height = r.width / ratio
            self.selectionView.rect = r
        }
        state.reset = { [weak self] in
            guard let self else { return }
            self.selectionView.rect = imageRect
        }

        let topBar = NSHostingView(rootView: CropTopBarView(state: state))
        topBar.frame = NSRect(x: 0, y: size.height - Self.topBarHeight, width: size.width, height: Self.topBarHeight)
        topBar.autoresizingMask = [.width, .minYMargin]

        let bottomBar = NSHostingView(rootView: CropBottomBarView(
            hasPreview: image != nil,
            onConfirm: { [weak self] in self?.confirmTapped() },
            onDiscard: { [weak self] in self?.discardTapped() }))
        bottomBar.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.bottomBarHeight)
        bottomBar.autoresizingMask = [.width, .maxYMargin]

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(imageContainer)
        root.addSubview(topBar)
        root.addSubview(bottomBar)
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(selectionView)
    }

    /// Esc = Discard (AC-CROP-1).
    override func cancelOperation(_ sender: Any?) { discardTapped() }

    /// The titlebar's red close button = Discard too, and must end the sheet session properly
    /// (`endSheet`, not a bare `close()`) rather than leave the parent window sheet-blocked.
    override func close() {
        if sheetParent != nil { discardTapped() } else { super.close() }
    }

    private func confirmTapped() {
        onConfirm(CropMapping.normRect(fromView: selectionView.rect, imageRect: state.imageRect))
        end()
    }

    private func discardTapped() { end() }

    private func end() {
        if let parent = sheetParent { parent.endSheet(self) } else { orderOut(nil) }
    }
}

/// Bridges `SelectionRectView` (AppKit) and the SwiftUI top bar, and converts to/from source pixels
/// for the Size/Position fields (SPEC §6.7: "Size/position in source pixels").
@Observable
private final class CropState {
    let sourceSize: CGSize
    var imageRect: CGRect = .zero
    var rect: CGRect = .zero
    /// Set by `CropSheetWindow` to `{ selectionView.rect = $0 }`.
    var apply: (CGRect) -> Void = { _ in }
    var applyAspect: (CGFloat?) -> Void = { _ in }
    var reset: () -> Void = {}

    init(sourceSize: CGSize) { self.sourceSize = sourceSize }

    /// Source-pixel rect (top-left origin), two-way bound to `rect` via `CropMapping` + `sourceSize`.
    var pixelRect: CGRect {
        get {
            let n = CropMapping.normRect(fromView: rect, imageRect: imageRect)
            return CGRect(x: n.x * sourceSize.width, y: n.y * sourceSize.height,
                          width: n.w * sourceSize.width, height: n.h * sourceSize.height)
        }
        set {
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }
            let n = NormRect(x: newValue.minX / sourceSize.width, y: newValue.minY / sourceSize.height,
                              w: newValue.width / sourceSize.width, h: newValue.height / sourceSize.height)
            apply(CropMapping.viewRect(from: n, imageRect: imageRect))
        }
    }
}

// MARK: - Top bar (Size/Position fields, aspect presets, Reset)

private enum CropPreset: String, CaseIterable, Identifiable {
    case free = "Free", r16x9 = "16:9", r4x3 = "4:3", r1x1 = "1:1", r9x16 = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .r16x9: return 16.0 / 9.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        }
    }
}

private struct CropTopBarView: View {
    var state: CropState
    @State private var preset: CropPreset = .free

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Crop source").font(Font(Theme.headingFont(24)))
                Spacer()
                Text("Whole recording · dimensions in source pixels")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            }
        HStack(spacing: 16) {
            field("Size", "×", sizeMode: true)
            Menu {
                ForEach(CropPreset.allCases) { p in
                    Button(p.rawValue) { preset = p; state.applyAspect(p.ratio) }
                }
            } label: {
                TechMenuLabel(title: "Aspect · " + preset.rawValue, symbol: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .tint(Theme.textPrimaryColor)
            .fixedSize()
            field("Position", nil, sizeMode: false)
            Button {
                preset = .free
                state.applyAspect(nil)
                state.reset()
            } label: {
                Label("Reset", systemImage: "crop")
            }
            .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            Spacer()
            Image(systemName: "keyboard")
                .foregroundStyle(Theme.textSecondaryColor)
                .help("Arrow keys move the selection; Shift moves it farther.")
        }
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .foregroundStyle(Theme.textPrimaryColor)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
    }

    private func field(_ title: String, _ separator: String?, sizeMode: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Font(Theme.bodyFont)).foregroundStyle(Theme.textSecondaryColor)
            numberField(sizeMode ? \CGRect.size.width : \CGRect.origin.x, label: sizeMode ? "Crop width in pixels" : "Crop left in pixels")
            if let separator { Text(separator).foregroundStyle(Theme.textSecondaryColor) }
            numberField(sizeMode ? \CGRect.size.height : \CGRect.origin.y, label: sizeMode ? "Crop height in pixels" : "Crop top in pixels")
        }
    }

    private func numberField(_ keyPath: WritableKeyPath<CGRect, CGFloat>, label: String) -> some View {
        TextField("", value: binding(keyPath), format: .number)
            .textFieldStyle(TechFieldStyle())
            .accessibilityLabel(label)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
    }

    private func binding(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int(state.pixelRect[keyPath: keyPath].rounded()) },
            set: { newValue in
                var r = state.pixelRect
                r[keyPath: keyPath] = CGFloat(newValue)
                state.pixelRect = r
            }
        )
    }
}

// MARK: - Bottom bar (Confirm/Discard)

private struct CropBottomBarView: View {
    let hasPreview: Bool
    let onConfirm: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(hasPreview ? "Drag the edges to frame your recording." : "Source preview unavailable · use pixel fields or cancel.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Spacer()
            Button("Cancel", action: onDiscard)
                .buttonStyle(TechButtonStyle(kind: .quiet))
                .keyboardShortcut(.cancelAction)
            Button("Apply crop", action: onConfirm)
                .buttonStyle(TechButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .top) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
    }
}
