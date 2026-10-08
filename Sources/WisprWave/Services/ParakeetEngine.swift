import Foundation
import FluidAudio
import os

/// NVIDIA Parakeet TDT models via FluidAudio (Core ML, Neural Engine). Owns one loaded
/// `AsrManager` actor. Batch transcription only; Boost streaming stays Whisper-only.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
    let kind: SpeechEngine = .parakeet

    private var asrManager: AsrManager?
    /// Transcriptions currently awaiting `asrManager`; `unload()` skips `cleanup()` while
    /// any are running, because a cleanup mid-transcribe makes that transcribe throw.
    private var activeTranscriptions = 0

    // MARK: - Catalog id <-> FluidAudio version

    /// The one place that maps catalog ids to FluidAudio model versions.
    ///
    /// FluidAudio resolves every download / existence check to
    /// `<parent of the folder we pass>/<repo.folderName>`, so `Models/<catalog id>` only
    /// works because each id equals its repo's folder name. `version(for:)` asserts that.
    nonisolated private static let models: [String: (version: AsrModelVersion, repo: Repo)] = [
        "parakeet-tdt-0.6b-v2": (.v2, .parakeetV2),
        "parakeet-tdt-0.6b-v3": (.v3, .parakeetV3),
    ]

    /// Encoder build used for v3 (v2 has a single encoder). Download, existence check and
    /// load must all agree on it.
    nonisolated private static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// Written into the model folder once `download` finishes. FluidAudio's own
    /// `modelsExist` only checks that the top-level bundles exist, which an interrupted
    /// download (app quit mid-transfer) can already satisfy.
    nonisolated private static let completeMarkerName = ".wisprwave-complete"

    nonisolated static func version(for modelId: String) -> AsrModelVersion? {
        guard let entry = models[modelId] else { return nil }
        assert(entry.repo.folderName == modelId,
               "FluidAudio stores \(modelId) in '\(entry.repo.folderName)'; the catalog id must match")
        return entry.version
    }

    // MARK: - Lifecycle

    /// Loads the model folder `<modelStoragePath>/<name>`. Never touches the network;
    /// throws if the folder is missing or incomplete.
    init(modelName name: String, modelStoragePath: URL) async throws {
        guard let version = Self.version(for: name) else {
            throw ParakeetEngineError.unknownModel(name)
        }
        let folder = modelStoragePath.appendingPathComponent(name)
        // loadLocal synchronously opens four Core ML models; keep that off the main actor.
        let models = try await Self.loadLocalModels(from: folder, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
    }

    @concurrent
    nonisolated private static func loadLocalModels(
        from folder: URL, version: AsrModelVersion
    ) async throws -> AsrModels {
        try AsrModels.loadLocal(from: folder, version: version, encoderPrecision: encoderPrecision)
    }

    func unload() async {
        guard let manager = asrManager else { return }
        asrManager = nil
        // With a transcription in flight, just drop our reference: the manager (and its
        // models) is freed when that transcription releases it.
        if activeTranscriptions == 0 {
            await manager.cleanup()
        }
    }

    func transcribe(samples audioSamples: [Float]) async throws -> String {
        guard let manager = asrManager else { throw ParakeetEngineError.notLoaded }

        // FluidAudio rejects clips under 0.3 s; treat them as silence, like an empty result.
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        guard audioSamples.count >= minimumSamples else { return "" }

        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }

        // Fresh decoder state per dictation so nothing carries over between them.
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(audioSamples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Files on disk

    /// True if `<modelStoragePath>/<modelId>` holds a complete download of that model.
    nonisolated static func isDownloaded(modelId: String, in modelStoragePath: URL) -> Bool {
        guard let version = version(for: modelId) else { return false }
        let folder = modelStoragePath.appendingPathComponent(modelId)
        let marker = folder.appendingPathComponent(completeMarkerName)
        return FileManager.default.fileExists(atPath: marker.path)
            && AsrModels.modelsExist(at: folder, version: version, encoderPrecision: encoderPrecision)
    }

    /// Downloads a Parakeet model into `<modelStoragePath>/<modelId>` (about 460 MB for v2).
    ///
    /// Honours task cancellation; a cancelled or failed download leaves completed and
    /// `.partial` files behind, which the caller deletes or a later download resumes.
    ///
    /// - Parameter progress: Called on an arbitrary queue with a fraction in 0...1 that
    ///   never decreases, and whether bytes are being transferred (false while FluidAudio
    ///   lists files or compiles the downloaded models).
    @concurrent
    nonisolated static func download(
        modelId: String,
        to modelStoragePath: URL,
        progress: @escaping @Sendable (_ fraction: Double, _ isTransferring: Bool) -> Void
    ) async throws {
        guard let version = version(for: modelId) else {
            throw ParakeetEngineError.unknownModel(modelId)
        }
        if isDownloaded(modelId: modelId, in: modelStoragePath) {
            progress(1, false)
            return
        }
        let folder = modelStoragePath.appendingPathComponent(modelId)
        let marker = folder.appendingPathComponent(completeMarkerName)

        // FluidAudio skips the download when its (shallow) existence check passes. Without
        // our marker that may be an interrupted download, so fetch everything again.
        let force = AsrModels.modelsExist(at: folder, version: version, encoderPrecision: encoderPrecision)

        // FluidAudio runs one repo download (bytes over all files reported as 0...0.5, then
        // compile 0.5...1) followed by three cached loads that each restart at 0.5 with
        // totalFiles == 0. Only the byte phase is real progress, so stretch it to 0...1 and
        // hold the bar at its high-water mark for everything else.
        let highWater = OSAllocatedUnfairLock(initialState: 0.0)
        let handler: ProgressHandler = { update in
            let transferring: Bool
            if case .downloading(_, let totalFiles) = update.phase, totalFiles > 0 {
                transferring = true
            } else {
                transferring = false
            }
            let candidate = transferring ? min(max(update.fractionCompleted * 2, 0), 1) : 0
            let fraction = highWater.withLock { value in
                value = max(value, candidate)
                return value
            }
            progress(fraction, transferring)
        }

        try await AsrModels.download(
            to: folder,
            force: force,
            version: version,
            encoderPrecision: encoderPrecision,
            progressHandler: handler
        )
        try Task.checkCancellation()
        try Data().write(to: marker)
    }
}

enum ParakeetEngineError: LocalizedError {
    /// The engine was used after `unload()`.
    case notLoaded
    /// The id is not a Parakeet model in the catalog.
    case unknownModel(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "No Parakeet model is loaded."
        case .unknownModel(let id): return "\(id) is not a Parakeet model."
        }
    }
}
