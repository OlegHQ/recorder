import SwiftUI
import RecorderCore

/// Scope stays explicit while composition navigation remains available above the workspace.
struct InspectorView: View {
    static let width: CGFloat = 320
    let model: EditorModel
    private var tab: Tab { model.inspectorTab }

    init(model: EditorModel, initialTab: Tab? = nil) {
        self.model = model
        if let initialTab { model.inspectorTab = initialTab }
    }

    private enum Selection: Hashable {
        case multiple(Int)
        case keys(UUID)
        case camera(UUID)
        case clip(Int)
        case zoom(UUID)
        case layout(UUID)
        case mask(UUID)
    }

    private var selectionCount: Int { model.selectedClips.count + model.selection.count }

    private var selection: Selection? {
        guard !model.inspectorShowsProject else { return nil }
        if selectionCount > 1 { return .multiple(selectionCount) }
        if let i = model.selectedClip, model.project.clips.indices.contains(i) { return .clip(i) }
        if model.selection.count == 1, let id = model.selection.first {
            if model.project.keystrokeClips.contains(where: { $0.id == id.uuidString }) { return .keys(id) }
            if model.project.cameraClips.contains(where: { $0.id == id.uuidString }) { return .camera(id) }
            if model.project.zooms.contains(where: { $0.id == id.uuidString }) { return .zoom(id) }
            if model.project.layouts.contains(where: { $0.id == id.uuidString }) { return .layout(id) }
            if model.project.masks.contains(where: { $0.id == id.uuidString }) { return .mask(id) }
        }
        return nil
    }

    private var contentIdentity: String {
        switch selection {
        case .multiple(let count): return "multiple-\(count)"
        case .keys(let id): return "keys-\(id)"
        case .camera(let id): return "camera-\(id)"
        case .clip(let index): return "clip-\(index)"
        case .zoom(let id): return "zoom-\(id)"
        case .layout(let id): return "layout-\(id)"
        case .mask(let id): return "mask-\(id)"
        case nil: return "tab-\(tab.rawValue)"
        }
    }

    enum Tab: Int, CaseIterable {
        case background, cursor, camera, audio, animations, keys

        var title: String {
            switch self {
            case .background: return "Canvas"
            case .cursor: return "Cursor"
            case .camera: return "Camera"
            case .audio: return "Sound"
            case .animations: return "Motion"
            case .keys: return "Keystrokes"
            }
        }

        var icon: String {
            switch self {
            case .background: return "photo"
            case .cursor: return "cursorarrow"
            case .camera: return "camera"
            case .audio: return "waveform"
            case .animations: return "sparkles"
            case .keys: return "keyboard"
            }
        }

        var key: KeyEquivalent { KeyEquivalent(Character("\(rawValue + 1)")) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button("Whole project") { model.inspectorShowsProject = true }
                    .buttonStyle(TechButtonStyle(kind: selection == nil ? .primary : .quiet, compact: true))
                Button(selectionCount == 0 ? "Selection" : "Selection · \(selectionCount)") {
                    model.inspectorShowsProject = false
                }
                .buttonStyle(TechButtonStyle(kind: selection != nil ? .primary : .quiet, compact: true))
                .disabled(selectionCount == 0)
                Spacer(minLength: 0)
            }.padding(12)
            Divider().overlay(Theme.strokeColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if selection == nil {
                        HStack {
                            Text(tab.title).font(Font(Theme.headingFont(28)))
                            Spacer()
                            PresetsMenu(model: model)
                        }
                        Text(tab == .camera || tab == .keys ? "Project default · intervals can override" : "Applies throughout the recording")
                            .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    }
                    content
                        .modifier(InspectorReveal(identity: contentIdentity, order: 1, enabled: !hasSectionReveals))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .id(contentIdentity)
            .transition(.identity)
            if selection == nil && tab == .camera && model.project.source.hasCamera {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let layout = activeCameraLayout {
                        Text("Timed layout active at \(String(format: "%.1f s", model.playhead))")
                            .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                        Button("Edit this timed layout") {
                            model.selectedClips = []
                            model.selection = [UUID(uuidString: layout.id)!]
                            model.inspectorShowsProject = false
                        }.buttonStyle(TechButtonStyle(kind: .primary, compact: true))
                    } else { CameraTimelineActions(model: model) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if selection == nil && tab == .animations {
                Divider()
                ZoomTimelineActions(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if selection == nil && tab == .keys {
                Divider()
                KeysTimelineActions(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .onChange(of: model.cameraInspectorRequested) { _, requested in
            if requested {
                model.inspectorTab = .camera
                // Preview manipulation selects an active layout, otherwise it edits the default.
                model.inspectorShowsProject = selectionCount == 0
                model.cameraInspectorRequested = false
            }
        }
        .frame(minWidth: Self.width, maxWidth: Self.width, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .font(Font(Theme.bodyFont))
        .foregroundStyle(Theme.textPrimaryColor)
        .toggleStyle(TechToggleStyle())
        .disclosureGroupStyle(InspectorDisclosureStyle())
        .background(Theme.bgPanelColor)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.strokeColor).frame(width: 1) }
        .signalWindow()
    }

    private var hasSectionReveals: Bool {
        if case .zoom = selection { return true }
        return selection == nil && (tab == .camera || tab == .audio)
    }

    private var activeCameraLayout: RecorderCore.Layout? {
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        return model.project.layouts.first { $0.kind != .settings && time >= $0.start && time < $0.end }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .multiple(let count):
            InspectorSelectionHeader(title: "\(count) selected") { model.selectedClips = []; model.selection = [] }
            Text("Move or remove these items on the timeline. Select one item to change its properties.")
                .foregroundStyle(Theme.textSecondaryColor)
        case .keys(let id):
            InspectorSelectionHeader(title: "Keystroke clip") { model.selection = [] }
            KeysTab(model: model, layoutID: id)
            Button("Remove keystroke clip", role: .destructive) {
                model.edit("Remove Keystrokes") { $0.removeBlock(id) }
                model.selection = []
            }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
        case .camera(let id):
            InspectorSelectionHeader(title: "Camera clip") { model.selection = [] }
            Text("This interval controls camera footage timing. Appearance is set by project defaults and timed layouts.")
                .foregroundStyle(Theme.textSecondaryColor)
            Button("Edit camera appearance") { model.showProjectInspector(.camera) }
                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            Button("Remove camera clip", role: .destructive) {
                model.edit("Remove Camera") { $0.removeBlock(id) }
                model.selection = []
            }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
        case .clip(let i): ClipPanel(model: model, clipIndex: i)
        case .zoom(let id): ZoomPanel(model: model, zoomID: id)
        case .layout(let id): LayoutPanel(model: model, layoutID: id)
        case .mask(let id): MaskPanel(model: model, maskID: id)
        case nil:
            switch tab {
            case .background: BackgroundTab(model: model)
            case .cursor: CursorTab(model: model)
            case .camera: CameraTab(model: model, showsTimelineActions: false)
            case .audio: AudioTab(model: model)
            case .animations: AnimationsTab(model: model)
            case .keys: KeysTab(model: model, showsTimelineActions: false)
            }
        }
    }
}

/// The `‹ Back` header a selection panel (`ZoomPanel`, `ClipPanel`, …) shows instead of the tab
/// bar (SPEC §6.6, AC-INS-3).
struct InspectorSelectionHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(Font(Theme.headingFont(28)))
                .foregroundStyle(Theme.textPrimaryColor)
            Spacer(minLength: 8)
            Button(action: onBack) {
                Image(systemName: "xmark").frame(width: 16, height: 24)
            }
            .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            .help("Deselect")
            .accessibilityLabel("Deselect")
        }
        .padding(.bottom, 4)
    }
}


/// Production navigation shared with gallery fixtures. Selecting a destination preserves timeline selection.
struct EditorCompositionNavigation: View {
    let model: EditorModel?
    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorView.Tab.allCases, id: \.rawValue) { tab in
                Button { model?.showProjectInspector(tab) } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TechButtonStyle(kind: model.map { $0.inspectorTab == tab &&
                    ($0.inspectorShowsProject || ($0.selection.isEmpty && $0.selectedClips.isEmpty)) } ?? false ? .primary : .quiet, compact: true))
                .keyboardShortcut(tab.key, modifiers: [])
                .help("\(tab.title) · project settings · \(tab.rawValue + 1)")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .bottom) { Theme.strokeColor.frame(height: 1) }
        .disabled(model == nil)
        .signalWindow()
    }
}

/// Selection and playhead are independent. Explain the relationship without moving either implicitly.
struct EffectPreviewControls: View {
    let model: EditorModel
    let start: Double
    let end: Double
    var editsRegion = false
    var regionHint = "Preview is unzoomed for region editing."

    private var containsPlayhead: Bool {
        let time = model.timeMap.sourceTime(atOutput: model.playhead)
        return time >= start && time < end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editsRegion {
                TechSegmentedControl(selection: Binding(get: { model.previewShowsResult }, set: { result in
                    model.stopEffectPreview()
                    model.previewShowsResult = result
                }), options: [(false, "Edit region"), (true, "View result")])
                Text(model.previewShowsResult ? "Preview shows the composed result." : regionHint)
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            }
            HStack {
                Button {
                    if model.previewPlaybackEnd != nil { model.stopEffectPreview() }
                    else { model.replayEffect(start: start, end: end) }
                } label: {
                    Label(model.previewPlaybackEnd != nil ? "Stop preview" : "Replay change",
                          systemImage: model.previewPlaybackEnd != nil ? "stop.fill" : "play.fill")
                }.buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                .disabled(model.previewTime(start: start, end: end) == nil)
                Spacer(minLength: 0)
            }
            if !containsPlayhead {
                HStack {
                    Text("Playhead outside interval")
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                    Spacer(minLength: 4)
                    Button("Go to interval") {
                        if let time = model.previewTime(start: start, end: end) {
                            model.isPlaying = false
                            model.playhead = time
                        }
                    }.buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                    .disabled(model.previewTime(start: start, end: end) == nil)
                }
            }
        }
    }
}
