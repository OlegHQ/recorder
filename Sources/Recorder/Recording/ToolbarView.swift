import SwiftUI
import AVFoundation

/// SPEC §4.2 mockup: close · 3 mode buttons · 3 input buttons (open native `NSMenu`s, built by
/// `ToolbarController`) · gear. Hosted inside a `FloatingPanel` (HUD material already supplies the background).
struct ToolbarView: View {
    var settings = RecordingSettings.shared
    var onClose: () -> Void
    var onSelectMode: (RecordingSettings.Mode) -> Void
    var onCamera: () -> Void
    var onMicrophone: () -> Void
    var onSystemAudio: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            closeButton
            divider
            modeButtons
            divider
            inputButtons
            divider
            settingsButton
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .fixedSize()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.textSecondaryColor)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
    }

    private var modeButtons: some View {
        HStack(spacing: 4) {
            modeButton(.display, symbol: "display", title: "Display")
            modeButton(.window, symbol: "macwindow", title: "Window")
            modeButton(.area, symbol: "rectangle.dashed", title: "Area")
        }
        .padding(.horizontal, 12)
    }

    private func modeButton(_ mode: RecordingSettings.Mode, symbol: String, title: String) -> some View {
        let selected = settings.mode == mode
        return Button { onSelectMode(mode) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(Font(Theme.captionFont))
            }
            .foregroundStyle(selected ? Theme.textPrimaryColor : Theme.textSecondaryColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Theme.bgHoverColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
    }

    private var inputButtons: some View {
        HStack(spacing: 16) {
            inputButton(title: cameraTitle, on: settings.cameraID != nil,
                        onIcon: "video.fill", offIcon: "video.slash", action: onCamera)
            inputButton(title: micTitle, on: settings.micID != nil,
                        onIcon: "mic.fill", offIcon: "mic.slash", action: onMicrophone)
            inputButton(title: systemAudioTitle, on: !isSystemAudioOff,
                        onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash", action: onSystemAudio)
        }
        .padding(.horizontal, 12)
    }

    private func inputButton(title: String, on: Bool, onIcon: String, offIcon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? onIcon : offIcon)
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(on ? Theme.textPrimaryColor : Theme.textSecondaryColor)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 140, alignment: .leading)
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(Theme.textSecondaryColor)
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
    }

    private var divider: some View {
        Rectangle().fill(Theme.strokeColor).frame(width: 1, height: 28)
    }

    private var cameraTitle: String {
        guard let id = settings.cameraID, let device = AVCaptureDevice(uniqueID: id) else { return "No camera" }
        return device.localizedName
    }

    private var micTitle: String {
        guard let id = settings.micID, let device = AVCaptureDevice(uniqueID: id) else { return "No microphone" }
        return device.localizedName
    }

    private var isSystemAudioOff: Bool {
        if case .off = settings.systemAudio { return true }
        return false
    }

    private var systemAudioTitle: String {
        switch settings.systemAudio {
        case .off: return "No system audio"
        case .all: return "All apps"
        case .apps(let ids): return ids.isEmpty ? "No system audio" : "\(ids.count) app\(ids.count == 1 ? "" : "s")"
        }
    }
}
