import Foundation
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor
class PermissionManager: ObservableObject {
    @Published var isAccessibilityGranted: Bool = false
    
    init() {
        checkAccessibilityPermission()
    }
    
    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
