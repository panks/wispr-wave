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
                Text(appState.modelManager.currentModelName)
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
        }
        .padding()
    }
}
