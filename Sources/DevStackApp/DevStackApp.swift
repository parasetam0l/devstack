import AppKit
import DevStackCore
import SwiftUI

@main
struct DevStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.makeForLaunch()

    var body: some Scene {
        WindowGroup("DevStack", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear {
                    appDelegate.model = model
                    NSApp.applicationIconImage = DevStackDesign.icon
                    appDelegate.configureWindow()
                }
        }
        .defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Site…") { model.requestNewSite() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selectedSection = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Workspace") {
                ForEach(Array(NavigationSection.allCases.enumerated()), id: \.element.id) { index, section in
                    Button(section.rawValue) { model.selectedSection = section }
                        .keyboardShortcut(KeyEquivalent(Character(index < 9 ? String(index + 1) : "0")))
                }
                Divider()
                #if DEBUG
                Button("Compact Review Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 820, height: 540)) }
                Button("Default Review Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 920, height: 620)) }
                Divider()
                #endif
                Button("Start Stack") { Task { await model.startAll() } }.disabled(model.isBusy || model.stackIsRunning)
                Button("Stop Stack") { Task { await model.stopAll() } }.disabled(model.isBusy || !model.hasRunningServices)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(nsImage: DevStackDesign.menuBarIcon).accessibilityLabel("DevStack")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isFinishingTermination = false

    func configureWindow() {
        Task { @MainActor in
            // The window may not be registered or laid out yet when SwiftUI recreates
            // it through openWindow, so poll briefly instead of giving up.
            for _ in 0..<40 {
                if let window = MainWindowLocator.current {
                    window.contentMaxSize = NSSize(width: 1100, height: window.contentMaxSize.height)
                    window.collectionBehavior.remove(.fullScreenPrimary)
                    window.collectionBehavior.insert(.fullScreenNone)
                    if let size = window.contentView?.bounds.size, size.width > 920 || size.height > 620 {
                        window.setContentSize(NSSize(width: min(size.width, 920), height: min(size.height, 620)))
                        window.center()
                    }
                    widenSidebarIfNeeded(window)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Older builds stored a ~144 pt sidebar in the split view autosave, which
    /// overrides navigationSplitViewColumnWidth on restore. Widen it once per
    /// launch so the sidebar labels are never truncated.
    private func widenSidebarIfNeeded(_ window: NSWindow) {
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let splitView = Self.firstSplitView(in: window.contentView),
                      splitView.arrangedSubviews.count >= 2 else { return }
                let sidebar = splitView.arrangedSubviews[0]
                guard sidebar.frame.width < 190 else { return }
                splitView.setPosition(210, ofDividerAt: 0)
            }
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView { return splitView }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingTermination, let model, model.hasRunningServices else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Stop DevStack services before quitting?"
        alert.informativeText = "DevStack services are still running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Services and Quit")
        alert.addButton(withTitle: "Quit Without Stopping")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            isFinishingTermination = true
            Task { @MainActor in
                await model.stopAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

// SwiftUI wraps the app delegate, so NSApp.delegate is not AppDelegate; both the
// delegate and the model use this locator instead of casting.
@MainActor
enum MainWindowLocator {
    static var current: NSWindow? {
        NSApp.windows.first { window in
            !(window is NSPanel) && (window.contentView?.bounds.width ?? 0) >= 820
        }
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ForEach(model.dashboardServices) { service in
            let state = model.serviceState(service)
            Menu {
                Button(state.phase == .running ? "Stop" : "Start") {
                    Task {
                        if state.phase == .running { await model.stopService(service) }
                        else { await model.startService(service) }
                    }
                }.disabled(model.isBusy)
                Button("Restart") { Task { await model.restartService(service) } }.disabled(model.isBusy || state.phase != .running)
            } label: {
                Label("\(service.displayName) · \(state.phase.rawValue.capitalized)", systemImage: state.phase.symbol)
            }
        }
        Divider()
        let dnsRunning = model.helperStatus?.dnsEnabled == true
        Menu {
            Button(dnsRunning ? "Stop" : "Start") {
                Task { await model.setLocalNetworkAccess(!dnsRunning) }
            }.disabled(model.isBusy || !model.helperInstalled)
        } label: {
            Label("Local DNS · \(dnsRunning ? "Running" : "Stopped")", systemImage: "wifi.router")
        }
        Divider()
        Button("Open DevStack") {
            model.showMainWindow()
        }
        Button("Start All") { Task { await model.startAll() } }
            .disabled(model.isBusy || model.stackIsRunning)
        Button("Stop All") { Task { await model.stopAll() } }
            .disabled(model.isBusy || !model.hasRunningServices)
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

extension ServicePhase {
    var symbol: String {
        switch self {
        case .stopped: "circle"
        case .starting, .stopping: "clock"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
