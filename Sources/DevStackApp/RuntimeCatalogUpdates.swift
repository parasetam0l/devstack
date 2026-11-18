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
        Task { await checkForRuntimeUpdates() }
    }

    /// Fetches the signed runtime catalog, keeps it when it verifies, and
    /// shows which packs have updates. Nothing is installed here.
    func checkForRuntimeUpdates() async {
        guard !isCheckingRuntimeCatalog else { return }
        isCheckingRuntimeCatalog = true
        defer { isCheckingRuntimeCatalog = false }
        var state = runtimeCatalogState
        let now = Date()
        do {
            let keys = try loadTrustedRuntimeKeys()
            let data = try await Self.fetchRuntimeCatalog(RuntimeCatalog.defaultURL)
            let catalog = try RuntimeCatalog.verify(envelope: data, trustedKeys: keys, acceptedSequence: state.highestSequence)
            try AtomicFileWriter.write(data, to: paths.runtimeCatalog, permissions: 0o644)
            state.highestSequence = max(state.highestSequence ?? 0, catalog.sequence)
            merge(catalog)
            let updates = runtimePackCatalog.packs.filter { runtimePackStatus($0) == .updateAvailable }.count
            let message = switch updates {
            case 0: "Your runtimes are up to date."
            case 1: "1 runtime update is available."
            default: "\(updates) runtime updates are available."
            }
            runtimeCatalogCheck = RuntimeCatalogCheck(date: now, message: message, failed: false)
        } catch {
            runtimeCatalogCheck = RuntimeCatalogCheck(date: now, message: error.localizedDescription, failed: true)
        }
        state.lastChecked = now
        saveRuntimeCatalogState(state)
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
