import AppKit
import Combine
import DevStackCore
import SwiftUI

struct SitesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var viewState = SitesViewState()

    var body: some View {
        VStack(spacing: 0) {
            if model.configuration.sites.isEmpty {
                ContentUnavailableView {
                    Label("No Sites", systemImage: "network")
                } description: {
                    Text("Each site gets its own Apache virtual host and PHP-FPM pool.")
                } actions: {
                    Button("Add Site") { viewState.editingSite = newSite() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.configuration.sites) { site in
                        SiteRow(site: site) {
                            viewState.editingSite = site
                        } delete: {
                            Task { await model.deleteSite(site) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sites")
        .toolbar {
            Button("Add Site", systemImage: "plus") { viewState.editingSite = newSite() }
        }
        .sheet(item: $viewState.editingSite) { site in
            SiteEditor(site: site) { saved in
                try await model.saveSite(saved)
            }
        }
    }

    private func newSite() -> SiteDefinition {
        let id = UUID()
        return SiteDefinition(
            id: id,
            name: "New Site",
            hostname: "site.devstack.test",
            documentRoot: NSHomeDirectory(),
            logs: SiteLogPaths(
                access: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-access.log").path,
                error: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-error.log").path
            )
        )
    }
}

@MainActor
private final class SitesViewState: ObservableObject {
    @Published var editingSite: SiteDefinition?
}

private struct SiteRow: View {
    let site: SiteDefinition
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: site.tlsEnabled ? "lock.fill" : "globe")
                .foregroundStyle(site.tlsEnabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name).font(.headline)
                Text(site.hostname).foregroundStyle(.secondary)
                Text(site.documentRoot).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if site.phpRuntimeID == "php-7.4" {
                Text("EOL").font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(site.phpRuntimeID.replacingOccurrences(of: "php-", with: "PHP "))
                .font(.callout.monospacedDigit())
            Button("Open") {
                let scheme = site.tlsEnabled ? "https" : "http"
                NSWorkspace.shared.open(URL(string: "\(scheme)://\(site.hostname)")!)
            }
            Button("Edit", action: edit)
            Menu {
                Button("Delete", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
    }
}

private struct SiteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: SiteEditorState
    let save: (SiteDefinition) async throws -> Void

    init(site: SiteDefinition, save: @escaping (SiteDefinition) async throws -> Void) {
        _editor = StateObject(wrappedValue: SiteEditorState(site: site))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Site Configuration").font(.title2.bold())
            Form {
                TextField("Name", text: $editor.site.name)
                TextField("Hostname", text: $editor.site.hostname)
                    .textContentType(.URL)
                if HostnameValidator.shadowsPublicDomain(editor.site.hostname) {
                    Label("This hostname is not in the reserved .test domain; its /etc/hosts entry can shadow the real domain.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Document root") {
                    HStack {
                        TextField("Folder", text: $editor.site.documentRoot)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("PHP", selection: phpRuntimeBinding) {
                    Text("PHP 8.5.11").tag("php-8.5")
                    Text("PHP 7.4.33 — Legacy/EOL").tag("php-7.4")
                }
                Toggle("Enable trusted HTTPS", isOn: $editor.site.tlsEnabled)
                Section("PHP limits") {
                    TextField("Memory limit", text: $editor.site.phpOverrides.memoryLimit)
                    TextField("Upload limit", text: $editor.site.phpOverrides.uploadMaxFilesize)
                    TextField("POST limit", text: $editor.site.phpOverrides.postMaxSize)
                    Stepper("Execution time: \(editor.site.phpOverrides.maxExecutionTime)s", value: $editor.site.phpOverrides.maxExecutionTime, in: 1...3_600)
                    Toggle("Display errors", isOn: $editor.site.phpOverrides.displayErrors)
                }
            }
            .formStyle(.grouped)

            if editor.site.phpRuntimeID == "php-7.4" {
                Label("PHP 7.4 is end-of-life. Use it only for legacy compatibility.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let errorMessage = editor.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    editor.isSaving = true
                    Task {
                        do {
                            try await save(editor.site)
                            dismiss()
                        } catch {
                            editor.errorMessage = error.localizedDescription
                            editor.isSaving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editor.isSaving || editor.site.name.isEmpty || editor.site.hostname.isEmpty || editor.site.documentRoot.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 600)
        .alert("PHP 7.4 is end-of-life", isPresented: $editor.isConfirmingLegacyRuntime) {
            Button("Use PHP 7.4", role: .destructive) { editor.site.phpRuntimeID = "php-7.4" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PHP 7.4 no longer receives security fixes. Use it only for legacy compatibility and keep the site off untrusted networks.")
        }
    }

    private var phpRuntimeBinding: Binding<String> {
        Binding(
            get: { editor.site.phpRuntimeID },
            set: { newValue in
                if newValue == "php-7.4", editor.site.phpRuntimeID != "php-7.4" {
                    editor.isConfirmingLegacyRuntime = true
                } else {
                    editor.site.phpRuntimeID = newValue
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editor.site.documentRoot = url.path
        }
    }
}

@MainActor
private final class SiteEditorState: ObservableObject {
    @Published var site: SiteDefinition
    @Published var errorMessage: String?
    @Published var isSaving = false
    @Published var isConfirmingLegacyRuntime = false

    init(site: SiteDefinition) {
        self.site = site
    }
}
