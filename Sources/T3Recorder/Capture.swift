import AVFoundation
import AppKit
import CoreGraphics
import QuartzCore
import ScreenCaptureKit

/// Records one display to a file. The hardware encoder does the work, so this stays cheap while Isaac reproduces his problem.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var finished: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var started = false
    private(set) var startTime: CFTimeInterval = 0
    var onFailure: ((Error) -> Void)?

    /// On the main thread: ScreenCaptureKit builds its menu bar indicator here and crashes anywhere else.
    @MainActor func start(displayID: CGDirectDisplayID, excluding windowIDs: [CGWindowID], to url: URL, maxWidth: Int = 2560) async throws -> (width: Int, height: Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError("No screen to record was found.")
        }
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), CGFloat(maxWidth) / CGFloat(display.width))
        config.width = Int(CGFloat(display.width) * scale) & ~1
        config.height = Int(CGFloat(display.height) * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.showMouseClicks = true
        config.queueDepth = 6

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream
        self.output = output
        startTime = CACurrentMediaTime()
        try await stream.startCapture()
        return (config.width, config.height)
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            finished = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { self.resumeFinished() }
        }
        self.stream = nil
        output = nil
    }

    private func resumeFinished() {
        lock.lock()
        let c = finished
        finished = nil
        lock.unlock()
        c?.resume()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock()
        defer { lock.unlock() }
        if !started {
            started = true
            startTime = CACurrentMediaTime()
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resumeFinished() }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Log.info("recording failed: \(error)")
        onFailure?(error)
        resumeFinished()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error)")
        onFailure?(error)
        resumeFinished()
    }
}

/// The microphone goes to its own file: Parakeet reads it directly and the editor can treat voice and picture separately.
final class MicRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var startTime: CFTimeInterval = 0

    func start(to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.prepareToRecord(), r.record() else { return false }
        recorder = r
        startTime = CACurrentMediaTime()
        return true
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
