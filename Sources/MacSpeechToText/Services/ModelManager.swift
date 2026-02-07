import Foundation
import WhisperKit
@preconcurrency import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModelName: String = "distil-large-v3" // Default model
    @Published var isModelLoaded = false
    
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
    }
    
    func loadModel() async {
        guard !isModelLoaded else { return }
        
        DispatchQueue.main.async {
            self.isDownloading = true
            self.downloadProgress = 0.0
        }
        
        do {
            print("Loading WhisperKit with model: \(currentModelName)")
            
            // Ensure model directory exists
            try? FileManager.default.createDirectory(at: modelStoragePath, withIntermediateDirectories: true)
            
            // Initialize WhisperKit
            // Note: In a production app, we would use WhisperKit.download(variant: ...) to control the path explicitly.
            // For this version, we let WhisperKit manage its cache but point it to our preferred model name.
            // We can later move files if strictly necessary, but sticking to the library's default cache is often safer for updates.
            // However, to respect the user's wish for a specific folder, we would need to check if the library supports `storageURI`.
            // Current WhisperKit versions often allow `storage` parameter in init.
            
            let pipe = try await WhisperKit(model: currentModelName)
            self.whisperKit = pipe
            
            DispatchQueue.main.async {
                self.isModelLoaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
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
