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
        let previousTask = lastInjectionTask
        lastInjectionTask = Task.detached(priority: .userInitiated) {
             // Wait for previous task
            _ = await previousTask?.value
            
            // 1. Save current clipboard (on background thread)
            // ... (rest of the logic)
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
        vUp.post(tap: loc)
        cmdUp.post(tap: loc)
    }

    // Serial Queue
    private var lastInjectionTask: Task<Void, Never>?
    
    func reset() {
        lastInjectionTask?.cancel()
        lastInjectionTask = nil
    }
    
    func injectDiff(old: String, new: String) {
        let oldWords = old.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let newWords = new.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // Find common word prefix
        var commonCount = 0
        let minCount = min(oldWords.count, newWords.count)
        while commonCount < minCount && oldWords[commonCount] == newWords[commonCount] {
            commonCount += 1
        }
        
        let wordsToRemove = oldWords.count - commonCount
        let wordsToAdd = newWords.suffix(from: commonCount).joined(separator: " ")
        
        // Chain task
        let previousTask = lastInjectionTask
        lastInjectionTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask?.value
            
            // 1. Delete words if needed
            if wordsToRemove > 0 {
                // Option+Backspace * N
                await self.simulateWordBackspace(count: wordsToRemove)
            }
            
            // 2. Inject new text
            if !wordsToAdd.isEmpty {
                var textToType = wordsToAdd
                // Add leading space if we are appending (no deletion) and there is a prefix
                if wordsToRemove == 0 && commonCount > 0 {
                    textToType = " " + textToType
                }
                
                await self.injectSequence(text: textToType)
            }
        }
    }
    
    @MainActor
    private func simulateWordBackspace(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        // Hold Option
        let flags: CGEventFlags = [.maskAlternate]
        
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) { // 0x33 is Delete
                down.flags = flags
                down.post(tap: loc)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                up.flags = flags
                up.post(tap: loc)
            }
            try? Thread.sleep(forTimeInterval: 0.05) // 50ms per word
        }
    }
    
    private func injectSequence(text: String) async {
        let pasteboard = NSPasteboard.general
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
        
        await MainActor.run {
             let pb = NSPasteboard.general
             pb.clearContents()
             pb.setString(text, forType: .string)
        }
        
        await self.simulatePasteCommand()
        
        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
        
        await MainActor.run {
             let pb = NSPasteboard.general
             pb.clearContents()
             pb.writeObjects(oldItems)
        }
    }

    @MainActor
    private func simulateBackspace(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) { // 0x33 is Delete
                down.post(tap: loc)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                up.post(tap: loc)
            }
            // Small delay to ensure apps process it
            try? Thread.sleep(forTimeInterval: 0.03) // 30ms
        }
    }
}
