import Testing
@testable import RecorderCore

@Test func timeMapRoundTrip() {
    // 0-2s kept, 2-4s removed, 4-8s kept at 2x  => output is 2s + 2s = 4s
    let m = TimeMap([Clip(sourceStart: 0, sourceEnd: 2), Clip(sourceStart: 4, sourceEnd: 8, speed: 2)])
    #expect(m.outputDuration == 4)
    #expect(m.sourceTime(atOutput: 1) == 1)
    #expect(m.sourceTime(atOutput: 3) == 6)
    #expect(m.sourceTime(atOutput: 99) == 8)
    #expect(m.outputTime(atSource: 6) == 3)
    #expect(m.outputTime(atSource: 3) == nil)
}
