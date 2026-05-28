import Foundation
import WhisperKit
@preconcurrency import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = "Initializing..."
    @Published var currentModelName: String? = nil
    @Published var isModelLoaded = false
    
    // UserDefaults key
    private let lastUsedModelKey = "WisprWave.LastUsedModel"
    
    // Use models from config
    let supportedModels = ModelsConfig.supportedModels
    
    @Published var downloadedModels: Set<String> = []
    
    var whisperKit: WhisperKit?
    private let modelStoragePath: URL
    
    init() {
        // Set up the model storage path
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.modelStoragePath = appSupport.appendingPathComponent("WisprWave/Models")
        } else {
            self.modelStoragePath = FileManager.default.temporaryDirectory
        }
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: modelStoragePath, withIntermediateDirectories: true)
        
        print("ModelManager initialized. Storage path: \(modelStoragePath.path)")
        
        // Scan for existing models
        scanModels()
    }
    
    func scanModels() {
        do {
            let items = try FileManager.default.contentsOfDirectory(at: modelStoragePath, includingPropertiesForKeys: nil)
            let directories = items.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
            
            DispatchQueue.main.async {
                self.downloadedModels = Set(directories)
                
                // If we have a current model but it's not on disk (deleted?), unset it
                if let current = self.currentModelName, !self.downloadedModels.contains(current) {
                    self.currentModelName = nil
                    self.isModelLoaded = false
                }
            }
        } catch {
            print("Error scanning models: \(error)")
        }
    }
    
    // Load a specific model (User clicked "Turn On")
    func loadModel(name: String) async {
        // If already loaded, do nothing
        if currentModelName == name && isModelLoaded { return }
        
        guard downloadedModels.contains(name) else {
            print("Model \(name) not downloaded.")
            return
        }
        
        // Update UI immediately
        self.currentModelName = name
        self.isModelLoaded = false
        self.isDownloading = false
        
        do {
            print("Loading WhisperKit with model: \(name)")
            let localModelURL = modelStoragePath.appendingPathComponent(name)
            let config = WhisperKitConfig(
                modelFolder: localModelURL.path,
                computeOptions: ModelComputeOptions(),
                verbose: false,
                logLevel: .none,
                prewarm: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            
            self.whisperKit = pipe
            self.isModelLoaded = true  // Update on main actor
            
            // Save as last used model
            UserDefaults.standard.set(name, forKey: lastUsedModelKey)
            
            print("WhisperKit loaded successfully")
        } catch {
            print("Error loading model: \(error)")
            self.currentModelName = nil // Load failed
            self.isModelLoaded = false
        }
    }
    
    // Auto-load last used model if available
    func loadLastUsedModel() async {
        guard let lastModel = UserDefaults.standard.string(forKey: lastUsedModelKey),
              downloadedModels.contains(lastModel) else {
            print("No last used model to load")
            return
        }
        
        print("Auto-loading last used model: \(lastModel)")
        await loadModel(name: lastModel)
    }
    
    // Download a specific model (User clicked "Download")
    //
    // Uses WhisperKit's built-in Swift downloader (backed by swift-transformers' HubApi),
    // which fetches model files straight from HuggingFace in-process. This avoids depending
    // on an external `hf`/`huggingface-cli` binary — which is rarely installed and, even when
    // it is, isn't on the minimal PATH a Finder-launched .app inherits.
    func downloadModel(modelId: String) async {
        guard !isDownloading else { return }

        // Find model info
        guard let modelInfo = supportedModels.first(where: { $0.id == modelId }) else { return }

        // Parse HuggingFace URL
        // Format: https://huggingface.co/{repo}/tree/{branch}/{path}
        // Example: https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3
        guard let url = URL(string: modelInfo.url) else {
            print("Error downloading: invalid URL \(modelInfo.url)")
            self.downloadStatus = "Invalid model URL"
            return
        }

        let pathComponents = url.pathComponents
        // pathComponents: ["", "plive", "whisperkit-coreml", "tree", "main", "openai_whisper-large-v3"]
        guard pathComponents.count >= 6, pathComponents[3] == "tree" else {
            print("Error downloading: invalid HuggingFace tree URL \(modelInfo.url)")
            self.downloadStatus = "Invalid model URL"
            return
        }

        let repo = "\(pathComponents[1])/\(pathComponents[2])"  // "plive/whisperkit-coreml"
        let variant = pathComponents[5...].joined(separator: "/") // "openai_whisper-large-v3"

        self.isDownloading = true
        self.downloadProgress = 0.0
        self.downloadStatus = "Preparing \(modelInfo.name)..."

        print("Downloading model: \(modelId) (variant: \(variant)) from \(repo)")

        let destinationURL = self.modelStoragePath.appendingPathComponent(modelInfo.id)
        // Fresh temp base per download; WhisperKit writes to <base>/models/<repo>/<variant>.
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        // Run as a cancellable task so cancelDownload() can stop it mid-flight.
        let task = Task { () -> Bool in
            do {
                let modelURL = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: tempBase,
                    from: repo,
                    progressCallback: { [weak self] progress in
                        // progressCallback may fire off the main actor; hop back to update UI.
                        Task { @MainActor in
                            guard let self else { return }
                            self.downloadProgress = progress.fractionCompleted
                            self.downloadStatus = "Downloading \(modelInfo.name) (\(Int(progress.fractionCompleted * 100))%)..."
                        }
                    }
                )

                try Task.checkCancellation()

                // Move the downloaded folder into our Models/<id> layout.
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: modelURL, to: destinationURL)
                try? FileManager.default.removeItem(at: tempBase)

                print("Download and move complete!")
                return true
            } catch is CancellationError {
                print("Download cancelled")
                try? FileManager.default.removeItem(at: tempBase)
                return false
            } catch {
                print("Error downloading: \(error)")
                try? FileManager.default.removeItem(at: tempBase)
                await MainActor.run {
                    self.downloadStatus = "Download failed: \(error.localizedDescription)"
                }
                return false
            }
        }

        self.downloadTask = task
        let success = await task.value
        self.downloadTask = nil

        if success {
            print("Updating UI after download completion")
            self.scanModels() // Refresh list
            self.downloadProgress = 1.0
        } else {
            self.downloadProgress = 0.0
        }
        self.isDownloading = false
    }
    
    // Unload
    func unloadModel() {
        self.whisperKit = nil
        self.currentModelName = nil
        self.isModelLoaded = false
    }

    func transcribe(audioPath: String) async throws -> String? {
        guard let whisperKit = whisperKit else { return nil }
        
        let result = try await whisperKit.transcribe(audioPath: audioPath)
        return result.map { $0.text }.joined(separator: " ")
    }
    
    func transcribe(audioSamples: [Float]) async throws -> String? {
        guard let whisperKit = whisperKit else { return nil }
        
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
    
    // Track the in-flight download for cancellation
    private var downloadTask: Task<Bool, Never>?

    // Cancel any active download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
        downloadStatus = "Cancelled"
    }
}
