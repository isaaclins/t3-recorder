import Foundation

public struct FrameRef: Equatable {
    public var t: Double
    public var file: String

    public init(t: Double, file: String) {
        self.t = t
        self.file = file
    }
}

/// Where the finished files live for whoever reads the report.
public struct ReportLinks: Equatable {
    /// Folder the agent can open on the Mac mini; nil when the upload failed.
    public var folder: String?
    public var pageURL: String?

    public init(folder: String?, pageURL: String?) {
        self.folder = folder
        self.pageURL = pageURL
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
        case .app: return "switched to\(place)"
        case .draw:
            if e.shape == .mark { return "marked this spot\(at)\(place)" }
            let what = e.shape == .text ? "wrote \"\(e.text ?? "")\"" : "drew a \(e.shape?.rawValue ?? "mark")"
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

    /// The text that lands on the clipboard. Text only: T3 drops the text of a paste that also carries images.
    public static func clipboard(_ p: Project, frames: [FrameRef], links: ReportLinks) -> String {
        let screen = p.clips.first?.screen
        var head = "Screen recording from Isaac, \(stamp(p.duration)) long"
        if let screen { head += ", \(screen.name) (\(screen.width)x\(screen.height))" }
        head += ". This shows the problem; his words are transcribed, so a word may be misheard."
        var lines = [head]
        if let folder = links.folder {
            lines.append("Files on the Mac mini: \(folder)/ . Open every FRAME below with your file reading tool before you answer. recording.mp4 is the full video.")
        } else {
            lines.append("The upload failed, so the screenshots and the video are not on the Mac mini. Only this text arrived.")
        }
        if let url = links.pageURL, links.folder != nil { lines.append("Isaac's page: \(url)") }
        lines.append("")
        lines.append("Times are minutes:seconds into the video. Places are percent of the screen from the top left.")
        for r in rows(p, frames: frames) {
            let text = r.frame.map { f in links.folder.map { "\($0)/\(f)" } ?? f } ?? r.text
            lines.append("[\(stamp(r.t))] \(r.label): \(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
