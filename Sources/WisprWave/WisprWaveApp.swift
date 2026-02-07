import SwiftUI
import AppKit

@main
struct WisprWaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("WisprWave", systemImage: "mic.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            SettingsView(appState: AppState.shared)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Hide Dock Icon (Make it an agent app)
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cancel any active downloads synchronously
        // Since we are on MainActor, we can call this directly to ensure it runs before exit
        AppState.shared.modelManager.cancelDownload()
    }
}
