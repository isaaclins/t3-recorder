import Foundation

public struct Word: Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum Transcript {
    /// Parakeet returns word pieces; a new word starts at a `▁` or a leading space.
    public static func words(tokens: [(text: String, start: Double, end: Double)]) -> [Word] {
        var out: [Word] = []
        for tok in tokens {
            let startsWord = tok.text.hasPrefix("▁") || tok.text.hasPrefix(" ")
            let clean = tok.text.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            if startsWord || out.isEmpty {
                out.append(Word(text: clean, start: tok.start, end: tok.end))
            } else {
                out[out.count - 1].text += clean
                out[out.count - 1].end = tok.end
            }
        }
        return out
    }

    /// Spoken lines for the timeline: end at sentence ends and pauses, never run on past `maxSeconds`.
    public static func lines(_ words: [Word], pause: Double = 0.7, maxSeconds: Double = 8) -> [Word] {
        var out: [Word] = []
        var current: Word?
        for w in words {
            guard var line = current else { current = w; continue }
            let sentenceDone = [".", "?", "!"].contains { line.text.hasSuffix($0) }
            if w.start - line.end >= pause || sentenceDone || w.end - line.start > maxSeconds {
                out.append(line)
                current = w
            } else {
                line.text += " " + w.text
                line.end = w.end
                current = line
            }
        }
        if let current { out.append(current) }
        return out
    }
}
