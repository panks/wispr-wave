import Foundation
@preconcurrency import WhisperKit

/// Whisper models via WhisperKit (Core ML). Owns one loaded `WhisperKit` instance and
/// provides batch transcription plus the Whisper-only Boost streaming mode.
@MainActor
final class WhisperEngine: TranscriptionEngine {
    let kind: SpeechEngine = .whisper

    private var whisperKit: WhisperKit?

    /// Loads the model folder `<modelStoragePath>/<name>`. Throws if WhisperKit fails to load.
    init(modelName name: String, modelStoragePath: URL) async throws {
        let localModelURL = modelStoragePath.appendingPathComponent(name)
        // Redirect tokenizer + any Hub fallback away from ~/Documents/huggingface
        // (swift-transformers' HubApi default), into our App Support sandbox.
        let hubBase = modelStoragePath.appendingPathComponent("hub")
        try? FileManager.default.createDirectory(at: hubBase, withIntermediateDirectories: true)
        let config = WhisperKitConfig(
            downloadBase: hubBase,
            modelFolder: localModelURL.path,
            tokenizerFolder: hubBase,
            computeOptions: ModelComputeOptions(),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        
        self.whisperKit = pipe
    }

    func unload() async {
        self.whisperKit = nil
    }

    func transcribe(audioPath: String) async throws -> String? {
        guard let whisperKit = whisperKit else { return nil }
        
        let result = try await whisperKit.transcribe(audioPath: audioPath)
        return result.map { $0.text }.joined(separator: " ")
    }
    
    func transcribe(samples audioSamples: [Float]) async throws -> String {
        guard let whisperKit = whisperKit else { throw WhisperEngineError.notLoaded }
        
        let options = DecodingOptions(
            task: .transcribe,
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )
        
        let result: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: options
        )
        return result.map { $0.text }.joined(separator: " ")
    }
    
    // MARK: - Streaming Transcription (Boost Mode)
    // Uses clipTimestamps to avoid re-decoding the entire buffer each time.
    // Tracks confirmed segments so each intermediate transcription only processes new audio.
    // On stop, a fast final transcription captures the last few words.
    
    func transcribe(stream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            var accumulatedSamples: [Float] = []
            var lastTranscribeTime = Date()
            var confirmedSegments: [TranscriptionSegment] = []
            var lastConfirmedSegmentEndSeconds: Float = 0
            // Time-based confirmation: any segment whose end lies more than this many
            // seconds before the current audio end is considered settled and won't be
            // re-decoded. We pair this with `withoutTimestamps: false` below so the
            // model emits multiple 2-10s segments per 30s window (vs. one giant 30s
            // atom under withoutTimestamps:true). That's what lets Boost actually help
            // for short clips — confirmation can fire well before 30s of speech.
            let confirmationLagSeconds: Float = 8.0
            
            Task {
                do {
                    for try await chunk in stream {
                        accumulatedSamples.append(contentsOf: chunk)
                        
                        guard let whisperKit = self.whisperKit else { continue }
                        
                        // Throttle: transcribe at most every 1 second and only when we have
                        // at least 1 second of new audio past the last confirmed point.
                        let totalSeconds = Float(accumulatedSamples.count) / Float(WhisperKit.sampleRate)
                        let newAudioSeconds = totalSeconds - lastConfirmedSegmentEndSeconds
                        
                        guard Date().timeIntervalSince(lastTranscribeTime) > 1.0,
                              newAudioSeconds > 1.0 else {
                            continue
                        }
                        
                        // Use clipTimestamps to skip already-confirmed audio
                        let options = DecodingOptions(
                            task: .transcribe,
                            temperature: 0,
                            temperatureFallbackCount: 0,
                            usePrefillPrompt: true,
                            skipSpecialTokens: true,
                            // Timestamps ON so the segmenter can split each 30s window
                            // into finer 2-10s segments — required for the time-based
                            // confirmation rule above to confirm anything before 30s
                            // of speech has elapsed.
                            withoutTimestamps: false,
                            clipTimestamps: [lastConfirmedSegmentEndSeconds],
                            suppressBlank: true
                        )
                        
                        print("ModelManager: Streaming transcribe from \(lastConfirmedSegmentEndSeconds)s (total: \(totalSeconds)s)")
                        
                        let results: [TranscriptionResult] = try await whisperKit.transcribe(
                            audioArray: accumulatedSamples,
                            decodeOptions: options
                        )
                        
                        let segments = results.flatMap { $0.segments }

                        // Time-based confirmation: anything ending more than
                        // `confirmationLagSeconds` before the current audio end is
                        // considered stable. Works regardless of how many segments
                        // the model emits.
                        let confirmableEnd = totalSeconds - confirmationLagSeconds
                        let newlyConfirmed = segments.filter { $0.end <= confirmableEnd }
                        let stillUnconfirmed = segments.filter { $0.end > confirmableEnd }

                        if let newEnd = newlyConfirmed.last?.end, newEnd > lastConfirmedSegmentEndSeconds {
                            confirmedSegments.append(contentsOf: newlyConfirmed)
                            lastConfirmedSegmentEndSeconds = newEnd
                            print("ModelManager: Confirmed \(newlyConfirmed.count) segments up to \(lastConfirmedSegmentEndSeconds)s")
                        }

                        let confirmedText = confirmedSegments.map { $0.text }.joined()
                        let unconfirmedText = stillUnconfirmed.map { $0.text }.joined()
                        let fullText = (confirmedText + unconfirmedText).trimmingCharacters(in: .whitespaces)

                        if !fullText.isEmpty {
                            continuation.yield(fullText)
                        }

                        lastTranscribeTime = Date()
                    }
                    
                    // Final transcription: decode only from the last confirmed point.
                    // This is fast because it's just a few seconds of audio.
                    if !accumulatedSamples.isEmpty, let whisperKit = self.whisperKit {
                        let options = DecodingOptions(
                            task: .transcribe,
                            temperature: 0,
                            temperatureFallbackCount: 0,
                            usePrefillPrompt: true,
                            skipSpecialTokens: true,
                            // Timestamps ON so the segmenter can split each 30s window
                            // into finer 2-10s segments — required for the time-based
                            // confirmation rule above to confirm anything before 30s
                            // of speech has elapsed.
                            withoutTimestamps: false,
                            clipTimestamps: [lastConfirmedSegmentEndSeconds],
                            suppressBlank: true
                        )
                        
                        let totalSeconds = Float(accumulatedSamples.count) / Float(WhisperKit.sampleRate)
                        print("ModelManager: Final transcription from \(lastConfirmedSegmentEndSeconds)s to \(totalSeconds)s")
                        
                        let results: [TranscriptionResult] = try await whisperKit.transcribe(
                            audioArray: accumulatedSamples,
                            decodeOptions: options
                        )
                        
                        let finalSegments = results.flatMap { $0.segments }
                        let confirmedText = confirmedSegments.map { $0.text }.joined()
                        let finalText = (confirmedText + finalSegments.map { $0.text }.joined())
                            .trimmingCharacters(in: .whitespaces)
                        
                        print("ModelManager: Final result: '\(finalText)'")
                        
                        if !finalText.isEmpty {
                            continuation.yield(finalText)
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum WhisperEngineError: Error {
    /// The engine was used after `unload()`.
    case notLoaded
}
