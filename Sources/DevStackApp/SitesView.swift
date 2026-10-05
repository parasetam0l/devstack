import AppKit
import Combine
import DevStackCore
import SwiftUI

struct SitesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SitesViewState()

    var body: some View {
        Group {
            if model.configuration.sites.isEmpty {
                ContentUnavailableView {
                    Label("No Sites", systemImage: "globe")
                } description: {
                    Text("Add a project folder to serve it at its own local domain, with its own PHP version and HTTPS.")
                } actions: {
                    Button("New Site…") { state.editingSite = newSite() }
                    Button("Import from Another App…") { model.presentMigrationWizard() }
                }
            } else if filteredSites.isEmpty {
                ContentUnavailableView.search(text: state.search)
            } else {
                PanelPage {
                    Panel {
                        ForEach(filteredSites) { site in
                            SiteRow(site: site, served: served(site), edit: { state.editingSite = site }, remove: { state.deletingSite = site })
                        }
                    }
                    Text("Double-click a site to edit it.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, -9)
                }
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Search Sites")
        .toolbar {
            // Its own glass capsule, apart from the stack controls.
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            ToolbarItem {
                Button { model.presentMigrationWizard() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import projects and databases from XAMPP")
            }
            ToolbarItem {
                Button { state.editingSite = newSite() } label: { Label("New Site", systemImage: "plus") }
                    .help("Add a site (⌘N)")
            }
        }
        .sheet(item: $state.editingSite) { site in
            SiteEditor(site: site, isNew: !model.configuration.sites.contains { $0.id == site.id }) { saved in try await model.saveSite(saved) }
                .environmentObject(model)
        }
        .alert("Remove \(state.deletingSite?.name ?? "this site")?",
               isPresented: Binding(get: { state.deletingSite != nil }, set: { if !$0 { state.deletingSite = nil } }),
               presenting: state.deletingSite) { site in
            Button("Remove", role: .destructive) { state.deletingSite = nil; Task { await model.deleteSite(site) } }
            Button("Cancel", role: .cancel) { state.deletingSite = nil }
        } message: { _ in
            Text("DevStack stops serving it. The project folder and its files stay where they are.")
        }
        .onAppear(perform: presentRequestedSite)
        .onChange(of: model.isPresentingNewSite) { _, _ in presentRequestedSite() }
    }

    private var filteredSites: [SiteDefinition] {
        model.configuration.sites
            .filter { state.search.isEmpty || "\($0.name) \($0.hostname) \($0.documentRoot)".localizedCaseInsensitiveContains(state.search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Served while the web server and the site's PHP version run.
    private func served(_ site: SiteDefinition) -> Bool {
        model.serviceIsRunning(model.configuration.selectedWebServer.service)
            && ServiceKind(rawValue: site.phpRuntimeID).map(model.serviceIsRunning) == true
    }

    private func presentRequestedSite() {
        guard model.isPresentingNewSite else { return }
        state.editingSite = newSite()
        model.isPresentingNewSite = false
    }

    private func newSite() -> SiteDefinition {
        let id = UUID()
        var number = 1
        let hosts = Set(model.configuration.sites.map(\.hostname))
        while hosts.contains("site-\(number).localhost") { number += 1 }
        return SiteDefinition(id: id, name: "", hostname: "site-\(number).localhost", documentRoot: "", phpRuntimeID: model.configuration.defaultPHPRuntimeID,
                              logs: SiteLogPaths(access: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-access.log").path,
                                                 error: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-error.log").path))
    }
}

/// A site on one line: whether it is served, its name, URL, folder and PHP
/// version, and quick actions. Double-click edits it.
private struct SiteRow: View {
    @EnvironmentObject private var model: AppModel
    let site: SiteDefinition
    let served: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        let url = model.siteURL(site)
        let folder = URL(fileURLWithPath: site.documentRoot)
        PanelRow {
            StatusDot(color: served ? .green : Color(nsColor: .tertiaryLabelColor))
                .help(served ? "Served" : "Not served while the stack is stopped")
            Image(systemName: site.tlsEnabled ? "lock" : "globe").foregroundStyle(.secondary).frame(width: 18)
                .help(site.tlsEnabled ? "HTTPS" : "HTTP only")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(site.name).fontWeight(.medium).lineLimit(1)
                    if site.hostname == "localhost" { Tag(text: "Default") }
                }
                Text((site.documentRoot as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .help(site.documentRoot)
            }
            .frame(width: 220, alignment: .leading)
            Text(url).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(url)
            Tag(text: site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "), tint: site.phpRuntimeID == "php-7.4" ? .orange : .secondary)
                .help(site.phpRuntimeID == "php-7.4" ? "PHP 7.4 is end-of-life" : "")
            HStack(spacing: 6) {
                IconButton(title: "Open \(site.name) in the browser", symbol: "arrow.up.forward.app") { model.openURL(url) }
                IconButton(title: "Show the project folder in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                IconButton(title: "Edit \(site.name)", symbol: "pencil", action: edit)
                Menu {
                    menuItems(url: url, folder: folder)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More actions for \(site.name)")
            }
            .frame(width: ServiceRowLayout.controls, alignment: .trailing)
        }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu { menuItems(url: url, folder: folder) }
    }

    @ViewBuilder private func menuItems(url: String, folder: URL) -> some View {
        Button("Open in Browser") { model.openURL(url) }
        Button("Edit Site…", action: edit)
        Divider()
        Button("Show Project Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        Button("Copy URL") { Pasteboard.copy(url) }
        Button("Copy Folder Path") { Pasteboard.copy(site.documentRoot) }
        if !site.logs.error.isEmpty {
            Button("Show Error Log") {
                model.selectedLogFile = URL(fileURLWithPath: site.logs.error).lastPathComponent
                model.selectedSection = .logs
            }
        }
        if site.hostname != "localhost" {
            Divider()
            Button("Remove Site…", role: .destructive, action: remove)
        }
    }
}

@MainActor private final class SitesViewState: ObservableObject {
    @Published var editingSite: SiteDefinition?
    @Published var deletingSite: SiteDefinition?
    @Published var search = ""
}

struct SiteEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: SiteEditorState
    let isNew: Bool
    let save: (SiteDefinition) async throws -> Void

    init(site: SiteDefinition, isNew: Bool = false, save: @escaping (SiteDefinition) async throws -> Void) {
        _editor = StateObject(wrappedValue: SiteEditorState(site: site))
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Site" : "Edit \(editor.site.name)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $editor.site.name, prompt: Text("My project"))
                    LabeledContent("Project folder") {
                        HStack {
                            Text(editor.site.documentRoot.isEmpty ? "None" : (editor.site.documentRoot as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(editor.site.documentRoot.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle).help(editor.site.documentRoot)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    TextField("Hostname", text: $editor.site.hostname, prompt: Text("project.localhost"))
                        .textContentType(.URL)
                        .disabled(isDefaultSite)
                    Picker("PHP version", selection: phpRuntimeBinding) {
                        ForEach(model.phpRuntimes) { runtime in
                            Text(model.runtimeOptionTitle("PHP \(runtime.version)", id: runtime.id)).tag(runtime.id)
                                .disabled(!model.runtimeIsAvailable(runtime.id))
                        }
                    }
                    Toggle("HTTPS", isOn: $editor.site.tlsEnabled).disabled(isDefaultSite)
                    Toggle("Add a starter index.php", isOn: $editor.site.createPlaceholderIndex)
                        .disabled(isDefaultSite)
                        .help("Writes a starter index.php when the folder has no index file. Existing files are never overwritten.")
                } footer: { SectionFooter {
                    VStack(alignment: .leading, spacing: 4) {
                        if isDefaultSite {
                            Label("The default site always serves localhost and 127.0.0.1 over HTTP and HTTPS.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        if let validationError {
                            Label(validationError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        } else if HostnameValidator.shadowsPublicDomain(editor.site.hostname) {
                            Label("This domain can hide a public website. Prefer .test or .localhost.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if editor.site.phpRuntimeID == "php-7.4" {
                            Label("PHP 7.4 is end-of-life. Use it only for legacy projects.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } }
                Section("PHP settings") {
                    TextField("Memory limit", text: $editor.site.phpOverrides.memoryLimit)
                    TextField("Upload limit", text: $editor.site.phpOverrides.uploadMaxFilesize)
                    TextField("POST limit", text: $editor.site.phpOverrides.postMaxSize)
                    Stepper("Execution time: \(editor.site.phpOverrides.maxExecutionTime) s",
                            value: $editor.site.phpOverrides.maxExecutionTime, in: 1...3600)
                    Toggle("Display errors", isOn: $editor.site.phpOverrides.displayErrors)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if editor.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                } else if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(editor.isSaving)
                Button(isNew ? "Create Site" : "Save", action: saveSite)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.isSaving || !canSave)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
        .alert("Use legacy PHP 7.4?", isPresented: $editor.isConfirmingLegacyRuntime) {
            Button("Use PHP 7.4", role: .destructive) { editor.site.phpRuntimeID = "php-7.4" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PHP 7.4 no longer receives security fixes. Use it only for legacy compatibility on this Mac.")
        }
        .interactiveDismissDisabled(editor.isSaving)
    }

    private var isDefaultSite: Bool { editor.site.hostname == "localhost" }

    private var validationError: String? {
        guard !editor.site.hostname.isEmpty else { return nil }
        do {
            _ = try HostnameValidator.validateSite(editor.site.hostname, existing: model.configuration.sites.filter { $0.id != editor.site.id }.map(\.hostname))
            return nil
        } catch { return error.localizedDescription }
    }

    private var canSave: Bool {
        !editor.site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !editor.site.hostname.isEmpty && validationError == nil
            && !editor.site.documentRoot.isEmpty && model.runtimeIsAvailable(editor.site.phpRuntimeID)
    }

    private var phpRuntimeBinding: Binding<String> {
        Binding(get: { editor.site.phpRuntimeID }, set: {
            if $0 == "php-7.4", editor.site.phpRuntimeID != "php-7.4" { editor.isConfirmingLegacyRuntime = true }
            else { editor.site.phpRuntimeID = $0 }
        })
    }

    private func saveSite() {
        editor.isSaving = true
        editor.errorMessage = nil
        editor.site.name = editor.site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do { try await save(editor.site); dismiss() }
            catch { editor.errorMessage = error.localizedDescription; editor.isSaving = false }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder to serve."
        if panel.runModal() == .OK, let url = panel.url {
            editor.site.documentRoot = url.path
            if editor.site.name.isEmpty { editor.site.name = url.lastPathComponent }
        }
    }
}

@MainActor private final class SiteEditorState: ObservableObject {
    @Published var site: SiteDefinition
    @Published var errorMessage: String?
    @Published var isSaving = false
    @Published var isConfirmingLegacyRuntime = false
    init(site: SiteDefinition) { self.site = site }
}
