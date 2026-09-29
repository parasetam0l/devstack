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
                    .buttonStyle(.glassProminent).controlSize(.large)
            }
            if model.configuration.sites.isEmpty {
                SurfacePanel {
                    EmptyWorkspace(symbol: "globe", title: "Your projects belong here", description: "Add an existing project folder to give it a local domain and trusted HTTPS.", actionTitle: "Add a Site") { state.editingSite = newSite() }
                }
            } else {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a site", text: $state.search).textFieldStyle(.plain)
                        if !state.search.isEmpty {
                            Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }.padding(11).glassEffect(.regular, in: .rect(cornerRadius: 12)).frame(maxWidth: 350)
                    Spacer()
                    Text("\(filteredSites.count) \(filteredSites.count == 1 ? "site" : "sites")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if filteredSites.isEmpty {
                    EmptyWorkspace(symbol: "magnifyingglass", title: "No matching sites", description: "Try a different name, hostname, or folder.")
                } else {
                    VStack(spacing: 12) {
                        ForEach(filteredSites) { site in
                            SiteRow(site: site, edit: { state.editingSite = site }, delete: { state.deletingSite = site })
                        }
                    }
                }
            }
        }
        .sheet(item: $state.editingSite) { site in
            SiteEditor(site: site, isNew: !model.configuration.sites.contains { $0.id == site.id }) { saved in try await model.saveSite(saved) }
                .environmentObject(model)
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
        while hosts.contains("site-\(number).devstack.test") { number += 1 }
        return SiteDefinition(id: id, name: "", hostname: "site-\(number).devstack.test", documentRoot: "", logs: SiteLogPaths(access: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-access.log").path, error: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-error.log").path))
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
        HStack(spacing: 16) {
            FeatureIcon(symbol: "globe")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(site.name).font(.system(size: 14, weight: .semibold))
                    if site.phpRuntimeID == "php-7.4" { StatusBadge(title: "Legacy", color: .orange) }
                }
                Text(site.hostname).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(site.documentRoot).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                StatusBadge(title: site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "))
                StatusBadge(title: site.tlsEnabled ? "HTTPS" : "HTTP", color: site.tlsEnabled ? DevStackDesign.accent : .secondary)
            }
            Button { model.openURL("\(site.tlsEnabled ? "https" : "http")://\(site.hostname)") } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Open \(site.name)").accessibilityLabel("Open \(site.name)")
            Menu {
                Button("Edit Site…", systemImage: "pencil", action: edit)
                Button("Reveal Project Folder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.documentRoot)]) }
                Button("Copy URL", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(site.tlsEnabled ? "https" : "http")://\(site.hostname)", forType: .string)
                }
                Divider()
                Button("Remove Site…", systemImage: "trash", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 22).help("Site actions").accessibilityLabel("Actions for \(site.name)")
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055), lineWidth: 1) }
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "globe")
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "New Site" : "Edit Site").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Give your project a place on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section("Project") {
                    TextField("Name", text: $editor.site.name, prompt: Text("My project"))
                    LabeledContent("Project folder") {
                        HStack {
                            Text(editor.site.documentRoot.isEmpty ? "Choose your document root" : editor.site.documentRoot)
                                .font(.system(size: 12)).foregroundStyle(editor.site.documentRoot.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Text("Select the folder Apache should serve, such as your project's public directory.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Local domain") {
                    TextField("Hostname", text: $editor.site.hostname).textContentType(.URL)
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red)
                    } else if HostnameValidator.shadowsPublicDomain(editor.site.hostname) {
                        Label("This domain can shadow a public website. A .test domain is recommended.", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Toggle("Trusted HTTPS", isOn: $editor.site.tlsEnabled)
                    Text("DevStack creates a local certificate for this domain.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("PHP runtime") {
                    Picker("Version", selection: phpRuntimeBinding) {
                        Text("PHP 8.5.11").tag("php-8.5").disabled(!model.runtimeIsAvailable("php-8.5"))
                        Text(model.runtimeIsAvailable("php-7.4") ? "PHP 7.4.33 · Legacy" : "PHP 7.4 · Not installed").tag("php-7.4").disabled(!model.runtimeIsAvailable("php-7.4"))
                    }
                    if editor.site.phpRuntimeID == "php-7.4" {
                        Label("End-of-life. Use only for legacy compatibility.", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("Advanced PHP settings") {
                    TextField("Memory limit", text: $editor.site.phpOverrides.memoryLimit)
                    TextField("Upload limit", text: $editor.site.phpOverrides.uploadMaxFilesize)
                    TextField("POST limit", text: $editor.site.phpOverrides.postMaxSize)
                    Stepper("Execution time: \(editor.site.phpOverrides.maxExecutionTime)s", value: $editor.site.phpOverrides.maxExecutionTime, in: 1...3600)
                    Toggle("Display errors", isOn: $editor.site.phpOverrides.displayErrors)
                }
            }.formStyle(.grouped)
            if let error = editor.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack {
                if editor.isSaving { ProgressView().controlSize(.small); Text("Saving…").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass).disabled(editor.isSaving)
                Button(isNew ? "Create Site" : "Save Changes", action: saveSite).keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                    .disabled(editor.isSaving || !canSave)
            }.padding(20)
        }
        .frame(width: 640, height: 690).tint(DevStackDesign.accent)
        .alert("Use legacy PHP 7.4?", isPresented: $editor.isConfirmingLegacyRuntime) {
            Button("Use PHP 7.4", role: .destructive) { editor.site.phpRuntimeID = "php-7.4" }
            Button("Cancel", role: .cancel) {}
        } message: { Text("PHP 7.4 no longer receives security fixes. Use it only for legacy compatibility on this Mac.") }
        .interactiveDismissDisabled(editor.isSaving)
    }

    private var validationError: String? {
        guard !editor.site.hostname.isEmpty else { return nil }
        do {
            _ = try HostnameValidator.validate(editor.site.hostname, existing: model.configuration.sites.filter { $0.id != editor.site.id }.map(\.hostname))
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
        panel.message = "Choose the folder Apache should serve."
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
