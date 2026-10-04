import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if !model.missingRuntimePacks.isEmpty {
                Section {
                    NoticeRow(symbol: "shippingbox", title: "Runtimes to install",
                              message: "The stack needs \(model.missingRuntimePacks.map(\.displayName).joined(separator: ", ")) before it can start.") {
                        Button("Install…") { model.selectedSection = .runtimes }
                    }
                }
            }

            Section("Services") {
                ServiceRow(title: "Web Server", symbol: "globe",
                           detail: "HTTP \(model.configuration.ports.webHTTP) · HTTPS \(model.configuration.ports.webHTTPS)",
                           service: model.configuration.selectedWebServer.service) {
                    Picker("Web server", selection: Binding(get: { model.configuration.selectedWebServer },
                                                            set: { server in Task { await model.selectWebServer(server) } })) {
                        ForEach(WebServer.allCases) { server in
                            Text(model.runtimeOptionTitle(server.displayName, id: server.service.runtimeID)).tag(server)
                                .disabled(!model.runtimeIsAvailable(server.service.runtimeID))
                        }
                    }
                }
                ServiceRow(title: "PHP", symbol: "chevron.left.forwardslash.chevron.right", detail: "Default for new sites",
                           service: ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85) {
                    PHPVersionPicker()
                } menuItems: {
                    Divider()
                    Button("Extensions…") { model.selectedSection = .php }
                    ForEach(model.serviceStates.filter { $0.service.phpRuntimeID != nil && $0.service.rawValue != model.configuration.defaultPHPRuntimeID && $0.phase == .running }) { other in
                        Button("Stop \(other.service.displayName)") { Task { await model.stopService(other.service) } }
                    }
                }
                DatabaseServiceRows()
                ServiceRow(title: "Mail", symbol: "envelope",
                           detail: "SMTP \(model.configuration.ports.mailpitSMTP) · Inbox \(model.configuration.ports.mailpitInbox)",
                           service: .mailpit) {
                    Text("Mailpit").foregroundStyle(.secondary)
                } menuItems: {
                    Divider()
                    Button("Open Inbox") { model.openURL("http://127.0.0.1:\(model.configuration.ports.mailpitInboxListen)") }
                }
                LocalDNSServiceRow()
            }

            Section {
                if model.configuration.sites.isEmpty {
                    NoticeRow(symbol: "globe", title: "No sites yet", message: "Add a project folder to serve it at its own local domain.", tint: .secondary) {
                        Button("New Site…") { model.requestNewSite() }
                    }
                } else {
                    ForEach(model.configuration.sites.prefix(5)) { site in
                        DashboardSiteRow(site: site)
                    }
                    HStack {
                        if model.configuration.sites.count > 5 {
                            Text("\(model.configuration.sites.count - 5) more").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show All") { model.selectedSection = .sites }
                        Button("New Site…") { model.requestNewSite() }
                    }
                }
            } header: {
                Text("Sites")
            }

            Section("Open") {
                LabeledContent("Database tools") {
                    HStack {
                        Button("phpMyAdmin") { model.openURL(model.toolURL("phpmyadmin")) }
                        Button("Adminer") { model.openURL(model.toolURL("adminer")) }
                    }
                    .disabled(!webServerRunning)
                }
                LabeledContent("Mail") {
                    Button("Inbox") { model.openURL("http://127.0.0.1:\(model.configuration.ports.mailpitInboxListen)") }
                        .disabled(!model.serviceIsRunning(.mailpit))
                }
                LabeledContent("Shell") {
                    Button("Terminal") { model.openManagedShell() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var webServerRunning: Bool { model.serviceIsRunning(model.configuration.selectedWebServer.service) }
}

private struct DashboardSiteRow: View {
    @EnvironmentObject private var model: AppModel
    let site: SiteDefinition

    var body: some View {
        HStack(spacing: 12) {
            ServiceRowTitle(title: site.name, symbol: "globe", detail: site.hostname)
            Spacer(minLength: 12)
            Text(site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP ")).foregroundStyle(.secondary)
            Label(site.tlsEnabled ? "HTTPS" : "HTTP", systemImage: site.tlsEnabled ? "lock.fill" : "lock.open")
                .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Button { model.openURL(model.siteURL(site)) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Open \(site.name) in the browser")
                .accessibilityLabel("Open \(site.name)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open in Browser") { model.openURL(model.siteURL(site)) }
            Button("Show All Sites") { model.selectedSection = .sites }
        }
    }
}

/// The helper's DNS responder as a service row: it answers DevStack hostnames
/// for phones and other devices on the network.
private struct LocalDNSServiceRow: View {
    @EnvironmentObject private var model: AppModel

    private var running: Bool { model.helperStatus?.dnsEnabled == true }
    private var available: Bool { model.helperInstalled }

    var body: some View {
        HStack(spacing: 12) {
            ServiceRowTitle(title: "Local DNS", symbol: "wifi.router", detail: detail)
            Spacer(minLength: 12)
            Text(model.localNetworkAddress ?? "No network")
                .font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(width: ServiceRowLayout.selector, alignment: .trailing)
            StatusLabel(title: available ? (running ? "Running" : "Stopped") : "Unavailable",
                        color: running ? .green : Color(nsColor: .tertiaryLabelColor))
                .frame(width: ServiceRowLayout.status, alignment: .leading)
            Button(running ? "Stop" : "Start") { Task { await model.setLocalNetworkAccess(!running) } }
                .frame(width: ServiceRowLayout.button)
                .disabled(model.isBusy || !available)
                .help(available ? "Answer DevStack hostnames for devices on this network" : "Needs the DevStack helper")
                .accessibilityLabel(running ? "Stop local DNS" : "Start local DNS")
            Menu {
                Button("Local DNS Settings…") { model.selectedSection = .localDNS }
                if let address = model.localNetworkAddress {
                    Button("Copy DNS Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Local DNS actions")
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard available else { return "Needs the DevStack helper" }
        return running ? "Answers DevStack hostnames" : "Hostnames for other devices"
    }
}

struct PHPVersionPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("PHP version", selection: Binding(get: { model.configuration.defaultPHPRuntimeID },
                                                 set: { id in Task { await model.selectPHP(id) } })) {
            ForEach(model.phpRuntimes) { runtime in
                Text(model.runtimeOptionTitle("PHP \(runtime.version)", id: runtime.id)).tag(runtime.id)
                    .disabled(!model.runtimeIsAvailable(runtime.id))
            }
        }
    }
}
