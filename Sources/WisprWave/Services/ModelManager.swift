import Foundation
@preconcurrency import WhisperKit
@preconcurrency import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = "Initializing..."
    @Published var currentModelName: String? = nil
    @Published var isModelLoaded = false
    /// True while `loadModel(name:)` or `switchEngine(to:)` is swapping models.
    @Published private(set) var isLoadingModel = false
    /// Id of the model whose last load failed; cleared on the next load attempt or engine switch.
    @Published private(set) var loadErrorModelName: String? = nil
    /// The engine whose models the popup shows and which loads at launch.
    @Published private(set) var activeEngine: SpeechEngine {
        didSet { UserDefaults.standard.set(activeEngine.rawValue, forKey: Self.activeEngineKey) }
    }
    
    // UserDefaults keys
    private static let activeEngineKey = "WisprWave.ActiveEngine"
    /// Pre-Parakeet single last-used key; only read by the migration in init.
    private static let legacyLastUsedModelKey = "WisprWave.LastUsedModel"
    private static func lastUsedModelKey(for engine: SpeechEngine) -> String {
        "WisprWave.LastUsedModel.\(engine.rawValue)"
    }
    
    // Use models from config (all engines)
    let supportedModels = ModelsConfig.supportedModels
    
    /// The active engine's models, which is what the popup lists.
    var visibleModels: [ModelsConfig.ModelInfo] {
        ModelsConfig.models(for: activeEngine)
    }
    
    @Published var downloadedModels: Set<String> = []
    
    /// The loaded speech engine, if any. Only Whisper exists for now.
    private(set) var engine: TranscriptionEngine?
    private let modelStoragePath: URL
    
    init() {
        let defaults = UserDefaults.standard
        self.activeEngine = defaults.string(forKey: Self.activeEngineKey).flatMap(SpeechEngine.init(rawValue:)) ?? .whisper
        
        // One-time migration: the single last-used key becomes the Whisper one.
        let whisperKey = Self.lastUsedModelKey(for: .whisper)
        if let legacy = defaults.string(forKey: Self.legacyLastUsedModelKey) {
            if defaults.string(forKey: whisperKey) == nil {
                defaults.set(legacy, forKey: whisperKey)
                defaults.removeObject(forKey: Self.legacyLastUsedModelKey)
            }
        }
        
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
    
    // Load a specific model (User clicked "Turn On", or an engine switch)
    //
    // Unloads whatever is loaded first, so two models never sit in memory at once.
    func loadModel(name: String) async {
        guard let modelInfo = ModelsConfig.model(id: name) else {
            print("Model \(name) is not in the catalog.")
            return
        }
        guard !isLoadingModel else {
            print("Ignoring load of \(name): another load is in progress.")
            return
        }
        
        // If already loaded, do nothing
        if currentModelName == name && isModelLoaded { return }
        
        guard downloadedModels.contains(name) else {
            print("Model \(name) not downloaded.")
            return
        }
        
        isLoadingModel = true
        defer { isLoadingModel = false }
        loadErrorModelName = nil
        
        // Update UI immediately (status reads "Loading <name>..." during the unload too)
        self.currentModelName = name
        self.isModelLoaded = false
        self.isDownloading = false
        
        await unloadEngine()
        
        do {
            let loaded: TranscriptionEngine
            switch modelInfo.engine {
            case .whisper:
                print("Loading WhisperKit with model: \(name)")
                loaded = try await WhisperEngine(modelName: name, modelStoragePath: modelStoragePath)
            case .parakeet:
                throw LoadError.engineUnavailable(.parakeet)
            }
            
            self.engine = loaded
            self.isModelLoaded = true  // Update on main actor
            
            // Save as that engine's last used model, and keep the active engine in step
            UserDefaults.standard.set(name, forKey: Self.lastUsedModelKey(for: modelInfo.engine))
            if activeEngine != modelInfo.engine {
                activeEngine = modelInfo.engine
            }
            
            print("\(modelInfo.engine.rawValue) model \(name) loaded successfully")
        } catch {
            print("Error loading model: \(error)")
            self.currentModelName = nil // Load failed
            self.isModelLoaded = false
            self.loadErrorModelName = name
            UserDefaults.standard.removeObject(forKey: Self.lastUsedModelKey(for: modelInfo.engine))
        }
    }
    
    // Auto-load the active engine's last used model if available
    func loadLastUsedModel() async {
        guard let lastModel = UserDefaults.standard.string(forKey: Self.lastUsedModelKey(for: activeEngine)),
              downloadedModels.contains(lastModel) else {
            print("No last used \(activeEngine.rawValue) model to load")
            return
        }
        
        print("Auto-loading last used model: \(lastModel)")
        await loadModel(name: lastModel)
    }
    
    /// Makes `newEngine` active: unloads the current model, then loads that engine's
    /// last-used model if it is downloaded, else stays unloaded.
    ///
    /// Ignored while downloading or loading. ModelManager can't see dictation state, so
    /// callers must not call this while AppState `isListening` or `isProcessing`.
    func switchEngine(to newEngine: SpeechEngine) async {
        guard newEngine != activeEngine, !isDownloading, !isLoadingModel else { return }
        
        print("Switching engine: \(activeEngine.rawValue) -> \(newEngine.rawValue)")
        activeEngine = newEngine
        loadErrorModelName = nil
        
        // Hold the loading flag while unloading so no power press slips in.
        isLoadingModel = true
        await unloadModel()
        isLoadingModel = false
        
        if let lastModel = UserDefaults.standard.string(forKey: Self.lastUsedModelKey(for: newEngine)),
           downloadedModels.contains(lastModel) {
            await loadModel(name: lastModel)
        } else {
            print("No downloaded \(newEngine.rawValue) model to load")
        }
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
        guard let modelInfo = ModelsConfig.model(id: modelId) else { return }

        // Parakeet downloads arrive with ParakeetEngine.
        guard modelInfo.engine == .whisper, let urlString = modelInfo.url else {
            print("Download of \(modelId) (\(modelInfo.engine.rawValue)) is not supported yet")
            return
        }

        // Parse HuggingFace URL
        // Format: https://huggingface.co/{repo}/tree/{branch}/{path}
        // Example: https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3
        guard let url = URL(string: urlString) else {
            print("Error downloading: invalid URL \(urlString)")
            self.downloadStatus = "Invalid model URL"
            return
        }

        let pathComponents = url.pathComponents
        // pathComponents: ["", "plive", "whisperkit-coreml", "tree", "main", "openai_whisper-large-v3"]
        guard pathComponents.count >= 6, pathComponents[3] == "tree" else {
            print("Error downloading: invalid HuggingFace tree URL \(urlString)")
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
    func unloadModel() async {
        await unloadEngine()
        self.currentModelName = nil
    }
    
    /// Releases the loaded engine's memory; leaves `currentModelName` to the caller.
    private func unloadEngine() async {
        if let engine {
            await engine.unload()
        }
        self.engine = nil
        self.isModelLoaded = false
    }

    func transcribe(audioPath: String) async throws -> String? {
        guard let whisper = engine as? WhisperEngine else { return nil }
        
        return try await whisper.transcribe(audioPath: audioPath)
    }
    
    func transcribe(audioSamples: [Float]) async throws -> String? {
        guard let engine = engine else { return nil }
        
        return try await engine.transcribe(samples: audioSamples)
    }
    
    // MARK: - Streaming Transcription (Boost Mode)
    // Whisper-only; see WhisperEngine.transcribe(stream:).
    
    func transcribe(stream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<String, Error> {
        if let whisper = engine as? WhisperEngine {
            return whisper.transcribe(stream: stream)
        }
        // No Whisper model loaded: consume the audio and finish without text.
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await _ in stream {}
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Load failures that come from ModelManager itself rather than an engine.
    private enum LoadError: Error {
        /// No engine implementation exists for this kind yet.
        case engineUnavailable(SpeechEngine)
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
