import Foundation
import Testing
@testable import RecorderCore

@Test func layerRenderingUsesConnectedOutputTimeAndHalfOpenEnds() throws {
    var project = Project(source: Source(duration: 20), clips: [Clip(sourceStart: 0, sourceEnd: 20, speed: 2)])
    let rect = NormRect(x: 0.18, y: 0.18, w: 0.64, h: 0.64)
    project.layers = [LayerBlock(kind: .image, start: 4, end: 8, file: "media/card.png", rect: rect, fadeIn: 0.4, fadeOut: 0.4)]
    #expect(project.layerStates(atOutput: 1.9).isEmpty)
    #expect(project.layerStates(atOutput: 2).first?.opacity == 0)
    let middle = try #require(project.layerStates(atOutput: 2.2).first)
    #expect(abs(middle.opacity - 0.5) < 1e-9 && middle.rect == rect)
    #expect(project.layerStates(atOutput: 5).first?.opacity == 1)
    #expect(abs(project.layerStates(atOutput: 5.8)[0].opacity - 0.5) < 1e-9)
    #expect(project.layerStates(atOutput: 6).isEmpty)
    #expect(project.layerStates(atOutput: .nan).isEmpty)
    project.layers[0].fadeIn = nil; project.layers[0].fadeOut = 0
    #expect(project.layerStates(atOutput: 2).first?.opacity == 1)
    project.layers[0].start = 18; project.layers[0].end = 22
    #expect(project.layerStates(atOutput: 12).first?.opacity == 1)
}

@Test func layerRenderingMotionOrderAndOverlappingFades() throws {
    var project = Project(source: Source(duration: 5), clips: [Clip(sourceStart: 0, sourceEnd: 5)])
    let rect = NormRect(x: 0.18, y: 0.18, w: 0.64, h: 0.64)
    project.layers = [LayerBlock(kind: .image, start: 1, end: 2, file: "media/scale.png", track: 1, rect: rect, motion: .scale, fadeIn: 1, fadeOut: 1),
                      LayerBlock(kind: .image, start: 1, end: 2, file: "media/slide.png", track: 0, rect: rect, motion: .slide, fadeIn: 1, fadeOut: 1)]
    let states = project.layerStates(atOutput: 1.5)
    #expect(states.map(\.block.track) == [0, 1])
    #expect(states.allSatisfy { abs($0.opacity - 0.5) < 1e-9 })
    #expect(abs(states[0].rect.y - 0.2) < 1e-9)
    #expect(abs(states[1].rect.w - 0.6208) < 1e-9)
    #expect(abs(states[1].rect.x + states[1].rect.w / 2 - 0.5) < 1e-9)
    #expect(project.layerStates(atOutput: 1).first?.rect.y == 0.22)
}
