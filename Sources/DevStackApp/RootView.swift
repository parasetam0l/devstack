import DevStackCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    BrandIcon(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DevStack").font(.system(size: 17, weight: .bold, design: .rounded))
                        
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.top, 17).padding(.bottom, 20)
                List(selection: $model.selectedSection) {
                    Section("Workspace") {
                        ForEach(Array(NavigationSection.allCases.prefix(5))) { section in sidebarRow(section) }
                    }
                    Section("Tools") {
                        ForEach(Array(NavigationSection.allCases.suffix(3))) { section in sidebarRow(section) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 218, max: 260)
        } detail: {
            VStack(spacing: 0) {
                selectedPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                statusFooter
            }
            .navigationTitle((model.selectedSection ?? .dashboard).rawValue)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.openManagedShell() } label: { Image(systemName: "terminal") }
                        .help("Open a terminal with DevStack tools").accessibilityLabel("Open managed terminal")
                    Button(action: stackAction) {
                        HStack(spacing: 6) {
                            if model.isBusy { ProgressView().controlSize(.mini) }
                            else { Image(systemName: model.hasRunningServices ? "stop.fill" : "play.fill").font(.system(size: 10)) }
                            Text(model.isBusy ? "Working…" : model.hasRunningServices ? "Stop Stack" : model.helperInstalled ? "Start Stack" : "Set Up Stack")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isBusy)
                    .help(model.helperInstalled || model.hasRunningServices ? "Start or stop your local services" : "Complete system setup before starting")
                }
            }
        }
        .tint(DevStackDesign.accent)
        .preferredColorScheme(model.appearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshHelperStatus() }
        }
        .task {
            guard !model.isReviewMode else { return }
            while !Task.isCancelled {
                await model.refreshServiceStates()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .alert("Something needs attention", isPresented: errorIsPresented) {
            Button("Dismiss", role: .cancel) { model.errorMessage = nil }
            Button("Open Doctor") { model.errorMessage = nil; model.selectedSection = .doctor }
        } message: { Text(model.errorMessage ?? "Unknown error") }
    }

    private func sidebarRow(_ section: NavigationSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 19).foregroundStyle(model.selectedSection == section ? Color.white : .secondary)
                .accessibilityHidden(true)
            Text(section.rawValue).font(.system(size: 12, weight: .medium))
            Spacer()
            if section == .sites, !model.configuration.sites.isEmpty {
                Text("\(model.configuration.sites.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5).tag(section)
    }

    @ViewBuilder private var selectedPage: some View {
        switch model.selectedSection ?? .dashboard {
        case .dashboard: DashboardView()
        case .sites: SitesView()
        case .php: PHPView()
        case .database: DatabaseView()
        case .mailpit: MailpitView()
        case .logs: LogsView()
        case .doctor: DoctorView()
        case .settings: SettingsView()
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 7) {
            let running = model.serviceStates.filter { $0.phase == .running }.count
            let failed = model.serviceStates.contains { $0.phase == .failed }
            Circle().fill(failed ? Color.red : running > 0 ? DevStackDesign.success : .secondary).frame(width: 5, height: 5)
            Text(failed ? "Service needs attention" : running > 0 ? "\(running) services running" : "Stack stopped")
            Spacer()
            Text("\(model.configuration.sites.count) \(model.configuration.sites.count == 1 ? "site" : "sites")")
            Button("View Logs") { model.selectedSection = .logs }.buttonStyle(.borderless).padding(.leading, 9)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(.bar)
    }

    private func stackAction() {
        if model.hasRunningServices { Task { await model.stopAll() } }
        else if !model.helperInstalled { model.selectedSection = .settings; Task { await model.installHelper() } }
        else { Task { await model.startAll() } }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
