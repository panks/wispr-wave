import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            ModelSettingsView(appState: appState)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
        }
        .frame(width: 400, height: 300)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if appState.permissionManager.isAccessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant") {
                            appState.permissionManager.requestAccessibilityPermission()
                        }
                    }
                }
                
                HStack {
                    Text("Microphone")
                    Spacer()
                    // Basic check, real app would check AVCaptureDevice auth status
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green) 
                }
            }
            
            Section("HotKey") {
                Text("Current: Cmd + Shift + ;")
                    .foregroundStyle(.secondary)
                // TODO: HotKey recorder
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Current Model") {
                Picker("Select Model", selection: Binding(
                    get: { appState.modelManager.currentModelName ?? "" },
                    set: { newValue in
                        Task {
                            if !newValue.isEmpty {
                                // In Settings, we assume user wants to switch to an already downloaded model
                                // or we trigger download? 
                                // Let's simplify: only show downloaded models in this picker
                                await appState.modelManager.loadModel(name: newValue)
                            }
                        }
                    }
                )) {
                    Text("None").tag("")
                    ForEach(appState.modelManager.supportedModels) { model in
                        // Only show if downloaded
                        if appState.modelManager.downloadedModels.contains(model.id) {
                            Text(model.name).tag(model.id)
                        }
                    }
                }
                
                // If model not downloaded, maybe show a hint?
                // For now, simpler to just list downloaded ones.
                
                Button("Refresh Models") {
                    appState.modelManager.scanModels()
                }
            }
            
            if appState.modelManager.isDownloading {
                Section("Status") {
                    ProgressView(value: appState.modelManager.downloadProgress)
                    Text("Downloading... \(Int(appState.modelManager.downloadProgress * 100))%")
                        .font(.caption)
                }
            } else {
                Text(appState.modelManager.isModelLoaded ? "Model Loaded Ready" : "Model Not Loaded")
                    .foregroundStyle(appState.modelManager.isModelLoaded ? .green : .orange)
            }
            
            Section("Model Storage") {
                Text("Place complete WhisperKit model folders in:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Open Models Folder", destination: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("WisprWave/Models"))
                    .font(.caption)
            }
        }
        .padding()
        .onAppear {
            appState.modelManager.scanModels()
        }
    }
}
