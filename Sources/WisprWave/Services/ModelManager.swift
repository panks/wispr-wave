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
    func downloadModel(modelId: String) async {
        guard !isDownloading else { return }
        
        // Find model info
        guard let modelInfo = supportedModels.first(where: { $0.id == modelId }) else { return }
        
        self.isDownloading = true
        self.downloadProgress = 0.0
        self.downloadStatus = "Preparing \(modelInfo.name)..."
        
        do {
            print("Downloading model: \(modelId) from \(modelInfo.url)")
            
            // Parse HuggingFace URL
            // Format: https://huggingface.co/{repo}/tree/{branch}/{path}
            // Example: https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3
            
            guard let url = URL(string: modelInfo.url) else {
                throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }
            
            let pathComponents = url.pathComponents
            // pathComponents: ["", "argmaxinc", "whisperkit-coreml", "tree", "main", "openai_whisper-large-v3"]
            
            guard pathComponents.count >= 6,
                  pathComponents[3] == "tree" else {
                throw NSError(domain: "ModelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HuggingFace tree URL format"])
            }
            
            let repo = "\(pathComponents[1])/\(pathComponents[2])"  // "argmaxinc/whisperkit-coreml"
            let branch = pathComponents[4]  // "main"
            let modelPath = pathComponents[5...].joined(separator: "/")  // "openai_whisper-large-v3"
            
            print("Repo: \(repo), Branch: \(branch), Path: \(modelPath)")
            
            // Use huggingface-cli to download
            let destinationURL = self.modelStoragePath.appendingPathComponent(modelInfo.id)
            
            // Use a fresh temp directory for each download to avoid stale locks
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Run download in background thread to avoid blocking UI
            let downloadTask = Task.detached {
                // Run huggingface-cli download
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [
                    "hf",
                    "download",
                    repo,
                    "--include", "\(modelPath)/*",
                    "--local-dir", tempDir.path
                ]
                
                // Store process for cancellation
                await self.setDownloadProcess(process)
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                print("Starting download process for \(modelInfo.name)...")
                try process.run()
                print("Process started, PID: \(process.processIdentifier)")
                
                // Update progress in parallel while download runs
                await withTaskGroup(of: Void.self) { group in
                    // Task 1: Monitor and update progress by reading output
                    group.addTask {
                        print("Output monitor started")
                        let handle = pipe.fileHandleForReading
                        
                        // Read byte by byte to handle \r (carriage return) updates
                        // This fixes "stuck" progress when CLI updates the same line
                        var buffer = Data()
                        
                        do {
                            for try await byte in handle.bytes {
                                // Check for newline or carriage return
                                if byte == 10 || byte == 13 { // \n or \r
                                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                                        print("HF Output: \(line)") // Debug logging
                                        
                                        await MainActor.run {
                                            // 1. Parse File Count: matches "3/15" or "[3/15]"
                                            // Regex to capture "(\d+/\d+)"
                                            if let range = line.range(of: #"(\d+/\d+)"#, options: .regularExpression) {
                                                let countStr = String(line[range])
                                                // Verify it looks like a fraction to avoid matching date-like strings if any
                                                if countStr.contains("/") {
                                                    self.downloadStatus = "Downloading \(modelInfo.name) (\(countStr))..."
                                                }
                                            } else if self.downloadStatus == "Initializing..." && self.downloadStatus.hasPrefix("Downloading") == false {
                                                self.downloadStatus = "Downloading \(modelInfo.name)..."
                                            }
                                            
                                            // 2. Parse Progress Percentage: 45%
                                            if let range = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                                                let percentStr = line[range].dropLast()
                                                if let percent = Double(percentStr) {
                                                    // Smooth out progress: prevent jumping to 100% too early for small files
                                                    // We could average it or just trust it. The user said it's janky.
                                                    // Let's just trust it for now but combined with file count it might feel better.
                                                    // Alternatively, if we know file count, we can do (fileIndex + percent) / totalFiles
                                                    self.downloadProgress = percent / 100.0
                                                }
                                            }
                                        }
                                    }
                                    buffer.removeAll()
                                } else {
                                    buffer.append(byte)
                                }
                            }
                        } catch {
                            print("Error reading output: \(error)")
                        }
                        print("Output monitor finished")
                    }
                    
                    // Task 2: Wait for process completion
                    group.addTask {
                        process.waitUntilExit()
                        print("Process completed with status: \(process.terminationStatus)")
                        // Close pipe to terminate the line reader
                        try? pipe.fileHandleForReading.close()
                    }
                    
                    // Wait for both tasks
                    await group.waitForAll()
                }
                
                // clear process
                await self.setDownloadProcess(nil)
                
                guard process.terminationStatus == 0 else {
                    // We can't easily get the full error output here since we consumed it above,
                    // but we printed it to console.
                    throw NSError(domain: "ModelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Download failed. Check logs for details."])
                }
                
                print("Moving downloaded files...")
                
                // Move downloaded model to destination
                let downloadedModelPath = tempDir.appendingPathComponent(modelPath)
                
                // Remove destination if exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // Move
                try FileManager.default.moveItem(at: downloadedModelPath, to: destinationURL)
                
                // Clean up temp directory for this model
                try? FileManager.default.removeItem(at: tempDir)
                
                print("Download and move complete!")
            }
            
            try await downloadTask.value
            
            // Update UI on main thread
            print("Updating UI after download completion")
            self.scanModels() // Refresh list
            self.isDownloading = false
            self.downloadProgress = 1.0
            
        } catch {
            print("Error downloading: \(error)")
            self.isDownloading = false
            self.downloadProgress = 0.0
        }
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
            usePrefillCache: true,
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
            let requiredSegmentsForConfirmation = 2
            
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
                            usePrefillCache: true,
                            skipSpecialTokens: true,
                            withoutTimestamps: true,
                            clipTimestamps: [lastConfirmedSegmentEndSeconds],
                            suppressBlank: true
                        )
                        
                        print("ModelManager: Streaming transcribe from \(lastConfirmedSegmentEndSeconds)s (total: \(totalSeconds)s)")
                        
                        let results: [TranscriptionResult] = try await whisperKit.transcribe(
                            audioArray: accumulatedSamples,
                            decodeOptions: options
                        )
                        
                        let segments = results.flatMap { $0.segments }
                        
                        // Confirm older segments (following AudioStreamTranscriber pattern)
                        if segments.count > requiredSegmentsForConfirmation {
                            let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation
                            let confirmedArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                            let unconfirmedArray = Array(segments.suffix(requiredSegmentsForConfirmation))
                            
                            if let lastConfirmed = confirmedArray.last,
                               lastConfirmed.end > lastConfirmedSegmentEndSeconds {
                                lastConfirmedSegmentEndSeconds = lastConfirmed.end
                                confirmedSegments.append(contentsOf: confirmedArray)
                                print("ModelManager: Confirmed \(confirmedArray.count) segments up to \(lastConfirmedSegmentEndSeconds)s")
                            }
                            
                            // Build full text: confirmed + unconfirmed
                            let confirmedText = confirmedSegments.map { $0.text }.joined()
                            let unconfirmedText = unconfirmedArray.map { $0.text }.joined()
                            let fullText = (confirmedText + unconfirmedText).trimmingCharacters(in: .whitespaces)
                            
                            if !fullText.isEmpty {
                                continuation.yield(fullText)
                            }
                        } else if !segments.isEmpty {
                            // Not enough segments to confirm yet, yield what we have
                            let confirmedText = confirmedSegments.map { $0.text }.joined()
                            let unconfirmedText = segments.map { $0.text }.joined()
                            let fullText = (confirmedText + unconfirmedText).trimmingCharacters(in: .whitespaces)
                            
                            if !fullText.isEmpty {
                                continuation.yield(fullText)
                            }
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
                            usePrefillCache: true,
                            skipSpecialTokens: true,
                            withoutTimestamps: true,
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
    
    // Track current process for cancellation
    private var currentDownloadProcess: Process?
    
    // Thread-safe process setter
    private func setDownloadProcess(_ process: Process?) {
        self.currentDownloadProcess = process
    }
    
    // Cancel any active download
    func cancelDownload() {
        if let process = currentDownloadProcess {
            print("Cancelling download process (PID: \(process.processIdentifier))")
            process.terminate()
            currentDownloadProcess = nil
        }
        isDownloading = false
        downloadProgress = 0.0
    }
}
