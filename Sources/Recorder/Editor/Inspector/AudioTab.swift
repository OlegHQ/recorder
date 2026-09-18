import SwiftUI
import RecorderCore

/// SPEC §6.6 Audio tab: Microphone/System volume + mute, "Reduce noise & normalise" (`denoise`),
/// "Mouse click sound". A row for a track the recording doesn't have (`source.hasMic` /
/// `hasSystemAudio` == false) is disabled (T-504 UI half). "Mouse click sound" is a `CursorStyle`
/// field (`cursor.clickSound`) even though the mockup puts the row on this tab.
struct AudioTab: View {
    let model: EditorModel

    private var project: Project { model.project }
    private var hasMic: Bool { project.source.hasMic }
    private var hasSystemAudio: Bool { project.source.hasSystemAudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            volumeRow(title: "Microphone", volume: \.audio.micVolume, muted: micMutedBinding,
                      gestureName: "Microphone volume")
                .disabled(!hasMic)

            volumeRow(title: "System", volume: \.audio.systemVolume, muted: systemMutedBinding,
                      gestureName: "System volume")
                .disabled(!hasSystemAudio)

            Toggle("Reduce noise & normalise", isOn: denoiseBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)
                .disabled(!hasMic)

            Toggle("Mouse click sound", isOn: clickSoundBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimaryColor)
        }
    }

    private func volumeRow(title: String, volume: WritableKeyPath<Project, Double>, muted: Binding<Bool>,
                            gestureName: String) -> some View {
        HStack(spacing: 8) {
            LabeledSlider(title: title, value: fieldBinding(volume), range: 0...1, defaultValue: 1,
                          onEditingChanged: gesture(gestureName))
            Button {
                muted.wrappedValue.toggle()
            } label: {
                Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted.wrappedValue ? Theme.dangerColor : Theme.textSecondaryColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bindings

    private func fieldBinding(_ keyPath: WritableKeyPath<Project, Double>) -> Binding<Double> {
        Binding(get: { model.project[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private var micMutedBinding: Binding<Bool> {
        Binding(get: { project.audio.micMuted }, set: { newValue in model.edit("Mute microphone") { $0.audio.micMuted = newValue } })
    }

    private var systemMutedBinding: Binding<Bool> {
        Binding(get: { project.audio.systemMuted }, set: { newValue in model.edit("Mute system audio") { $0.audio.systemMuted = newValue } })
    }

    private var denoiseBinding: Binding<Bool> {
        Binding(get: { project.audio.denoise }, set: { newValue in model.edit("Reduce noise & normalise") { $0.audio.denoise = newValue } })
    }

    private var clickSoundBinding: Binding<Bool> {
        Binding(get: { project.cursor.clickSound },
                set: { newValue in model.edit("Mouse click sound") { $0.cursor.clickSound = newValue } })
    }
}
