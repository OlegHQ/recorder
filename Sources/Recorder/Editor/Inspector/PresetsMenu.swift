import AppKit
import SwiftUI
import RecorderCore
import UniformTypeIdentifiers

/// T-605 (non-Core half), SPEC §1.1 "Presets (save/apply/export as JSON file)". `Preset` (the
/// styling-subset value + `apply`) lives in `RecorderCore/Preset.swift`; this is just where saved
/// presets live on disk. One JSON file per preset, named after it. `directory` is `var` so the
/// `presets` selftest can point it at a temp directory instead of Application Support.
enum PresetStore {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Recorder/Presets", isDirectory: true)
    }()

    static func list() -> [Preset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Overwrites any existing preset with the same name (SPEC gives presets no id, just a name).
    @discardableResult
    static func save(_ preset: Preset) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: preset.name)
        try JSONEncoder().encode(preset).write(to: url, options: .atomic)
        return url
    }

    static func delete(_ preset: Preset) throws {
        try FileManager.default.removeItem(at: fileURL(for: preset.name))
    }

    private static func fileURL(for name: String) -> URL {
        let safe = name.isEmpty ? "Untitled" : name.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safe).json")
    }
}

/// Compact "Presets ▾" menu at the top of the inspector tab bar (SPEC §6.6 doesn't pin an exact
/// spot for it). Applying a preset is one `model.edit` = one undo step, via Core `Preset.apply`.
struct PresetsMenu: View {
    let model: EditorModel
    @State private var presets: [Preset] = PresetStore.list()

    var body: some View {
        Menu {
            Button("Save Preset…", action: promptSave)
            if !presets.isEmpty {
                Divider()
                ForEach(presets, id: \.name) { preset in
                    Menu(preset.name) {
                        Button("Apply") { apply(preset) }
                        Button("Export…") { export(preset) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(preset) }
                    }
                }
            }
            Divider()
            Button("Import…", action: importPreset)
        } label: {
            HStack(spacing: 2) {
                Text("Presets").font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(Theme.textSecondaryColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func apply(_ preset: Preset) {
        model.edit("Apply Preset") { project in preset.apply(to: &project) }
    }

    private func delete(_ preset: Preset) {
        try? PresetStore.delete(preset)
        presets = PresetStore.list()
    }

    private func promptSave() {
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Saves the current background, frame, cursor, animation, and camera styling."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? PresetStore.save(Preset(name: name, from: model.project))
        presets = PresetStore.list()
    }

    private func export(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(preset.name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? JSONEncoder().encode(preset) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let preset = try? JSONDecoder().decode(Preset.self, from: data) else { return }
        try? PresetStore.save(preset)
        presets = PresetStore.list()
    }
}
