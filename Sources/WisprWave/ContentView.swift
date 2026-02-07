import SwiftUI

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        VStack(spacing: 16) {
            
            // --- Header: Master Toggle ---
            VStack {
                Button(action: {
                    appState.isAppEnabled.toggle()
                }) {
                    Text(appState.isAppEnabled ? "ON" : "OFF")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 120, height: 60)
                        .background(appState.isAppEnabled ? Color.green : Color.red)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                // Status Text
                if !appState.isAppEnabled {
                    Text("App Disabled")
                        .foregroundStyle(.secondary)
                } else if let modelId = appState.modelManager.currentModelName {
                    // Find the display name for the model
                    let displayName = appState.modelManager.supportedModels.first(where: { $0.id == modelId })?.name ?? modelId
                    let status = appState.modelManager.isModelLoaded ? "Using model \(displayName)" : "Loading \(displayName)..."
                    Text(status)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Download a Model")
                        .foregroundStyle(.secondary)
                        .foregroundColor(.orange)
                }
            }
            .padding(.top, 10)
            
            Divider()
            
            // --- Model List ---
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(appState.modelManager.supportedModels) { model in
                        ModelRow(model: model, appState: appState)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 150) // Fixed height for list
            
            Divider()
            
            // --- Footer: Download Progress & Hotkey ---
            VStack(spacing: 8) {
                if appState.modelManager.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Downloading...")
                                .font(.caption)
                            Spacer()
                            Button(action: {
                                appState.modelManager.cancelDownload()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel Download")
                        }
                        ProgressView(value: appState.modelManager.downloadProgress)
                    }
                    .padding(.horizontal)
                }
                
                HotKeyRecorder(appState: appState)
                    .padding(.bottom, 4)
                
                Toggle("Legacy Mode (VM)", isOn: $appState.isLegacyMode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Use file-based recording (slower but more compatible)")
                
                HStack {
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(width: 320)
        .padding(.bottom, 10)
        .onAppear {
            appState.modelManager.scanModels()
        }
    }
}

struct ModelRow: View {
    let model: ModelsConfig.ModelInfo
    @ObservedObject var appState: AppState
    
    var isDownloaded: Bool {
        appState.modelManager.downloadedModels.contains(model.id)
    }
    
    var isActive: Bool {
        appState.modelManager.currentModelName == model.id && appState.modelManager.isModelLoaded
    }
    
    var body: some View {
        HStack {
            Text(model.name)
                .font(.system(size: 13))
                .lineLimit(1)
            
            Spacer()
            
            // Download Button
            Button(action: {
                Task {
                    await appState.modelManager.downloadModel(modelId: model.id)
                }
            }) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundColor(isDownloaded || appState.modelManager.isDownloading ? .gray : .blue)
            }
            .buttonStyle(.plain)
            .disabled(isDownloaded || appState.modelManager.isDownloading)
            
            // Power/Select Button
            Button(action: {
                Task {
                    await appState.modelManager.loadModel(name: model.id)
                }
            }) {
                Image(systemName: "power")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? .green : (isDownloaded ? .primary : .gray))
                    // "Only one model can be turned on at a time if the model is turned on the button is green"
                    // "if the model is not downloaded the button is grayed out/inactive"
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
        }
        .padding(6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }
}
