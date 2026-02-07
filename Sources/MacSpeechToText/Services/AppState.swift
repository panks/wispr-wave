import Foundation
import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var status: String = "Idle"
    @Published var isListening = false
    @Published var transcribedText: String = ""
    
    let hotKeyService = HotKeyService()
    let audioRecorder = AudioRecorder()
    let modelManager = ModelManager()
    let permissionManager = PermissionManager()
    
    var hudWindow: HudWindow?
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupHotKey()
        setupHud()
        
        // Load model on startup
        Task {
            await modelManager.loadModel()
        }
    }
    
    private func setupHud() {
        self.hudWindow = HudWindow()
        self.hudWindow?.setContentView(view: HudView(appState: self))
    }
    
    private func setupHotKey() {
        hotKeyService.onKeyDown = { [weak self] in
            self?.startListening()
        }
        
        hotKeyService.onKeyUp = { [weak self] in
            self?.stopListening()
        }
    }
    
    func startListening() {
        guard !isListening else { return }
        guard modelManager.isModelLoaded else {
            status = "Model Loading..."
            return
        }
        
        Task { @MainActor in
            do {
            if await audioRecorder.requestPermission() {
                try audioRecorder.startRecording()
                isListening = true
                status = "Listening..."
                hudWindow?.show()
            } else {
                status = "Permission Denied"
            }
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func stopListening() {
        guard isListening else { return }
        
        let audioFile = audioRecorder.stopRecording()
        isListening = false
        status = "Transcribing..."
        
        Task { @MainActor in
            do {
                if let text = try await modelManager.transcribe(audioPath: audioFile.path) {
                    transcribedText = text
                    status = "Done: \(text)"
                    
                    // Inject Text
                    TextInjector.shared.inject(text: text)
                    
                    print("Transcribed: \(text)")
                } else {
                    status = "Transcription Failed"
                }
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            
            // Reset to idle after a delay
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            if status.starts(with: "Done") || status.starts(with: "Error") {
                status = "Idle"
                hudWindow?.hide()
            }
        }
    }
}
