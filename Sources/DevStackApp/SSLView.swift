import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct SSLView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SSLViewState()

    var body: some View {
        PanelPage {
            Panel("Certificate Authority", note: model.localCATrusted
                  ? "Browsers on this Mac trust every certificate DevStack issues."
                  : "Trust the DevStack CA so browsers on this Mac accept your sites' HTTPS without warnings.") {
                PanelRow {
                    StatusDot(color: model.localCATrusted ? .green : .orange)
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    Text("DevStack Local CA").fontWeight(.medium).frame(width: ServiceRowLayout.title, alignment: .leading)
                    Text(model.caSummary.map(expiration) ?? "Created when the stack first starts")
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.localCATrusted ? "Trusted" : "Not trusted")
                        .font(.callout).foregroundStyle(model.localCATrusted ? Color.secondary : .orange)
                        .frame(width: ServiceRowLayout.state, alignment: .leading)
                    HStack(spacing: 6) {
                        if !model.localCATrusted {
                            Button("Trust…") { Task { await model.trustHTTPS(); await model.refreshCertificates() } }
                                .controlSize(.small)
                                .disabled(model.isBusy)
                        }
                        if let ca = model.caSummary {
                            Menu {
                                Button("Details…") { state.detailCertificate = ca }
                                Button("Export…") { exportCertificate(ca) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ca.certificate]) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Certificate authority actions")
                        }
                    }
                    .frame(width: ServiceRowLayout.controls, alignment: .trailing)
                }
            }

            Panel("Certificates") {
                if model.certificateSummaries.isEmpty {
                    PanelRow {
                        Text("No certificates yet. Starting the stack creates them for your HTTPS sites.").foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(model.certificateSummaries) { certificate in certificateRow(certificate) }
                }
            } accessory: {
                Button { Task { await model.refreshCertificates() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                    .help("Read the certificates again")
                Button(action: beginIssuing) { Label("Issue Certificate…", systemImage: "plus") }
                    .buttonStyle(.borderless)
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
        let healthy = certificate.error == nil && !certificate.isExpired
        return PanelRow {
            StatusDot(color: healthy ? .green : .orange)
            Image(systemName: "lock.doc").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(certificate.hostname).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(certificate.hostname)
            Text(expiration(certificate)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(status(certificate))
                .font(.callout).foregroundStyle(healthy ? Color.secondary : .orange)
                .frame(width: ServiceRowLayout.state, alignment: .leading)
            HStack(spacing: 6) {
                IconButton(title: "Renew \(certificate.hostname)", symbol: "arrow.clockwise") {
                    Task { await model.issueCertificate(for: certificate.hostname) }
                }
                .disabled(model.isBusy)
                IconButton(title: "Certificate details", symbol: "info.circle") { state.detailCertificate = certificate }
                Menu {
                    Button("Details…") { state.detailCertificate = certificate }
                    Button("Export…") { exportCertificate(certificate) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([certificate.certificate]) }
                    if !model.managedTLSHostnames.contains(certificate.hostname) {
                        Divider()
                        Button("Delete…", role: .destructive) { state.pendingDelete = certificate; state.confirmingDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .disabled(model.isBusy)
                .accessibilityLabel("Actions for \(certificate.hostname)")
            }
            .frame(width: ServiceRowLayout.controls, alignment: .trailing)
        }
        .contextMenu {
            Button("Details…") { state.detailCertificate = certificate }
            Button("Export…") { exportCertificate(certificate) }
            Button("Renew") { Task { await model.issueCertificate(for: certificate.hostname) } }.disabled(model.isBusy)
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
