import Foundation
import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var status: String = "Idle"
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isAppEnabled = true // Master toggle
    @Published var transcribedText: String = ""
    @Published var activeAppIcon: NSImage? = nil
    @Published var isLegacyMode: Bool = UserDefaults.standard.bool(forKey: "WisprWave.IsLegacyMode") {
        didSet {
            UserDefaults.standard.set(isLegacyMode, forKey: "WisprWave.IsLegacyMode")
        }
    }
    @Published var isBoostMode: Bool = UserDefaults.standard.bool(forKey: "WisprWave.IsBoostMode") {
        didSet {
            UserDefaults.standard.set(isBoostMode, forKey: "WisprWave.IsBoostMode")
        }
    }
    
    let hotKeyService = HotKeyService()
    let audioRecorder = AudioRecorder()
    @Published var modelManager = ModelManager()
    @Published var permissionManager = PermissionManager()
    
    var hudWindow: HudWindow?
    
    private var cancellables = Set<AnyCancellable>()
    private var streamingTask: Task<Void, Never>?
    private var injectionTask: Task<Void, Error>?
    private var lastInjectedText: String = ""
    
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
                // Capture active app icon
                self.activeAppIcon = NSWorkspace.shared.frontmostApplication?.icon
                
                print("Permission granted, starting recording...")
                // Audio Feedback
                NSSound(named: "Tink")?.play()
                
                try audioRecorder.startRecording(useLegacy: isLegacyMode)
                isListening = true
                transcribedText = "" // Reset
                lastInjectedText = ""
                status = "Listening..."
                print("Recording started, status: \(status)")
                hudWindow?.show()
                
                // Start Streaming Task if not legacy and Boost Mode is ON
                if !isLegacyMode && isBoostMode, let audioStream = audioRecorder.audioStream {
                    print("Starting streaming task...")
                    streamingTask = Task {
                        do {
                            // Get the text stream
                            let textStream = modelManager.transcribe(stream: audioStream)
                            
                            for try await partialText in textStream {
                                print("AppState: Received partial text: '\(partialText)'")
                                // Update UI on MainActor
                                await MainActor.run {
                                    self.transcribedText = partialText
                                    self.status = partialText.isEmpty ? "Listening..." : partialText
                                    
                                    self.transcribedText = partialText
                                    self.status = partialText.isEmpty ? "Listening..." : partialText
                                    
                                    // Live Injection Disabled by User Request (Performance/Reliability)
                                    // We only update the UI here.
                                    /*
                                    // Debounced Live Injection
                                    self.injectionTask?.cancel()
                                    self.injectionTask = Task {
                                        // Wait for debounce
                                        try? await Task.sleep(nanoseconds: 200 * 1_000_000) // 200ms
                                        
                                        if Task.isCancelled { return }
                                        
                                        let current = self.transcribedText
                                        let old = self.lastInjectedText
                                        
                                        if current != old {
                                            print("AppState: Injecting diff. Old len: \(old.count), New len: \(current.count)")
                                            TextInjector.shared.injectDiff(old: old, new: current)
                                            self.lastInjectedText = current
                                        }
                                    }
                                    */
                                }
                            }
                            print("Streaming task finished loop")
                        } catch {
                            print("Streaming error: \(error)")
                            await MainActor.run {
                                self.status = "Error: \(error.localizedDescription)"
                            }
                        }
                    }
                }
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
        
        // Audio Feedback
        NSSound(named: "Pop")?.play()
        
        guard isListening else {
            print("Not listening, returning")
            return
        }
        
        // Optimistic UI Update: immediately reflect state change
        isListening = false
        isProcessing = true
        status = "Processing..."
        
        Task { @MainActor in
            // Yield execution to allow the UI to render the "Finishing..." state
            try? await Task.sleep(nanoseconds: 50 * 1_000_000) // 50ms buffer
            
            // Stop recording (closes the stream if active)
            let audioSamples = audioRecorder.stopRecording()
            
            if !isLegacyMode {
                // Check if we were streaming
                if let task = streamingTask {
                    print("Waiting for streaming task to complete...")
                    // Wait for the streaming loop to process the final chunks
                    _ = await task.value
                    streamingTask = nil
                    injectionTask?.cancel() // Cancel any pending debounce
                    
                    let text = transcribedText
                    // Hide HUD right before injection
                    isProcessing = false
                    hudWindow?.hide()
                    // Inject the final text
                    if !text.isEmpty {
                         print("Injecting final text...")
                         TextInjector.shared.reset() // Clear any pending tasks
                         TextInjector.shared.inject(text: text)
                    }
                    
                    print("Streaming complete. Final text: \(text)")
                    
                    if !text.isEmpty {
                        status = "Done"
                        print("Streaming complete. Text fully injected.")
                    } else {
                        status = "No speech detected"
                    }
                } else {
                    // Boost Mode OFF: Full buffer transcription
                    print("Boost Mode OFF: Transcribing full buffer...")
                    status = "Transcribing..."
                    
                    do {
                        if let text = try await modelManager.transcribe(audioSamples: audioSamples) {
                            transcribedText = text
                            status = "Done: \(text)"
                            
                            // Hide HUD right before injection
                            isProcessing = false
                            hudWindow?.hide()
                            
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
                }
            } else {
                // Legacy Mode Flow
                print("Legacy mode: using full buffer transcription")
                print("Recording stopped, captured \(audioSamples.count) samples")
                
                status = "Transcribing..."
                
                do {
                    print("Starting transcription...")
                    if let text = try await modelManager.transcribe(audioSamples: audioSamples) {
                        transcribedText = text
                        status = "Done: \(text)"
                        
                        // Hide HUD right before injection
                        isProcessing = false
                        hudWindow?.hide()
                        
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
            }
            
            // Ensure HUD is hidden if we got here without injecting (e.g. error/empty)
            if isProcessing {
                isProcessing = false
                hudWindow?.hide()
            }
            
            // Reset to idle after a delay
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            if status.starts(with: "Done") || status.starts(with: "Error") || status == "No speech detected" {
                status = "Idle"
            }
        }
    }
}
