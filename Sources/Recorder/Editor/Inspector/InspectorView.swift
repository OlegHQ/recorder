import SwiftUI
import RecorderCore

/// SPEC §6.6: the 300 pt-wide inspector. Hosted by the editor window as
/// `NSHostingView(rootView: InspectorView(model: model))`. Six SF-Symbol tabs (keys `1`–`6`);
/// Background (T-308), Cursor (T-414/T-604), Camera (T-502), Audio (T-504), Animations (T-501) and
/// Keys (T-602) all have real controls.
/// SPEC §6.6 "selection in timeline ⇒ the selection's panel replaces the tabs" (AC-INS-3): a
/// selected clip or zoom swaps the tab bar out for `ClipPanel`/`ZoomPanel`; layout/mask selection
/// has no panel yet (T-503/T-601), so it falls back to the tabs. `‹ Back` (or `Esc`, handled by
/// `TimelineView`'s key handling which clears the same `model.selection`/`selectedClip`) returns.
struct InspectorView: View {
    let model: EditorModel
    @State private var tab: Tab

    /// `initialTab` defaults to Background (SPEC §6.1 mockup); the `inspector-png` selftest passes
    /// `.cursor` to render the Cursor tab without simulating a click.
    init(model: EditorModel, initialTab: Tab = .background) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    private enum Selection {
        case clip(Int)
        case zoom(UUID)
    }

    private var selection: Selection? {
        if let i = model.selectedClip, model.project.clips.indices.contains(i) { return .clip(i) }
        if model.selection.count == 1, let id = model.selection.first,
           model.project.zooms.contains(where: { $0.id == id.uuidString }) {
            return .zoom(id)
        }
        return nil
    }

    enum Tab: Int, CaseIterable {
        case background, cursor, camera, audio, animations, keys

        var title: String {
            switch self {
            case .background: return "Background"
            case .cursor: return "Cursor"
            case .camera: return "Camera"
            case .audio: return "Audio"
            case .animations: return "Animations"
            case .keys: return "Keys"
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
            if selection == nil {
                HStack {
                    Spacer()
                    PresetsMenu(model: model)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)

                HStack(spacing: 4) {
                    ForEach(Tab.allCases, id: \.rawValue) { t in
                        Button { tab = t } label: {
                            Image(systemName: t.icon)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(tab == t ? Theme.bgHoverColor : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tab == t ? Theme.textPrimaryColor : Theme.textSecondaryColor)
                        .keyboardShortcut(t.key, modifiers: [])
                        .help(t.title)
                    }
                }
                .padding(8)

                Divider().overlay(Theme.strokeColor)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if selection == nil {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimaryColor)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .frame(width: 300)
        .background(Theme.bgPanelColor)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .clip(let i): ClipPanel(model: model, clipIndex: i)
        case .zoom(let id): ZoomPanel(model: model, zoomID: id)
        case nil:
            switch tab {
            case .background: BackgroundTab(model: model)
            case .cursor: CursorTab(model: model)
            case .camera: CameraTab(model: model)
            case .audio: AudioTab(model: model)
            case .animations: AnimationsTab(model: model)
            case .keys: KeysTab(model: model)
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
            Button(action: onBack) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentTextColor)
            .font(.system(size: 13))

            Spacer()

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimaryColor)
        }
    }
}
