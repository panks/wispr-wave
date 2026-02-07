import SwiftUI

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Text("WisprWave")
                .font(.headline)
            
            Text("Status: \(appState.status)")
                .foregroundStyle(.secondary)
            
            // Model Picker
            if !appState.modelManager.availableModels.isEmpty {
                Picker("Model", selection: Binding(
                    get: { appState.modelManager.currentModelName },
                    set: { newValue in
                        Task {
                            await appState.modelManager.checkAndLoadModel(name: newValue)
                        }
                    }
                )) {
                    ForEach(appState.modelManager.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            } else {
                 Text("Model: \(appState.modelManager.currentModelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if !appState.permissionManager.isAccessibilityGranted {
                VStack {
                    Text("Accessibility Permission Required")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Grant Permission") {
                        appState.permissionManager.requestAccessibilityPermission()
                    }
                }
            } else if appState.modelManager.isDownloading {
                ProgressView("Downloading...", value: appState.modelManager.downloadProgress, total: 1.0)
                    .padding()
            }
            
            Divider()
            
            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 300, height: 250) // Increased height for picker
        .onAppear {
            appState.modelManager.scanModels()
        }
    }
}
