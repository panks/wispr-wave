import Foundation
import AppKit
import HotKey
import Carbon

class HotKeyService: ObservableObject {
    private var hotKey: HotKey?
    
    @Published var isListening = false
    @Published var currentKey: Key = .semicolon
    @Published var currentModifiers: NSEvent.ModifierFlags = [.command, .shift]
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    var isPaused = false {
        didSet {
            hotKey?.isPaused = isPaused
        }
    }
    
    // UserDefaults keys
    private let hotkeyKeyCodeKey = "WisprWave.HotkeyKeyCode"
    private let hotkeyModifiersKey = "WisprWave.HotkeyModifiers"
    
    init() {
        // Load saved hotkey or use default
        if let savedKeyCode = UserDefaults.standard.value(forKey: hotkeyKeyCodeKey) as? UInt32,
           let savedModifiers = UserDefaults.standard.value(forKey: hotkeyModifiersKey) as? UInt,
           let key = Key(carbonKeyCode: savedKeyCode) {
            let modifiers = NSEvent.ModifierFlags(rawValue: savedModifiers)
            currentKey = key
            currentModifiers = modifiers
            setupHotKey(key: key, modifiers: modifiers)
        } else {
            // Default Cmd+Shift+;
            currentKey = .semicolon
            currentModifiers = [.command, .shift]
            setupHotKey(key: .semicolon, modifiers: [.command, .shift])
            saveHotKey(key: .semicolon, modifiers: [.command, .shift])
        }
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
        currentKey = key
        currentModifiers = modifiers
        setupHotKey(key: key, modifiers: modifiers)
        saveHotKey(key: key, modifiers: modifiers)
    }
    
    private func saveHotKey(key: Key, modifiers: NSEvent.ModifierFlags) {
        UserDefaults.standard.set(key.carbonKeyCode, forKey: hotkeyKeyCodeKey)
        UserDefaults.standard.set(modifiers.rawValue, forKey: hotkeyModifiersKey)
    }
}
