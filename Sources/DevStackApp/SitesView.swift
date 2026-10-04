import AppKit
import Combine
import DevStackCore
import SwiftUI

struct SitesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SitesViewState()

    var body: some View {
        WorkspacePage {
            HStack(alignment: .center) {
                PageHeading(title: "Sites", subtitle: "A local domain and a dedicated PHP pool for every project.")
                Spacer()
                Button { state.editingSite = newSite() } label: { Label("New Site", systemImage: "plus") }
                    .buttonStyle(DevStackProminentButtonStyle()).controlSize(.small)
            }
            if model.configuration.sites.isEmpty {
                SurfacePanel {
                    EmptyWorkspace(symbol: "globe", title: "Your projects belong here", description: "Add a project folder to configure its domain, PHP version, and HTTPS.", actionTitle: "Add a Site") { state.editingSite = newSite() }
                }
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a site", text: $state.search).textFieldStyle(.plain)
                        if !state.search.isEmpty {
                            Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }.padding(7).devStackGlass(.rect(cornerRadius: 8)).frame(maxWidth: 350)
                    Spacer()
                    Text("\(filteredSites.count) \(filteredSites.count == 1 ? "site" : "sites")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if filteredSites.isEmpty {
                    EmptyWorkspace(symbol: "magnifyingglass", title: "No matching sites", description: "Try a different name, hostname, or folder.")
                } else {
                    SurfacePanel {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredSites.enumerated()), id: \.element.id) { index, site in
                                if index > 0 { Divider() }
                                SiteRow(site: site, edit: { state.editingSite = site }, delete: { state.deletingSite = site })
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $state.editingSite) { site in
            SiteEditor(site: site, isNew: !model.configuration.sites.contains { $0.id == site.id }) { saved in try await model.saveSite(saved) }
                .environmentObject(model)
                .focusEffectDisabled()
        }
        .alert("Remove this site?", isPresented: Binding(get: { state.deletingSite != nil }, set: { if !$0 { state.deletingSite = nil } }), presenting: state.deletingSite) { site in
            Button("Remove Site", role: .destructive) { state.deletingSite = nil; Task { await model.deleteSite(site) } }
            Button("Cancel", role: .cancel) { state.deletingSite = nil }
        } message: { site in Text("\(site.name) will be removed from DevStack. Its project files will stay in place.") }
        .onAppear(perform: presentRequestedSite)
        .onChange(of: model.isPresentingNewSite) { _, _ in presentRequestedSite() }
    }

    private var filteredSites: [SiteDefinition] {
        model.configuration.sites.filter { state.search.isEmpty || "\($0.name) \($0.hostname) \($0.documentRoot)".localizedCaseInsensitiveContains(state.search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        return SiteDefinition(id: id, name: "", hostname: "site-\(number).localhost", documentRoot: "", phpRuntimeID: model.configuration.defaultPHPRuntimeID, logs: SiteLogPaths(access: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-access.log").path, error: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-error.log").path))
    }
}

@MainActor private final class SitesViewState: ObservableObject {
    @Published var editingSite: SiteDefinition?
    @Published var deletingSite: SiteDefinition?
    @Published var search = ""
}

private struct SiteRow: View {
    @EnvironmentObject private var model: AppModel
    let site: SiteDefinition
    let edit: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            FeatureIcon(symbol: "globe")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(site.name).font(.system(size: 12, weight: .semibold))
                    if site.hostname == "localhost" { StatusBadge(title: "Default", color: DevStackDesign.accent) }
                    if site.phpRuntimeID == "php-7.4" { StatusBadge(title: "Legacy", color: .orange) }
                }
                Text(site.hostname).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(site.documentRoot).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(site.documentRoot)
            HStack(spacing: 5) {
                StatusBadge(title: site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "))
                StatusBadge(title: site.tlsEnabled ? "HTTPS" : "HTTP", color: site.tlsEnabled ? DevStackDesign.accent : .secondary)
            }
            Button { model.openURL(model.siteURL(site)) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(.borderless).help("Open \(site.name)").accessibilityLabel("Open \(site.name)")
            Menu {
                Button("Edit Site…", systemImage: "pencil", action: edit)
                Button("Reveal Project Folder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.documentRoot)]) }
                Button("Copy URL", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(site.tlsEnabled ? "https" : "http")://\(site.hostname)", forType: .string)
                }
                Divider()
                if site.hostname != "localhost" {
                    Button("Remove Site…", systemImage: "trash", role: .destructive, action: delete)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("Site actions").accessibilityLabel("Actions for \(site.name)")
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Site" : "Edit Site").font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    TextField("My project", text: $editor.site.name)
                }
                GridRow {
                    Text("Project folder").foregroundStyle(.secondary)
                    HStack {
                        Text(editor.site.documentRoot.isEmpty ? "Choose document root" : editor.site.documentRoot)
                            .foregroundStyle(editor.site.documentRoot.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseFolder).buttonStyle(DevStackGlassButtonStyle())
                    }
                }
                GridRow {
                    Text("Hostname").foregroundStyle(.secondary)
                    TextField("project.localhost", text: $editor.site.hostname).textContentType(.URL)
                        .disabled(isDefaultSite)
                }
                GridRow {
                    Text("PHP version").foregroundStyle(.secondary)
                    Picker("PHP version", selection: phpRuntimeBinding) {
                        ForEach(model.availablePHPRuntimes) { runtime in Text("PHP \(runtime.version)").tag(runtime.id) }
                    }.labelsHidden().tint(.primary).frame(maxWidth: 180, alignment: .leading)
                }
                GridRow {
                    Text("SSL").foregroundStyle(.secondary)
                    Toggle("HTTPS", isOn: $editor.site.tlsEnabled).toggleStyle(.switch).disabled(isDefaultSite)
                }
                GridRow {
                    Text("Starter file").foregroundStyle(.secondary)
                    Toggle("Add index.php", isOn: $editor.site.createPlaceholderIndex)
                        .toggleStyle(.checkbox)
                        .disabled(isDefaultSite)
                        .help("Writes a starter index.php when the folder has no index file. Existing files are never overwritten.")
                }
            }.textFieldStyle(.roundedBorder)
            if isDefaultSite {
                Label("The default site always serves localhost and 127.0.0.1 over HTTP and HTTPS.", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            } else if HostnameValidator.shadowsPublicDomain(editor.site.hostname) {
                Label("This domain can shadow a public website. Prefer .test.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if editor.site.phpRuntimeID == "php-7.4" {
                Label("PHP 7.4 is end-of-life. Use only for legacy compatibility.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Divider()
            DisclosureGroup("Advanced PHP settings") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("Memory limit").frame(width: 90, alignment: .leading); TextField("Memory limit", text: $editor.site.phpOverrides.memoryLimit) }
                    GridRow { Text("Upload limit"); TextField("Upload limit", text: $editor.site.phpOverrides.uploadMaxFilesize) }
                    GridRow { Text("POST limit"); TextField("POST limit", text: $editor.site.phpOverrides.postMaxSize) }
                    GridRow { Text("Execution time"); Stepper("\(editor.site.phpOverrides.maxExecutionTime)s", value: $editor.site.phpOverrides.maxExecutionTime, in: 1...3600) }
                    GridRow { Text("Errors"); Toggle("Display errors", isOn: $editor.site.phpOverrides.displayErrors).toggleStyle(.switch) }
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
            }
            if let error = editor.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                if editor.isSaving { ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(DevStackGlassButtonStyle()).disabled(editor.isSaving)
                Button(isNew ? "Create Site" : "Save Changes", action: saveSite).keyboardShortcut(.defaultAction).buttonStyle(DevStackGlassButtonStyle())
                    .disabled(editor.isSaving || !canSave)
            }
        }.font(.system(size: 12)).controlSize(.small).padding(18)
        .frame(width: 580).tint(Color(nsColor: .controlAccentColor))
        .alert("Use legacy PHP 7.4?", isPresented: $editor.isConfirmingLegacyRuntime) {
            Button("Use PHP 7.4", role: .destructive) { editor.site.phpRuntimeID = "php-7.4" }
            Button("Cancel", role: .cancel) {}
        } message: { Text("PHP 7.4 no longer receives security fixes. Use it only for legacy compatibility on this Mac.") }
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
        !editor.site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !editor.site.hostname.isEmpty && validationError == nil && !editor.site.documentRoot.isEmpty && model.runtimeIsAvailable(editor.site.phpRuntimeID)
    }
    private var phpRuntimeBinding: Binding<String> {
        Binding(get: { editor.site.phpRuntimeID }, set: {
            if $0 == "php-7.4", editor.site.phpRuntimeID != "php-7.4" { editor.isConfirmingLegacyRuntime = true }
            else { editor.site.phpRuntimeID = $0 }
        })
    }
    private func saveSite() {
        editor.isSaving = true; editor.errorMessage = nil
        editor.site.name = editor.site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do { try await save(editor.site); dismiss() }
            catch { editor.errorMessage = error.localizedDescription; editor.isSaving = false }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
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
