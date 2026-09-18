import SwiftUI
import RecorderCore

/// SPEC §6.6 Keys tab: "Show keyboard shortcuts" is the only control backed by a `Keys` field
/// (`show`) — the mockup's "Size ──●── Position ◱ ◲" row has no `Keys` field in `Project.swift`
/// (T-602 UI half; the overlay itself, its chip size/position, is core work not yet built), so
/// it's left out here rather than adding new Core fields.
struct KeysTab: View {
    let model: EditorModel

    private var keys: Keys { model.project.keys }

    var body: some View {
        Toggle("Show keyboard shortcuts", isOn: showBinding)
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimaryColor)
    }

    private var showBinding: Binding<Bool> {
        Binding(get: { keys.show }, set: { newValue in model.edit("Show keyboard shortcuts") { $0.keys.show = newValue } })
    }
}
