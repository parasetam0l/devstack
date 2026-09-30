import AppKit
import SwiftUI

// A native behind-window backdrop gives Liquid Glass the desktop to sample.
// The controls still use SwiftUI's glassEffect; this view supplies the window surface.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            let height = window.contentMaxSize.height
            window.contentMaxSize = NSSize(width: 1400, height: height)
        }
    }
}
