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
        
        // Use a background task to save/restore clipboard to avoid Main Thread hangs
        Task.detached(priority: .userInitiated) {
            // 1. Save current clipboard (on background thread)
            // Accessed directly to avoid capturing non-Sendable instance across actors
            let pasteboard = NSPasteboard.general
            // NSPasteboardItem does not conform to NSCopying, so we must manually copy data
            var oldItems: [NSPasteboardItem] = []
            if let params = pasteboard.pasteboardItems {
                for item in params {
                    let newItem = NSPasteboardItem()
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            newItem.setData(data, forType: type)
                        }
                    }
                    oldItems.append(newItem)
                }
            }
            
            // 2. Set new text (must be done effectively immediately before pasting)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            
            // 3. Simulate Cmd+V
            await self.simulatePasteCommand()
            
            // 4. Restore clipboard after a delay
            try? await Task.sleep(nanoseconds: 500 * 1_000_000) // 0.5 seconds
            
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(oldItems)
            }
        }
    }
    
    @MainActor
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
