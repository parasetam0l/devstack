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
        if let applications = argument("--migration-e2e") { return makeEndToEndModel(applications: URL(fileURLWithPath: applications)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-UIReview")
        let model = AppModel(paths: DevStackPaths(applicationSupport: root, logs: root.appendingPathComponent("Logs"), defaultSiteRoot: root.appendingPathComponent("DevStack")), automaticallyLoad: false)
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
        if CommandLine.arguments.contains("--installed") {
            // Every current pack, as the installer leaves it; the legacy ones stay
            // uninstalled so both states show.
            let encoder = JSONEncoder()
            for pin in model.runtimePackCatalog.packs where !pin.isLegacy {
                model.configuration.importedRuntimeIDs.append(pin.id)
                let directory = model.paths.importedRuntimes.appendingPathComponent(pin.id)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? encoder.encode(pin).write(to: directory.appendingPathComponent(RuntimePackInstaller.markerName))
                for entryPoint in model.runtimeManifests.first(where: { $0.id == pin.id })?.entryPoints.values.map({ $0 }) ?? [] {
                    let file = directory.appendingPathComponent(entryPoint)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: file.path, contents: Data())
                }
            }
        }
        if CommandLine.arguments.contains("--running") {
            model.helperInstalled = true
            model.serviceStates = ServiceKind.allCases.map { .init(service: $0, phase: [.apache, .php85, .mysql84, .mailpit].contains($0) ? .running : .stopped) }
        }
        if CommandLine.arguments.contains("--report") {
            model.diagnosticReport = .init(appVersion: "UI review", results: [
                .init(id: "architecture", title: "Native Apple Silicon runtimes", severity: .info, evidence: "All inspected executables use arm64."),
                .init(id: "helper", title: "System integration", severity: .warning, evidence: "The privileged helper is not installed in this isolated review.", remediation: "Complete setup in Settings to enable local domains and HTTPS.", fix: .repairHelper),
                .init(id: "other-helper-1", title: "Helper from another DevStack copy", severity: .error,
                      evidence: "A DevStack helper runs from /Users/me/Downloads/DevStack.app, signed by team ABCDE12345. It holds the helper's name and the privileged ports, so this copy's helper cannot start, and macOS starts it again at every boot while that copy exists.",
                      remediation: "Remove stops it, moves that copy to the Trash and sets up this copy's helper. Empty the Trash afterwards.",
                      fix: .removeOtherHelper(executable: "/Users/me/Downloads/DevStack.app/Contents/Library/LaunchServices/DevStackPrivilegedHelper")),
                .init(id: "port", title: "Port 3306 is available", severity: .info, evidence: "No conflicting listener was found on the loopback interface.")
            ])
        }
        if CommandLine.arguments.contains("--repaired") {
            model.repairSummary = RepairSummary(done: ["Removed the helper of the DevStack copy at /Users/me/Downloads/DevStack.app", "Set up the helper", "Trusted the DevStack certificate authority"],
                                                remaining: ["Port 8080"])
        }
        if let step = argument("--migration") {
            model.preparedMigrationController = migrationFixture(step: step, model: model, root: root)
        }
        if let directory = argument("--snapshot") {
            // The bare debug executable has no bundle, so it launches as a
            // background tool without windows.
            NSApplication.shared.setActivationPolicy(.regular)
            scheduleSnapshots(of: model, into: URL(fileURLWithPath: directory))
        }
        return model
    }

    /// `--snapshot DIR` renders every page (or `--pages a,b`) of the main
    /// window to DIR/<page>.png and quits. The app draws its own window, so
    /// this needs no screen-recording permission.
    private static func scheduleSnapshots(of model: AppModel, into directory: URL) {
        let requested = argument("--pages")?.split(separator: ",").map { $0.lowercased() }
        let sections = NavigationSection.allCases.filter { section in
            requested.map { $0.contains(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")) } ?? true
        }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.activate(ignoringOtherApps: true)
            // Capture a scene window, as the app opens it. SwiftUI may restore
            // none at launch, so a window of our own asks for one; it stays
            // the fallback when no scene window appears.
            let own = makeWindow(for: model)
            own.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            model.openMainWindow?()
            var sceneWindow: NSWindow?
            for _ in 0..<30 {
                sceneWindow = NSApp.windows.first { $0 !== own && $0.identifier?.rawValue.hasPrefix("main") == true }
                if sceneWindow != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if sceneWindow != nil { own.close() }
            let window = sceneWindow ?? own
            window.setContentSize(NSSize(width: 980, height: 680))
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            guard let view = window.contentView else { NSApp.terminate(nil); return }
            for section in sections {
                model.selectedSection = section
                try? await Task.sleep(for: .milliseconds(900))
                if CommandLine.arguments.contains("--scroll-bottom"), let scrollView = firstScrollView(in: view) {
                    let height = scrollView.documentView?.frame.height ?? 0
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scrollView.contentView.bounds.height)))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                // The window as the window server composites it, glass included.
                // An app may capture its own windows without screen-recording
                // permission; the call is gone from the SDK, so it is looked up.
                guard let image = captureWindow(window.windowNumber) else {
                    FileHandle.standardError.write(Data("snapshot: could not capture the window\n".utf8))
                    continue
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                let name = section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
                // --migration STEP captures the migration wizard at that step.
                if let step = argument("--migration"), section == .sites {
                    model.isPresentingMigrationWizard = true
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let sheet = window.attachedSheet, let image = captureWindow(sheet.windowNumber) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("migration-\(step).png"))
                        window.endSheet(sheet)
                    }
                    model.isPresentingMigrationWizard = false
                    try? await Task.sleep(for: .milliseconds(500))
                }
                // --sheets also captures the page's sheet: the new-site editor
                // on Sites and the setup wizard on the Dashboard.
                if CommandLine.arguments.contains("--sheets"), section == .sites || section == .dashboard {
                    if section == .sites { model.isPresentingNewSite = true } else { model.isPresentingSetupWizard = true }
                    try? await Task.sleep(for: .milliseconds(1200))
                    if let sheet = window.attachedSheet, let image = captureWindow(sheet.windowNumber) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("\(name)-sheet.png"))
                        window.endSheet(sheet)
                    }
                    model.isPresentingSetupWizard = false
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// `--migration-e2e APPLICATIONS` imports the XAMPP found there into a
    /// throwaway DevStack (its own folders and high ports, the installed
    /// runtimes, no helper), prints what happened and quits.
    private static func makeEndToEndModel(applications: URL) -> AppModel {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-MigrationE2E-\(UUID().uuidString.prefix(8))")
        let runtimes = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevStack/Runtimes")
        let model = AppModel(paths: DevStackPaths(applicationSupport: base.appendingPathComponent("Support"), logs: base.appendingPathComponent("Logs"),
                                                  builtInRuntimes: runtimes, defaultSiteRoot: base.appendingPathComponent("DevStack/localhost")),
                             automaticallyLoad: false)
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            await model.load()
            var ports = model.configuration.ports
            ports.webHTTP = 18180; ports.webHTTPS = 18543; ports.mysql = 13406; ports.mailpitSMTP = 11025; ports.mailpitInbox = 18025
            model.configuration.ports = ports
            model.configuration.defaultPHPRuntimeID = "php-8.5"
            try? await model.saveConfiguration()
            say("support: \(model.paths.applicationSupport.path)")
            MigrationController.applicationsFolder = applications
            for round in 1...(CommandLine.arguments.contains("--twice") ? 2 : 1) {
            say("== round \(round)")
            let controller = MigrationController(model: model)
            controller.loadSources()
            say("installations: \(controller.installations.map(\.title))")
            await controller.scan()
            controller.phpRuntimeID = "php-8.5"
            for check in controller.checks { say("check [\(check.status)] \(check.title) — \(check.detail ?? "")") }
            for choice in controller.projects { say("project \(choice.project.name) → \(controller.url(for: choice))") }
            say("databases: \(controller.databases.map { "\($0.database.name)\($0.selected ? "" : " (off)")\($0.exists ? " exists → \($0.targetName)" : "")" })")
            let started = Date()
            controller.start()
            if let delay = argument("--cancel-after").flatMap(Int.init) {
                try? await Task.sleep(for: .milliseconds(delay))
                controller.cancel()
            }
            while controller.step != .results { try? await Task.sleep(for: .milliseconds(300)) }
            say("finished in \(Int(Date().timeIntervalSince(started))) s")
            for task in controller.tasks { say("task [\(task.state)] \(task.title) — \(task.detail ?? "")") }
            if let results = controller.results {
                say("outcome: \(results.outcome) failure: \(results.failure ?? "-")")
                for project in results.projects { say("site [\(project.outcome)] \(project.name) \(project.url) — \(project.message ?? "")") }
                for database in results.databases { say("database [\(database.outcome)] \(database.source) → \(database.target): \(database.tables) tables, \(database.rows) rows — \(database.message ?? "")") }
                for note in results.notes { say("note: \(note)") }
                say("report: \(results.report?.path ?? "-")")
            }
            }
            say("mysql settings: \(model.configuration.mysqlSettings)")
            for site in model.configuration.sites {
                let path = site.hostname == "localhost" ? "/wp/" : "/"
                let body = try? ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                    "-sk", "--max-time", "10", "--resolve", "\(site.hostname):18543:127.0.0.1", "https://\(site.hostname):18543\(path)"], timeout: 15)
                say("GET \(site.hostname)\(path) → \(body?.standardOutput.prefix(120) ?? "")")
            }
            await model.stopAll()
            NSApp.terminate(nil)
        }
        return model
    }

    /// The migration wizard at `step`, filled with an XAMPP that is not on disk.
    private static func migrationFixture(step: String, model: AppModel, root: URL) -> MigrationController {
        let controller = MigrationController(model: model)
        let xampp = XAMPPInstallation(root: URL(fileURLWithPath: "/Applications/XAMPP/xamppfiles"), version: "8.2.4",
                                      htdocs: URL(fileURLWithPath: "/Applications/XAMPP/xamppfiles/htdocs"), dataDirectory: URL(fileURLWithPath: "/Applications/XAMPP/xamppfiles/var/mysql"))
        let older = XAMPPInstallation(root: URL(fileURLWithPath: "/Applications/XAMPP81/xamppfiles"), version: "8.1.17",
                                      htdocs: URL(fileURLWithPath: "/Applications/XAMPP81/xamppfiles/htdocs"), dataDirectory: URL(fileURLWithPath: "/Applications/XAMPP81/xamppfiles/var/mysql"))
        controller.installations = [xampp, older]
        controller.installationID = xampp.id
        let htdocs = xampp.htdocs
        let projects = [
            MigrationProject(id: "crm", name: "crm", source: htdocs.appendingPathComponent("crm"), kind: .folder, framework: .plainPHP, webRoot: "", files: 812, bytes: 48_300_000),
            MigrationProject(id: "shop", name: "shop kopyası 2", source: htdocs.appendingPathComponent("shop kopyası 2"), kind: .folder, framework: .plainPHP, webRoot: "", virtualHost: "shop.local", files: 2_310, bytes: 210_000_000),
            MigrationProject(id: "app", name: "laravel-app", source: htdocs.appendingPathComponent("laravel-app"), kind: .folder, framework: .laravel, webRoot: "public", files: 9_120, bytes: 96_000_000),
            MigrationProject(id: "blog", name: "blog", source: htdocs.appendingPathComponent("blog"), kind: .folder, framework: .wordpress, webRoot: "", files: 3_402, bytes: 88_000_000),
            MigrationProject(id: "loose", name: "Files in htdocs", source: htdocs, kind: .looseFiles(["test.php", "info.php"]), framework: .plainPHP, webRoot: "", files: 2, bytes: 9_000)
        ]
        controller.inventory = XAMPPInventory(installation: xampp, projects: projects,
                                              databases: ["crm_db", "shop", "wp_blog", "test"].map { MigrationDatabase(name: $0, isSample: $0 == "test") },
                                              dataReadable: false, dataBytes: 412_000_000, serverArchitectures: ["x86_64"], virtualHostsIncluded: true,
                                              skippedDefaults: ["dashboard", "img", "index.php"])
        controller.rosettaAvailable = step != "check"
        controller.phpRuntimeID = "php-8.4"
        controller.projects = projects.map { project in
            let own = !project.webRoot.isEmpty || project.virtualHost != nil
            return MigrationController.ProjectChoice(project: project, address: own ? .ownSite : .localhostPath,
                                                     hostname: MigrationNaming.hostname(for: project, taken: []))
        }
        controller.databases = [
            MigrationController.DatabaseChoice(database: MigrationDatabase(name: "crm_db"), selected: true, exists: false, renamedName: "crm_db"),
            MigrationController.DatabaseChoice(database: MigrationDatabase(name: "shop"), selected: true, exists: true, renamedName: "shop_xampp"),
            MigrationController.DatabaseChoice(database: MigrationDatabase(name: "wp_blog"), selected: true, exists: false, renamedName: "wp_blog"),
            MigrationController.DatabaseChoice(database: MigrationDatabase(name: "test", isSample: true), selected: false, exists: false, renamedName: "test")
        ]
        switch step {
        case "source": controller.step = .source
        case "check": controller.step = .check
        case "choose": controller.step = .choose
        case "settings":
            controller.step = .choose
            controller.projects = Array(controller.projects.prefix(1))
            controller.databases = Array(controller.databases.prefix(1))
        case "importing":
            controller.step = .importing
            controller.isRunning = true
            controller.tasks = [
                .init(id: "files", title: "Copy projects", state: .done, detail: "15,646 files, 442 MB"),
                .init(id: "sites", title: "Add sites", state: .done, detail: "2 sites; localhost serves the rest"),
                .init(id: "data", title: "Copy XAMPP's database files", state: .done),
                .init(id: "server", title: "Start XAMPP's MariaDB on the copy", state: .done),
                .init(id: "export", title: "Export databases", state: .done, detail: "3 of 3 exported to Backups"),
                .init(id: "mysql", title: "Prepare MySQL 8.4.11 LTS", state: .done, detail: "root signs in without a password, XAMPP's SQL mode"),
                .init(id: "import", title: "Import and verify databases", state: .running, detail: "shop → shop_xampp (2 of 3)", progress: 0.52),
                .init(id: "accounts", title: "Recreate database accounts"),
                .init(id: "settings", title: "Update project settings"),
                .init(id: "stack", title: "Start the stack"),
                .init(id: "probe", title: "Open each site")
            ]
        default:
            controller.step = .results
            var results = MigrationController.Results()
            results.projects = [
                .init(id: "crm", name: "crm", url: "https://localhost/crm", folder: "/Users/me/DevStack/localhost/crm", outcome: .ok),
                .init(id: "shop", name: "shop kopyası 2", url: "https://shop.localhost", folder: "/Users/me/DevStack/shop kopyası 2", outcome: .ok),
                .init(id: "app", name: "laravel-app", url: "https://laravel-app.localhost", folder: "/Users/me/DevStack/laravel-app", outcome: .warning,
                      message: "A PHP function is missing: Call to undefined function mb_ereg_replace_callback()"),
                .init(id: "blog", name: "blog", url: "https://localhost/blog", folder: "/Users/me/DevStack/localhost/blog", outcome: .ok)
            ]
            results.databases = [
                .init(id: "crm_db", source: "crm_db", target: "crm_db", tables: 42, rows: 18_220, outcome: .ok),
                .init(id: "shop", source: "shop", target: "shop_xampp", tables: 6, rows: 1_204, outcome: .ok),
                .init(id: "wp_blog", source: "wp_blog", target: "wp_blog", tables: 12, rows: 3_118, outcome: .ok)
            ]
            results.notes = ["shop_xampp: Aria tables became InnoDB tables.", "shop_xampp: left out Sequence seq_orders: MySQL has no sequences.",
                             "blog: 14 database values now use https://localhost/blog"]
            results.report = root.appendingPathComponent("Report.md")
            controller.results = results
        }
        return controller
    }

    private static func makeWindow(for model: AppModel) -> NSWindow {
        let host = NSHostingController(rootView: RootView().environmentObject(model).frame(minWidth: 760, minHeight: 520))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.contentViewController = host
        return window
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        // The detail page's scroll view, not the sidebar's: the widest one.
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.width < $1.frame.width }
    }

    private static func captureWindow(_ number: Int) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // .optionIncludingWindow, .boundsIgnoreFraming
        return capture(.null, 1 << 3, UInt32(number), 1 << 0)?.takeRetainedValue()
    }

    private struct Catalog: Decodable { var runtimes: [RuntimeManifest] }
}
#endif
