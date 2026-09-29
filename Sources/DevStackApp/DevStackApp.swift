import AppKit
import DevStackCore
import SwiftUI

@main
struct DevStackApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DevStack") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 650)
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit DevStack") {
                    Task {
                        await model.stopAll()
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q")
            }
        }

        MenuBarExtra("DevStack", systemImage: model.menuBarSymbol) {
            MenuBarView()
                .environmentObject(model)
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
            Task {
                await model.stopAll()
                NSApplication.shared.terminate(nil)
            }
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
