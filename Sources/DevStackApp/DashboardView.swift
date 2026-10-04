import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "Dashboard", subtitle: "Services, sites and tools at a glance.")
                Spacer()
            }
            if !model.missingRuntimePacks.isEmpty {
                HStack(alignment: .center) {
                    InfoNotice(symbol: "shippingbox", title: "Runtimes to install",
                               message: "The stack needs \(model.missingRuntimePacks.map(\.displayName).joined(separator: ", ")) before it can start.", color: .orange)
                    Button("Install…") { model.selectedSection = .runtimes }.buttonStyle(DevStackGlassButtonStyle())
                }
            }

            SurfacePanel(title: "Services") {
                VStack(spacing: 0) {
                    ServiceControl(title: "Web Server", service: model.configuration.selectedWebServer.service,
                        detail: "HTTP \(model.configuration.ports.webHTTP) · HTTPS \(model.configuration.ports.webHTTPS)") {
                        Picker("Web server", selection: Binding(get: { model.configuration.selectedWebServer }, set: { server in Task { await model.selectWebServer(server) } })) {
                            ForEach(WebServer.allCases) { server in
                                Text(server.displayName).tag(server).disabled(!model.runtimeIsAvailable(server.service.runtimeID))
                            }
                        }
                    }
                    Divider()
                    ServiceControl(title: "PHP", service: ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85, detail: "Default runtime") { PHPVersionPicker() }
                    Divider()
                    DatabaseServiceControl(embedded: true)
                    Divider()
                    ServiceControl(title: "Mail", service: .mailpit, detail: "SMTP \(model.configuration.ports.mailpitSMTP) · Inbox \(model.configuration.ports.mailpitInbox)") { Text("Mailpit").font(.system(size: 12, weight: .medium)).padding(.leading, 10) }
                    Divider()
                    LocalDNSServiceControl()
                }
            }

            SurfacePanel {
                HStack {
                    Text("Sites").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !model.configuration.sites.isEmpty {
                        Button("View All") { model.selectedSection = .sites }.buttonStyle(.borderless)
                    }
                    Button { model.requestNewSite() } label: { Label("New Site", systemImage: "plus") }.buttonStyle(DevStackProminentButtonStyle())
                }
                if model.configuration.sites.isEmpty {
                    HStack(spacing: 8) {
                        FeatureIcon(symbol: "globe")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No sites yet").font(.system(size: 13, weight: .medium))
                            Text("Add a project folder to create a site.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.configuration.sites.prefix(4).enumerated()), id: \.element.id) { index, site in
                            if index > 0 { Divider().padding(.vertical, 5) }
                            HStack(spacing: 8) {
                                FeatureIcon(symbol: "globe")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.name).font(.system(size: 13, weight: .semibold))
                                    Text(site.hostname).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusBadge(title: site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "))
                                StatusBadge(title: site.tlsEnabled ? "HTTPS" : "HTTP", color: site.tlsEnabled ? DevStackDesign.success : .secondary)
                                Button { model.openURL(model.siteURL(site)) } label: { Image(systemName: "arrow.up.right") }
                                    .buttonStyle(.borderless).help("Open \(site.name)").accessibilityLabel("Open \(site.name)")
                            }.padding(.vertical, 2)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tools").font(.system(size: 13, weight: .semibold))
                DevStackGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        QuickAccessTile(symbol: "externaldrive", title: "Database", subtitle: "Connections and backups") { model.selectedSection = .database }
                        QuickAccessTile(symbol: "tray", title: "Mail Inbox", subtitle: "Open mail tools") { model.selectedSection = .mailpit }
                        QuickAccessTile(symbol: "terminal", title: "Terminal", subtitle: "Open managed shell", action: model.openManagedShell)
                    }
                }
            }
        }
    }

}

private struct ServiceControl<Selector: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let service: ServiceKind
    let detail: String
    @ViewBuilder var selector: Selector
    private var state: ServiceState { model.serviceState(service) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: service.icon).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 80, alignment: .leading)
            selector.pickerStyle(.menu).labelsHidden().controlSize(.small)
                .tint(.primary)
                .disabled(model.isBusy || state.phase == .running)
                .help(state.phase == .running ? "Stop the service before changing its version." : "Change \(title.lowercased())")
                .frame(width: 140, alignment: .leading)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            StatusBadge(title: state.phase.rawValue.capitalized, color: state.phase.color, dot: true, dotColor: state.phase.dotColor).frame(minWidth: 64, alignment: .trailing)
            Button(state.phase == .running ? "Stop" : "Start") {
                Task {
                    if state.phase == .running { await model.stopService(service) }
                    else { await model.startService(service) }
                }
            }.buttonStyle(DevStackGlassButtonStyle())
                .disabled(model.isBusy || !model.runtimeIsAvailable(service.runtimeID))
                .accessibilityLabel("\(state.phase == .running ? "Stop" : "Start") \(service.displayName)")
                .frame(width: 55)
                Menu {
                    Button("Open Logs") { model.showLogs(for: service) }
                    Button("Restart") { Task { await model.restartService(service) } }
                        .disabled(model.isBusy || state.phase != .running)
                    if service.phpRuntimeID != nil {
                        Divider()
                        Button("Extensions…") { model.selectedSection = .php }
                        ForEach(model.serviceStates.filter { $0.service.phpRuntimeID != nil && $0.service != service && $0.phase == .running }) { other in
                            Button("Stop \(other.service.displayName)") { Task { await model.stopService(other.service) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22).accessibilityLabel("\(title) actions")
        }.padding(.vertical, 6)
    }
}

/// The helper's local DNS responder shown as a service row: it answers
/// DevStack hostnames for phones and other devices on the network.
private struct LocalDNSServiceControl: View {
    @EnvironmentObject private var model: AppModel

    private var running: Bool { model.helperStatus?.dnsEnabled == true }
    private var available: Bool { model.helperInstalled }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.router").foregroundStyle(.secondary).frame(width: 16)
            Text("Local DNS").font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 80, alignment: .leading)
            Text(model.localNetworkAddress ?? "No network")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).padding(.leading, 10).frame(width: 140, alignment: .leading)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            StatusBadge(
                title: available ? (running ? "Running" : "Stopped") : "Unavailable",
                color: available ? (running ? DevStackDesign.success : .secondary) : .secondary,
                dot: true,
                dotColor: running ? .green : nil
            ).frame(minWidth: 64, alignment: .trailing)
            Button(running ? "Stop" : "Start") {
                Task { await model.setLocalNetworkAccess(!running) }
            }.buttonStyle(DevStackGlassButtonStyle())
                .disabled(model.isBusy || !available)
                .help(available ? "Answer DevStack hostnames for devices on this network" : "Requires the privileged helper")
                .accessibilityLabel(running ? "Stop local DNS" : "Start local DNS")
                .frame(width: 55)
            Menu {
                Button("Open Local DNS…") { model.selectedSection = .localDNS }
                if let address = model.localNetworkAddress {
                    Button("Copy DNS address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                }
                Button("Run Doctor") { model.selectedSection = .doctor }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22)
                .help("Local DNS actions").accessibilityLabel("Local DNS actions")
        }.padding(.vertical, 6)
    }

    private var detail: String {
        guard available else { return "Set up the helper in Settings" }
        guard running else { return "Off — serve DevStack hostnames to this network" }
        return "Answers DevStack hostnames · other queries forwarded"
    }
}

struct PHPVersionPicker: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Picker("PHP version", selection: Binding(get: { model.configuration.defaultPHPRuntimeID }, set: { id in Task { await model.selectPHP(id) } })) {
            ForEach(model.availablePHPRuntimes) { runtime in
                Text("PHP \(runtime.version)").tag(runtime.id)
            }
        }.pickerStyle(.menu)
            .tint(.primary)
            .disabled(model.isBusy || defaultRuntimeIsRunning)
            .help(defaultRuntimeIsRunning ? "Stop PHP before changing the default version." : "Choose the default PHP runtime.")
    }

    private var defaultRuntimeIsRunning: Bool {
        model.serviceIsRunning(ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85)
    }
}

private struct QuickAccessTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).devStackGlass(.rect(cornerRadius: 12), interactive: true)
    }
}
