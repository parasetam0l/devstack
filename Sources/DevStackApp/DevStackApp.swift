import AppKit
import DevStackCore
import SwiftUI

@main
struct DevStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DevStack") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 650)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1160, height: 760)

        MenuBarExtra("DevStack", systemImage: model.menuBarSymbol) {
            MenuBarView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isFinishingTermination = false

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
        ForEach(model.serviceStates) { state in
            Label(state.service.displayName, systemImage: state.phase.symbol)
        }
        Divider()
        Button("Open DevStack") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
        Button("Start All") { Task { await model.startAll() } }
            .disabled(model.isBusy)
        Button("Stop All") { Task { await model.stopAll() } }
            .disabled(model.isBusy)
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
        case .php74: "PHP 7.4"
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
