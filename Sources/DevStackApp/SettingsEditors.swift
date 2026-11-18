import AppKit
import DevStackCore
import SwiftUI

// MARK: - Shared rows

/// A size or number field on the right of a settings row.
private struct SettingField: View {
    let label: String
    var detail: String?
    @Binding var text: String
    var valid: Bool

    var body: some View {
        SettingRow(label: label, detail: detail) {
            TextField(label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: 110)
                .foregroundStyle(valid ? Color.primary : Color.red)
        }
    }
}

private func numberBinding(_ value: Binding<Int>) -> Binding<String> {
    Binding(get: { String(value.wrappedValue) }, set: { value.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 })
}

private func sizeBinding(_ value: Binding<String>) -> Binding<String> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.trimmingCharacters(in: .whitespaces).uppercased() })
}

/// Revert and Apply for a settings form, plus the button that opens the
/// user's own settings file.
private struct ApplyRow: View {
    let editLabel: String
    let changed: Bool
    let valid: Bool
    let edit: () -> Void
    let revert: () -> Void
    let apply: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PanelRow {
            Button(editLabel, action: edit)
            Spacer()
            if changed && !valid { Text("Check the values in red.").font(.caption).foregroundStyle(.red) }
            Button("Revert", action: revert).disabled(!changed)
            Button("Apply", action: apply).keyboardShortcut(.defaultAction).disabled(!changed || !valid)
        }
        .controlSize(.small)
        .disabled(model.isBusy)
    }
}

/// A plain-text editor for a settings file the user owns.
struct UserSettingsSheet: View {
    let title: String
    let detail: String
    let file: URL
    let template: String
    let save: (String) async throws -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .frame(minHeight: 280)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout).lineLimit(5)
            }
            HStack {
                Button("Open in Text Editor") {
                    model.openInTextEditor(file, template: text)
                    dismiss()
                }
                .help("Saves nothing; edit \(file.lastPathComponent) in your editor, then apply it here or restart the service")
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and Restart") {
                    saving = true
                    error = nil
                    Task {
                        do { try await save(text); dismiss() } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || model.isBusy)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear { text = model.userSettingsText(file, template: template) }
    }
}

// MARK: - PHP

struct PHPSettingsPanel: View {
    let runtimeID: String
    @EnvironmentObject private var model: AppModel
    @State private var draft = PHPSettings()
    @State private var editingINI = false
    @State private var error: String?

    private var saved: PHPSettings { model.configuration.php(runtimeID) }
    private var versionName: String { runtimeID.replacingOccurrences(of: "php-", with: "PHP ") }

    var body: some View {
        Panel("\(versionName) Settings", note: error ?? "Sites use these unless a site sets its own. Applying restarts PHP and the web server.") {
            SettingField(label: "Memory limit", detail: "-1 for no limit", text: sizeBinding($draft.memoryLimit),
                         valid: PHPSettings.isValidSize(draft.memoryLimit, unlimited: true))
            SettingField(label: "Upload limit", detail: "Largest uploaded file", text: sizeBinding($draft.uploadMaxFilesize),
                         valid: PHPSettings.isValidSize(draft.uploadMaxFilesize))
            SettingField(label: "POST limit", detail: "Whole request; keep it at least the upload limit", text: sizeBinding($draft.postMaxSize),
                         valid: PHPSettings.isValidSize(draft.postMaxSize))
            SettingField(label: "Execution time", detail: "Seconds; 0 for no limit", text: numberBinding($draft.maxExecutionTime),
                         valid: draft.maxExecutionTime >= 0)
            SettingField(label: "Input variables", detail: "max_input_vars", text: numberBinding($draft.maxInputVars),
                         valid: draft.maxInputVars > 0)
            SettingRow(label: "Error reporting") {
                Picker("Error reporting", selection: $draft.errorReporting) {
                    ForEach(PHPSettings.ErrorReporting.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            toggleRow("Display errors", detail: "Show errors in the page", isOn: $draft.displayErrors)
            toggleRow("Short open tags", detail: "Allow <? for older projects", isOn: $draft.shortOpenTag)
            toggleRow("OPcache", detail: "Cache compiled scripts", isOn: $draft.opcache)
            ApplyRow(editLabel: "Edit php.ini…", changed: draft != saved, valid: draft.isValid,
                     edit: { editingINI = true }, revert: { draft = saved }) {
                Task {
                    do { try await model.applyPHPSettings(draft, runtimeID: runtimeID); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { draft = saved }
        .onChange(of: runtimeID) { draft = saved; error = nil }
        .sheet(isPresented: $editingINI) {
            UserSettingsSheet(
                title: "\(versionName) php.ini",
                detail: "Your own php.ini lines, loaded after DevStack's settings so they win. DevStack keeps paths, sockets and extensions itself.",
                file: model.paths.userPHPINI(runtimeID),
                template: "; Your PHP settings for \(versionName). Lines here override DevStack's.\n; Example:\n; max_input_time = 300\n"
            ) { text in
                try await model.applyPHPSettings(draft.isValid ? draft : saved, userINI: text, runtimeID: runtimeID)
            }
            .environmentObject(model)
        }
    }

    private func toggleRow(_ label: String, detail: String, isOn: Binding<Bool>) -> some View {
        SettingRow(label: label, detail: detail) {
            Toggle(label, isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

// MARK: - MySQL

struct MySQLSettingsPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = MySQLSettings()
    @State private var editingConfiguration = false
    @State private var error: String?

    private var engine: DatabaseEngine { model.configuration.selectedDatabase }
    private var saved: MySQLSettings { model.configuration.mysql(engine) }

    var body: some View {
        Panel("MySQL Settings", note: error ?? "Applying restarts MySQL.") {
            SettingField(label: "Max packet", detail: "Largest query or row; raise it for big imports", text: sizeBinding($draft.maxAllowedPacket),
                         valid: PHPSettings.isValidSize(draft.maxAllowedPacket))
            SettingField(label: "Buffer pool", detail: "Memory InnoDB caches data in", text: sizeBinding($draft.innodbBufferPoolSize),
                         valid: PHPSettings.isValidSize(draft.innodbBufferPoolSize))
            SettingField(label: "Max connections", text: numberBinding($draft.maxConnections), valid: (1...100_000).contains(draft.maxConnections))
            SettingField(label: "Idle timeout", detail: "Seconds before an idle connection closes", text: numberBinding($draft.waitTimeout),
                         valid: (1...31_536_000).contains(draft.waitTimeout))
            SettingRow(label: "SQL mode", detail: "Empty keeps MySQL's default") {
                TextField("SQL mode", text: Binding(get: { draft.sqlMode ?? "" }, set: {
                    let mode = $0.replacingOccurrences(of: " ", with: "").uppercased()
                    draft.sqlMode = mode.isEmpty ? nil : mode
                }), prompt: Text("Default"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: 260)
            }
            SettingRow(label: "Slow query log", detail: "Logs queries over 2 seconds to \(engine.rawValue)-slow.log") {
                Toggle("Slow query log", isOn: $draft.slowQueryLog).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            ApplyRow(editLabel: "Edit my.cnf…", changed: draft != saved, valid: draft.isValid,
                     edit: { editingConfiguration = true }, revert: { draft = saved }) {
                Task {
                    do { try await model.applyMySQLSettings(draft); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { draft = saved }
        .onChange(of: engine) { draft = saved; error = nil }
        .sheet(isPresented: $editingConfiguration) {
            UserSettingsSheet(
                title: "\(engine.displayName) my.cnf",
                detail: "Your own [mysqld] options, loaded after DevStack's settings so they win. Saving restarts MySQL; a typo keeps the old settings.",
                file: model.paths.userMySQLConfiguration(engine),
                template: "# Your MySQL options. Lines here override DevStack's.\n# Example:\n# innodb_log_buffer_size=64M\n"
            ) { text in
                try await model.applyMySQLSettings(draft.isValid ? draft : saved, userConfiguration: text)
            }
            .environmentObject(model)
        }
    }
}

// MARK: - phpMyAdmin

struct PHPMyAdminSettingsPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = PHPMyAdminSettings()
    @State private var editingConfiguration = false
    @State private var error: String?

    private var saved: PHPMyAdminSettings { model.configuration.phpMyAdminSettings }

    var body: some View {
        Panel("phpMyAdmin", note: error ?? "Adminer uses the same upload and memory limits.") {
            SettingField(label: "Upload limit", detail: "Largest file to import", text: sizeBinding($draft.uploadLimit),
                         valid: PHPSettings.isValidSize(draft.uploadLimit))
            SettingField(label: "Memory limit", detail: "-1 for no limit", text: sizeBinding($draft.memoryLimit),
                         valid: PHPSettings.isValidSize(draft.memoryLimit, unlimited: true))
            SettingField(label: "Import time limit", detail: "Seconds; 0 for no limit", text: numberBinding($draft.execTimeLimit),
                         valid: draft.execTimeLimit >= 0)
            SettingField(label: "Rows per page", text: numberBinding($draft.maxRows), valid: (1...10_000).contains(draft.maxRows))
            ApplyRow(editLabel: "Edit config…", changed: draft != saved, valid: draft.isValid,
                     edit: { editingConfiguration = true }, revert: { draft = saved }) {
                Task {
                    do { try await model.applyPHPMyAdminSettings(draft); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { draft = saved }
        .sheet(isPresented: $editingConfiguration) {
            UserSettingsSheet(
                title: "phpMyAdmin config",
                detail: "Your own $cfg settings, loaded after DevStack's so they win. DevStack keeps the sign-in settings itself.",
                file: model.paths.userPHPMyAdminConfiguration,
                template: "<?php\n// Your phpMyAdmin settings. Lines here override DevStack's.\n// Example:\n// $cfg['NavigationTreeEnableGrouping'] = false;\n"
            ) { text in
                try await model.applyPHPMyAdminSettings(draft.isValid ? draft : saved, userConfiguration: text)
            }
            .environmentObject(model)
        }
    }
}
