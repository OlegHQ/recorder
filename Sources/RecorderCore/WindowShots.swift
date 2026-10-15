import Foundation

/// SPEC "Windows as layers": which window of a multi-window recording is visible, and where the cursor
/// is inside it. Everything here is a pure function of `project.json` + `events.json`.
public extension Project {
    /// Number of recorded windows (1 for display/area/single-window projects).
    var windowCount: Int { max(1, source.windowSizes.count) }

    /// Visible window at source time `t`: the covering shot, else window 0.
    func windowIndex(atSource t: Double) -> Int {
        min(windowShots.first { t >= $0.start && t < $0.end }?.window ?? 0, windowCount - 1)
    }

    mutating func setWindowShot(_ id: UUID, window: Int) {
        guard let i = windowShots.firstIndex(where: { $0.id == id.uuidString }) else { return }
        windowShots[i].window = min(max(window, 0), windowCount - 1)
    }
}

/// End-of-recording shots: the visible window switches to the window that was clicked, but never sooner
/// than `minShot` after the previous switch or within `minShot` of the end. Pointer events must carry
/// global points (multi-window `EventLog`). `[]` when nothing ever leaves window 0.
public func autoWindowShots(events: EventLog, duration: Double, windowCount: Int, minShot: Double = 1.5) -> [WindowShot] {
    guard windowCount > 1, let frames = events.windowFrames else { return [] }
    func frame(_ i: Int, at t: Double) -> WindowFrame? {
        let f = frames.filter { $0.i == i }
        return f.last { $0.t <= t } ?? f.first
    }
    var shots: [WindowShot] = []
    var current = 0, start = 0.0
    for click in events.clicks().sorted(by: { $0.t < $1.t }) where click.t >= start + minShot && click.t <= duration - minShot {
        guard let x = click.x, let y = click.y,
              let hit = (0..<windowCount).first(where: { i in
                  frame(i, at: click.t).map { x >= $0.x && x <= $0.x + $0.w && y >= $0.y && y <= $0.y + $0.h } ?? false
              }), hit != current else { continue }
        shots.append(WindowShot(start: start, end: click.t, window: current))
        current = hit; start = click.t
    }
    guard !shots.isEmpty else { return [] }
    return shots + [WindowShot(start: start, end: duration, window: current)]
}

/// Pointer events of a multi-window recording (global points) → normalised against the window visible at
/// each instant. `hidden` = media-time spans where the pointer is outside that window (cursor not drawn).
/// A synthetic move at every shot edge re-evaluates a resting pointer against the newly visible window.
/// Single-window logs are returned untouched.
public func remapWindowEvents(_ log: EventLog, project: Project) -> (events: EventLog, hidden: [TimeRange]) {
    guard let frames = log.windowFrames, project.windowCount > 1 else { return (log, []) }
    // Shots are source time, events media time; they only differ for clips moved by unlinked edits.
    func source(_ m: Double) -> Double {
        project.clips.first { !$0.isEmpty && m >= $0.mediaIn && m < $0.mediaIn + $0.mediaDuration }
            .map { $0.sourceStart + (m - $0.mediaIn) * $0.timeScale / $0.speed } ?? m
    }
    let pointer = log.events.filter { $0.x != nil && $0.y != nil }
    var extra: [InputEvent] = []
    for edge in project.windowShots.flatMap({ [$0.start, $0.end] }) {
        for clip in project.clips where !clip.isEmpty && edge >= clip.sourceStart && edge < clip.sourceEnd {
            let m = clip.mediaTime(atSource: edge)
            if let last = pointer.last(where: { $0.t <= m }) { extra.append(InputEvent(t: m, k: .move, x: last.x, y: last.y)) }
        }
    }
    let byWindow = (0..<project.windowCount).map { i in frames.filter { $0.i == i }.sorted { $0.t < $1.t } }
    var cursorAt = [Int](repeating: 0, count: byWindow.count) // events are walked in time order
    var hidden: [TimeRange] = []
    var outsideSince: Double?
    let mapped = (pointer + extra).sorted { $0.t < $1.t }.map { event -> InputEvent in
        let w = project.windowIndex(atSource: source(event.t))
        let list = byWindow[w]
        while cursorAt[w] + 1 < list.count, list[cursorAt[w] + 1].t <= event.t { cursorAt[w] += 1 }
        guard cursorAt[w] < list.count, list[cursorAt[w]].w > 0, list[cursorAt[w]].h > 0 else { return event }
        let f = list[cursorAt[w]]
        var moved = event
        moved.x = (event.x! - f.x) / f.w
        moved.y = (event.y! - f.y) / f.h
        if (0...1).contains(moved.x!) && (0...1).contains(moved.y!) {
            if let from = outsideSince { hidden.append(TimeRange(start: from, end: event.t)); outsideSince = nil }
        } else if outsideSince == nil { outsideSince = event.t }
        return moved
    }
    if let from = outsideSince { hidden.append(TimeRange(start: from, end: 1e9)) }
    let rest = log.events.filter { $0.x == nil || $0.y == nil }
    return (EventLog(events: (mapped + rest).sorted { $0.t < $1.t }), hidden)
}
