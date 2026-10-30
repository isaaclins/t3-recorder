import Foundation

/// Where finished recordings go. Lives in ~/Library/Application Support/T3Recorder/config.json; the defaults are the house.
struct Config: Codable {
    var sshTarget = "stewie@100.90.249.60"
    var remoteRoot = "/Users/stewie/share/recordings"
    var webRoot = "https://agent-machine.isaaclins.com/share/recordings"
    /// Start and stop. Default Control-Option-R; Carbon key code and modifiers.
    var hotKeyCode: UInt32 = 15
    var hotKeyModifiers: UInt32 = 0x1000 | 0x0800
    /// Turns mark mode on and off during a recording. Default Control-Option-M.
    var markHotKeyCode: UInt32 = 46
    var markHotKeyModifiers: UInt32 = 0x1000 | 0x0800

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("T3Recorder")
    static let recordings = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("T3 Recorder")
    static var keyFile: URL { support.appendingPathComponent("upload_key") }

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
