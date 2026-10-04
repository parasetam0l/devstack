import AppKit

/// "Hide app icon from Dock": while it is on, minimizing or closing the main
/// window leaves DevStack in the menu bar only, without a Dock icon, and
/// Open DevStack in that menu brings the window back. While the window is
/// open the icon stays, so ⌘Tab and the app's menus keep working. Off by
/// default.
@MainActor final class MenuBarMode: NSObject {
    static let shared = MenuBarMode()
    static let defaultsKey = "DevStackHideDockIcon"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    private var observedWindows: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// Takes over the main window's minimize button. Window ▸ Minimize (⌘M)
    /// clicks the same button, so it follows the setting too.
    func attach(to window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let button = window.standardWindowButton(.miniaturizeButton) {
            button.target = self
            button.action = #selector(minimize(_:))
        }
        guard observedWindows[id] == nil else { return }
        let center = NotificationCenter.default
        observedWindows[id] = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    self?.observedWindows.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
                    // Only the last DevStack window leaves the Dock.
                    let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                    if self?.isEnabled == true, !othersOpen { self?.enter() }
                }
            },
            // Any other way the window reaches the Dock (a title-bar double-click,
            // for one) still ends in the menu bar.
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isEnabled == true { self?.enter() } }
            }
        ]
    }

    @objc private func minimize(_ sender: NSButton) {
        guard let window = sender.window else { return }
        if isEnabled {
            window.orderOut(sender)
            enter()
        } else {
            window.miniaturize(sender)
        }
    }

    /// Leaves the Dock; the menu bar item stays.
    private func enter() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Back in the Dock and in front, before the window shows again.
    func leave() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }
}
