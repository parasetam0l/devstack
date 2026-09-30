import AppKit
import DevStackCore
import SwiftUI

@main
struct DevStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.makeForLaunch()

    var body: some Scene {
        WindowGroup("DevStack") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear {
                    appDelegate.model = model
                    NSApp.applicationIconImage = DevStackDesign.icon
                    appDelegate.limitWindowWidth()
                }
        }
        .defaultSize(width: 1200, height: 800)
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
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
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

    func limitWindowWidth() {
        Task { @MainActor in
            await Task.yield()
            for window in NSApp.windows where window.contentView?.bounds.width ?? 0 >= 1000 {
                window.contentMaxSize = NSSize(width: 1400, height: window.contentMaxSize.height)
                if let size = window.contentView?.bounds.size, size.width > 1400 {
                    window.setContentSize(NSSize(width: 1400, height: size.height))
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingTermination, let model, model.hasRunningServices else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Stop DevStack services before quitting?"
        alert.informativeText = "Apache, PHP, MySQL, or Mailpit are still running."
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
        Button("Open DevStack") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
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

extension ServiceKind {
    var displayName: String {
        switch self {
        case .apache: "Apache"
        case .nginx: "Nginx"
        case .php74: "PHP 7.4"
        case .php84: "PHP 8.4"
        case .php85: "PHP 8.5"
        case .mysql57: "MySQL 5.7"
        case .mysql84: "MySQL 8.4"
        case .mailpit: "Mailpit"
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
