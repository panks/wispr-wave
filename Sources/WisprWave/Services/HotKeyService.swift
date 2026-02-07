import Foundation
import AppKit
import HotKey
import Carbon

class HotKeyService: ObservableObject {
    private var hotKey: HotKey?
    
    @Published var isListening = false
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    var isPaused = false {
        didSet {
            hotKey?.isPaused = isPaused
        }
    }
    
    init() {
        // Default Cmd+Shift+;
        // 0x29 is semicolon on US keyboard
        // 0x37 is Command (handled by modifiers)
        // 0x38 is Shift (handled by modifiers)
        // Carbon key codes are tricky, usually best to stick to Carbon.Key if possible or use the library's Key enum
        // HotKey library Key.semicolon
        
        setupHotKey(key: .semicolon, modifiers: [.command, .shift])
    }
    
    func setupHotKey(key: Key, modifiers: NSEvent.ModifierFlags) {
        hotKey = HotKey(key: key, modifiers: modifiers)
        
        hotKey?.keyDownHandler = { [weak self] in
            print("HotKey Down")
            self?.onKeyDown?()
        }
        
        hotKey?.keyUpHandler = { [weak self] in
            print("HotKey Up")
            self?.onKeyUp?()
        }
    }
    
    func updateKey(key: Key, modifiers: NSEvent.ModifierFlags) {
        // Pause/Invalidate old one
        hotKey = nil
        setupHotKey(key: key, modifiers: modifiers)
    }
}
