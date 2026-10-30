import Foundation

/// A moment worth a screenshot, in finished-video time. Higher priority survives when there are too many.
public struct Moment: Equatable {
    public var t: Double
    public var priority: Int
    public var why: String

    public init(t: Double, priority: Int, why: String) {
        self.t = t
        self.priority = priority
        self.why = why
    }
}

public enum FramePicker {
    public static let maxFrames = 30

    /// Screenshots follow what Isaac did: right after a click or app switch so the result shows, when a drawing is
    /// finished, at notes and at visual changes. While he only talks, at least one every `talkGap` seconds.
    public static func moments(_ p: Project, sceneChanges: [Double], duration: Double, talkGap: Double = 12) -> [Moment] {
        // The starting point is always shown: everything that follows reads as a change from it.
        var out = [Moment(t: 0.2, priority: 3, why: "start")]
        var said: [Double] = []
        for e in p.events {
            guard let t = p.outputTime(clipID: e.clipID, t: e.t) else { continue }
            switch e.kind {
            case .draw:
                let done = e.end.flatMap { p.outputTime(clipID: e.clipID, t: $0) } ?? t
                out.append(Moment(t: done + 0.15, priority: 4, why: "drawing"))
            case .note: out.append(Moment(t: t, priority: 4, why: "note"))
            case .click: out.append(Moment(t: t + 0.5, priority: 2, why: "click"))
            case .app: out.append(Moment(t: t + 0.7, priority: 2, why: "app"))
            case .said: said.append(t)
            }
        }
        for o in p.overlays {
            if let t = p.outputTime(clipID: o.clipID, t: o.t) { out.append(Moment(t: t + min(0.2, o.duration / 2), priority: 4, why: "overlay")) }
        }
        out += sceneChanges.map { Moment(t: $0, priority: 3, why: "screen changed") }
        for t in said.sorted() where !(out.contains { abs($0.t - t) < talkGap }) {
            out.append(Moment(t: t, priority: 1, why: "talking"))
        }
        let last = max(0, duration - 0.05)
        return out.map { Moment(t: min(max(0, $0.t), last), priority: $0.priority, why: $0.why) }
    }

    /// Thin out: moments closer than `minGap` merge (best kept), then the lowest priorities go until `limit` remain.
    public static func choose(_ moments: [Moment], minGap: Double = 1.2, limit: Int = maxFrames) -> [Moment] {
        var kept: [Moment] = []
        for m in moments.sorted(by: { $0.priority != $1.priority ? $0.priority > $1.priority : $0.t < $1.t }) {
            if kept.count < limit, !kept.contains(where: { abs($0.t - m.t) < minGap }) { kept.append(m) }
        }
        return kept.sorted { $0.t < $1.t }
    }

    /// Times where the picture differs from the last kept one by more than `threshold` (0...1 mean difference).
    public static func sceneChanges(samples: [(t: Double, luma: [UInt8])], threshold: Double = 0.02) -> [Double] {
        var out: [Double] = []
        var reference: [UInt8]?
        for s in samples {
            defer { if reference == nil { reference = s.luma } }
            guard let r = reference, r.count == s.luma.count, !r.isEmpty else { continue }
            var total = 0
            for i in 0..<r.count { total += abs(Int(r[i]) - Int(s.luma[i])) }
            if Double(total) / Double(r.count) / 255 > threshold {
                out.append(s.t)
                reference = s.luma
            }
        }
        return out
    }
}
