import DevStackCore
import SwiftUI

/// Column widths shared by service rows, so names, addresses, states and
/// controls line up down a panel.
enum ServiceRowLayout {
    static let title: CGFloat = 168
    static let state: CGFloat = 84
    static let controls: CGFloat = 104
}

/// One service on one line: a state dot, the name and version, where it
/// listens, its state and its controls.
struct ServiceLine<Title: View, Controls: View, MenuItems: View>: View {
    let symbol: String
    let dot: Color
    let state: String
    var stateTint: Color = .secondary
    var stateHelp: String?
    let address: String
    @ViewBuilder var title: Title
    @ViewBuilder var controls: Controls
    @ViewBuilder var menuItems: MenuItems

    var body: some View {
        PanelRow {
            StatusDot(color: dot)
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            title.frame(width: ServiceRowLayout.title, alignment: .leading)
            Text(address)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(address)
            Text(state)
                .font(.callout)
                .foregroundStyle(stateTint)
                .lineLimit(1)
                .frame(width: ServiceRowLayout.state, alignment: .leading)
                .help(stateHelp ?? state)
            HStack(spacing: 6) { controls }
                .frame(width: ServiceRowLayout.controls, alignment: .trailing)
        }
        .contextMenu { menuItems }
    }
}

/// A service DevStack supervises. `service` is nil while it is left out of
/// the stack; `versions`, when given, is a picker that switches versions
/// while the service is stopped.
struct ServiceRow<Versions: View, MenuItems: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let symbol: String
    let address: String
    let service: ServiceKind?
    var runtimeID: String?
    @ViewBuilder var versions: Versions
    @ViewBuilder var menuItems: MenuItems

    private var phase: ServicePhase { service.map { model.serviceState($0).phase } ?? .stopped }
    private var running: Bool { phase == .running }
    private var installed: Bool { (runtimeID ?? service?.runtimeID).map(model.runtimeIsAvailable) ?? true }

    var body: some View {
        ServiceLine(symbol: symbol, dot: dot, state: state, stateTint: stateTint,
                    stateHelp: service.flatMap { model.serviceState($0).failure?.message }, address: address) {
            ServiceTitleMenu(title: title, locked: running || model.isBusy,
                             lockedNote: running ? "Stop \(title) to switch versions" : nil) { versions }
        } controls: {
            if let service {
                if !installed {
                    Button("Install") { model.installRuntime(runtimeID ?? service.runtimeID) }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                } else {
                    IconButton(title: running ? "Stop \(title)" : "Start \(title)", symbol: running ? "stop.fill" : "play.fill") {
                        Task { if running { await model.stopService(service) } else { await model.startService(service) } }
                    }
                    .disabled(model.isBusy)
                    IconButton(title: "Restart \(title)", symbol: "arrow.clockwise") { Task { await model.restartService(service) } }
                        .disabled(model.isBusy || !running)
                    IconButton(title: "Show \(title) logs", symbol: "text.alignleft") { model.showLogs(for: service) }
                }
                Menu {
                    Button("Show Logs") { model.showLogs(for: service) }
                    Button("Copy Address") { Pasteboard.copy(address) }
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More \(title) actions")
                .accessibilityLabel("More \(title) actions")
            }
        } menuItems: {
            if let service {
                Button(running ? "Stop" : "Start") {
                    Task { if running { await model.stopService(service) } else { await model.startService(service) } }
                }
                .disabled(model.isBusy || !installed)
                Button("Restart") { Task { await model.restartService(service) } }.disabled(model.isBusy || !running)
                Button("Show Logs") { model.showLogs(for: service) }
                Divider()
            }
            Button("Copy Address") { Pasteboard.copy(address) }
            menuItems
        }
    }

    private var dot: Color {
        guard service != nil else { return Color(nsColor: .tertiaryLabelColor) }
        return installed || running ? phase.statusColor : .orange
    }

    private var state: String {
        guard service != nil else { return "Off" }
        if !installed && !running { return "Not installed" }
        switch phase {
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        default: return phase.title
        }
    }

    private var stateTint: Color {
        if service != nil, !installed, !running { return .orange }
        return phase == .failed ? .red : .secondary
    }
}

extension ServiceRow where MenuItems == EmptyView {
    init(title: String, symbol: String, address: String, service: ServiceKind?, runtimeID: String? = nil,
         @ViewBuilder versions: () -> Versions) {
        self.init(title: title, symbol: symbol, address: address, service: service, runtimeID: runtimeID, versions: versions) { EmptyView() }
    }
}

/// A service's name and version. With version choices it is a menu, as in
/// Xcode's scheme and destination menus; the choices lock while it runs.
struct ServiceTitleMenu<Versions: View>: View {
    let title: String
    let locked: Bool
    var lockedNote: String?
    @ViewBuilder var versions: Versions

    var body: some View {
        if Versions.self == EmptyView.self {
            Text(title).fontWeight(.medium).lineLimit(1)
        } else {
            Menu {
                versions
                    .pickerStyle(.inline)
                    .disabled(locked)
                if let lockedNote, locked {
                    Divider()
                    Text(lockedNote)
                }
            } label: {
                // Flush with plain titles; the chevron marks the choice.
                HStack(spacing: 3) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(locked ? (lockedNote ?? "Busy") : "Switch version")
        }
    }
}

extension ServicePhase {
    var statusColor: Color {
        switch self {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        }
    }

    var title: String { rawValue.capitalized }
}

extension AppModel {
    /// Installs one runtime pack (and what it needs) from a row's Install button.
    func installRuntime(_ id: String) {
        guard runtimePackCatalog.pin(for: id) != nil else { selectedSection = .runtimes; return }
        Task {
            if let message = await installRuntimePacks([id]) { errorMessage = message }
        }
    }

    /// A runtime's version from its manifest, such as "2.4.68".
    func runtimeVersion(_ id: String) -> String? {
        runtimeManifests.first { $0.id == id }?.version
    }

    /// "Apache 2.4.68": a product with the version DevStack runs.
    func runtimeTitle(_ name: String, id: String) -> String {
        runtimeVersion(id).map { "\(name) \($0)" } ?? name
    }
}
