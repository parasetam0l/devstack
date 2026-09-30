import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "Dashboard", subtitle: "")
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Services").font(.system(size: 15, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ServiceControl(title: "Web Server", service: model.configuration.selectedWebServer.service,
                        detail: model.helperInstalled ? "HTTP 80 · HTTPS 443" : "HTTP 8080 · HTTPS 8443") {
                        Picker("Web server", selection: Binding(get: { model.configuration.selectedWebServer }, set: { server in Task { await model.selectWebServer(server) } })) {
                            ForEach(WebServer.allCases) { server in
                                Text(server.displayName).tag(server).disabled(!model.runtimeIsAvailable(server.service.runtimeID))
                            }
                        }
                    }
                    ServiceControl(title: "PHP", service: ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85,
                        detail: "Default for new sites and Terminal") {
                        PHPVersionPicker()
                    }
                    ServiceControl(title: "Database", service: model.configuration.selectedDatabase == .mysql84 ? .mysql84 : .mysql57,
                        detail: "127.0.0.1:3306") {
                        Picker("Database engine", selection: Binding(get: { model.configuration.selectedDatabase }, set: { model.selectedDatabaseBinding = $0 })) {
                            ForEach(DatabaseEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine).disabled(!model.runtimeIsAvailable(engine.rawValue))
                            }
                        }
                    }
                    ServiceControl(title: "Mail", service: .mailpit, detail: "SMTP 1025 · Inbox 8025") {
                        Text("Mailpit").font(.system(size: 15, weight: .medium)).frame(height: 28, alignment: .leading)
                    }
                }
            }

            SurfacePanel {
                HStack {
                    Text("Sites").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !model.configuration.sites.isEmpty {
                        Button("View All") { model.selectedSection = .sites }.buttonStyle(.borderless)
                    }
                    Button { model.requestNewSite() } label: { Label("New Site", systemImage: "plus") }.buttonStyle(.glass)
                }
                if model.configuration.sites.isEmpty {
                    HStack(spacing: 14) {
                        FeatureIcon(symbol: "globe")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No sites yet").font(.system(size: 13, weight: .medium))
                            Text("Add a project folder to create a site.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.configuration.sites.prefix(4).enumerated()), id: \.element.id) { index, site in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            HStack(spacing: 12) {
                                FeatureIcon(symbol: "globe")
                                VStack(alignment: .leading, spacing: 4) {
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

            VStack(alignment: .leading, spacing: 12) {
                Text("Tools").font(.system(size: 15, weight: .semibold))
                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: service.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(DevStackDesign.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusBadge(title: state.phase.rawValue.capitalized, color: state.phase.color, dot: true)
            }
            selector.pickerStyle(.menu).labelsHidden().controlSize(.large)
                .disabled(model.isBusy).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(state.phase == .running ? "Stop" : "Start") {
                    Task {
                        if state.phase == .running { await model.stopService(service) }
                        else { await model.startService(service) }
                    }
                }.buttonStyle(DevStackGlassButtonStyle())
                    .disabled(model.isBusy || !model.runtimeIsAvailable(service.runtimeID))
                    .accessibilityLabel("\(state.phase == .running ? "Stop" : "Start") \(service.displayName)")
                Menu {
                    Button("Open Logs") { model.selectedLogService = service; model.selectedSection = .logs }
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
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("\(title) actions")
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct PHPVersionPicker: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Picker("PHP version", selection: Binding(get: { model.configuration.defaultPHPRuntimeID }, set: { id in Task { await model.selectPHP(id) } })) {
            ForEach(model.availablePHPRuntimes) { runtime in
                Text("PHP \(runtime.version)").tag(runtime.id)
            }
        }.pickerStyle(.menu).disabled(model.isBusy)
    }
}

private struct QuickAccessTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(DevStackDesign.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}
