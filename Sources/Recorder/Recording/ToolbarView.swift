import SwiftUI
import AVFoundation

/// Capture choice, input review, then target selection. Commands stay in ToolbarController.
struct ToolbarView: View {
    var settings = RecordingSettings.shared
    var onClose: () -> Void
    var onSelectMode: (RecordingSettings.Mode) -> Void
    var onCamera: () -> Void
    var onMicrophone: () -> Void
    var onSystemAudio: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Record").font(Font(Theme.headingFont(26)))
                modeButtons
                closeButton
            }
            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            inputButtons
            HStack {
                Text("Choose a target on screen, then Start.")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                Spacer(minLength: 8)
                settingsButton
            }
        }
        .padding(16)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .signalWindow()
        .overlay { TechCornerMarks().padding(1) }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .frame(width: 16, height: 32)
        }
        .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
        .help("Close recording setup")
        .accessibilityLabel("Close recording setup")
    }

    private var modeButtons: some View {
        HStack(spacing: 2) {
            modeButton(.display, symbol: "display", title: "Display")
            modeButton(.window, symbol: "macwindow", title: "Window")
            modeButton(.area, symbol: "rectangle.dashed", title: "Area")
        }
        .padding(2)
        .background(Theme.bgControlColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture source")
    }

    private func modeButton(_ mode: RecordingSettings.Mode, symbol: String, title: String) -> some View {
        let selected = settings.mode == mode
        return Button { onSelectMode(mode) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(TechButtonStyle(kind: selected ? .primary : .quiet, compact: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Choose a \(title.lowercased()) to record")
    }

    private var inputButtons: some View {
        HStack(spacing: 8) {
            inputButton(label: "Camera", title: cameraTitle, on: settings.cameraID != nil,
                        onIcon: "video.fill", offIcon: "video.slash", action: onCamera)
            inputButton(label: "Microphone", title: micTitle, on: settings.micID != nil,
                        onIcon: "mic.fill", offIcon: "mic.slash", action: onMicrophone)
            inputButton(label: "System audio", title: systemAudioTitle, on: !isSystemAudioOff,
                        onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash", action: onSystemAudio)
        }
    }

    private func inputButton(label: String, title: String, on: Bool, onIcon: String, offIcon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: on ? onIcon : offIcon)
                        .frame(width: 14)
                    Text(label)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Theme.textSecondaryColor)
                Text(title)
                    .font(Font(Theme.labelFont))
                    .foregroundStyle(on ? Theme.textPrimaryColor : Theme.textSecondaryColor)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Font(Theme.captionFont))
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
        .background(Theme.bgControlColor)
        .accessibilityLabel(label)
        .accessibilityValue(title)
        .accessibilityHint("Opens recording input choices")
        .help("\(label): \(title)")
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            HStack(spacing: 6) {
                Text("Options")
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .frame(height: 28)
        }
        .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
        .help("Countdown and recording options")
    }

    private var cameraTitle: String {
        guard let id = settings.cameraID else { return "Off" }
        guard let device = AVCaptureDevice(uniqueID: id) else { return "Unavailable" }
        return device.localizedName
    }

    private var micTitle: String {
        guard let id = settings.micID else { return "Off" }
        guard let device = AVCaptureDevice(uniqueID: id) else { return "Unavailable" }
        return device.localizedName
    }

    private var isSystemAudioOff: Bool {
        if case .off = settings.systemAudio { return true }
        return false
    }

    private var systemAudioTitle: String {
        switch settings.systemAudio {
        case .off: return "Off"
        case .all: return "All apps"
        case .apps(let ids): return ids.isEmpty ? "Off" : "\(ids.count) app\(ids.count == 1 ? "" : "s")"
        }
    }
}
