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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                sourceHeading("Microphone", available: hasMic)
                if hasMic {
                    volumeRow(title: "Volume", volume: \.audio.micVolume, muted: micMutedBinding,
                              gestureName: "Microphone volume", source: "microphone")
                    Toggle("Reduce rumble & normalize", isOn: denoiseBinding)
                    Text("Cleanup is applied on export. Preview plays the original microphone audio.")
                        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .modifier(InspectorReveal(identity: "microphone", order: 0))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sourceHeading("System audio", available: hasSystemAudio)
                if hasSystemAudio {
                    volumeRow(title: "Volume", volume: \.audio.systemVolume, muted: systemMutedBinding,
                              gestureName: "System volume", source: "system audio")
                }
            }
            .modifier(InspectorReveal(identity: "system-audio", order: 2))
            Divider()
            Toggle("Mouse click sound", isOn: clickSoundBinding)
                .foregroundStyle(Theme.textPrimaryColor)
        }
    }

    private func sourceHeading(_ title: String, available: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Font(Theme.headingFont(22)))
            Spacer(minLength: 4)
            if !available {
                Text("Not recorded").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            }
        }
    }

    private func volumeRow(title: String, volume: WritableKeyPath<Project, Double>, muted: Binding<Bool>,
                            gestureName: String, source: String) -> some View {
        HStack(spacing: 8) {
            LabeledSlider(title: title, value: fieldBinding(volume), range: 0...1, defaultValue: 1,
                          onEditingChanged: gesture(gestureName))
            Button {
                muted.wrappedValue.toggle()
            } label: {
                Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted.wrappedValue ? Theme.dangerColor : Theme.textSecondaryColor)
            }
            .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
            .help(muted.wrappedValue ? "Unmute \(source)" : "Mute \(source)")
            .accessibilityLabel(muted.wrappedValue ? "Unmute \(source)" : "Mute \(source)")
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
        Binding(get: { project.audio.denoise }, set: { newValue in model.edit("Microphone cleanup") { $0.audio.denoise = newValue } })
    }

    private var clickSoundBinding: Binding<Bool> {
        Binding(get: { project.cursor.clickSound },
                set: { newValue in model.edit("Mouse click sound") { $0.cursor.clickSound = newValue } })
    }
}
