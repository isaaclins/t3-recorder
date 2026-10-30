import FluidAudio
import Foundation
import RecorderCore

/// Parakeet TDT 0.6B v3 on the Neural Engine, the model OpenWhispr offers: finds the language itself, nothing leaves the Mac.
/// The first use downloads about 490 MB into ~/Library/Application Support/FluidAudio/Models.
actor Parakeet {
    static let shared = Parakeet()
    private var manager: AsrManager?

    /// Fetch and load the model ahead of time, so the first recording doesn't wait for the download.
    func prepare(status: (@Sendable (String) -> Void)? = nil) async throws {
        if manager == nil {
            let onDisk = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            status?(onDisk ? "Loading speech model…" : "Downloading speech model (once, about 490 MB)…")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
        }
    }

    func words(in audio: URL, status: (@Sendable (String) -> Void)? = nil) async throws -> [Word] {
        try await prepare(status: status)
        guard let manager else { return [] }
        status?("Transcribing…")
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(audio, decoderState: &state)
        let tokens = (result.tokenTimings ?? []).map { (text: $0.token, start: $0.startTime, end: $0.endTime) }
        return Transcript.words(tokens: tokens)
    }
}
