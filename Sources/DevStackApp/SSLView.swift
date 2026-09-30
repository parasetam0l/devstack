import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct SSLView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SSLViewState()

    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "SSL", subtitle: "Local CA and site certificates.")
                Spacer()
                Button("Issue Certificate…", systemImage: "plus") { state.hostname = ""; state.issuing = true }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                Button { Task { await model.refreshCertificates() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DevStackGlassButtonStyle()).help("Refresh certificates").accessibilityLabel("Refresh certificates").disabled(model.isBusy)
            }
            SurfacePanel {
                HStack(spacing: 8) {
                    FeatureIcon(symbol: "lock.shield")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DevStack Local CA").font(.system(size: 12, weight: .semibold))
                        Text(model.localCATrusted ? "Trusted by macOS" : "Trust required for browser HTTPS")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let ca = model.caSummary {
                        Text(expiration(ca)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Details") { state.detailCertificate = ca }.buttonStyle(.borderless)
                        Menu {
                            Button("Export CA…") { exportCertificate(ca) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ca.certificate]) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("CA actions")
                    }
                    if !model.localCATrusted {
                        Button("Trust CA…") { Task { await model.trustHTTPS(); await model.refreshCertificates() } }
                            .buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                    } else { StatusBadge(title: "Trusted", color: DevStackDesign.success) }
                }
            }
            SurfacePanel {
                HStack {
                    Text("Certificates").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.certificateSummaries.count)").foregroundStyle(.secondary)
                }
                if model.certificateSummaries.isEmpty {
                    EmptyWorkspace(symbol: "lock.doc", title: "No certificates yet", description: "Issue a certificate or start the stack to create certificates for your sites.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.certificateSummaries.enumerated()), id: \.element.id) { index, certificate in
                            if index > 0 { Divider() }
                            certificateRow(certificate)
                        }
                    }
                }
            }
        }
        .task { await model.refreshCertificates() }
        .sheet(isPresented: $state.issuing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Issue SSL Certificate").font(.system(size: 17, weight: .semibold))
                TextField("Hostname", text: $state.hostname).textFieldStyle(.roundedBorder).frame(width: 340)
                Text("For example, project.localhost. Certificates are signed by the DevStack Local CA.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 340, alignment: .leading)
                HStack { Spacer(); Button("Cancel") { state.issuing = false }.buttonStyle(DevStackGlassButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Issue") { let host = state.hostname; state.issuing = false; Task { await model.issueCertificate(for: host) } }
                        .buttonStyle(DevStackGlassButtonStyle()).keyboardShortcut(.defaultAction).disabled(state.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(18)
        }
        .sheet(item: $state.detailCertificate) { certificate in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(certificate.hostname).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    StatusBadge(title: certificate.error != nil ? "Invalid" : certificate.isExpired ? "Expired" : "Valid", color: certificate.error != nil || certificate.isExpired ? .orange : DevStackDesign.success)
                }
                details(certificate)
                HStack {
                    Button("Export…") { exportCertificate(certificate) }.buttonStyle(DevStackGlassButtonStyle())
                    Spacer()
                    Button("Done") { state.detailCertificate = nil }.buttonStyle(DevStackGlassButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }.padding(18).frame(width: 580).controlSize(.small)
        }
        .alert("Delete certificate?", isPresented: $state.confirmingDelete, presenting: state.pendingDelete) { certificate in
            Button("Delete", role: .destructive) { Task { await model.deleteCertificate(certificate) }; state.pendingDelete = nil }
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
        } message: { certificate in Text("This removes the certificate and private key for \(certificate.hostname).") }
    }

    private func certificateRow(_ certificate: CertificateSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.doc").font(.system(size: 13)).foregroundStyle(certificate.isExpired ? Color.orange : Color.secondary).frame(width: 18)
            Button { state.detailCertificate = certificate } label: {
                Text(certificate.hostname).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            }.buttonStyle(.plain).help("Certificate details").accessibilityLabel("Details for \(certificate.hostname)")
            Spacer(minLength: 8)
            Text(expiration(certificate)).font(.system(size: 11)).foregroundStyle(.secondary)
            StatusBadge(title: certificate.error != nil ? "Invalid" : certificate.isExpired ? "Expired" : "Valid", color: certificate.error != nil || certificate.isExpired ? .orange : DevStackDesign.success).frame(width: 55)
            Button("Renew") { Task { await model.issueCertificate(for: certificate.hostname) } }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                .accessibilityLabel("Renew \(certificate.hostname)")
            Menu {
                Button("Certificate Details…") { state.detailCertificate = certificate }
                Button("Export Certificate…") { exportCertificate(certificate) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([certificate.certificate]) }
                if !model.managedTLSHostnames.contains(certificate.hostname) {
                    Divider()
                    Button("Delete…", role: .destructive) { state.pendingDelete = certificate; state.confirmingDelete = true }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22).disabled(model.isBusy)
                .accessibilityLabel("Certificate actions for \(certificate.hostname)")
        }.padding(.vertical, 6)
    }
    private func expiration(_ certificate: CertificateSummary) -> String {
        guard let date = certificate.expiresAt else { return certificate.error == nil ? "Expiration unknown" : "Unable to read certificate" }
        return "\(certificate.isExpired ? "Expired" : "Expires") \(date.formatted(date: .abbreviated, time: .omitted))"
    }
    private func details(_ certificate: CertificateSummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = certificate.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            CopyValueRow(label: "Subject", value: certificate.subject)
            CopyValueRow(label: "Issuer", value: certificate.issuer)
            CopyValueRow(label: "Serial", value: certificate.serial)
            CopyValueRow(label: "SHA-256", value: certificate.fingerprint)
            CopyValueRow(label: "File", value: certificate.certificate.path)
            if let date = certificate.validFrom { CopyValueRow(label: "Valid from", value: date.formatted()) }
            if let date = certificate.expiresAt { CopyValueRow(label: "Expires", value: date.formatted()) }
        }.font(.system(size: 12))
    }
    private func exportCertificate(_ certificate: CertificateSummary) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = certificate.hostname + ".pem"
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
