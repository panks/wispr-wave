import Foundation
import WhisperKit
@preconcurrency import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModelName: String = "distil-large-v3" // Default model
    @Published var isModelLoaded = false
    @Published var availableModels: [String] = []
    
    var whisperKit: WhisperKit?
    
    private let modelStoragePath: URL
    
    init() {
        // Set up the model storage path
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.modelStoragePath = appSupport.appendingPathComponent("MacSpeechToText/Models")
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
            let models = items.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
            
            DispatchQueue.main.async {
                self.availableModels = models
                
                // Auto-select logic:
                // If we found models, and the current default model is NOT among them,
                // automatically switch to the first available model to avoid unwanted downloads.
                if !models.isEmpty && !models.contains(self.currentModelName) {
                    if let firstModel = models.first {
                        print("Default model not found, switching to available: \(firstModel)")
                        self.currentModelName = firstModel
                        // Trigger load for this new model if we aren't already loaded
                        Task {
                            await self.checkAndLoadModel(name: firstModel)
                        }
                    }
                }
            }
        } catch {
            print("Error scanning models: \(error)")
        }
    }
    
    func checkAndLoadModel(name: String) async {
        guard currentModelName != name || !isModelLoaded else { return }
        
        // Update state
        self.currentModelName = name
        self.isModelLoaded = false
        self.isDownloading = true
        self.downloadProgress = 0.0
        
        await loadModel()
    }
    
    func loadModel() async {
        do {
            print("Loading WhisperKit with model: \(currentModelName)")
            
            // Ensure model directory exists
            try? FileManager.default.createDirectory(at: modelStoragePath, withIntermediateDirectories: true)
            
            // Check if model exists locally in our custom storage
            let localModelURL = modelStoragePath.appendingPathComponent(currentModelName)
            let pipe: WhisperKit
            
            if FileManager.default.fileExists(atPath: localModelURL.path) {
                print("Found local model at: \(localModelURL.path)")
                // Use WhisperKitConfig with modelFolder for local models
                let config = WhisperKitConfig(modelFolder: localModelURL.path)
                pipe = try await WhisperKit(config)
            } else {
                print("Model not found locally, downloading default: \(currentModelName)")
                pipe = try await WhisperKit(model: currentModelName)
            }
            
            self.whisperKit = pipe
            
            DispatchQueue.main.async {
                self.isModelLoaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
                // Rescan to update list if a new model was downloaded
                self.scanModels()
            }
            print("WhisperKit loaded successfully")
            
        } catch {
            print("Error loading model: \(error)")
            DispatchQueue.main.async {
                self.isDownloading = false
            }
        }
    }
    
    func transcribe(audioPath: String) async throws -> String? {
        guard let whisperKit = whisperKit else { return nil }
        
        let result = try await whisperKit.transcribe(audioPath: audioPath)
        return result.map { $0.text }.joined(separator: " ")
    }
}
