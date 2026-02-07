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
                if !appState.modelManager.availableModels.isEmpty {
                    Picker("Select Model", selection: Binding(
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
                } else {
                    Text(appState.modelManager.currentModelName)
                }
                
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
                Link("Open Models Folder", destination: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MacSpeechToText/Models"))
                    .font(.caption)
            }
        }
        .padding()
        .onAppear {
            appState.modelManager.scanModels()
        }
    }
}
