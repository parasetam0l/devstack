import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 205), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DevStack")
                            .font(.largeTitle.bold())
                        Text("Offline local development, entirely on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop All", systemImage: "stop.fill") {
                        Task { await model.stopAll() }
                    }
                    .disabled(model.isBusy)
                    Button("Start All", systemImage: "play.fill") {
                        Task { await model.startAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.serviceStates) { state in
                        ServiceCard(state: state)
                    }
                }

                GroupBox("Quick access") {
                    HStack(spacing: 12) {
                        Button("phpMyAdmin", systemImage: "cylinder") {
                            model.openURL("https://phpmyadmin.devstack.test")
                        }
                        Button("Mailpit", systemImage: "envelope") {
                            model.openURL("https://mailpit.devstack.test")
                        }
                        Button("Managed Shell", systemImage: "terminal") {
                            model.openManagedShell()
                        }
                        Button("Copy Env Command", systemImage: "doc.on.clipboard") {
                            model.copyManagedEnvironmentCommand()
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                if !model.runtimeManifests.isEmpty {
                    GroupBox("Runtimes") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.runtimeManifests) { manifest in
                                RuntimeProvenanceRow(
                                    manifest: manifest,
                                    imported: model.configuration.importedRuntimeIDs.contains(manifest.id)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if model.configuration.sites.isEmpty {
                    ContentUnavailableView {
                        Label("No sites yet", systemImage: "network")
                    } description: {
                        Text("Add a site to create an Apache virtual host and a dedicated PHP-FPM pool.")
                    } actions: {
                        Button("Add a Site") { model.selectedSection = .sites }
                    }
                    .frame(minHeight: 180)
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .task {
            while !Task.isCancelled {
                await model.refreshServiceStates()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct RuntimeProvenanceRow: View {
    let manifest: RuntimeManifest
    let imported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(manifest.kind.displayName) \(manifest.version)")
                    .font(.headline)
                Text(manifest.supportState.label(for: manifest))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(manifest.supportState.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(manifest.supportState.color)
                if imported {
                    Text("Imported")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(manifest.architecture) · macOS \(manifest.minimumMacOS)+")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(provenance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var provenance: String {
        var parts = [
            "Source \(manifest.source.url.host() ?? manifest.source.url.absoluteString)",
            "SHA-256 \(manifest.source.sha256.prefix(12))…",
            "License \(manifest.license)"
        ]
        if let abi = manifest.abi { parts.append("ABI \(abi)") }
        if let build = manifest.build {
            parts.append("Build \(build.buildSystem)")
            if !build.flags.isEmpty { parts.append(build.flags.joined(separator: " ")) }
            if let gate = build.feasibilityGate { parts.append("Gate: \(gate)") }
        }
        return parts.joined(separator: " · ")
    }
}

private extension RuntimeKind {
    var displayName: String {
        switch self {
        case .apache: "Apache"
        case .php: "PHP"
        case .mysql: "MySQL"
        case .mailpit: "Mailpit"
        case .phpMyAdmin: "phpMyAdmin"
        case .composer: "Composer"
        case .openssl: "OpenSSL"
        case .phpExtension: "PHP extension"
        case .library: "Library"
        }
    }
}

private extension RuntimeSupportState {
    func label(for manifest: RuntimeManifest) -> String {
        switch self {
        case .supported: "Supported"
        case .legacy: "Legacy"
        case .endOfLife: "EOL"
        case .conditional: manifest.build?.feasibilityGate != nil ? "EOL · Gate pending" : "Conditional"
        }
    }

    var color: Color {
        switch self {
        case .supported: .green
        case .legacy: .orange
        case .endOfLife: .red
        case .conditional: .orange
        }
    }
}

private struct ServiceCard: View {
    let state: ServiceState

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: state.phase.symbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.service.displayName)
                        .font(.headline)
                    Text(state.phase.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                    if let pid = state.pid {
                        Text("PID \(pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }
}
