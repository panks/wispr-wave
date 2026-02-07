import Foundation
import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var status: String = "Idle"
    @Published var isListening = false
    @Published var isAppEnabled = true // Master toggle
    @Published var transcribedText: String = ""
    
    let hotKeyService = HotKeyService()
    let audioRecorder = AudioRecorder()
    @Published var modelManager = ModelManager()
    let permissionManager = PermissionManager()
    
    var hudWindow: HudWindow?
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupHotKey()
        setupHud()
        
        // Forward ModelManager's objectWillChange to AppState's objectWillChange
        // This ensures that when ModelManager properties change, AppState notifies its observers
        modelManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        // Auto-load last used model after scanning
        Task {
            modelManager.scanModels()
            await modelManager.loadLastUsedModel()
        }
    }
    
    private func setupHud() {
        self.hudWindow = HudWindow()
        self.hudWindow?.setContentView(view: HudView(appState: self))
    }
    
    private func setupHotKey() {
        // Toggle mode: only respond to keyUp, ignore keyDown repeats
        hotKeyService.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.toggleListening()
            }
        }
    }
    
    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
    
    func startListening() {
        print("startListening called - isListening: \(isListening), modelLoaded: \(modelManager.isModelLoaded)")
        guard !isListening else {
            print("Already listening, returning")
            return
        }
        
        // Master switch check
        guard isAppEnabled else {
            print("App is disabled")
            status = "App Disabled"
            return
        }
        
        guard modelManager.isModelLoaded else {
            print("Model not loaded yet")
            status = "Model Not Loaded"
            return
        }
        
        Task { @MainActor in
            do {
            if await audioRecorder.requestPermission() {
                print("Permission granted, starting recording...")
                try audioRecorder.startRecording()
                isListening = true
                status = "Listening..."
                print("Recording started, status: \(status)")
                hudWindow?.show()
            } else {
                print("Permission denied")
                status = "Permission Denied"
            }
            } catch {
                print("Error starting recording: \(error)")
                status = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func stopListening() {
        print("stopListening called - isListening: \(isListening)")
        guard isListening else {
            print("Not listening, returning")
            return
        }
        
        // Optimistic UI Update: immediately reflect state change
        isListening = false
        status = "Finishing..."
        hudWindow?.hide() // Hide immediately as requested by user
        
        Task { @MainActor in
            // Yield execution to allow the UI to render the "Finishing..." state
            // This prevents the "freeze" feeling while the recorder stops
            try? await Task.sleep(nanoseconds: 50 * 1_000_000) // 50ms buffer
            
            let audioSamples = audioRecorder.stopRecording()
            print("Recording stopped, captured \(audioSamples.count) samples")
            
            status = "Transcribing..."
            
            do {
                print("Starting transcription...")
                if let text = try await modelManager.transcribe(audioSamples: audioSamples) {
                    transcribedText = text
                    status = "Done: \(text)"
                    
                    // Inject Text
                    print("Injecting text: \(text)")
                    TextInjector.shared.inject(text: text)
                    
                    print("Transcribed: \(text)")
                } else {
                    print("Transcription returned nil")
                    status = "Transcription Failed"
                }
            } catch {
                print("Transcription error: \(error)")
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
