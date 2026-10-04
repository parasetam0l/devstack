import AppKit
import SwiftUI

// A native behind-window backdrop gives Liquid Glass the desktop to sample.
// The controls use devStackGlass (Liquid Glass on macOS 26 and later); this
// view supplies the window surface.
struct WindowBackdrop: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

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
            context.coordinator.observe(window)
        }
    }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var observation: NSObjectProtocol?

        func observe(_ window: NSWindow) {
            if self.window !== window {
                if let observation { NotificationCenter.default.removeObserver(observation) }
                self.window = window
                observation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.applyLimits() }
                }
            }
            applyLimits()
        }

        private func applyLimits() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            // SwiftUI can reinsert AppKit's default toggle while restoring a toolbar.
            // Keep the explicit compact control in RootView as the only toggle.
            if let toolbar = window.toolbar {
                for index in toolbar.items.indices.reversed() where toolbar.items[index].itemIdentifier == .toggleSidebar {
                    toolbar.removeItem(at: index)
                }
            }
            window.contentMaxSize = NSSize(width: 1100, height: window.contentMaxSize.height)
            let maximumFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1100, height: 1))
            window.maxSize = NSSize(width: maximumFrame.width, height: window.maxSize.height)
            if let size = window.contentView?.bounds.size, size.width > 1100 {
                window.setContentSize(NSSize(width: 1100, height: size.height))
            }
        }

        isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
