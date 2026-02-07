import Foundation
import AppKit
@preconcurrency import ApplicationServices

@MainActor
class TextInjector {
    static let shared = TextInjector()
    
    func inject(text: String) {
        // 1. Save current clipboard
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { $0.copy() as! NSPasteboardItem } ?? []
        
        // 2. Set new text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // 3. Simulate Cmd+V
        simulatePasteCommand()
        
        // 4. Restore clipboard after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            pasteboard.writeObjects(oldItems)
        }
    }
    
    private func simulatePasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Command key down
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true) // kVK_Command
        cmdDown?.flags = .maskCommand
        
        // 'V' key down
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // kVK_ANSI_V
        vDown?.flags = .maskCommand
        
        // 'V' key up
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) // kVK_ANSI_V
        vUp?.flags = .maskCommand
        
        // Command key up
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) // kVK_Command
        
        // Post events
        let loc = CGEventTapLocation.cghidEventTap
        cmdDown?.post(tap: loc)
        vDown?.post(tap: loc)
        vUp?.post(tap: loc)
        cmdUp?.post(tap: loc)
    }
}
