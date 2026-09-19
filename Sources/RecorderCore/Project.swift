import Foundation

/// `decodeIfPresent(...) ?? default` in one call, used by every nested type below so that
/// a `project.json` missing any key still decodes (SPEC §5: "every field has a default").
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default d: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? d }
}

// MARK: - Small shared shapes

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double = 0, end: Double = 0) { self.start = start; self.end = end }
    enum CodingKeys: String, CodingKey { case start, end }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.value(.start, default: 0)
        end = try c.value(.end, default: 0)
    }
}

public struct NormPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0.5, y: Double = 0.5) { self.x = x; self.y = y }
    enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.value(.x, default: 0.5)
        y = try c.value(.y, default: 0.5)
    }
}

public struct NormRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    enum CodingKeys: String, CodingKey { case x, y, w, h }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.value(.x, default: 0)
        y = try c.value(.y, default: 0)
        w = try c.value(.w, default: 1)
        h = try c.value(.h, default: 1)
    }
}

// MARK: - Project sections

public struct Source: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case display, window, area }
    public var kind: Kind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var duration: Double
    public var hasCamera: Bool
    public var hasMic: Bool
    public var hasSystemAudio: Bool
    public init(kind: Kind = .display, pixelWidth: Int = 0, pixelHeight: Int = 0, scale: Double = 1,
                duration: Double = 0, hasCamera: Bool = false, hasMic: Bool = false, hasSystemAudio: Bool = false) {
        self.kind = kind; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scale = scale
        self.duration = duration; self.hasCamera = hasCamera; self.hasMic = hasMic; self.hasSystemAudio = hasSystemAudio
    }
    enum CodingKeys: String, CodingKey { case kind, pixelWidth, pixelHeight, scale, duration, hasCamera, hasMic, hasSystemAudio }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.value(.kind, default: .display)
        pixelWidth = try c.value(.pixelWidth, default: 0)
        pixelHeight = try c.value(.pixelHeight, default: 0)
        scale = try c.value(.scale, default: 1)
        duration = try c.value(.duration, default: 0)
        hasCamera = try c.value(.hasCamera, default: false)
        hasMic = try c.value(.hasMic, default: false)
        hasSystemAudio = try c.value(.hasSystemAudio, default: false)
    }
}

public struct Zoom: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case auto, manual }
    public var id: String
    public var start: Double
    public var end: Double
    public var scale: Double
    public var mode: Mode
    public var center: NormPoint
    public var instant: Bool
    public var enabled: Bool
    public init(id: String = UUID().uuidString, start: Double = 0, end: Double = 3, scale: Double = 2,
                mode: Mode = .manual, center: NormPoint = NormPoint(), instant: Bool = false, enabled: Bool = true) {
        self.id = id; self.start = start; self.end = end; self.scale = scale
        self.mode = mode; self.center = center; self.instant = instant; self.enabled = enabled
    }
    enum CodingKeys: String, CodingKey { case id, start, end, scale, mode, center, instant, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID().uuidString)
        start = try c.value(.start, default: 0)
        end = try c.value(.end, default: 3)
        scale = try c.value(.scale, default: 2)
        mode = try c.value(.mode, default: .manual)
        center = try c.value(.center, default: NormPoint())
        instant = try c.value(.instant, default: false)
        enabled = try c.value(.enabled, default: true)
    }
}

public struct Layout: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case cameraFull, hidden, bubble, settings }
    public var id: String
    public var start: Double
    public var end: Double
    public var kind: Kind
    public var camera: Camera?
    public var keys: Keys?
    public var transition: Double = 0.3
    public init(id: String = UUID().uuidString, start: Double = 0, end: Double = 0, kind: Kind = .cameraFull, camera: Camera? = nil, keys: Keys? = nil) {
        self.id = id; self.start = start; self.end = end; self.kind = kind; self.camera = camera; self.keys = keys
    }
    enum CodingKeys: String, CodingKey { case id, start, end, kind, camera, keys, transition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID().uuidString)
        start = try c.value(.start, default: 0)
        end = try c.value(.end, default: 0)
        kind = try c.value(.kind, default: .cameraFull)
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera)
        keys = try c.decodeIfPresent(Keys.self, forKey: .keys)
        transition = try c.value(.transition, default: 0.3)
    }
}

public struct Mask: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case mask, highlight, blur }
    public var id: String
    public var start: Double
    public var end: Double
    public var kind: Kind
    public var rect: NormRect
    public var opacity: Double
    public var transition: Double

    public func strength(at time: Double) -> Double {
        guard time >= start, time <= end else { return 0 }
        let fade = min(max(0, transition), (end - start) / 2)
        guard fade > 0 else { return opacity }
        let t = min(1, max(0, min(time - start, end - time) / fade))
        return opacity * t * t * (3 - 2 * t)
    }

    public init(id: String = UUID().uuidString, start: Double = 0, end: Double = 0, kind: Kind = .mask,
                rect: NormRect = NormRect(), opacity: Double = 0.8, transition: Double = 0) {
        self.id = id; self.start = start; self.end = end; self.kind = kind; self.rect = rect; self.opacity = opacity; self.transition = transition
    }
    enum CodingKeys: String, CodingKey { case id, start, end, kind, rect, opacity, transition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID().uuidString)
        start = try c.value(.start, default: 0)
        end = try c.value(.end, default: 0)
        kind = try c.value(.kind, default: .mask)
        rect = try c.value(.rect, default: NormRect())
        opacity = try c.value(.opacity, default: 0.8)
        transition = try c.value(.transition, default: 0)
    }
}

public struct Background: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case wallpaper, gradient, color, image }
    public var kind: Kind
    public var wallpaper: String
    public var color: String
    public var gradient: [String]
    public var gradientAngle: Double
    public var imagePath: String
    public var blur: Double
    public init(kind: Kind = .wallpaper, wallpaper: String = "01", color: String = "#5B3DF5",
                gradient: [String] = ["#5B3DF5", "#E0567A"], gradientAngle: Double = 45,
                imagePath: String = "", blur: Double = 0) {
        self.kind = kind; self.wallpaper = wallpaper; self.color = color; self.gradient = gradient
        self.gradientAngle = gradientAngle; self.imagePath = imagePath; self.blur = blur
    }
    enum CodingKeys: String, CodingKey { case kind, wallpaper, color, gradient, gradientAngle, imagePath, blur }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.value(.kind, default: .wallpaper)
        wallpaper = try c.value(.wallpaper, default: "01")
        color = try c.value(.color, default: "#5B3DF5")
        gradient = try c.value(.gradient, default: ["#5B3DF5", "#E0567A"])
        gradientAngle = try c.value(.gradientAngle, default: 45)
        imagePath = try c.value(.imagePath, default: "")
        blur = try c.value(.blur, default: 0)
    }
}

public struct Frame: Codable, Equatable, Sendable {
    public var padding: Double
    public var cornerRadius: Double
    public var inset: Double
    public var insetColor: String
    public var shadow: Double
    public init(padding: Double = 0.08, cornerRadius: Double = 0.02, inset: Double = 0,
                insetColor: String = "#000000", shadow: Double = 0.5) {
        self.padding = padding; self.cornerRadius = cornerRadius; self.inset = inset
        self.insetColor = insetColor; self.shadow = shadow
    }
    enum CodingKeys: String, CodingKey { case padding, cornerRadius, inset, insetColor, shadow }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        padding = try c.value(.padding, default: 0.08)
        cornerRadius = try c.value(.cornerRadius, default: 0.02)
        inset = try c.value(.inset, default: 0)
        insetColor = try c.value(.insetColor, default: "#000000")
        shadow = try c.value(.shadow, default: 0.5)
    }
}

public struct CursorStyle: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case smooth, medium, rapid, none }
    public var hidden: Bool
    public var size: Double
    public var style: Style
    public var hideWhenIdle: Bool
    public var loop: Bool
    public var alwaysArrow: Bool
    public var rotate: Bool
    public var removeShakes: Bool
    public var clickSound: Bool
    public init(hidden: Bool = false, size: Double = 1.5, style: Style = .smooth, hideWhenIdle: Bool = true,
                loop: Bool = false, alwaysArrow: Bool = false, rotate: Bool = false, removeShakes: Bool = false,
                clickSound: Bool = false) {
        self.hidden = hidden; self.size = size; self.style = style; self.hideWhenIdle = hideWhenIdle
        self.loop = loop; self.alwaysArrow = alwaysArrow; self.rotate = rotate
        self.removeShakes = removeShakes; self.clickSound = clickSound
    }
    enum CodingKeys: String, CodingKey { case hidden, size, style, hideWhenIdle, loop, alwaysArrow, rotate, removeShakes, clickSound }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.value(.hidden, default: false)
        size = try c.value(.size, default: 1.5)
        style = try c.value(.style, default: .smooth)
        hideWhenIdle = try c.value(.hideWhenIdle, default: true)
        loop = try c.value(.loop, default: false)
        alwaysArrow = try c.value(.alwaysArrow, default: false)
        rotate = try c.value(.rotate, default: false)
        removeShakes = try c.value(.removeShakes, default: false)
        clickSound = try c.value(.clickSound, default: false)
    }
}

public struct Animation: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable { case focused, smooth }
    public var screen: Screen
    public var motionBlur: Double
    public var blurCursor: Bool
    public var blurZoom: Bool
    public var blurPan: Bool
    public init(screen: Screen = .focused, motionBlur: Double = 0.5, blurCursor: Bool = true,
                blurZoom: Bool = true, blurPan: Bool = true) {
        self.screen = screen; self.motionBlur = motionBlur
        self.blurCursor = blurCursor; self.blurZoom = blurZoom; self.blurPan = blurPan
    }
    enum CodingKeys: String, CodingKey { case screen, motionBlur, blurCursor, blurZoom, blurPan }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.value(.screen, default: .focused)
        motionBlur = try c.value(.motionBlur, default: 0.5)
        blurCursor = try c.value(.blurCursor, default: true)
        blurZoom = try c.value(.blurZoom, default: true)
        blurPan = try c.value(.blurPan, default: true)
    }
}

public struct Camera: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public var size: Double
    public var aspect: Double
    public var position: NormPoint?
    public var corner: Corner
    public var roundness: Double
    public var mirror: Bool
    public var shadow: Double
    public var shrinkWhenZoomed: Bool
    public init(size: Double = 0.2, corner: Corner = .bottomRight, roundness: Double = 0.5,
                mirror: Bool = true, shadow: Double = 0.5, shrinkWhenZoomed: Bool = true, position: NormPoint? = nil, aspect: Double = 1) {
        self.aspect = aspect
        self.position = position
        self.size = size; self.corner = corner; self.roundness = roundness
        self.mirror = mirror; self.shadow = shadow; self.shrinkWhenZoomed = shrinkWhenZoomed
    }
    enum CodingKeys: String, CodingKey { case size, corner, roundness, mirror, shadow, shrinkWhenZoomed, position, aspect }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.value(.aspect, default: 1)
        position = try c.decodeIfPresent(NormPoint.self, forKey: .position)
        size = try c.value(.size, default: 0.2)
        corner = try c.value(.corner, default: .bottomRight)
        roundness = try c.value(.roundness, default: 0.5)
        mirror = try c.value(.mirror, default: true)
        shadow = try c.value(.shadow, default: 0.5)
        shrinkWhenZoomed = try c.value(.shrinkWhenZoomed, default: true)
    }
}

public struct Audio: Codable, Equatable, Sendable {
    public var micVolume: Double
    public var systemVolume: Double
    public var micMuted: Bool
    public var systemMuted: Bool
    public var denoise: Bool
    public init(micVolume: Double = 1, systemVolume: Double = 1, micMuted: Bool = false,
                systemMuted: Bool = false, denoise: Bool = false) {
        self.micVolume = micVolume; self.systemVolume = systemVolume
        self.micMuted = micMuted; self.systemMuted = systemMuted; self.denoise = denoise
    }
    enum CodingKeys: String, CodingKey { case micVolume, systemVolume, micMuted, systemMuted, denoise }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        micVolume = try c.value(.micVolume, default: 1)
        systemVolume = try c.value(.systemVolume, default: 1)
        micMuted = try c.value(.micMuted, default: false)
        systemMuted = try c.value(.systemMuted, default: false)
        denoise = try c.value(.denoise, default: false)
    }
}

public struct Keys: Codable, Equatable, Sendable {
    public var show: Bool
    public var allKeys: Bool
    public var size: Double
    public var position: NormPoint
    public var hold: Double
    public init(show: Bool = false, allKeys: Bool = false, size: Double = 1,
                position: NormPoint = NormPoint(x: 0.5, y: 1), hold: Double = 1.2) {
        self.show = show; self.allKeys = allKeys; self.size = size; self.position = position; self.hold = hold
    }
    enum CodingKeys: String, CodingKey { case show, allKeys, size, position, hold }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = try c.value(.show, default: false)
        allKeys = try c.value(.allKeys, default: false)
        size = try c.value(.size, default: 1)
        position = try c.value(.position, default: NormPoint(x: 0.5, y: 1))
        hold = try c.value(.hold, default: 1.2)
    }
}

public struct Output: Codable, Equatable, Sendable {
    public enum Aspect: String, Codable, Sendable {
        case auto
        case r16x9 = "16:9"
        case r9x16 = "9:16"
        case r1x1 = "1:1"
        case r4x3 = "4:3"
        case r16x10 = "16:10"
    }
    public var aspect: Aspect
    public init(aspect: Aspect = .auto) { self.aspect = aspect }
    enum CodingKeys: String, CodingKey { case aspect }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.value(.aspect, default: .auto)
    }
}

// MARK: - Project

public enum ProjectError: Error, Equatable, Sendable {
    case newerVersion(Int)
}

/// The editor's entire edit state. See docs/SPEC.md §5. `project.json` is the only file the
/// editor ever rewrites; media alongside it is never modified after recording.
public struct Project: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var title: String
    public var createdAt: String
    public var source: Source
    public var clips: [Clip]
    public var zooms: [Zoom]
    public var layouts: [Layout]
    public var masks: [Mask]
    public var cursorHidden: [TimeRange]
    public var crop: NormRect
    public var output: Output
    public var background: Background
    public var frame: Frame
    public var cursor: CursorStyle
    public var animation: Animation
    public var camera: Camera
    public var audio: Audio
    public var keys: Keys

    public init(
        version: Int = Project.currentVersion,
        id: String = UUID().uuidString,
        title: String = "Untitled",
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        source: Source = Source(),
        clips: [Clip] = [],
        zooms: [Zoom] = [],
        layouts: [Layout] = [],
        masks: [Mask] = [],
        cursorHidden: [TimeRange] = [],
        crop: NormRect = NormRect(),
        output: Output = Output(),
        background: Background = Background(),
        frame: Frame = Frame(),
        cursor: CursorStyle = CursorStyle(),
        animation: Animation = Animation(),
        camera: Camera = Camera(),
        audio: Audio = Audio(),
        keys: Keys = Keys()
    ) {
        self.version = version; self.id = id; self.title = title; self.createdAt = createdAt
        self.source = source; self.clips = clips; self.zooms = zooms; self.layouts = layouts; self.masks = masks
        self.cursorHidden = cursorHidden; self.crop = crop; self.output = output; self.background = background
        self.frame = frame; self.cursor = cursor; self.animation = animation; self.camera = camera
        self.audio = audio; self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case version, id, title, createdAt, source, clips, zooms, layouts, masks, cursorHidden, crop, output,
             background, frame, cursor, animation, camera, audio, keys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: Project.currentVersion)
        id = try c.value(.id, default: UUID().uuidString)
        title = try c.value(.title, default: "Untitled")
        createdAt = try c.value(.createdAt, default: ISO8601DateFormatter().string(from: Date()))
        source = try c.value(.source, default: Source())
        clips = try c.value(.clips, default: [])
        zooms = try c.value(.zooms, default: [])
        layouts = try c.value(.layouts, default: [])
        masks = try c.value(.masks, default: [])
        cursorHidden = try c.value(.cursorHidden, default: [])
        crop = try c.value(.crop, default: NormRect())
        output = try c.value(.output, default: Output())
        background = try c.value(.background, default: Background())
        frame = try c.value(.frame, default: Frame())
        cursor = try c.value(.cursor, default: CursorStyle())
        animation = try c.value(.animation, default: Animation())
        camera = try c.value(.camera, default: Camera())
        audio = try c.value(.audio, default: Audio())
        keys = try c.value(.keys, default: Keys())
    }

    /// Throws `ProjectError.newerVersion` rather than silently opening (and risking a rewrite) a
    /// `project.json` written by a future version of the app.
    public static func load(from url: URL) throws -> Project {
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        guard project.version <= currentVersion else { throw ProjectError.newerVersion(project.version) }
        return project
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
