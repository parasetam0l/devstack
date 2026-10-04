import AppKit
import DevStackCore
import SwiftUI

/// Progress of a running pack installation, for the Runtimes page and the
/// setup wizard.
struct RuntimePackProgress: Equatable {
    var packName: String
    var index: Int
    var count: Int
    var completedBytes: Int64
    var totalBytes: Int64

    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

enum RuntimePackStatus: Equatable {
    case notInstalled, installed, updateAvailable
    /// Inside the app bundle (development builds, or before packs existed).
    case bundled
}

extension RuntimePackPin {
    private static let names = [
        "openssl-3.5": "OpenSSL", "apache-2.4": "Apache", "nginx-1.30": "Nginx", "php-7.4": "PHP 7.4",
        "php-8.4": "PHP 8.4", "php-8.5": "PHP 8.5", "mysql-5.7": "MySQL 5.7", "mysql-8.4": "MySQL 8.4",
        "postgresql-18": "PostgreSQL 18", "mailpit-1.31.1": "Mailpit", "phpmyadmin-5.2.3": "phpMyAdmin",
        "adminer-6.1.1": "Adminer", "composer-2.10.3": "Composer", "imagemagick-7.1": "ImageMagick"
    ]
    var displayName: String { Self.names[id] ?? id }
    var isLegacy: Bool { id == "php-7.4" || id == "mysql-5.7" }
}

extension AppModel {
    static func loadRuntimePackCatalog() -> RuntimePackCatalog {
        #if DEBUG
        // Development builds can point at a local catalog, for example one
        // with file: URLs to packs built by devstack-runtimes.
        if let override = ProcessInfo.processInfo.environment["DEVSTACK_RUNTIME_CATALOG"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: override)),
           let catalog = try? JSONDecoder().decode(RuntimePackCatalog.self, from: data) {
            return catalog
        }
        #endif
        guard let url = DevStackResources.bundle.url(forResource: "runtime-packs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(RuntimePackCatalog.self, from: data) else { return RuntimePackCatalog() }
        return catalog
    }

    var runtimePackInstaller: RuntimePackInstaller? {
        guard let keys = try? loadTrustedRuntimeKeys() else { return nil }
        // A signed DevStack accepts only packs signed by its own team.
        let verifier = RuntimePackVerifier(trustedPublicKeys: keys, requiredTeamID: runningTeamID)
        #if DEBUG
        return RuntimePackInstaller(verifier: verifier, runtimes: paths.importedRuntimes, allowsFileURLs: true)
        #else
        return RuntimePackInstaller(verifier: verifier, runtimes: paths.importedRuntimes)
        #endif
    }

    func runtimePackStatus(_ pin: RuntimePackPin) -> RuntimePackStatus {
        if let installed = runtimePackInstaller?.installedPin(pin.id) {
            return installed == pin ? .installed : .updateAvailable
        }
        let bundled = paths.builtInRuntimes.appendingPathComponent(pin.id)
        return FileManager.default.fileExists(atPath: bundled.path) ? .bundled : .notInstalled
    }

    /// The packs the current configuration runs: the tools every stack uses,
    /// the selected web server and databases, and every PHP version in use.
    var runtimePacksInUse: [String] {
        var ids: Set<String> = ["openssl-3.5", "imagemagick-7.1", "php-8.5", "phpmyadmin-5.2.3", "adminer-6.1.1",
                                "mailpit-1.31.1", "composer-2.10.3", configuration.selectedWebServer.service.runtimeID,
                                configuration.defaultPHPRuntimeID]
        ids.formUnion(configuration.selectedDatabaseServices.map(\.runtimeID))
        ids.formUnion(configuration.sites.map(\.phpRuntimeID))
        return runtimePackCatalog.packs.map(\.id).filter(ids.contains)
    }

    /// True while a service runs from a runtime inside the app bundle, which an
    /// app update would replace underneath it.
    var runsBundledRuntimes: Bool {
        serviceStates.contains { $0.phase == .running && !configuration.importedRuntimeIDs.contains($0.service.runtimeID) }
    }

    /// Packs the current configuration needs that are neither installed nor bundled.
    var missingRuntimePacks: [RuntimePackPin] {
        (try? runtimePackCatalog.installationOrder(for: runtimePacksInUse))?
            .filter { runtimePackStatus($0) == .notInstalled } ?? []
    }

    /// Download size of the packs not yet installed among `ids` and what they require.
    func runtimePackDownloadSize(_ ids: [String]) -> Int64 {
        ((try? runtimePackCatalog.installationOrder(for: ids)) ?? [])
            .filter { runtimePackStatus($0) != .installed }
            .reduce(0) { $0 + $1.size }
    }

    /// Installs or updates packs and everything they require. Returns nil on
    /// success or a message to show.
    @discardableResult
    func installRuntimePacks(_ ids: [String]) async -> String? {
        guard !isBusy else { return "Another operation is still running." }
        guard let installer = runtimePackInstaller else { return "DevStack's trusted runtime keys are missing." }
        let order: [RuntimePackPin]
        do { order = try runtimePackCatalog.installationOrder(for: ids).filter { runtimePackStatus($0) != .installed } }
        catch { return error.localizedDescription }
        guard !order.isEmpty else { return nil }
        // Replacing a runtime under running services would mix versions.
        if hasRunningServices, order.contains(where: { runtimePackStatus($0) == .updateAvailable }) {
            return "Stop the stack before updating runtimes."
        }
        isBusy = true
        defer { isBusy = false; runtimePackProgress = nil }
        let total = order.reduce(0) { $0 + $1.size }
        var completed: Int64 = 0
        for (index, pin) in order.enumerated() {
            runtimePackProgress = RuntimePackProgress(packName: pin.displayName, index: index + 1, count: order.count, completedBytes: completed, totalBytes: total)
            let base = completed
            do {
                try await installer.install(pin) { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.runtimePackProgress?.packName == pin.displayName else { return }
                        self.runtimePackProgress?.completedBytes = base + bytes
                    }
                }
            } catch {
                await refreshRuntimeInventory()
                return "\(pin.displayName): \(error.localizedDescription)"
            }
            completed += pin.size
            if !configuration.importedRuntimeIDs.contains(pin.id) {
                configuration.importedRuntimeIDs.append(pin.id)
                configuration.importedRuntimeIDs.sort()
            }
            try? await saveConfiguration()
        }
        await refreshRuntimeInventory()
        return nil
    }

    /// Removes an installed pack unless the current configuration or another
    /// installed pack needs it. Databases and settings stay.
    @discardableResult
    func removeRuntimePack(_ pin: RuntimePackPin) async -> String? {
        guard !isBusy else { return "Another operation is still running." }
        if runtimePacksInUse.contains(pin.id) { return "\(pin.displayName) is part of the current stack." }
        if let dependent = runtimePackCatalog.packs.first(where: { $0.requires.contains(pin.id) && runtimePackStatus($0) == .installed }) {
            return "\(dependent.displayName) needs \(pin.displayName)."
        }
        if let service = ServiceKind.allCases.first(where: { $0.runtimeID == pin.id }), serviceIsRunning(service) {
            return "Stop \(service.displayName) first."
        }
        do {
            try runtimePackInstaller?.remove(pin.id)
            configuration.importedRuntimeIDs.removeAll { $0 == pin.id }
            try await saveConfiguration()
        } catch {
            return error.localizedDescription
        }
        await refreshRuntimeInventory()
        return nil
    }
}

struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var confirmingRemoval: RuntimePackPin?

    var body: some View {
        WorkspacePage {
            HStack(alignment: .top) {
                PageHeading(title: "Runtimes", subtitle: "The server software DevStack runs. Each runtime downloads once, is verified, and stays on this Mac.")
                Spacer()
                Button("Import Pack…", action: chooseRuntimePack).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
            }
            if let progress = model.runtimePackProgress {
                RuntimePackProgressPanel(progress: progress)
            } else if !model.missingRuntimePacks.isEmpty {
                let missing = model.missingRuntimePacks
                SurfacePanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(missing.count) runtime\(missing.count == 1 ? "" : "s") to install").font(.system(size: 13, weight: .semibold))
                            Text(missing.map(\.displayName).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install (\(ByteCountFormatter.string(fromByteCount: missing.reduce(0) { $0 + $1.size }, countStyle: .file)))") {
                            Task { message = await model.installRuntimePacks(missing.map(\.id)) }
                        }.buttonStyle(DevStackProminentButtonStyle()).disabled(model.isBusy)
                    }
                }
            }
            if let message {
                InfoNotice(symbol: "exclamationmark.triangle", title: "Runtimes", message: message, color: .orange)
            }
            if model.runtimePackCatalog.packs.isEmpty {
                InfoNotice(symbol: "shippingbox", title: "This build bundles its runtimes",
                           message: "Runtimes come with this copy of DevStack. Later versions download them here instead.")
            } else {
                SurfacePanel {
                    VStack(spacing: 0) {
                        ForEach(model.runtimePackCatalog.packs) { pin in
                            RuntimePackRow(pin: pin, status: model.runtimePackStatus(pin), inUse: model.runtimePacksInUse.contains(pin.id),
                                           install: { Task { message = await model.installRuntimePacks([pin.id]) } },
                                           remove: { confirmingRemoval = pin })
                            if pin.id != model.runtimePackCatalog.packs.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .alert("Remove \(confirmingRemoval?.displayName ?? "runtime")?", isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }), presenting: confirmingRemoval) { pin in
            Button("Remove", role: .destructive) { Task { message = await model.removeRuntimePack(pin) } }
        } message: { _ in Text("Its databases and settings stay. You can install it again at any time.") }
    }

    private func chooseRuntimePack() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose a signed .devstack-runtime pack."
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importRuntimePack(from: url) } }
    }
}

private struct RuntimePackRow: View {
    @EnvironmentObject private var model: AppModel
    let pin: RuntimePackPin
    let status: RuntimePackStatus
    let inUse: Bool
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pin.displayName).font(.system(size: 12, weight: .semibold))
                    Text(pin.version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if pin.isLegacy { StatusBadge(title: "LEGACY", color: .orange) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .installed:
                StatusBadge(title: "Installed", dot: true, dotColor: .green)
                if !inUse { Button("Remove", action: remove).buttonStyle(.borderless).disabled(model.isBusy) }
            case .updateAvailable:
                Button("Update", action: install).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
            case .bundled:
                StatusBadge(title: "Bundled")
            case .notInstalled:
                Button("Install", action: install).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
            }
        }.padding(.vertical, 7)
    }

    private var detail: String {
        var parts = [ByteCountFormatter.string(fromByteCount: pin.size, countStyle: .file)]
        if !pin.requires.isEmpty {
            parts.append("needs " + pin.requires.map { id in model.runtimePackCatalog.pin(for: id)?.displayName ?? id }.joined(separator: ", "))
        }
        if inUse { parts.append("used by the current stack") }
        return parts.joined(separator: " · ")
    }
}

struct RuntimePackProgressPanel: View {
    let progress: RuntimePackProgress

    var body: some View {
        SurfacePanel {
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing \(progress.packName) (\(progress.index) of \(progress.count))").font(.system(size: 12, weight: .semibold))
                ProgressView(value: progress.fraction)
                Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)), verified before installing")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
