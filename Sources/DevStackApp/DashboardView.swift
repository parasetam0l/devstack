import AppKit
import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private var ports: ServicePorts { model.configuration.ports }
    private var webServer: WebServer { model.configuration.selectedWebServer }
    private var webServerRunning: Bool { model.serviceIsRunning(webServer.service) }
    private static let visibleSites = 8

    var body: some View {
        PanelPage {
            RuntimeInstallBanner()

            Panel("Services") {
                ServiceRow(title: model.runtimeTitle(webServer.displayName, id: webServer.service.runtimeID), symbol: "globe",
                           address: "http :\(ports.webHTTP) · https :\(ports.webHTTPS)", service: webServer.service) {
                    Picker("Web server", selection: Binding(get: { webServer }, set: { server in Task { await model.selectWebServer(server) } })) {
                        ForEach(WebServer.allCases) { server in
                            Text(model.runtimeOptionTitle(model.runtimeTitle(server.displayName, id: server.service.runtimeID), id: server.service.runtimeID))
                                .tag(server)
                                .disabled(!model.runtimeIsAvailable(server.service.runtimeID))
                        }
                    }
                } menuItems: {
                    Divider()
                    Button("Open localhost") { model.openURL("http://localhost\(ports.webHTTP == 80 ? "" : ":\(ports.webHTTP)")") }
                }
                ForEach(model.phpRuntimeIDsInUse, id: \.self) { id in PHPServiceRow(runtimeID: id) }
                DatabaseServiceRows()
                ServiceRow(title: model.runtimeTitle("Mailpit", id: ServiceKind.mailpit.runtimeID), symbol: "envelope",
                           address: "smtp :\(ports.mailpitSMTP) · web :\(ports.mailpitInbox)", service: .mailpit) {
                    EmptyView()
                } menuItems: {
                    Divider()
                    Button("Open Inbox") { model.openURL(model.mailInboxURL) }
                }
                LocalDNSServiceRow()
            }

            Panel("Sites") {
                if model.configuration.sites.isEmpty {
                    PanelRow {
                        Text("No sites yet. Add a project folder to serve it at its own local domain.").foregroundStyle(.secondary)
                        Spacer()
                        Button("New Site…") { model.requestNewSite() }.controlSize(.small)
                    }
                } else {
                    ForEach(model.configuration.sites.prefix(Self.visibleSites)) { site in DashboardSiteRow(site: site) }
                    if model.configuration.sites.count > Self.visibleSites {
                        PanelRow {
                            Button("Show \(model.configuration.sites.count - Self.visibleSites) more…") { model.selectedSection = .sites }
                                .buttonStyle(.link)
                            Spacer()
                        }
                    }
                }
            } accessory: {
                Button("Show All") { model.selectedSection = .sites }.buttonStyle(.borderless)
                Button { model.presentMigrationWizard() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Import projects and databases from XAMPP")
                Button { model.requestNewSite() } label: { Label("New Site", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a site (⌘N)")
            }

            Panel("Open") {
                PanelRow {
                    HStack(spacing: 18) {
                        Button { model.openURL(model.toolURL("phpmyadmin")) } label: { Label("phpMyAdmin", systemImage: "tablecells") }
                            .disabled(!webServerRunning)
                        Button { model.openURL(model.toolURL("adminer")) } label: { Label("Adminer", systemImage: "tablecells") }
                            .disabled(!webServerRunning)
                        Button { model.openURL(model.mailInboxURL) } label: { Label("Mail Inbox", systemImage: "tray") }
                            .disabled(!model.serviceIsRunning(.mailpit))
                        Button { model.openManagedShell() } label: { Label("Terminal", systemImage: "terminal") }
                        Button { model.copyManagedEnvironmentCommand() } label: { Label("Copy Shell Env", systemImage: "doc.on.doc") }
                            .help("Copy a command that puts DevStack's PHP, Composer and database tools on your shell's PATH")
                    }
                    .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Install progress, or the runtimes the stack still needs, above the panels.
struct RuntimeInstallBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let progress = model.runtimePackProgress {
            Banner(symbol: "arrow.down.circle", title: "Installing \(progress.packName) (\(progress.index) of \(progress.count))",
                   detail: "\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))",
                   tint: .accentColor) {
                ProgressView(value: progress.fraction).frame(width: 140)
            }
        } else if !model.missingRuntimePacks.isEmpty {
            let missing = model.missingRuntimePacks
            Banner(symbol: "arrow.down.circle", title: "\(missing.count) runtime\(missing.count == 1 ? "" : "s") to install before the stack can start",
                   detail: missing.map(\.displayName).joined(separator: ", "), tint: .accentColor) {
                Button("Details") { model.selectedSection = .runtimes }
                Button("Install All (\(ByteCountFormatter.string(fromByteCount: missing.reduce(0) { $0 + $1.size }, countStyle: .file)))") {
                    Task { if let message = await model.installRuntimePacks(missing.map(\.id)) { model.errorMessage = message } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
    }
}

/// A PHP-FPM pool the stack runs: the default version (a menu switches it)
/// and every other version a site uses.
private struct PHPServiceRow: View {
    @EnvironmentObject private var model: AppModel
    let runtimeID: String

    private var isDefault: Bool { runtimeID == model.configuration.defaultPHPRuntimeID }

    private var address: String {
        let sites = model.configuration.sites.filter { $0.phpRuntimeID == runtimeID }.count
        return (["php-fpm"] + (isDefault ? ["default"] : []) + ["\(sites) site\(sites == 1 ? "" : "s")"]).joined(separator: " · ")
    }

    var body: some View {
        let title = model.runtimeTitle("PHP", id: runtimeID)
        let symbol = "chevron.left.forwardslash.chevron.right"
        if isDefault {
            ServiceRow(title: title, symbol: symbol, address: address, service: ServiceKind(rawValue: runtimeID)) {
                PHPVersionPicker()
            } menuItems: {
                Divider()
                Button("Extensions…") { model.selectedSection = .php }
            }
        } else {
            ServiceRow(title: title, symbol: symbol, address: address, service: ServiceKind(rawValue: runtimeID)) {
                EmptyView()
            } menuItems: {
                Divider()
                Button("Extensions…") { model.selectedSection = .php }
            }
        }
    }
}

private struct DashboardSiteRow: View {
    @EnvironmentObject private var model: AppModel
    let site: SiteDefinition

    /// Served while the web server and the site's PHP version run.
    private var served: Bool {
        model.serviceIsRunning(model.configuration.selectedWebServer.service)
            && ServiceKind(rawValue: site.phpRuntimeID).map(model.serviceIsRunning) == true
    }

    var body: some View {
        let url = model.siteURL(site)
        PanelRow {
            StatusDot(color: served ? .green : Color(nsColor: .tertiaryLabelColor))
                .help(served ? "Served" : "Not served while the stack is stopped")
            Text(site.name).fontWeight(.medium).lineLimit(1).frame(width: ServiceRowLayout.title, alignment: .leading)
            SiteLink(url: url)
                .frame(maxWidth: .infinity, alignment: .leading)
            Tag(text: site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "), tint: site.phpRuntimeID == "php-7.4" ? .orange : .secondary)
                .frame(width: ServiceRowLayout.state, alignment: .leading)
            SiteActionsMenu(title: "More actions for \(site.name)") { menuItems(url: url) }
                .controlSize(.small)
                .frame(width: ServiceRowLayout.controls, alignment: .trailing)
        }
        .contextMenu { menuItems(url: url) }
    }

    @ViewBuilder private func menuItems(url: String) -> some View {
        Button { model.openURL(url) } label: { Label("Open in Browser", systemImage: "safari") }
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.documentRoot)]) } label: { Label("Show in Finder", systemImage: "folder") }
        Button { Pasteboard.copy(url) } label: { Label("Copy URL", systemImage: "link") }
        Divider()
        Button { model.selectedSection = .sites } label: { Label("Show All Sites", systemImage: "globe") }
    }
}

/// The helper's DNS responder: it answers DevStack hostnames for phones and
/// other devices on the network.
private struct LocalDNSServiceRow: View {
    @EnvironmentObject private var model: AppModel

    private var running: Bool { model.helperStatus?.dnsEnabled == true }
    private var available: Bool { model.helperInstalled }

    var body: some View {
        let address = model.localNetworkAddress.map { "\($0):53" } ?? "no network"
        ServiceLine(symbol: "wifi.router", dot: running ? .green : Color(nsColor: .tertiaryLabelColor),
                    state: available ? (running ? "Running" : "Stopped") : "Needs helper", stateTint: available ? .secondary : .orange,
                    address: address) {
            Text("Local DNS").fontWeight(.medium)
        } controls: {
            if available {
                IconButton(title: running ? "Stop local DNS" : "Start local DNS", symbol: running ? "stop.fill" : "play.fill") {
                    Task { await model.setLocalNetworkAccess(!running) }
                }
                .disabled(model.isBusy)
            } else {
                Button("Set Up…") { model.selectedSection = .settings }.controlSize(.small)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More local DNS actions")
        } menuItems: {
            menuItems
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Device Setup…") { model.selectedSection = .localDNS }
        if let address = model.localNetworkAddress {
            Button("Copy DNS Address") { Pasteboard.copy(address) }
        }
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

extension AppModel {
    var mailInboxURL: String { "http://127.0.0.1:\(configuration.ports.mailpitInboxListen)" }
}
