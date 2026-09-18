import SwiftUI
import RecorderCore

/// SPEC §6.6 "Layout selected": replaces the tabs in `InspectorView` while a layout block is
/// selected. Kind picker (Camera fullscreen / Camera hidden) + Remove — same shape/pattern as
/// `ZoomPanel` (plain field writes through `model.edit`, `Project.removeBlock` for Remove).
struct LayoutPanel: View {
    let model: EditorModel
    let layoutID: UUID

    private var index: Int? { model.project.layouts.firstIndex { $0.id == layoutID.uuidString } }
    private var layout: RecorderCore.Layout? { index.map { model.project.layouts[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Layout") { deselect() }

            if let layout {
                VStack(alignment: .leading, spacing: 6) {
                    kindRow("Camera fullscreen", .cameraFull, current: layout.kind)
                    kindRow("Camera hidden", .hidden, current: layout.kind)
                }

                Button("Remove", role: .destructive, action: remove)
            }
        }
    }

    private func kindRow(_ title: String, _ kind: RecorderCore.Layout.Kind, current: RecorderCore.Layout.Kind) -> some View {
        Button { setKind(kind) } label: {
            HStack(spacing: 8) {
                Image(systemName: current == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(current == kind ? Theme.accentColor : Theme.textSecondaryColor)
                Text(title).foregroundStyle(Theme.textPrimaryColor)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    // MARK: - Actions

    private func setKind(_ kind: RecorderCore.Layout.Kind) {
        edit { $0.kind = kind }
    }

    private func remove() {
        model.edit("Remove layout") { $0.removeBlock(layoutID) }
        deselect()
    }

    private func edit(_ change: @escaping (inout RecorderCore.Layout) -> Void) {
        model.edit("Layout") { project in
            guard let i = project.layouts.firstIndex(where: { $0.id == layoutID.uuidString }) else { return }
            change(&project.layouts[i])
        }
    }

    private func deselect() {
        model.selection = []
    }
}
