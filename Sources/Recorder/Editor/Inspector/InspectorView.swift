import SwiftUI

/// SPEC §6.6: the 300 pt-wide inspector. Hosted by the editor window as
/// `NSHostingView(rootView: InspectorView(model: model))`. Six SF-Symbol tabs (keys `1`–`6`);
/// only Background (T-308) has real controls — the rest are placeholders until their own tasks.
/// Selection-swaps-the-tabs (SPEC §6.6 "selection in timeline ⇒ the selection's panel replaces the
/// tabs") is out of scope here: no selection UI exists yet to swap from (T-4xx).
struct InspectorView: View {
    let model: EditorModel
    @State private var tab: Tab = .background

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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimaryColor)
                    content
                }
                .padding(12)
            }
        }
        .frame(width: 300)
        .background(Theme.bgPanelColor)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .background: BackgroundTab(model: model)
        default: Text("Coming in M4/M5")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondaryColor)
        }
    }
}
