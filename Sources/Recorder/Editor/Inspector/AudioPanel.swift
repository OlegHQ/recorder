import SwiftUI
import RecorderCore

struct AudioPanel: View {
    let model: EditorModel
    let audioID: UUID

    var clip: AudioClip? { model.project.audioClips.first { $0.id == audioID.uuidString } }
    private var duration: Double {
        guard let clip else { return 0 }
        let segments = model.project.audioSegments(clip)
        return (segments.last?.output.end ?? 0) - (segments.first?.output.start ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Audio clip") { model.selection = [] }
            if let clip {
                Text(model.project.audioTracks[clip.track].name).font(Font(Theme.headingFont(22)))
                Text(URL(fileURLWithPath: clip.file).lastPathComponent)
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                let words = model.transcriptWords(in: clip)
                if !words.isEmpty {
                    Text("Transcript").font(Font(Theme.headingFont(22)))
                    Text(words.map(\.text).joined(separator: " ")).font(Font(Theme.captionFont))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("Linked to").font(Font(Theme.headingFont(22)))
                TechSegmentedControl(selection: Binding(get: { clip.link?.rawValue ?? "none" }, set: { value in
                    changeLink(AudioClip.Link(rawValue: value))
                }), options: linkOptions)
                if let offset = model.project.syncOffset(clip) {
                    HStack {
                        Text(abs(offset) < 1 / 60.0 ? "In sync" : String(format: "%+.2f s out of sync", offset))
                            .font(Font(Theme.captionFont)).foregroundStyle(abs(offset) < 1 / 60.0 ? Theme.textSecondaryColor : Theme.dangerColor)
                        Spacer(minLength: 0)
                    }
                    Button("Move into Sync", action: moveIntoSync)
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                        .disabled(abs(offset) < 1e-9)
                }
                Divider()
                LabeledSlider(title: "Gain", value: gainBinding, range: -60...20 * log10(2), defaultValue: 0,
                              format: { String(format: "%+.1f dB", $0) }, onEditingChanged: gesture("Audio Gain"))
                Toggle("Mute clip", isOn: Binding(get: { clip.gain == 0 }, set: { muted in
                    model.edit("Mute Audio") { project in
                        if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) { project.audioClips[index].gain = muted ? 0 : 1 }
                    }
                }))
                ForEach([true, false], id: \.self) { incoming in
                    LabeledSlider(title: incoming ? "Fade in" : "Fade out", value: fadeBinding(incoming: incoming),
                                  range: 0...max(0.1, duration), defaultValue: 0,
                                  format: { $0 == 0 ? "Off" : String(format: "%.2f s", $0) },
                                  onEditingChanged: gesture("Audio Fade"))
                }
                Text(String(format: "Duration %.2f s", duration)).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Button("Remove audio", role: .destructive) {
                    model.edit("Remove Audio") { $0.removeBlock(audioID) }
                    model.selection = []
                }.buttonStyle(TechButtonStyle(kind: .danger, compact: true))
            }
        }
    }

    private var linkOptions: [(String, String)] {
        var options = [("none", "None"), ("screen", "Screen")]
        if model.project.source.hasCamera { options.append(("camera", "Camera")) }
        if let clip, model.project.layers.contains(where: { $0.kind == .video && $0.file == clip.file }) { options.append(("layer", "Its video")) }
        return options
    }

    func changeLink(_ link: AudioClip.Link?) {
        model.edit(link == nil ? "Unlink Audio" : "Link Audio") { project in
            if let link { _ = project.linkAudio(audioID, to: link) }
            else { _ = project.unlinkAudio(audioID) }
        }
    }

    func moveIntoSync() { model.edit("Move into Sync") { $0.moveIntoSync(audioID) } }

    var gainBinding: Binding<Double> {
        Binding(get: { 20 * log10(max(0.001, clip?.gain ?? 1)) }, set: { value in
            guard value.isFinite else { return }
            model.update { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) {
                    project.audioClips[index].gain = min(2, max(0, pow(10, value / 20)))
                }
            }
        })
    }

    func fadeBinding(incoming: Bool) -> Binding<Double> {
        Binding(get: { (incoming ? clip?.fadeIn : clip?.fadeOut) ?? 0 }, set: { value in
            guard value.isFinite else { return }
            let seconds = min(duration, max(0, (value * 10).rounded() / 10))
            model.update { project in
                if let index = project.audioClips.firstIndex(where: { $0.id == audioID.uuidString }) {
                    if incoming { project.audioClips[index].fadeIn = seconds > 0 ? seconds : nil }
                    else { project.audioClips[index].fadeOut = seconds > 0 ? seconds : nil }
                }
            }
        })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }
}
