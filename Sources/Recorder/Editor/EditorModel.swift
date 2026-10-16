import Dispatch
import Foundation
import Observation
import RecorderCore

/// One editor window's state (SPEC §2 "Undo", §5 "Autosave"). `project` is only ever mutated
/// through `edit`/`beginGesture…commitGesture`, so every completed change is exactly one undo step.
@MainActor @Observable final class EditorModel {
    let packageURL: URL
    private(set) var project: Project
    let events: EventLog
    var playhead: Double = 0            // OUTPUT seconds
    var isPlaying = false {
        didSet { if !isPlaying { previewPlaybackEnd = nil } }
    }
    private(set) var previewPlaybackEnd: Double?
    var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { inspectorShowsProject = false; previewShowsResult = false; stopEffectPreview() } }
    }
    var inspectorTab: InspectorView.Tab = .background
    var previewShowsResult = false
    var inspectorShowsProject = false

    func showProjectInspector(_ tab: InspectorView.Tab) {
        inspectorTab = tab
        inspectorShowsProject = true
    }
    /// Create from any editor entry point and open the new interval for editing.
    @discardableResult
    func addZoom(atSource time: Double, length: Double = 3) -> UUID? {
        let mode: Zoom.Mode = events.clicks().contains { abs($0.t - time) <= 1 } ? .auto : .manual
        var updated = project
        guard let id = updated.addZoom(atSource: time, length: length, mode: mode) else { return nil }
        edit("Add Zoom") { $0 = updated }
        isPlaying = false
        selectedClips = []
        selection = [id]
        inspectorShowsProject = false
        return id
    }

    /// Adds a Title text block (Text lane, `T`, inspector footer) and selects it; one undo step.
    @discardableResult
    func addText(atSource time: Double, length: Double = 3) -> UUID? {
        var id: UUID?
        edit("Add Text") { id = $0.addText(atSource: time, length: length) }
        if let id { isPlaying = false; selectedClips = []; selection = [id]; inspectorShowsProject = false }
        return id
    }

    /// SPEC §7.3 ↑/↓: the nearest edit point (clip boundary or block edge, output time) before/after `t`.
    func editPoint(from t: Double, forward: Bool) -> Double? {
        var points: [Double] = [0]
        var end = 0.0
        for clip in project.clips { end += clip.outputDuration; points.append(end) }
        let edges = project.zooms.map { ($0.start, $0.end) } + project.layouts.map { ($0.start, $0.end) }
            + project.masks.map { ($0.start, $0.end) } + project.keystrokeClips.map { ($0.start, $0.end) }
            + project.cameraClips.map { ($0.start, $0.end) } + project.texts.map { ($0.start, $0.end) }
        for (a, b) in edges { points += [a, b].compactMap { timeMap.outputTime(atSource: $0) } }
        return forward ? points.filter { $0 > t + 1e-4 }.min() : points.filter { $0 < t - 1e-4 }.max()
    }

    /// Find a retained point inside an effect interval, accounting for cuts and clip speed.
    func previewTime(start: Double, end: Double) -> Double? {
        for clip in project.clips {
            let lower = max(start, clip.sourceStart), upper = min(end, clip.sourceEnd)
            if upper > lower { return timeMap.outputTime(atSource: (lower + upper) / 2) }
        }
        return nil
    }

    /// Replay the retained effect interval with context on both sides, using output time.
    func replayEffect(start: Double, end: Double) {
        var output = 0.0
        var first: Double?
        var last: Double?
        for clip in project.clips {
            let lower = max(start, clip.sourceStart), upper = min(end, clip.sourceEnd)
            if upper > lower {
                if first == nil { first = output + (lower - clip.sourceStart) / clip.timeScale }
                last = output + (upper - clip.sourceStart) / clip.timeScale
            }
            output += clip.outputDuration
        }
        guard let first, let last else { return }
        isPlaying = false
        previewShowsResult = true
        playhead = max(0, first - 0.6)
        previewPlaybackEnd = min(timeMap.outputDuration, last + 1.5)
        isPlaying = true
    }

    func stopEffectPreview() {
        if previewPlaybackEnd != nil { isPlaying = false }
    }

    func advancePlayback(to time: Double) {
        if let end = previewPlaybackEnd, time >= end {
            playhead = end
            isPlaying = false
        } else { playhead = time }
    }

    var cameraInspectorRequested = false
    var selectedClips: Set<Int> = [] {
        didSet { if selectedClips != oldValue { inspectorShowsProject = false; previewShowsResult = false; stopEffectPreview() } }
    }
    var selectedClip: Int? {
        get { selectedClips.min() }
        set { selectedClips = newValue.map { [$0] } ?? [] }
    }
    var timeMap: TimeMap { TimeMap(project.clips) }

    /// 240 Hz lookup tables for the render pipeline (SPEC §6.2, §6.3, §6.5) — simulated once here,
    /// not per frame, so scrubbing/export sampling (`CameraPath`/`CursorPath.sample`) is O(1)
    /// (T-413). Rebuilt only when a change could actually move them (see `rebuildPathsIfNeeded`).
    /// `// ponytail: full re-simulation on every such edit, not incremental — SPEC §6.3's own
    /// ponytail note (~2 ms for a 10 min recording); revisit only if profiling says so.`
    private(set) var cursorPath: CursorPath
    private(set) var cameraPath: CameraPath

    // ponytail: whole-struct snapshots; Project is a few KB.
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    // Parallel to undo/redoStack: the `edit`/`commitGesture` name that produced each snapshot, so a
    // menu can show "Undo Split" cheaply (T-311) without changing the snapshot-stack design.
    private var undoNames: [String] = []
    private var redoNames: [String] = []
    private let undoCap = 200

    /// For selftests (AC-TL-6: "every gesture is exactly one undo step"): how many completed
    /// edits/gestures are currently undoable.
    var undoStepCount: Int { undoStack.count }

    private var gestureSnapshot: Project?
    private var autosaveWork: DispatchWorkItem?
    private(set) var saveStatus = "Saved"
    private(set) var saveError: String?

    /// The name of the edit `undo()`/`redo()` would apply next, or `nil` if there is none.
    var undoName: String? { undoNames.last }
    var redoName: String? { redoNames.last }

    /// T-610: the full undo/redo NAME stacks (not the `Project` snapshots themselves), for the state
    /// snapshot dump — oldest first, same order as `undoStack`/`redoStack`.
    var undoStepNames: [String] { undoNames }
    var redoStepNames: [String] { redoNames }

    init(packageURL: URL, project: Project, events: EventLog, paths: (CursorPath, CameraPath)? = nil) {
        self.packageURL = packageURL
        self.project = project
        self.events = events
        (cursorPath, cameraPath) = paths ?? Self.buildPaths(project: project, events: events)
    }

    /// The ONLY way to mutate `project` outside a gesture. One call = one undo step.
    func edit(_ name: String, _ change: (inout Project) -> Void) {
        push(project, name: name)
        let before = project
        change(&project)
        rebuildPathsIfNeeded(from: before)
        redoStack.removeAll()
        redoNames.removeAll()
        scheduleAutosave()
    }

    /// For drags: begin → many `update` → commit | cancel. One undo step total. Paths rebuild once,
    /// at `commitGesture` — not per `update` call, which a drag can call dozens of times a second.
    func beginGesture() {
        autosaveWork?.cancel()
        autosaveWork = nil
        gestureSnapshot = project
    }

    func update(_ change: (inout Project) -> Void) {
        change(&project)
    }

    func commitGesture(_ name: String) {
        guard let snapshot = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard snapshot != project else { return }
        push(snapshot, name: name)
        redoStack.removeAll()
        redoNames.removeAll()
        rebuildPathsIfNeeded(from: snapshot)
        scheduleAutosave()
    }

    func cancelGesture() {
        guard let snapshot = gestureSnapshot else { return }
        project = snapshot
        gestureSnapshot = nil
        scheduleAutosave()
    }

    func undo() {
        guard let previous = undoStack.popLast(), let name = undoNames.popLast() else { return }
        redoStack.append(project)
        redoNames.append(name)
        let before = project
        project = previous
        keepExistingSelection()
        rebuildPathsIfNeeded(from: before)
        scheduleAutosave()
    }

    func redo() {
        guard let next = redoStack.popLast(), let name = redoNames.popLast() else { return }
        undoStack.append(project)
        undoNames.append(name)
        let before = project
        project = next
        keepExistingSelection()
        rebuildPathsIfNeeded(from: before)
        scheduleAutosave()
    }

    /// SPEC §7.2: selection survives undo/redo when the ids still exist. An open gesture can't outlive a
    /// snapshot swap. // ponytail: clips have no ids, so selected clip *indices* are kept if still in range.
    private func keepExistingSelection() {
        gestureSnapshot = nil
        let ids = Set(project.zooms.map(\.id) + project.layouts.map(\.id) + project.masks.map(\.id)
                      + project.keystrokeClips.map(\.id) + project.cameraClips.map(\.id)
                      + project.audioClips.map(\.id) + project.texts.map(\.id) + project.windowShots.map(\.id))
        selection = selection.filter { ids.contains($0.uuidString) }
        selectedClips = selectedClips.filter { project.clips.indices.contains($0) }
    }

    func saveNow() {
        autosaveWork?.cancel()
        autosaveWork = nil
        do {
            try project.save(to: packageURL.appendingPathComponent("project.json"))
            saveStatus = "Saved"
            saveError = nil
        } catch {
            saveStatus = "Save failed · Retry"
            saveError = error.localizedDescription
        }
    }

    /// Only `zooms`/`cursor`/`animation.screen`/`cursorHidden` feed `CursorPath`/`CameraPath`
    /// (T-413) — everything else (background, frame, camera tab, …) skips the resimulation.
    private func rebuildPathsIfNeeded(from before: Project) {
        guard before.clips != project.clips || before.zooms != project.zooms || before.cursor != project.cursor
            || before.animation.screen != project.animation.screen || before.cursorHidden != project.cursorHidden
            || before.windowShots != project.windowShots
        else { return }
        (cursorPath, cameraPath) = Self.buildPaths(project: project, events: events)
    }

    nonisolated static func buildPaths(project: Project, events: EventLog) -> (CursorPath, CameraPath) {
        // Multi-window: pointer normalised against the visible window, hidden outside it (identity otherwise).
        let (events, outside) = remapWindowEvents(events, project: project)
        let cursorPath = CursorPath(events: events, style: project.cursor, hidden: project.cursorHidden + outside, duration: project.source.duration)
        // Remap recorded pointer motion into the edited video clock for automatic zoom following.
        let mappedEvents = project.clips.filter { !$0.isEmpty }.flatMap { clip -> [InputEvent] in
            let initial = cursorPath.sample(atSource: clip.mediaIn)
            var mapped = [InputEvent(t: clip.sourceStart, k: .move, x: initial.x, y: initial.y)]
            mapped += events.events.filter { $0.t >= clip.mediaIn && $0.t < clip.mediaIn + clip.mediaDuration }.map { event in
                var moved = event
                moved.t = clip.sourceStart + (event.t - clip.mediaIn) * clip.timeScale / clip.speed
                return moved
            }
            return mapped
        }.sorted { $0.t < $1.t }
        let timelineCursor = CursorPath(events: EventLog(events: mappedEvents), style: project.cursor,
                                        hidden: [], duration: project.timelineSourceDuration)
        let cameraPath = CameraPath(zooms: project.zooms, cursor: timelineCursor,
                                     spring: project.animation.screen == .focused ? .focused : .smooth,
                                     duration: project.timelineSourceDuration, clips: project.clips)
        return (cursorPath, cameraPath)
    }

    private func push(_ snapshot: Project, name: String) {
        undoStack.append(snapshot)
        undoNames.append(name)
        if undoStack.count > undoCap { undoStack.removeFirst(); undoNames.removeFirst() }
    }

    private func scheduleAutosave() {
        saveStatus = "Saving…"
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
