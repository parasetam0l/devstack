import DevStackCore
import SwiftUI

/// Column widths shared by every service row, so pickers, states and buttons
/// line up down a section.
enum ServiceRowLayout {
    static let selector: CGFloat = 220
    static let status: CGFloat = 84
    static let button: CGFloat = 62
}

/// A service in a form section: what it is, which version, its state and its
/// controls. `service` is nil while the service is left out of the stack.
struct ServiceRow<Selector: View, MenuItems: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let symbol: String
    let detail: String
    let service: ServiceKind?
    @ViewBuilder var selector: Selector
    @ViewBuilder var menuItems: MenuItems

    private var phase: ServicePhase { service.map { model.serviceState($0).phase } ?? .stopped }
    private var running: Bool { phase == .running }

    var body: some View {
        HStack(spacing: 12) {
            ServiceRowTitle(title: title, symbol: symbol, detail: detail)
            Spacer(minLength: 12)
            selector
                .labelsHidden()
                .disabled(model.isBusy || running)
                .help(running ? "Stop \(title) before changing its version." : "Choose the \(title) version")
                .frame(width: ServiceRowLayout.selector, alignment: .trailing)
            if let service {
                StatusLabel(phase).frame(width: ServiceRowLayout.status, alignment: .leading)
                Button(running ? "Stop" : "Start") {
                    Task { if running { await model.stopService(service) } else { await model.startService(service) } }
                }
                .frame(width: ServiceRowLayout.button)
                .disabled(model.isBusy || !model.runtimeIsAvailable(service.runtimeID))
                .accessibilityLabel("\(running ? "Stop" : "Start") \(title)")
                Menu {
                    Button("Show Logs") { model.showLogs(for: service) }
                    Button("Restart") { Task { await model.restartService(service) } }
                        .disabled(model.isBusy || !running)
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More \(title) actions")
                .accessibilityLabel("\(title) actions")
            } else {
                StatusLabel(title: "Off", color: Color(nsColor: .tertiaryLabelColor))
                    .frame(width: ServiceRowLayout.status, alignment: .leading)
                ServiceRowSpacer()
            }
        }
        .padding(.vertical, 2)
    }
}

extension ServiceRow where MenuItems == EmptyView {
    init(title: String, symbol: String, detail: String, service: ServiceKind?, @ViewBuilder selector: () -> Selector) {
        self.init(title: title, symbol: symbol, detail: detail, service: service, selector: selector) { EmptyView() }
    }
}

struct ServiceRowTitle: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        } icon: {
            // A fixed column, so titles line up whatever the symbol's width.
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
        }
    }
}

/// Keeps a row without a Start/Stop button and menu aligned with the others.
struct ServiceRowSpacer: View {
    var body: some View {
        Color.clear.frame(width: ServiceRowLayout.button + 12 + 22, height: 1)
    }
}
