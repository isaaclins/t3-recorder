import Foundation

/// Settings, in ~/Library/Application Support/T3Recorder/config.json.
struct Config: Codable {
    /// Start and stop. Default Control-Option-R; Carbon key code and modifiers.
    var hotKeyCode: UInt32 = 15
    var hotKeyModifiers: UInt32 = 0x1000 | 0x0800
    /// Turns mark mode on and off during a recording. Default Control-Option-M.
    var markHotKeyCode: UInt32 = 46
    var markHotKeyModifiers: UInt32 = 0x1000 | 0x0800
    /// Optional, so a config.json written by an older version still loads and keeps its shortcuts.
    var onboardingDone: Bool?
    /// The tour's page, so it carries on after macOS makes the app reopen for Screen Recording.
    var onboardingStep: Int?

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("T3Recorder")
    /// Not ~/Movies: macOS guards that folder, and T3 has to be able to read what lands on the clipboard.
    static let recordings = support.appendingPathComponent("Recordings")

    func save() {
        try? FileManager.default.createDirectory(at: Config.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Config.support.appendingPathComponent("config.json"), options: .atomic)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}

enum Log {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/T3Recorder")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recorder.log")
    }()

    static func info(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
