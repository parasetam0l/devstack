#if DEBUG
import AppKit
import DevStackCore
import SwiftUI

/// Development-only fixture mode for native UI review. Does not load user configuration.
@MainActor enum UIReview {
    private static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func makeModel() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-UIReview")
        let model = AppModel(paths: DevStackPaths(applicationSupport: root, logs: root.appendingPathComponent("Logs")), automaticallyLoad: false)
        model.appearance = CommandLine.arguments.contains("--dark") ? .dark : .light
        model.selectedSection = NavigationSection.allCases.first { $0.rawValue.lowercased() == argument("--ui-review")?.lowercased() } ?? .dashboard
        if let url = DevStackResources.bundle.url(forResource: "runtime-lock", withExtension: "json"),
           let data = try? Data(contentsOf: url), let lock = try? JSONDecoder().decode(Catalog.self, from: data) {
            model.runtimeManifests = lock.runtimes
        }
        if CommandLine.arguments.contains("--populated") {
            model.configuration.sites = [
                SiteDefinition(name: "Portfolio", hostname: "portfolio.devstack.test", documentRoot: root.appendingPathComponent("Projects/portfolio/public").path, logs: .init(access: "", error: "")),
                SiteDefinition(name: "Storefront", hostname: "storefront.devstack.test", documentRoot: root.appendingPathComponent("Projects/storefront/public").path, logs: .init(access: "", error: "")),
                SiteDefinition(name: "API Sandbox", hostname: "api.devstack.test", documentRoot: root.appendingPathComponent("Projects/api/public").path, tlsEnabled: false, logs: .init(access: "", error: ""))
            ]
        }
        if CommandLine.arguments.contains("--running") {
            model.helperInstalled = true
            model.serviceStates = ServiceKind.allCases.map { .init(service: $0, phase: [.apache, .php85, .mysql84, .mailpit].contains($0) ? .running : .stopped) }
        }
        if CommandLine.arguments.contains("--report") {
            model.diagnosticReport = .init(appVersion: "UI review", results: [
                .init(id: "architecture", title: "Native Apple Silicon runtimes", severity: .info, evidence: "All inspected executables use arm64."),
                .init(id: "helper", title: "System integration", severity: .warning, evidence: "The privileged helper is not installed in this isolated review.", remediation: "Complete setup in Settings to enable local domains and HTTPS."),
                .init(id: "port", title: "Port 3306 is available", severity: .info, evidence: "No conflicting listener was found on the loopback interface.")
            ])
        }
        return model
    }

    private struct Catalog: Decodable { var runtimes: [RuntimeManifest] }
}
#endif
