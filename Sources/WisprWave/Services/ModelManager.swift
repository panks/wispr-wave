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
    
    // Config: List of supported models
    struct ModelInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let url: String  // HuggingFace tree URL
    }
    
    let supportedModels: [ModelInfo] = [
        ModelInfo(id: "openai_whisper-large-v3-v20240930_547MB", name: "Whisper Large V3 Quant", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_547MB"),
        ModelInfo(id: "openai_whisper-large-v3", name: "Whisper Large V3", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3"),
        ModelInfo(id: "distil-whisper_distil-large-v3", name: "Distil Whisper Large V3", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3"),
        ModelInfo(id: "openai_whisper-base", name: "Whisper Base", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base"),
        ModelInfo(id: "openai_whisper-small", name: "Whisper Small", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small"),
        ModelInfo(id: "openai_whisper-tiny", name: "Whisper Tiny", url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny")
    ]
    
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
                
                // If no model is selected but we have downloaded ones, maybe select the first one?
                // User requirement: "App begins with default in on state... If there is no model present... show text"
                // We won't auto-select here to respect the "turn on/off" UI explicitly, 
                // but if we were previously using one, we keep it. 
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
            
            // Create temp directory for download
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
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
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            try process.run()
            
            // Monitor progress (simplified - just wait for completion)
            // In a more advanced implementation, we could parse output for progress
            DispatchQueue.main.async {
                self.downloadProgress = 0.5
            }
            
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "ModelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Download failed: \(output)"])
            }
            
            // Move downloaded model to destination
            let downloadedModelPath = tempDir.appendingPathComponent(modelPath)
            
            // Remove destination if exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            // Move
            try FileManager.default.moveItem(at: downloadedModelPath, to: destinationURL)
            
            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)
            
            DispatchQueue.main.async {
                self.scanModels() // Refresh list
                self.isDownloading = false
                self.downloadProgress = 1.0
            }
            
            print("Download complete: \(destinationURL.path)")
            
        } catch {
            print("Error downloading: \(error)")
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadProgress = 0.0
            }
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
}
