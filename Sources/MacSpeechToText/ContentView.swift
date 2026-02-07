import SwiftUI

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Text("MacSpeechToText")
                .font(.headline)
            
            Text("Status: \(appState.status)")
                .foregroundStyle(.secondary)
            
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
                ProgressView("Downloading Model...", value: appState.modelManager.downloadProgress, total: 1.0)
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
        .frame(width: 300, height: 200)
    }
}
