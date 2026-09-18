import SwiftUI
import RecorderCore

/// SPEC §6.6 "Clip selected" / §7.2 "Speed": replaces the tabs in `InspectorView` while a clip is
/// selected. Speed edits go through `Project.setSpeed` (`TimelineOps.swift`, clamps to 0.25...16
/// and re-checks invariants); Remove through `Project.removeClip`.
struct ClipPanel: View {
    let model: EditorModel
    let clipIndex: Int

    private static let presets: [Double] = [0.5, 1, 1.5, 2, 4, 8]

    private var clip: Clip? { model.project.clips[safeIndex: clipIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSelectionHeader(title: "Clip") { deselect() }

            if let clip {
                presetPicker(current: clip.speed)

                LabeledSlider(title: "Custom", value: speedBinding, range: 0.25...16, defaultValue: 1,
                              format: { String(format: "%.2f×", $0) }, onEditingChanged: gesture("Speed"))

                HStack {
                    Text("Duration")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondaryColor)
                    Spacer()
                    Text("\(timecode(clip.sourceEnd - clip.sourceStart)) → \(timecode(clip.outputDuration))")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.textPrimaryColor)
                }

                Button("Remove clip", role: .destructive, action: removeClip)
                    .disabled(model.project.clips.count <= 1)
            }
        }
    }

    private func presetPicker(current: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.presets, id: \.self) { preset in
                Button(formatSpeed(preset) + "×") {
                    model.edit("Speed") { $0.setSpeed(clipIndex, preset) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(current == preset ? Theme.accentColor : Theme.bgControlColor)
                .foregroundStyle(current == preset ? Color.white : Theme.textSecondaryColor)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - Bindings

    private var speedBinding: Binding<Double> {
        Binding(
            get: { clip?.speed ?? 1 },
            set: { newValue in model.update { $0.setSpeed(clipIndex, newValue) } })
    }

    private func gesture(_ name: String) -> (Bool) -> Void {
        { editing in editing ? model.beginGesture() : model.commitGesture(name) }
    }

    private func removeClip() {
        model.edit("Remove clip") { _ = $0.removeClip(clipIndex) }
        deselect()
    }

    private func deselect() {
        model.selectedClip = nil
    }

    private func formatSpeed(_ speed: Double) -> String {
        speed.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", speed) : String(format: "%.1f", speed)
    }

    private func timecode(_ t: Double) -> String {
        let centi = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centi / 6000, (centi / 100) % 60, centi % 100)
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
