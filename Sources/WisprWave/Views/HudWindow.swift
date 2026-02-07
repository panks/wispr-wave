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
        HStack(spacing: 12) {
            if let icon = appState.activeAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            
            // Replaces Mic Icon with Animation
            if appState.isListening {
                RecordingWaveView()
                    .frame(height: 20)
                    .padding(.horizontal, 4)
            }
            
            Text(appState.status)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Material.ultraThin)
        .cornerRadius(10)
        .padding(1) // Border-like effect container if needed
    }
}

struct RecordingWaveView: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray)
                    .frame(width: 3, height: isAnimating ? CGFloat.random(in: 8...20) : 4)
                    .animation(
                        Animation.easeInOut(duration: 0.35)
                            .repeatForever()
                            .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}
