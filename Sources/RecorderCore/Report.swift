import Foundation

public struct FrameRef: Equatable {
    public var t: Double
    public var file: String

    public init(t: Double, file: String) {
        self.t = t
        self.file = file
    }
}

public struct TimelineRow: Equatable {
    public var t: Double
    public var label: String
    public var text: String
    public var frame: String?

    public init(t: Double, label: String, text: String, frame: String? = nil) {
        self.t = t
        self.label = label
        self.text = text
        self.frame = frame
    }
}

/// What happened to the video on this paste. It stays on the Mac unless someone asks for it, because it is by far the biggest file.
public enum VideoDelivery: Equatable {
    case leftOut, attached, tooBig
}

public enum Report {
    public static func stamp(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    public static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func describe(_ e: Event) -> String {
        var place = ""
        if let app = e.app, !app.isEmpty { place += " in \(app)" }
        if let w = e.window, !w.isEmpty { place += " \"\(w)\"" }
        let at = e.rect.map { " at \(percent($0.centerX)) across, \(percent($0.centerY)) down" } ?? ""
        switch e.kind {
        case .said: return "\"\(e.text ?? "")\""
        case .note: return e.text ?? ""
        case .click: return "click\(at)\(place)"
        case .app: return "switched to \(e.app ?? "another app")"
        case .draw:
            if e.shape == .mark { return "marked this spot\(at)\(place)" }
            let what: String
            switch e.shape {
            case .text: what = "wrote \"\(e.text ?? "")\""
            case .pen: what = "drew with the pen"
            case .arrow: what = "drew an arrow"
            default: what = "drew a \(e.shape?.rawValue ?? "mark")"
            }
            return "\(what)\(at)"
        }
    }

    public static func rows(_ p: Project, frames: [FrameRef]) -> [TimelineRow] {
        var rows: [(order: Int, row: TimelineRow)] = []
        for e in p.events {
            guard let t = p.outputTime(clipID: e.clipID, t: e.t) else { continue }
            let label: String
            switch e.kind {
            case .said: label = "SAID"
            case .note: label = "NOTE"
            case .click: label = "CLICK"
            case .app: label = "APP"
            case .draw: label = "DRAW"
            }
            rows.append((0, TimelineRow(t: t, label: label, text: describe(e))))
        }
        for o in p.overlays {
            guard let t = p.outputTime(clipID: o.clipID, t: o.t) else { continue }
            let what = o.shape == .text ? "wrote \"\(o.text ?? "")\"" : "marked with \(o.shape == .arrow ? "an" : "a") \(o.shape.rawValue)"
            let at = " at \(percent(o.rect.centerX)) across, \(percent(o.rect.centerY)) down"
            rows.append((0, TimelineRow(t: t, label: "DRAW", text: what + at)))
        }
        for f in frames { rows.append((1, TimelineRow(t: f.t, label: "FRAME", text: f.file, frame: f.file))) }
        return rows.sorted { $0.row.t != $1.row.t ? $0.row.t < $1.row.t : $0.order < $1.order }.map(\.row)
    }

    /// The report that travels with the screenshots. It goes as a file, because T3 drops pasted text when images come along.
    public static func document(_ p: Project, frames: [FrameRef], video: VideoDelivery) -> String {
        let screen = p.clips.first?.screen
        var head = "Screen recording from Isaac, \(stamp(p.duration)) long"
        if let screen { head += ", \(screen.name) (\(screen.width)x\(screen.height))" }
        head += ". This shows the problem; his words are transcribed, so a word may be misheard."
        var lines = [head]
        lines.append("The screenshots named below are attached to this message. Look at every one before you answer.")
        switch video {
        case .attached: lines.append("recording.mp4, also attached, is the full video.")
        case .leftOut: lines.append("The full video is not attached; it stays on his Mac. Ask him for it if the screenshots don't settle something.")
        case .tooBig: lines.append("The full video was too big to attach; it stays on his Mac.")
        }
        lines.append("")
        lines.append("Times are minutes:seconds into the video. Places are percent of the screen from the top left.")
        for r in rows(p, frames: frames) { lines.append("[\(stamp(r.t))] \(r.label): \(r.text)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
