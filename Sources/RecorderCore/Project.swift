import Foundation

/// One recording session on disk: raw clips plus every edit. Nothing here touches the raw video, so all edits stay undoable.
public struct Project: Codable, Equatable {
    public var id: String
    public var createdAt: Date
    public var clips: [Clip] = []
    /// What is kept, in playback order. Cutting and adding sections only ever change this list.
    public var segments: [Segment] = []
    public var events: [Event] = []
    public var overlays: [Overlay] = []

    public init(id: String, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }

    public static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "r-" + f.string(from: date)
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.length } }

    public func clip(_ id: String) -> Clip? { clips.first { $0.id == id } }

    /// Add a freshly recorded clip at the end of the timeline.
    public mutating func append(_ clip: Clip, events new: [Event]) {
        clips.append(clip)
        segments.append(Segment(clipID: clip.id, start: 0, end: clip.duration))
        events.append(contentsOf: new)
    }

    /// Where a moment of a clip lands in the finished video; nil when it was cut out.
    public func outputTime(clipID: String, t: Double) -> Double? {
        var offset = 0.0
        for s in segments {
            if s.clipID == clipID, t >= s.start, t < s.end { return offset + t - s.start }
            offset += s.length
        }
        return nil
    }

    /// The clip moment shown at a time of the finished video.
    public func sourceTime(output t: Double) -> (clipID: String, t: Double)? {
        var offset = 0.0
        for s in segments {
            if t < offset + s.length { return (s.clipID, s.start + max(0, t - offset)) }
            offset += s.length
        }
        guard let last = segments.last else { return nil }
        return (last.clipID, last.end)
    }

    /// Remove a stretch of the finished video. Events inside it drop out of the report on their own.
    public mutating func cut(from a: Double, to b: Double) {
        let lo = max(0, min(a, b)), hi = min(duration, max(a, b))
        guard hi > lo else { return }
        var offset = 0.0
        var kept: [Segment] = []
        for s in segments {
            let sLo = offset, sHi = offset + s.length
            offset = sHi
            if hi <= sLo || lo >= sHi { kept.append(s); continue }
            if lo > sLo { kept.append(Segment(clipID: s.clipID, start: s.start, end: s.start + (lo - sLo))) }
            if hi < sHi { kept.append(Segment(clipID: s.clipID, start: s.start + (hi - sLo), end: s.end)) }
        }
        segments = kept.filter { $0.length > 0.02 }
    }
}

public struct Clip: Codable, Equatable {
    public var id: String
    public var videoFile: String
    public var audioFile: String?
    public var duration: Double
    /// Seconds the audio file starts after the video (negative: it started first).
    public var audioOffset: Double
    public var screen: ScreenInfo

    public init(id: String, videoFile: String, audioFile: String?, duration: Double, audioOffset: Double, screen: ScreenInfo) {
        self.id = id
        self.videoFile = videoFile
        self.audioFile = audioFile
        self.duration = duration
        self.audioOffset = audioOffset
        self.screen = screen
    }
}

public struct ScreenInfo: Codable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int

    public init(name: String, width: Int, height: Int) {
        self.name = name
        self.width = width
        self.height = height
    }
}

public struct Segment: Codable, Equatable {
    public var clipID: String
    public var start: Double
    public var end: Double
    public var length: Double { end - start }

    public init(clipID: String, start: Double, end: Double) {
        self.clipID = clipID
        self.start = start
        self.end = end
    }
}

/// Position on the screen as 0...1 fractions, top-left origin, so it stays valid at any frame size.
public struct NormRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public enum MarkShape: String, Codable, CaseIterable {
    case pen, rectangle, circle, arrow, text, mark
}

public enum TimelineKind: String, Codable {
    case said, click, app, draw, note
}

public struct Event: Codable, Equatable, Identifiable {
    public var id: UUID
    public var clipID: String
    public var t: Double
    public var end: Double?
    public var kind: TimelineKind
    public var text: String?
    public var shape: MarkShape?
    public var rect: NormRect?
    public var app: String?
    public var window: String?

    public init(id: UUID = UUID(), clipID: String, t: Double, end: Double? = nil, kind: TimelineKind, text: String? = nil,
                shape: MarkShape? = nil, rect: NormRect? = nil, app: String? = nil, window: String? = nil) {
        self.id = id
        self.clipID = clipID
        self.t = t
        self.end = end
        self.kind = kind
        self.text = text
        self.shape = shape
        self.rect = rect
        self.app = app
        self.window = window
    }
}

/// A shape added in the editor; burned into the finished video for `duration` seconds from `t`.
public struct Overlay: Codable, Equatable, Identifiable {
    public var id: UUID
    public var clipID: String
    public var t: Double
    public var duration: Double
    public var shape: MarkShape
    public var rect: NormRect
    /// Arrows point from the first corner to the second; these say which way the diagonal runs.
    public var flipX: Bool
    public var flipY: Bool
    public var text: String?

    public init(id: UUID = UUID(), clipID: String, t: Double, duration: Double = 3, shape: MarkShape, rect: NormRect,
                flipX: Bool = false, flipY: Bool = false, text: String? = nil) {
        self.id = id
        self.clipID = clipID
        self.t = t
        self.duration = duration
        self.shape = shape
        self.rect = rect
        self.flipX = flipX
        self.flipY = flipY
        self.text = text
    }
}

public enum ProjectStore {
    public static func load(_ dir: URL) throws -> Project {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Project.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
    }

    public static func save(_ p: Project, to dir: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
    }
}
