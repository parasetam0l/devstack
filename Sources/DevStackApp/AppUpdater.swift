import AppKit
import Combine
import Sparkle

/// Updates from GitHub Releases with Sparkle, as in SemiVPN and LocalDesktop.
/// The feed (SUFeedURL) is the appcast.xml attached to the latest published
/// release. Each update is signed with the EdDSA key whose public half is
/// SUPublicEDKey, and must carry the same Developer ID signature as the
/// running app. DevStack checks once a day and always asks before installing.
/// Development builds don't check: they aren't releases.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Nil in development builds.
    private let controller: SPUStandardUpdaterController?
    private let delegate = UpdaterDelegate()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?
    private var cancellables: Set<AnyCancellable> = []

    var isAvailable: Bool { controller != nil }

    /// Set while Sparkle quits DevStack to install an update, so quitting
    /// does not ask about the running services.
    var isRelaunchingForUpdate: Bool { delegate.isRelaunching }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private init() {
        #if DEBUG
        controller = nil
        #else
        // Without the update key Sparkle refuses to start and says so at every
        // launch; builds made before the key exists simply don't update.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = key.flatMap { Data(base64Encoded: $0) }?.count == 32
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) : nil
        #endif
        if let updater = controller?.updater {
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
                .store(in: &cancellables)
            updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.lastCheck = $0 }
                .store(in: &cancellables)
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// "0.4.0 (1791023807)"
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var relaunching = false

    var isRelaunching: Bool {
        lock.lock(); defer { lock.unlock() }
        return relaunching
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        lock.lock(); relaunching = true; lock.unlock()
    }
}
