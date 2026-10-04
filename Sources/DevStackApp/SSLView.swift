import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct SSLView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SSLViewState()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ServiceRowTitle(title: "DevStack Local CA", symbol: "checkmark.shield",
                                    detail: model.caSummary.map(expiration) ?? "Created when the stack first starts")
                    Spacer(minLength: 12)
                    StatusLabel(title: model.localCATrusted ? "Trusted" : "Not trusted", color: model.localCATrusted ? .green : .orange)
                    if !model.localCATrusted {
                        Button("Trust…") { Task { await model.trustHTTPS(); await model.refreshCertificates() } }
                            .disabled(model.isBusy)
                    }
                    if let ca = model.caSummary {
                        Menu {
                            Button("Details…") { state.detailCertificate = ca }
                            Button("Export…") { exportCertificate(ca) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ca.certificate]) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Certificate authority actions")
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Certificate authority")
            } footer: {
                SectionFooter {
                    Text(model.localCATrusted
                         ? "Browsers on this Mac trust every certificate DevStack issues."
                         : "Trust the DevStack CA so browsers on this Mac accept your sites' HTTPS without warnings.")
                }
            }

            Section("Certificates") {
                if model.certificateSummaries.isEmpty {
                    NoticeRow(symbol: "lock.doc", title: "No certificates yet",
                              message: "Starting the stack creates certificates for your HTTPS sites. You can also issue one yourself.", tint: .secondary) {
                        Button("Issue…") { beginIssuing() }.disabled(model.isBusy)
                    }
                } else {
                    ForEach(model.certificateSummaries) { certificate in certificateRow(certificate) }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshCertificates() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
                    .help("Read the certificates again")
            }
            ToolbarItem {
                Button(action: beginIssuing) { Label("Issue Certificate", systemImage: "plus") }
                    .disabled(model.isBusy)
                    .help("Issue a certificate for a hostname")
            }
        }
        .task { await model.refreshCertificates() }
        .sheet(isPresented: $state.issuing) { issueSheet }
        .sheet(item: $state.detailCertificate) { certificate in detailSheet(certificate) }
        .alert("Delete the certificate for \(state.pendingDelete?.hostname ?? "this hostname")?", isPresented: $state.confirmingDelete, presenting: state.pendingDelete) { certificate in
            Button("Delete", role: .destructive) { Task { await model.deleteCertificate(certificate) }; state.pendingDelete = nil }
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
        } message: { _ in
            Text("This removes the certificate and its private key.")
        }
    }

    private func certificateRow(_ certificate: CertificateSummary) -> some View {
        HStack(spacing: 12) {
            ServiceRowTitle(title: certificate.hostname, symbol: "lock.doc", detail: expiration(certificate))
            Spacer(minLength: 12)
            StatusLabel(title: status(certificate), color: certificate.error != nil || certificate.isExpired ? .orange : .green)
            Button("Renew") { Task { await model.issueCertificate(for: certificate.hostname) } }
                .disabled(model.isBusy)
                .accessibilityLabel("Renew \(certificate.hostname)")
            Menu {
                Button("Details…") { state.detailCertificate = certificate }
                Button("Export…") { exportCertificate(certificate) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([certificate.certificate]) }
                if !model.managedTLSHostnames.contains(certificate.hostname) {
                    Divider()
                    Button("Delete…", role: .destructive) { state.pendingDelete = certificate; state.confirmingDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.isBusy)
            .accessibilityLabel("Actions for \(certificate.hostname)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Details…") { state.detailCertificate = certificate }
            Button("Export…") { exportCertificate(certificate) }
        }
    }

    private var issueSheet: some View {
        VStack(spacing: 0) {
            Text("Issue Certificate").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 18)
            Form {
                Section {
                    TextField("Hostname", text: $state.hostname, prompt: Text("project.localhost"))
                } footer: {
                    SectionFooter { Text("Signed by the DevStack Local CA, like your sites' certificates.") }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { state.issuing = false }.keyboardShortcut(.cancelAction)
                Button("Issue") {
                    let host = state.hostname
                    state.issuing = false
                    Task { await model.issueCertificate(for: host) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 230)
    }

    private func detailSheet(_ certificate: CertificateSummary) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(certificate.hostname).font(.headline)
                Spacer()
                StatusLabel(title: status(certificate), color: certificate.error != nil || certificate.isExpired ? .orange : .green)
            }
            .padding(.horizontal, 20).padding(.top, 18)
            Form {
                if let error = certificate.error {
                    Section { NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Unreadable certificate", message: error) }
                }
                Section {
                    CopyableValueRow(label: "Subject", value: certificate.subject)
                    CopyableValueRow(label: "Issuer", value: certificate.issuer)
                    CopyableValueRow(label: "Serial", value: certificate.serial)
                    CopyableValueRow(label: "SHA-256", value: certificate.fingerprint)
                    if let date = certificate.validFrom { LabeledContent("Valid from", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = certificate.expiresAt { LabeledContent(certificate.isExpired ? "Expired" : "Expires", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    CopyableValueRow(label: "File", value: certificate.certificate.path)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Export…") { exportCertificate(certificate) }
                Spacer()
                Button("Done") { state.detailCertificate = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 470)
    }

    private func beginIssuing() {
        state.hostname = ""
        state.issuing = true
    }

    private func status(_ certificate: CertificateSummary) -> String {
        certificate.error != nil ? "Invalid" : certificate.isExpired ? "Expired" : "Valid"
    }

    private func expiration(_ certificate: CertificateSummary) -> String {
        guard let date = certificate.expiresAt else { return certificate.error == nil ? "Expiration unknown" : "Unable to read the certificate" }
        return "\(certificate.isExpired ? "Expired" : "Expires") \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func exportCertificate(_ certificate: CertificateSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = certificate.hostname + ".pem"
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        if panel.runModal() == .OK, let target = panel.url {
            do { try AtomicFileWriter.write(Data(contentsOf: certificate.certificate), to: target, permissions: 0o644) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

@MainActor private final class SSLViewState: ObservableObject {
    @Published var detailCertificate: CertificateSummary?
    @Published var issuing = false
    @Published var hostname = ""
    @Published var pendingDelete: CertificateSummary?
    @Published var confirmingDelete = false
}
