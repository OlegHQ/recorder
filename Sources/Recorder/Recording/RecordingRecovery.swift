import AVFoundation
import Foundation
import RecorderCore

/// SPEC AC-REC-3: if the app is killed mid-recording, `screen.mov` is still playable
/// (`movieFragmentInterval = 10 s`, T-110) but `project.json` was never written (`RecordingController`
/// only writes it in `finish`). Called once at launch (`AppDelegate`): scan `folder` for any `.recorder`
/// package like that and synthesize a default `Project` from the asset's measured duration/size.
enum RecordingRecovery {
    static func recoverOrphans(in folder: URL) async {
        let fm = FileManager.default
        guard let packages = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for package in packages where package.pathExtension == "recorder" {
            let movURL = package.appendingPathComponent("screen.mov")
            let projectURL = package.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: movURL.path), !fm.fileExists(atPath: projectURL.path) else { continue }
            await recover(package: package, movURL: movURL, projectURL: projectURL)
        }
    }

    private static func recover(package: URL, movURL: URL, projectURL: URL) async {
        let fm = FileManager.default
        let asset = AVURLAsset(url: movURL)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return }

        var source = Source(pixelWidth: Int(size.width), pixelHeight: Int(size.height), duration: duration)
        source.hasCamera = fm.fileExists(atPath: package.appendingPathComponent("camera.mov").path)
        source.hasMic = fm.fileExists(atPath: package.appendingPathComponent("mic.m4a").path)
        source.hasSystemAudio = fm.fileExists(atPath: package.appendingPathComponent("system.m4a").path)

        let project = Project(title: package.deletingPathExtension().lastPathComponent, source: source,
                               clips: [Clip(sourceStart: 0, sourceEnd: duration)])
        try? project.save(to: projectURL)
    }
}
