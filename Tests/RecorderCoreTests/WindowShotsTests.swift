import Foundation
import Testing
@testable import RecorderCore

private func twoWindows(shots: [WindowShot] = []) -> Project {
    Project(source: Source(pixelWidth: 800, pixelHeight: 600, duration: 12, windowSizes: [PixelSize(w: 800, h: 600), PixelSize(w: 400, h: 400)]),
            clips: [Clip(sourceStart: 0, sourceEnd: 12)], windowShots: shots)
}

private func frames() -> [WindowFrame] {
    [WindowFrame(t: 0, i: 0, x: 0, y: 0, w: 800, h: 600), WindowFrame(t: 0, i: 1, x: 1000, y: 100, w: 400, h: 400),
     WindowFrame(t: 6, i: 1, x: 1100, y: 100, w: 400, h: 400)]
}

private func click(_ t: Double, _ x: Double, _ y: Double) -> InputEvent { InputEvent(t: t, k: .down, x: x, y: y, b: 0) }

@Test func windowShotsDecodeDefaultsAndRoundTrip() throws {
    #expect(try JSONDecoder().decode(Project.self, from: Data("{}".utf8)).windowShots.isEmpty)
    #expect(try JSONDecoder().decode(EventLog.self, from: Data(#"{"events":[]}"#.utf8)).windowFrames == nil)
    let p = twoWindows(shots: [WindowShot(start: 1, end: 4, window: 1)])
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
    let log = EventLog(events: [], windowFrames: frames())
    #expect(try JSONDecoder().decode(EventLog.self, from: JSONEncoder().encode(log)).windowFrames == frames())
}

@Test func windowShotBlocksUseTheGenericEngine() throws {
    var p = twoWindows()
    let added = p.addWindowShot(atSource: 2, length: 3, window: 1)
    let id = try #require(added)
    #expect(p.windowIndex(atSource: 3) == 1 && p.windowIndex(atSource: 6) == 0)
    p.moveWindowShot(id, toStart: 5)
    p.resizeWindowShot(id, edge: .trailing, to: 9)
    #expect(p.windowShots[0].start == 5 && p.windowShots[0].end == 9 && p.checkInvariants() == nil)
    let didSplit = p.splitBlock(id, atSource: 7)
    #expect(didSplit && p.windowShots.count == 2 && p.windowShots.allSatisfy { $0.window == 1 })
    p.setWindowShot(id, window: 9) // clamped to the last window
    #expect(p.windowShots[0].window == 1)
    p.removeBlock(id)
    #expect(p.windowShots.count == 1)
}

@Test func windowShotsFollowLinkedClipEdits() {
    var p = twoWindows(shots: [WindowShot(start: 2, end: 10, window: 1)])
    let didSplit = p.split(atOutput: 6)
    #expect(didSplit)
    p.liftClip(1)
    #expect(p.windowShots.allSatisfy { $0.end <= 6 } && p.checkInvariants() == nil)
}

@Test func autoWindowShotsSwitchToClickedWindowRespectingMinShot() {
    let log = EventLog(events: [click(1, 100, 100), click(3, 1200, 200), click(3.5, 100, 100), click(8, 100, 100), click(11, 1200, 200)],
                       windowFrames: frames())
    let shots = autoWindowShots(events: log, duration: 12, windowCount: 2)
    // t=1 is inside window 0 (no change); t=3 → window 1; t=3.5 is < 1.5 s into the shot; t=8 → back; t=11 is within 1.5 s of the end.
    #expect(shots.map(\.window) == [0, 1, 0])
    #expect(shots.map(\.start) == [0, 3, 8] && shots.map(\.end) == [3, 8, 12])
    #expect(autoWindowShots(events: EventLog(events: [click(2, 100, 100)], windowFrames: frames()), duration: 12, windowCount: 2).isEmpty)
}

@Test func cursorIsNormalisedAgainstTheVisibleWindowAndHiddenOutside() {
    let p = twoWindows(shots: [WindowShot(start: 0, end: 5, window: 0), WindowShot(start: 5, end: 12, window: 1)])
    let log = EventLog(events: [InputEvent(t: 1, k: .move, x: 400, y: 300), InputEvent(t: 2, k: .move, x: 1200, y: 300),
                                InputEvent(t: 7, k: .move, x: 1300, y: 300), InputEvent(t: 8, k: .key, keyCode: 1)],
                       windowFrames: frames())
    let out = remapWindowEvents(log, project: p)
    let moves = out.events.moves()
    #expect(moves.first { $0.t == 1 }?.x == 0.5 && moves.first { $0.t == 1 }?.y == 0.5)
    // t=2 is outside window 0 (800 wide); the synthetic move at the t=5 cut puts the resting pointer inside window 1's frame sample.
    #expect(out.hidden.first == TimeRange(start: 2, end: 5))
    #expect(abs((moves.first { $0.t == 7 }?.x ?? 0) - 0.5) < 1e-9) // window 1 moved to x=1100 at t=6
    #expect(out.events.events.contains { $0.k == .key })
    #expect(remapWindowEvents(EventLog(events: log.events), project: p).hidden.isEmpty)
}
