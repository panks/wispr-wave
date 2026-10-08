import Foundation
@preconcurrency import ApplicationServices
import AppKit
import SwiftUI

@MainActor
class PermissionManager: ObservableObject {
    @Published var isAccessibilityGranted: Bool = false

    private var timer: Timer?

    init() {
        checkAccessibilityPermission()
        // Always keep polling: the trust state can change at any time (user grants it
        // in System Settings, or it was a stale read at launch). Polling is cheap.
        startPolling()
    }

    /// Reads the *live* accessibility trust state for this exact process.
    func checkAccessibilityPermission() {
        // prompt:false — never show the system dialog from a passive check.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let granted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
        }
    }

    /// User asked to grant permission. Show the system prompt *and* open the exact
    /// Settings pane — the prompt alone often does nothing once the app already has a
    /// (stale) entry in the list, so the deep link is the reliable path.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openAccessibilitySettings()
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch the app. Needed when the grant was made against a previous build
    /// (ad-hoc signing changes the app's identity each build) or when the running
    /// process is holding a stale "untrusted" read — a fresh launch re-evaluates trust.
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibilityPermission()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
