import AVFoundation
import AppKit
import RecorderCore

// Headless paths used by the tests on the mini: they run the same code as the app, without windows.
let args = CommandLine.arguments

func finish(_ work: @escaping () async throws -> Void) -> Never {
    Task {
        do { try await work(); exit(0) } catch { print("failed: \(error)"); exit(1) }
    }
    dispatchMain()
}

if args.count >= 2, args[1] == "--prepare" {
    finish { try await Parakeet.shared.prepare { print($0) } }
}

if args.count >= 5, args[1] == "--import" {
    // --import <video> <audio|-> <folder>: make a project from existing files, transcribe it, render it.
    finish {
        let dir = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: dir.appendingPathComponent("clip-1.mov"))
        var audioName: String?
        if args[3] != "-" {
            audioName = "clip-1.m4a"
            try FileManager.default.copyItem(at: URL(fileURLWithPath: args[3]), to: dir.appendingPathComponent("clip-1.m4a"))
        }
        let asset = AVURLAsset(url: dir.appendingPathComponent("clip-1.mov"))
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        let clip = Clip(id: "clip-1", videoFile: "clip-1.mov", audioFile: audioName, duration: try await asset.load(.duration).seconds, audioOffset: 0,
                        screen: ScreenInfo(name: "Imported", width: Int(size.width), height: Int(size.height)))
        var events: [Event] = []
        if let audioName {
            let words = try await Parakeet.shared.words(in: dir.appendingPathComponent(audioName)) { print($0) }
            events = Transcript.lines(words).map { Event(clipID: "clip-1", t: $0.start, end: $0.end, kind: .said, text: $0.text) }
        }
        var p = Project(id: dir.lastPathComponent, createdAt: Date())
        p.append(clip, events: events)
        try ProjectStore.save(p, to: dir)
        print("imported, \(events.count) spoken lines")
    }
}

if args.count >= 3, args[1] == "--export" {
    // --export <folder>: render and upload, print what would go on the clipboard.
    finish {
        let dir = URL(fileURLWithPath: args[2])
        let result = try await Exporter.run(try ProjectStore.load(dir), in: dir, config: Config.load()) { print($0) }
        try await Task.sleep(for: .seconds(2))
        print("uploaded: \(result.uploaded)\n\(result.text)")
    }
}

if args.count >= 4, args[1] == "--capture-test" {
    // --capture-test <seconds> <file>: record the main display, inside a running app like the real thing.
    Task { @MainActor in
        do {
            let r = ScreenRecorder()
            let size = try await r.start(displayID: CGMainDisplayID(), excluding: [], to: URL(fileURLWithPath: args[3]))
            try await Task.sleep(for: .seconds(Double(args[2]) ?? 3))
            await r.stop()
            print("recorded \(size)")
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    NSApplication.shared.run()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
if args.count >= 3, args[1] == "--self-test" {
    // --self-test <screenshot.png>
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Task { @MainActor in await controller.selfTest(screenshot: args[2]) } }
}
app.run()
