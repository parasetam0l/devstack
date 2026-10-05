import AppKit
import Combine
import DevStackCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Section("Workspace") {
                    ForEach(NavigationSection.workspace) { section in sidebarRow(section) }
                }
                Section("Tools") {
                    ForEach(NavigationSection.tools) { section in sidebarRow(section) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clearToolbarBacking()
                .navigationTitle((model.selectedSection ?? .dashboard).rawValue)
                .navigationSubtitle(statusSummary)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { model.openManagedShell() } label: {
                            Label("Terminal", systemImage: "terminal")
                        }
                        .help("Open a terminal with DevStack's PHP, Composer and database tools")
                        if model.hasRunningServices && !model.stackIsRunning {
                            Button { Task { await model.stopAll() } } label: {
                                Label("Stop All", systemImage: "stop.fill")
                            }
                            .disabled(model.isBusy)
                            .help("Stop every running service")
                        }
                        Button(action: stackAction) {
                            Label(stackActionTitle, systemImage: stackActionSymbol).labelStyle(.titleAndIcon)
                        }
                        .disabled(model.isBusy)
                        .help(needsRuntimes ? "Install the runtimes the stack needs first"
                              : model.stackIsRunning ? "Stop all services" : "Start the stack")
                    }
                }
        }
        .onAppear {
            model.applyAppearance()
            model.openMainWindow = { openWindow(id: "main") }
        }
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
            Button("OK", role: .cancel) { model.errorMessage = nil }
            Button("Open Doctor") { model.errorMessage = nil; model.selectedSection = .doctor }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .sheet(isPresented: helperNoticeIsPresented) { HelperNoticeSheet().environmentObject(model) }
        .sheet(isPresented: $model.isPresentingSetupWizard) { SetupWizardView().environmentObject(model) }
        .sheet(isPresented: $model.isPresentingMigrationWizard) {
            MigrationWizardView(controller: model.makeMigrationController()).environmentObject(model)
        }
    }

    @ViewBuilder private func sidebarRow(_ section: NavigationSection) -> some View {
        if section == .sites, !model.configuration.sites.isEmpty {
            Label(section.rawValue, systemImage: section.symbol).badge(model.configuration.sites.count).tag(section)
        } else {
            Label(section.rawValue, systemImage: section.symbol).tag(section)
        }
    }

    @ViewBuilder private var selectedPage: some View {
        switch model.selectedSection ?? .dashboard {
        case .dashboard: DashboardView()
        case .sites: SitesView()
        case .php: PHPView()
        case .database: DatabaseView()
        case .ssl: SSLView()
        case .mailpit: MailpitView()
        case .localDNS: LocalDNSView()
        case .runtimes: RuntimesView()
        case .logs: LogsView()
        case .doctor: DoctorView()
        case .settings: SettingsView()
        }
    }

    /// The toolbar's subtitle: what the stack is doing right now.
    private var statusSummary: String {
        if let progress = model.runtimePackProgress {
            return "Installing \(progress.packName) (\(progress.index) of \(progress.count))"
        }
        if model.serviceStates.contains(where: { $0.phase == .failed }) { return "A service needs attention" }
        let running = model.serviceStates.filter { $0.phase == .running }.count
        if running > 0 { return "\(running) service\(running == 1 ? "" : "s") running" }
        if !model.missingRuntimePacks.isEmpty { return "Runtimes to install" }
        return "Stopped"
    }

    /// The stack cannot start before its runtimes are installed; the button
    /// leads to them instead.
    private var needsRuntimes: Bool { !model.stackIsRunning && !model.missingRuntimePacks.isEmpty }

    private var stackActionTitle: String {
        if model.runtimePackProgress != nil { return "Installing…" }
        if model.isBusy { return "Working…" }
        if needsRuntimes { return "Install Runtimes" }
        return model.stackIsRunning ? "Stop Stack" : "Start Stack"
    }

    private var stackActionSymbol: String {
        if model.isBusy { return "hourglass" }
        if needsRuntimes { return "arrow.down.circle" }
        return model.stackIsRunning ? "stop.fill" : "play.fill"
    }

    private func stackAction() {
        if model.stackIsRunning { Task { await model.stopAll() } }
        else if needsRuntimes { model.selectedSection = .runtimes }
        else { Task { await model.startAll() } }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var helperNoticeIsPresented: Binding<Bool> {
        Binding(get: { model.helperNotice != nil }, set: { if !$0 { model.helperNotice = nil } })
    }
}

private extension View {
    /// The toolbar floats over the window on every page. Without this, pages
    /// whose top is not a scroll view (Logs, empty states) get an opaque bar.
    /// macOS 15 keeps its standard bar, which scrolled content needs there.
    @ViewBuilder func clearToolbarBacking() -> some View {
        if #available(macOS 26, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

extension NavigationSection {
    static let workspace: [NavigationSection] = [.dashboard, .sites, .php, .database, .ssl, .mailpit, .localDNS]
    static let tools: [NavigationSection] = [.runtimes, .logs, .doctor, .settings]
}

struct HelperNoticeSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var suppress = false

    var body: some View {
        let blocking = model.helperNotice?.isBlocking == true
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(blocking ? "This setup needs the helper" : "Set up the DevStack helper?").font(.headline)
                    Text("Sites on ports 8080 and 8443 with .localhost names run without it. The helper is needed for custom hostnames and for ports 80 and 443.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(blocking
                         ? "Switch to 8080/8443 with .localhost names to run without it, or set it up now."
                         : "macOS asks you to approve it in System Settings → General → Login Items & Extensions.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .unavailable(let reason) = model.helperSetupState {
                        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if model.isPreviewBuild, model.runningTeamID == nil {
                        Label("This preview build cannot use the helper. Open the signed copy in Applications.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                if !blocking {
                    Toggle("Don't show again", isOn: $suppress).toggleStyle(.checkbox).disabled(model.isBusy)
                }
                Spacer()
                if model.isPreviewBuild {
                    Button("Open Signed Copy…") {
                        model.helperNotice = nil
                        model.openApplicationsBuild()
                    }
                    .disabled(model.isBusy)
                }
                Button(blocking ? "Not Now" : "Later") {
                    Task { if suppress { await model.dismissHelperNotice() } else { model.helperNotice = nil } }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
                Button {
                    Task {
                        // Stay open until installHelper finishes; close only on
                        // success (or keep "don't show again" when checked).
                        await model.installHelper()
                        if suppress { await model.dismissHelperNotice() }
                        else if model.helperInstalled { model.helperNotice = nil }
                    }
                } label: {
                    if model.isBusy { ProgressView().controlSize(.small) } else { Text("Set Up Helper…") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(model.isBusy)
    }
}
