import Foundation
import AppKit
import HotKey
import Carbon

class HotKeyService: ObservableObject {
    private var hotKey: HotKey?
    
    @Published var isListening = false
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    init() {
        // Default: Command + Shift + ;
        // We use Carbon key codes.
        // kVK_ANSI_Semicolon = 0x29 (41)
        
        self.hotKey = HotKey(key: .semicolon, modifiers: [.command, .shift])
        
        self.hotKey?.keyDownHandler = { [weak self] in
            print("HotKey Down")
            self?.onKeyDown?()
        }
        
        self.hotKey?.keyUpHandler = { [weak self] in
            print("HotKey Up")
            self?.onKeyUp?()
        }
    }
    
    func updateKey(key: Key, modifiers: NSEvent.ModifierFlags) {
        self.hotKey = HotKey(key: key, modifiers: modifiers)
    }
}
