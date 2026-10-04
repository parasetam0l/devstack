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
                }
            } else if filteredSites.isEmpty {
                ContentUnavailableView.search(text: state.search)
            } else {
                Table(filteredSites, selection: $state.selection) {
                    TableColumn("Name") { site in
                        HStack(spacing: 6) {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                            Text(site.name)
                            if site.hostname == "localhost" { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Hostname") { site in Text(site.hostname) }
                        .width(min: 120, ideal: 180)
                    TableColumn("PHP") { site in
                        Text(site.phpRuntimeID.replacingOccurrences(of: "php-", with: ""))
                            .foregroundStyle(site.phpRuntimeID == "php-7.4" ? .orange : .primary)
                            .help(site.phpRuntimeID == "php-7.4" ? "PHP 7.4 is end-of-life" : "")
                    }
                    .width(48)
                    TableColumn("HTTPS") { site in
                        Image(systemName: site.tlsEnabled ? "lock.fill" : "lock.open")
                            .foregroundStyle(site.tlsEnabled ? .primary : .tertiary)
                            .accessibilityLabel(site.tlsEnabled ? "HTTPS" : "HTTP only")
                    }
                    .width(52)
                    TableColumn("Folder") { site in
                        Text((site.documentRoot as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(site.documentRoot)
                    }
                    .width(min: 120)
                }
                .contextMenu(forSelectionType: SiteDefinition.ID.self) { ids in
                    if ids.count == 1, let site = sites(ids).first {
                        Button("Open in Browser") { model.openURL(model.siteURL(site)) }
                        Button("Edit Site…") { state.editingSite = site }
                        Divider()
                        Button("Show Project Folder in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.documentRoot)])
                        }
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.siteURL(site), forType: .string)
                        }
                        if site.hostname != "localhost" {
                            Divider()
                            Button("Remove Site…", role: .destructive) { state.deletingSite = site }
                        }
                    }
                } primaryAction: { ids in
                    if let site = sites(ids).first { state.editingSite = site }
                }
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Search Sites")
        .toolbar {
            ToolbarItem {
                Button { if let site = selectedSite { model.openURL(model.siteURL(site)) } } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .disabled(selectedSite == nil)
                .help("Open the selected site in the browser")
            }
            ToolbarItem {
                Button { state.editingSite = newSite() } label: { Label("New Site", systemImage: "plus") }
                    .help("Add a site")
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

    private var selectedSite: SiteDefinition? { sites(state.selection).first }

    private func sites(_ ids: Set<SiteDefinition.ID>) -> [SiteDefinition] {
        model.configuration.sites.filter { ids.contains($0.id) }
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

@MainActor private final class SitesViewState: ObservableObject {
    @Published var editingSite: SiteDefinition?
    @Published var deletingSite: SiteDefinition?
    @Published var selection = Set<SiteDefinition.ID>()
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
