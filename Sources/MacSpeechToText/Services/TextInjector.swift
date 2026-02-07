import Foundation
import AppKit
@preconcurrency import ApplicationServices

@MainActor
class TextInjector {
    static let shared = TextInjector()
    
    func inject(text: String) {
        // Skip injection if text is empty
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        // Check accessibility permissions
        guard AXIsProcessTrusted() else {
            print("TextInjector: Accessibility permission not granted")
            return
        }
        
        // Set new text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Simulate Cmd+V
        simulatePasteCommand()
        
        // Note: We previously attempted to save/restore the clipboard,
        // but reading pasteboard items on the Main Actor can cause hangs
        // if the clipboard owner is unresponsive. For stability, we 
        // currently overwrite the clipboard without restoring.
    }
    
    private func simulatePasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Command key down
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true) else {
            print("TextInjector: Failed to create cmdDown event")
            return
        }
        cmdDown.flags = .maskCommand
        
        // 'V' key down
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            print("TextInjector: Failed to create vDown event")
            return
        }
        vDown.flags = .maskCommand
        
        // 'V' key up
        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("TextInjector: Failed to create vUp event")
            return
        }
        vUp.flags = .maskCommand
        
        // Command key up
        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            print("TextInjector: Failed to create cmdUp event")
            return
        }
        
        // Post events
        let loc = CGEventTapLocation.cghidEventTap
        cmdDown.post(tap: loc)
        vDown.post(tap: loc)
        vUp.post(tap: loc)
        cmdUp.post(tap: loc)

    }
}
