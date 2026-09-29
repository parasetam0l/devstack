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

            if !model.helperInstalled {
                HStack(spacing: 14) {
                    FeatureIcon(symbol: "lock.shield")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System integration required").font(.system(size: 13, weight: .semibold))
                        Text("Set up the helper to enable domains and HTTPS.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up…") { model.selectedSection = .settings; Task { await model.installHelper() } }.buttonStyle(.glass).disabled(model.isBusy)
                }.padding(16).background(DevStackDesign.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Services").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    StatusBadge(title: model.hasRunningServices ? "Running" : "Stopped", color: model.hasRunningServices ? DevStackDesign.success : .secondary, dot: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(model.visibleServiceStates) { state in
                        Button { model.selectedLogService = state.service; model.selectedSection = .logs } label: { ServiceTile(state: state) }
                            .buttonStyle(.plain).help("Read \(state.service.displayName) logs")
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
                                Button { model.openURL("\(site.tlsEnabled ? "https" : "http")://\(site.hostname)") } label: { Image(systemName: "arrow.up.right") }
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

private struct ServiceTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: ServiceState
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: state.service.icon).font(.system(size: 20, weight: .light)).foregroundStyle(state.phase == .running ? DevStackDesign.success : .secondary)
                Spacer()
                Circle().fill(state.phase.color).frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(state.service.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(state.service.endpoint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text(state.phase.rawValue.capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(state.phase.color)
                Spacer(minLength: 0)
                if let pid = state.pid { Text("\(pid)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(red: 0.115, green: 0.135, blue: 0.175) : .white, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(state.phase == .failed ? Color.red.opacity(0.25) : .primary.opacity(0.06), lineWidth: 1) }
        .accessibilityElement(children: .combine)
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
