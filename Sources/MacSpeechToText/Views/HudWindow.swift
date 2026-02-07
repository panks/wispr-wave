import SwiftUI
import AppKit

class HudWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hidesOnDeactivate = false
    }
    
    func setContentView<Content: View>(view: Content) {
        self.contentViewController = NSHostingController(rootView: view)
    }
    
    func show() {
        // Center near cursor or bottom center of screen
        if let screen = NSScreen.main {
             let screenRect = screen.visibleFrame
             let windowRect = self.frame
             let x = (screenRect.width - windowRect.width) / 2 + screenRect.minX
             let y = screenRect.minY + 100 // Bottom area
             self.setFrameOrigin(NSPoint(x: x, y: y))
        }
        self.orderFront(nil)
    }
    
    func hide() {
        self.orderOut(nil)
    }
}

struct HudView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: appState.isListening)
            Text(appState.status)
                .font(.headline)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}
