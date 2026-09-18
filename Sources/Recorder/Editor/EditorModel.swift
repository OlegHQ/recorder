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

    // ponytail: whole-struct snapshots; Project is a few KB.
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private let undoCap = 200

    private var gestureSnapshot: Project?
    private var autosaveWork: DispatchWorkItem?

    init(packageURL: URL, project: Project, events: EventLog) {
        self.packageURL = packageURL
        self.project = project
        self.events = events
    }

    /// The ONLY way to mutate `project` outside a gesture. One call = one undo step.
    func edit(_ name: String, _ change: (inout Project) -> Void) {
        push(project)
        change(&project)
        redoStack.removeAll()
        scheduleAutosave()
    }

    /// For drags: begin → many `update` → commit | cancel. One undo step total.
    func beginGesture() {
        gestureSnapshot = project
    }

    func update(_ change: (inout Project) -> Void) {
        change(&project)
    }

    func commitGesture(_ name: String) {
        guard let snapshot = gestureSnapshot else { return }
        push(snapshot)
        gestureSnapshot = nil
        redoStack.removeAll()
        scheduleAutosave()
    }

    func cancelGesture() {
        guard let snapshot = gestureSnapshot else { return }
        project = snapshot
        gestureSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        scheduleAutosave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        scheduleAutosave()
    }

    func saveNow() {
        autosaveWork?.cancel()
        autosaveWork = nil
        try? project.save(to: packageURL.appendingPathComponent("project.json"))
    }

    private func push(_ snapshot: Project) {
        undoStack.append(snapshot)
        if undoStack.count > undoCap { undoStack.removeFirst() }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
