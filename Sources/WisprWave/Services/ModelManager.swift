import Foundation
import WhisperKit
@preconcurrency import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
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
            let config = WhisperKitConfig(modelFolder: localModelURL.path)
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
                                        
                                        // Parse progress
                                        // Look for pattern like "Downloading: 45%" or just "45%"
                                        if let range = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                                            let percentStr = line[range].dropLast()
                                            if let percent = Double(percentStr) {
                                                await MainActor.run {
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
