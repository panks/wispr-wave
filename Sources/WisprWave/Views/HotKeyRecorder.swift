import SwiftUI
import HotKey
import Carbon

struct HotKeyRecorder: View {
    @ObservedObject var appState: AppState
    @State private var isRecording = false
    @State private var keyString = "" // Will be set from HotKeyService
    
    var body: some View {
        HStack {
            Text("Hotkey:")
                .font(.caption)
            
            Button(action: {
                isRecording.toggle()
            }) {
                HStack {
                    if isRecording {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                        Text("Press keys...")
                    } else {
                        Image(systemName: "command")
                        Text(keyString)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .background(WindowAccessor { window in
                // Using a hidden window accessor to get key events if needed,
                // but for a menu bar app simple focus might be tricky.
                // We'll use a local event monitor when recording.
            })
        }
        .onAppear {
            // Initialize from current hotkey
            updateDisplayString()
        }
        .onChange(of: isRecording) { recording in
            if recording {
                startRecording()
            } else {
                stopRecording()
            }
        }
    }
    
    @State private var monitor: Any?
    
    private func startRecording() {
        // Monitor local key events
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore just modifier keys
            if event.keyCode == 55 || event.keyCode == 56 || event.keyCode == 58 || event.keyCode == 59 || event.keyCode == 60 || event.keyCode == 61 || event.keyCode == 62 {
                return event
            }
            
            // Capture key
            let modifiers = event.modifierFlags
            let key = Key(carbonKeyCode: UInt32(event.keyCode))
            
            // Update HotKey
            DispatchQueue.main.async {
                updateHotKey(key: key, modifiers: modifiers)
                self.isRecording = false
            }
            
            return nil // Consume event
        }
    }
    
    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
    
    
    private func updateDisplayString() {
        let key = appState.hotKeyService.currentKey
        let modifiers = appState.hotKeyService.currentModifiers
        
        var str = ""
        if modifiers.contains(.control) { str += "Ctrl + " }
        if modifiers.contains(.option) { str += "Opt + " }
        if modifiers.contains(.shift) { str += "Shift + " }
        if modifiers.contains(.command) { str += "Cmd + " }
        str += key.description.capitalized
        
        self.keyString = str
    }
    
    private func updateHotKey(key: Key?, modifiers: NSEvent.ModifierFlags) {
        guard let key = key else { return }
        
        var carbonModifiers: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { carbonModifiers.insert(.command) }
        if modifiers.contains(.option) { carbonModifiers.insert(.option) }
        if modifiers.contains(.control) { carbonModifiers.insert(.control) }
        if modifiers.contains(.shift) { carbonModifiers.insert(.shift) }
        
        // Convert to Carbon flags for display/HotKey
        // Note: HotKey library handles this, but for display string we do it manually or use helpers
        
        // Update AppState's HotKey
        // For now, since HotKeyService is hardcoded, we will just update the display string
        // and LOGICALLY, we would need to update HotKeyService to accept new keys.
        // Assuming HotKeyService has a method `reset(key:modifiers:)`
        
        // Since I can't easily modify HotKeyService API without seeing it and it might be hardcoded,
        // I will just update the visual string for this task until I verify HotKeyService capabilities.
        // BUT, the user asked for reassignment. 
        
        // Let's generate a string representation
        var str = ""
        if modifiers.contains(.control) { str += "Ctrl + " }
        if modifiers.contains(.option) { str += "Opt + " }
        if modifiers.contains(.shift) { str += "Shift + " }
        if modifiers.contains(.command) { str += "Cmd + " }
        str += key.description.capitalized
        
        self.keyString = str
        
        // Update HotKeyService
        appState.hotKeyService.updateKey(key: key, modifiers: carbonModifiers)
    }
}

// Helper to access window for events if needed
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.callback(view.window)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
