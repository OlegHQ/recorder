import Foundation

/// SPEC §6 "Presets": the saved/applied unit is only the *styling* subset of `Project` —
/// `background, frame, cursor, animation, camera` — never `clips`/`zooms`/`layouts`/`source`/etc.
/// File panels and the `~/Library/Application Support/Recorder/Presets/` directory are app-side
/// (T-605's non-core part); this is just the pure value + apply.
public struct Preset: Codable, Equatable, Sendable {
    public var name: String
    public var background: Background
    public var frame: Frame
    public var cursor: CursorStyle
    public var animation: Animation
    public var camera: Camera

    public init(name: String, from project: Project) {
        self.name = name
        self.background = project.background
        self.frame = project.frame
        self.cursor = project.cursor
        self.animation = project.animation
        self.camera = project.camera
    }

    /// Overwrites only the styling subset of `project`; clips/zooms/layouts/masks/source/etc. are untouched.
    public func apply(to project: inout Project) {
        project.background = background
        project.frame = frame
        project.cursor = cursor
        project.animation = animation
        project.camera = camera
    }

    enum CodingKeys: String, CodingKey { case name, background, frame, cursor, animation, camera }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: "Untitled")
        background = try c.value(.background, default: Background())
        frame = try c.value(.frame, default: Frame())
        cursor = try c.value(.cursor, default: CursorStyle())
        animation = try c.value(.animation, default: Animation())
        camera = try c.value(.camera, default: Camera())
    }
}
