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
    var isPlaying = false
    var selection: Set<UUID> = []       // zoom/layout/mask ids
    var selectedClip: Int?
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

    /// The name of the edit `undo()`/`redo()` would apply next, or `nil` if there is none.
    var undoName: String? { undoNames.last }
    var redoName: String? { redoNames.last }

    init(packageURL: URL, project: Project, events: EventLog) {
        self.packageURL = packageURL
        self.project = project
        self.events = events
        (cursorPath, cameraPath) = Self.buildPaths(project: project, events: events)
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
        gestureSnapshot = project
    }

    func update(_ change: (inout Project) -> Void) {
        change(&project)
    }

    func commitGesture(_ name: String) {
        guard let snapshot = gestureSnapshot else { return }
        push(snapshot, name: name)
        gestureSnapshot = nil
        redoStack.removeAll()
        redoNames.removeAll()
        rebuildPathsIfNeeded(from: snapshot)
        scheduleAutosave()
    }

    func cancelGesture() {
        guard let snapshot = gestureSnapshot else { return }
        project = snapshot
        gestureSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast(), let name = undoNames.popLast() else { return }
        redoStack.append(project)
        redoNames.append(name)
        let before = project
        project = previous
        rebuildPathsIfNeeded(from: before)
        scheduleAutosave()
    }

    func redo() {
        guard let next = redoStack.popLast(), let name = redoNames.popLast() else { return }
        undoStack.append(project)
        undoNames.append(name)
        let before = project
        project = next
        rebuildPathsIfNeeded(from: before)
        scheduleAutosave()
    }

    func saveNow() {
        autosaveWork?.cancel()
        autosaveWork = nil
        try? project.save(to: packageURL.appendingPathComponent("project.json"))
    }

    /// Only `zooms`/`cursor`/`animation.screen`/`cursorHidden` feed `CursorPath`/`CameraPath`
    /// (T-413) — everything else (background, frame, camera tab, …) skips the resimulation.
    private func rebuildPathsIfNeeded(from before: Project) {
        guard before.zooms != project.zooms || before.cursor != project.cursor
            || before.animation.screen != project.animation.screen || before.cursorHidden != project.cursorHidden
        else { return }
        (cursorPath, cameraPath) = Self.buildPaths(project: project, events: events)
    }

    private static func buildPaths(project: Project, events: EventLog) -> (CursorPath, CameraPath) {
        let cursorPath = CursorPath(events: events, style: project.cursor, hidden: project.cursorHidden, duration: project.source.duration)
        let cameraPath = CameraPath(zooms: project.zooms, cursor: cursorPath,
                                     spring: project.animation.screen == .focused ? .focused : .smooth,
                                     duration: project.source.duration)
        return (cursorPath, cameraPath)
    }

    private func push(_ snapshot: Project, name: String) {
        undoStack.append(snapshot)
        undoNames.append(name)
        if undoStack.count > undoCap { undoStack.removeFirst(); undoNames.removeFirst() }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
