import Combine
import DevStackCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var navigation = RootNavigationState()

    var body: some View {
        NavigationSplitView(columnVisibility: $navigation.visibility) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    BrandIcon(size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DevStack").font(.system(size: 14, weight: .semibold, design: .rounded))
                        
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
                List(selection: $model.selectedSection) {
                    Section("Workspace") {
                        ForEach(Array(NavigationSection.allCases.prefix(6))) { section in sidebarRow(section) }
                    }
                    Section("Tools") {
                        ForEach(Array(NavigationSection.allCases.suffix(3))) { section in sidebarRow(section) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .padding(4)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(6)
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                selectedPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                statusFooter
            }
            .toolbar(removing: .sidebarToggle)
            .navigationTitle((model.selectedSection ?? .dashboard).rawValue)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        navigation.visibility = navigation.visibility == .detailOnly ? .all : .detailOnly
                    } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(DevStackGlassButtonStyle())
                        .help(navigation.visibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                        .accessibilityLabel(navigation.visibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.openManagedShell() } label: { Image(systemName: "terminal") }
                        .buttonStyle(DevStackGlassButtonStyle())
                        .help("Open a terminal with DevStack tools").accessibilityLabel("Open managed terminal")
                    Button(action: stackAction) {
                        HStack(spacing: 6) {
                            if model.isBusy { ProgressView().controlSize(.mini) }
                            else { Image(systemName: model.stackIsRunning ? "stop.fill" : "play.fill").font(.system(size: 10)) }
                            Text(model.isBusy ? "Working…" : model.stackIsRunning ? "Stop Stack" : "Start Stack")
                        }
                    }
                    .buttonStyle(DevStackGlassButtonStyle())
                    .disabled(model.isBusy)
                    .help("Start or stop the stack")
                    if model.hasRunningServices && !model.stackIsRunning {
                        Button("Stop Stack", systemImage: "stop.fill") { Task { await model.stopAll() } }
                            .buttonStyle(DevStackGlassButtonStyle())
                            .disabled(model.isBusy)
                    }
                }.sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .background(WindowBackdrop().ignoresSafeArea())
        .tint(DevStackDesign.accent)
        .controlSize(.small)
        .onAppear { model.applyAppearance() }
        .onChange(of: model.appearance) { _, _ in model.applyAppearance() }
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
        .sheet(isPresented: helperNoticeIsPresented) { HelperNoticeSheet().environmentObject(model) }
    }

    private func sidebarRow(_ section: NavigationSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 19).foregroundStyle(model.selectedSection == section ? Color.primary : .secondary)
                .accessibilityHidden(true)
            Text(section.rawValue).font(.system(size: 12, weight: .medium))
            Spacer()
            if section == .sites, !model.configuration.sites.isEmpty {
                Text("\(model.configuration.sites.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2).tag(section)
    }

    @ViewBuilder private var selectedPage: some View {
        switch model.selectedSection ?? .dashboard {
        case .dashboard: DashboardView()
        case .sites: SitesView()
        case .php: PHPView()
        case .database: DatabaseView()
        case .ssl: SSLView()
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
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(WorkspaceBackground())
        .overlay(alignment: .top) { Divider() }
    }

    private func stackAction() {
        if model.stackIsRunning { Task { await model.stopAll() } }
        else { Task { await model.startAll() } }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var helperNoticeIsPresented: Binding<Bool> {
        Binding(get: { model.helperNotice != nil }, set: { if !$0 { model.helperNotice = nil } })
    }
}

struct HelperNoticeSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var suppress = false

    var body: some View {
        let blocking = model.helperNotice?.isBlocking == true
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 22)).foregroundStyle(DevStackDesign.accent)
                Text(blocking ? "Approve the helper to start" : "DevStack needs a helper")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("The background helper adds your site hostnames to the system hosts file and lets the web server answer on ports 80 and 443. Everything else keeps running on DevStack's own ports (8080 and 8443 by default).")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Approve DevStack in System Settings → General → Login Items & Extensions. The stack cannot start until the helper is ready.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .unavailable(let reason) = model.helperSetupState {
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !blocking {
                Toggle("Do not show this again", isOn: $suppress).toggleStyle(.checkbox).controlSize(.small)
            }
            HStack {
                Spacer()
                Button(blocking ? "Not Now" : "Later") {
                    Task {
                        if suppress { await model.dismissHelperNotice() } else { model.helperNotice = nil }
                    }
                }
                Button("Set Up Helper…") {
                    Task {
                        if suppress { await model.dismissHelperNotice() } else { model.helperNotice = nil }
                        await model.installHelper()
                    }
                }.buttonStyle(DevStackGlassButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

@MainActor private final class RootNavigationState: ObservableObject {
    @Published var visibility: NavigationSplitViewVisibility = .all
}
