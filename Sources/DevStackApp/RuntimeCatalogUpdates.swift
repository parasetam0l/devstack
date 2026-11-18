import AppKit
import DevStackCore
import Foundation

/// The outcome of the last runtime catalog check, for the Runtimes page.
struct RuntimeCatalogCheck: Equatable {
    var date: Date
    var message: String
    var failed: Bool
}

private enum RuntimeCatalogFetchError: LocalizedError {
    case insecure, status(Int), tooLarge

    var errorDescription: String? {
        switch self {
        case .insecure: "The runtime catalog was not served over HTTPS."
        case .status(let code): "The runtime catalog server answered with status \(code)."
        case .tooLarge: "The runtime catalog is larger than DevStack accepts."
        }
    }
}

extension AppModel {
    /// Launch checks happen at most this often; the button checks any time.
    static let runtimeCatalogCheckInterval: TimeInterval = 24 * 60 * 60

    private var appShortVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var runtimeCatalogState: RuntimeCatalogState {
        guard let data = try? Data(contentsOf: paths.runtimeCatalogState) else { return RuntimeCatalogState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RuntimeCatalogState.self, from: data)) ?? RuntimeCatalogState()
    }

    private func saveRuntimeCatalogState(_ state: RuntimeCatalogState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) { try? AtomicFileWriter.write(data, to: paths.runtimeCatalogState, permissions: 0o644) }
    }

    private func merge(_ catalog: RuntimeCatalog) {
        runtimePackCatalog = catalog.merged(into: bundledRuntimePackCatalog, macOSVersion: Self.macOSVersion, appVersion: appShortVersion)
    }

    /// Re-verifies the catalog accepted earlier and merges it into the bundled
    /// pins. A saved catalog that no longer verifies is ignored.
    func applySavedRuntimeCatalog() {
        guard let data = try? Data(contentsOf: paths.runtimeCatalog),
              let keys = try? loadTrustedRuntimeKeys(),
              let catalog = try? RuntimeCatalog.verify(envelope: data, trustedKeys: keys, acceptedSequence: runtimeCatalogState.highestSequence)
        else { return }
        merge(catalog)
    }

    /// At launch: checks when the last check is more than a day old.
    func checkForRuntimeUpdatesIfDue() {
        guard !isReviewMode, !bundledRuntimePackCatalog.packs.isEmpty else { return }
        if let lastChecked = runtimeCatalogState.lastChecked, Date().timeIntervalSince(lastChecked) < Self.runtimeCatalogCheckInterval { return }
        Task {
            // Like the app updater: a background check speaks up only when it finds something.
            if let updates = await checkForRuntimeUpdates(), !updates.isEmpty { presentRuntimeUpdates(updates) }
        }
    }

    /// Menu command: checks now and always answers, the way Check for Updates… does.
    func checkForRuntimeUpdatesInteractively() {
        Task {
            guard let updates = await checkForRuntimeUpdates() else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't check for runtime updates"
                alert.informativeText = runtimeCatalogCheck?.message ?? "Try again later."
                alert.addButton(withTitle: "OK")
                NSApp.activate()
                alert.runModal()
                return
            }
            presentRuntimeUpdates(updates)
        }
    }

    /// Shows what a check found and installs the updates when asked.
    private func presentRuntimeUpdates(_ updates: [RuntimePackPin]) {
        let alert = NSAlert()
        alert.icon = DevStackDesign.icon
        if updates.isEmpty {
            alert.messageText = "Your runtimes are up to date!"
            alert.informativeText = "Every installed runtime is the newest build available."
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
            return
        }
        alert.messageText = updates.count == 1 ? "A runtime update is available" : "\(updates.count) runtime updates are available"
        let lines = updates.map { pin in
            let installed = runtimePackInstaller?.installedPin(pin.id)?.version
            return "• \(pin.displayName) \(pin.version)" + (installed.map { $0 == pin.version ? " (new build)" : " (installed \($0))" } ?? "")
        }
        let restart = runningServices(using: Set(updates.map(\.id))).isEmpty ? "" : "\n\nServices that use these runtimes restart on the new builds."
        alert.informativeText = lines.joined(separator: "\n") + restart
        alert.addButton(withTitle: updates.count == 1 ? "Update" : "Update All")
        alert.addButton(withTitle: "Show Runtimes")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if let failure = await installRuntimePacks(updates.map(\.id)) {
                    let error = NSAlert()
                    error.alertStyle = .warning
                    error.messageText = "Couldn't update the runtimes"
                    error.informativeText = failure
                    error.runModal()
                }
            }
        case .alertSecondButtonReturn:
            showMainWindow()
            selectedSection = .runtimes
        default:
            break
        }
    }

    /// Fetches the signed runtime catalog, keeps it when it verifies, and
    /// shows which packs have updates. Nothing is installed here.
    /// Returns the packs with updates, or nil when the check failed.
    @discardableResult
    func checkForRuntimeUpdates() async -> [RuntimePackPin]? {
        guard !isCheckingRuntimeCatalog else { return nil }
        isCheckingRuntimeCatalog = true
        defer { isCheckingRuntimeCatalog = false }
        var state = runtimeCatalogState
        let now = Date()
        var found: [RuntimePackPin]?
        do {
            let keys = try loadTrustedRuntimeKeys()
            let data = try await Self.fetchRuntimeCatalog(RuntimeCatalog.defaultURL)
            let catalog = try RuntimeCatalog.verify(envelope: data, trustedKeys: keys, acceptedSequence: state.highestSequence)
            try AtomicFileWriter.write(data, to: paths.runtimeCatalog, permissions: 0o644)
            state.highestSequence = max(state.highestSequence ?? 0, catalog.sequence)
            merge(catalog)
            found = runtimePackCatalog.packs.filter { runtimePackStatus($0) == .updateAvailable }
            let message = switch found?.count ?? 0 {
            case 0: "Your runtimes are up to date."
            case 1: "1 runtime update is available."
            default: "\(found?.count ?? 0) runtime updates are available."
            }
            runtimeCatalogCheck = RuntimeCatalogCheck(date: now, message: message, failed: false)
        } catch {
            runtimeCatalogCheck = RuntimeCatalogCheck(date: now, message: error.localizedDescription, failed: true)
        }
        state.lastChecked = now
        saveRuntimeCatalogState(state)
        return found
    }

    /// Downloads the envelope over HTTPS, refusing anything above the size cap.
    nonisolated static func fetchRuntimeCatalog(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw RuntimeCatalogFetchError.insecure }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw RuntimeCatalogFetchError.insecure }
        guard http.statusCode == 200 else { throw RuntimeCatalogFetchError.status(http.statusCode) }
        guard http.expectedContentLength <= Int64(RuntimeCatalog.maximumSize) else { throw RuntimeCatalogFetchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > RuntimeCatalog.maximumSize { throw RuntimeCatalogFetchError.tooLarge }
        }
        return data
    }

    /// Running services whose runtime is one of `packIDs` or needs one of them.
    func runningServices(using packIDs: Set<String>) -> [ServiceKind] {
        guard !packIDs.isEmpty else { return [] }
        return serviceStates.filter { $0.phase == .running || $0.phase == .starting }.map(\.service).filter { service in
            let needs = ((try? runtimePackCatalog.installationOrder(for: [service.runtimeID])) ?? []).map(\.id)
            return !packIDs.isDisjoint(with: needs + [service.runtimeID])
        }
    }
}
