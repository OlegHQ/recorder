import AppKit
import Darwin
import Foundation
import RecorderCore

/// T-610 "State snapshot dump" (SPEC §8): "here's the problem, here's the state" for an AI coding
/// assistant debugging Recorder from a pasted folder path — a self-contained, plain-text folder under
/// `~/Library/Logs/Recorder/Snapshots/<timestamp>/`, whose path lands on the clipboard.
///
/// Privacy (CLAUDE.md's rule, never relaxed here): no raw input events, no typed text, and no screen
/// contents other than Recorder's OWN windows are ever written — see `README.txt`'s own copy of this
/// rule for whoever receives the folder. `directory`/`pasteboard`/`playSound` are injectable so the
/// `snapshot` selftest never touches the user's real Logs folder or clipboard.
@MainActor
enum StateSnapshot {
    // `nonisolated`: touches only `FileManager`, not `@MainActor` state — needed so it can be used as
    // a default-parameter expression on `dump` below (default-argument expressions aren't themselves
    // actor-isolated to the function they default into).
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Recorder/Snapshots", isDirectory: true)
    }

    @discardableResult
    static func dump(to directory: URL = StateSnapshot.defaultDirectory, pasteboard: NSPasteboard = .general,
                      playSound: Bool = true) -> URL? {
        guard let folder = try? makeFolder(in: directory) else { return nil }

        writeSnapshotJSON(to: folder)
        for (i, controller) in EditorWindowController.allOpen.enumerated() {
            try? controller.model.project.save(to: folder.appendingPathComponent("editor-\(i)-project.json"))
            writeEventsSummary(controller.model.events, index: i, to: folder)
        }
        writeWindowPNGs(to: folder)
        writeREADME(to: folder)

        prune(directory: directory)

        pasteboard.clearContents()
        pasteboard.setString(folder.path, forType: .string)
        if playSound { NSSound(named: "Glass")?.play() }
        // Best-effort, transient confirmation (SPEC §8) — `nil` under `--selftest` (no `AppDelegate`
        // instance exists there) and harmless to skip.
        (NSApp.delegate as? AppDelegate)?.flashStatusItem("Snapshot copied")

        return folder
    }

    // MARK: - Folder

    private static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Disambiguates with " (2)", " (3)", … in the unlikely event two dumps land in the same second.
    private static func makeFolder(in directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = folderNameFormatter.string(from: Date())
        var name = base
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) (\(n))"
            n += 1
        }
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Keeps only the newest 20 snapshot folders (SPEC §8 housekeeping).
    private static func prune(directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        else { return }
        let folders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let sorted = folders.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        for old in sorted.dropFirst(20) { try? fm.removeItem(at: old) }
    }

    private static func writeJSON(_ object: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - snapshot.json

    private static func writeSnapshotJSON(to folder: URL) {
        let dict: [String: Any] = [
            "app": appInfo(),
            "permissions": ["screen": Permissions.screen, "accessibility": Permissions.accessibility,
                             "camera": Permissions.camera, "mic": Permissions.mic],
            "recording": recordingInfo(),
            "recordingSettings": recordingSettingsInfo(),
            "hotkeys": hotkeysInfo(),
            "memory": memoryInfo(),
            "windows": windowsInfo(),
            "editors": editorsInfo(),
        ]
        writeJSON(dict, to: folder.appendingPathComponent("snapshot.json"))
    }

    /// App version/build (from `Info.plist`, "unknown" when running outside a real `.app` bundle, e.g.
    /// `--selftest`), macOS version, wall-clock timestamp, and this process's own uptime. The git
    /// commit isn't baked in at build time anywhere in this project (no such Makefile step exists) —
    /// per this task's own instruction, omitted rather than added just for this.
    private static func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "uptimeSeconds": processUptimeSeconds(),
        ]
    }

    private static func recordingInfo() -> [String: Any] {
        let rc = RecordingController.shared
        var dict: [String: Any] = ["state": String(describing: rc.state), "elapsedSeconds": rc.elapsed]
        dict["target"] = rc.currentTargetDescription ?? "none"
        return dict
    }

    private static func recordingSettingsInfo() -> [String: Any] {
        let s = RecordingSettings.shared
        return [
            "mode": s.mode.rawValue,
            "cameraID": s.cameraID ?? "none",
            "micID": s.micID ?? "none",
            "systemAudio": systemAudioDescription(s.systemAudio),
            "denoise": s.denoise,
            "disableAGC": s.disableAGC,
            "hideDesktopIcons": s.hideDesktopIcons,
            "hideDockIcon": s.hideDockIcon,
            "highlightArea": s.highlightArea,
            "countdown": s.countdown,
            "fps": s.fps,
            "projectsFolder": s.projectsFolder.path,
        ]
    }

    private static func systemAudioDescription(_ s: RecordingSettings.SystemAudio) -> Any {
        switch s {
        case .off: return "off"
        case .all: return "all"
        case .apps(let ids): return ["apps": ids]
        }
    }

    private static func hotkeysInfo() -> [[String: Any]] {
        Hotkeys.table.map { hotkey in
            let b = Hotkeys.currentBinding(for: hotkey)
            return [
                "title": hotkey.title,
                "keyCode": Int(b.keyCode),
                "modifiers": Int(b.modifiers),
                "character": b.character,
                "alwaysActive": hotkey.alwaysActive,
            ]
        }
    }

    private static func memoryInfo() -> [String: Any] {
        ["physFootprintBytes": Int(physFootprintBytes()), "threadCount": threadCount()]
    }

    private static func windowsInfo() -> [[String: Any]] {
        NSApp.windows.map { window in
            [
                "class": String(describing: type(of: window)),
                "title": window.title,
                "frame": ["x": Double(window.frame.origin.x), "y": Double(window.frame.origin.y),
                          "width": Double(window.frame.width), "height": Double(window.frame.height)],
                "isVisible": window.isVisible,
                "isKeyWindow": window.isKeyWindow,
                "level": window.level.rawValue,
                "isOccluded": !window.occlusionState.contains(.visible),
                "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
            ]
        }
    }

    /// `selectedClip: -1` means "no clip selected" (a valid clip index is always >= 0);
    /// `preview.hoverTime: -1` means "not hovering" (SPEC §7.2's split-mode hover, AC-TL-7).
    private static func editorsInfo() -> [[String: Any]] {
        EditorWindowController.allOpen.enumerated().map { i, controller in
            let model = controller.model
            return [
                "index": i,
                "package": model.packageURL.path,
                "playhead": model.playhead,
                "isPlaying": model.isPlaying,
                "selection": model.selection.map(\.uuidString).sorted(),
                "selectedClip": model.selectedClip ?? -1,
                "undoStepNames": model.undoStepNames,
                "redoStepNames": model.redoStepNames,
                "timeMapOutputDuration": model.timeMap.outputDuration,
                "invariants": model.project.checkInvariants() ?? "ok",
                "preview": previewInfo(controller.previewView),
                "timeline": timelineInfo(controller.coreTimelineView),
                "inspectorPanel": inspectorPanelDescription(controller),
                "previewShowsResult": model.previewShowsResult,
                "exportSheet": controller.window?.attachedSheet != nil ? "open" : "closed",
            ]
        }
    }

    private static func previewInfo(_ preview: PreviewView) -> [String: Any] {
        [
            "playerItemStatus": preview.debugPlayerStatus,
            "rate": Double(preview.debugRate),
            "currentTime": preview.debugCurrentTime,
            "hoverTime": preview.hoverTime ?? -1,
            "hasScreenPixelBuffer": preview.debugHasScreenPixelBuffer,
            "pendingFrameRetries": preview.debugPendingFrameRetries,
            "isSeeking": preview.debugIsSeeking,
        ]
    }

    private static func timelineInfo(_ timeline: TimelineView) -> [String: Any] {
        [
            "pixelsPerSecond": timeline.geometry.pxPerSecond,
            "scrollOffset": timeline.geometry.scrollX,
            "splitMode": timeline.debugSplitMode,
            "activeDragKind": timeline.debugDragKind ?? "none",
        ]
    }

    /// Mirrors `InspectorView`'s own "selection ⇒ its panel replaces the tabs" rule (SPEC §6.6,
    /// AC-INS-3) directly off `model` — always accurate, unlike `currentInspectorTab` (see its own
    /// doc comment in `EditorWindowController`).
    private static func inspectorPanelDescription(_ controller: EditorWindowController) -> String {
        let model = controller.model
        if model.inspectorShowsProject { return "\(model.inspectorTab.title) · whole project" }
        let count = model.selectedClips.count + model.selection.count
        if count > 1 { return "\(count) selected items" }
        if let i = model.selectedClip, model.project.clips.indices.contains(i) { return "Clip panel (clip \(i))" }
        if model.selection.count == 1, let id = model.selection.first {
            let key = id.uuidString
            if model.project.cameraClips.contains(where: { $0.id == key }) { return "Camera footage panel" }
            if model.project.keystrokeClips.contains(where: { $0.id == key }) { return "Keystroke clip panel" }
            if model.project.zooms.contains(where: { $0.id == key }) { return "Zoom panel" }
            if model.project.layouts.contains(where: { $0.id == key }) { return "Layout panel" }
            if model.project.masks.contains(where: { $0.id == key }) { return "Mask panel" }
        }
        return "\(controller.currentInspectorTab.title) tab"
    }

    // MARK: - editor-<n>-events-summary.json

    /// Counts per `InputEvent.Kind` + first/last timestamps — NEVER the raw events (CLAUDE.md's
    /// privacy rule: typed text is never logged, and this goes further by logging no event content
    /// at all, only kind counts and timing).
    private static func writeEventsSummary(_ events: EventLog, index: Int, to folder: URL) {
        var counts: [String: Int] = [:]
        for e in events.events { counts[e.k.rawValue, default: 0] += 1 }
        let timestamps = events.events.map(\.t)
        var dict: [String: Any] = ["totalCount": events.events.count, "countsByKind": counts]
        if let first = timestamps.min() { dict["firstTimestamp"] = first }
        if let last = timestamps.max() { dict["lastTimestamp"] = last }
        writeJSON(dict, to: folder.appendingPathComponent("editor-\(index)-events-summary.json"))
    }

    // MARK: - window-<n>-<class>.png

    /// Recorder's OWN visible windows only — never other apps, never the whole screen.
    // ponytail: `CGWindowListCreateImage` (own-window capture needing no Screen Recording permission)
    // is compile-time `unavailable` on this SDK ("Please use ScreenCaptureKit instead."), so this uses
    // `cacheDisplay` for every window instead of trying that path first. Upgrade path: if a future SDK
    // restores it (or `SCScreenshotManager` grows an own-window-only mode that doesn't need the
    // Screen Recording TCC prompt), prefer that over `cacheDisplay` — the MTKView-backed preview can
    // render blank in a `cacheDisplay` capture.
    private static func writeWindowPNGs(to folder: URL) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let contentView = window.contentView,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let className = String(describing: type(of: window))
            try? data.write(to: folder.appendingPathComponent("window-\(i)-\(className).png"))
        }
    }

    // MARK: - README.txt

    private static func writeREADME(to folder: URL) {
        let text = """
        Recorder state snapshot — for whoever is debugging this from a pasted folder path.

        snapshot.json                    App/OS/permission/recording/settings/hotkey/memory state,
                                          every window, and one entry per open editor (playhead,
                                          selection, undo/redo names, preview/timeline internals,
                                          invariants). Start here.
        editor-<n>-project.json          The CURRENT in-memory Project of open editor <n> (same
                                          encoder Project.save uses) — includes unsaved edits, unlike
                                          the package's own on-disk project.json.
        editor-<n>-events-summary.json   Counts of recorded input events per kind + first/last
                                          timestamps for editor <n>. Never the raw events.
        window-<n>-<class>.png           A screenshot of one of Recorder's OWN visible windows.

        Privacy: no raw mouse/keyboard events, no typed text, and no screen contents other than
        Recorder's own windows are ever captured here. Only Recorder's own on-screen pixels, its own
        settings, and counts/timestamps of event KINDS (never content) are written.

        Retention: only the newest 20 snapshot folders under this directory are kept.
        """
        try? text.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Process stats (Darwin/Mach — no third-party dependency)

    private static func processUptimeSeconds() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startSeconds
    }

    private static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &count) == KERN_SUCCESS, let threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        return Int(count)
    }
}
