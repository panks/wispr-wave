import Foundation
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor
class PermissionManager: ObservableObject {
    @Published var isAccessibilityGranted: Bool = false
    
    private var timer: Timer?
    
    init() {
        checkAccessibilityPermission()
        if !isAccessibilityGranted {
            startPolling()
        }
    }
    
    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let granted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        DispatchQueue.main.async {
            self.isAccessibilityGranted = granted
            if granted {
                self.stopPolling()
            }
        }
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        // Start polling if not already
        if !isAccessibilityGranted {
            startPolling()
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
