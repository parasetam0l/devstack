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
                .init(id: "helper", title: "System integration", severity: .warning, evidence: "The privileged helper is not installed in this isolated review.", remediation: "Complete setup in Settings to enable local domains and HTTPS."),
                .init(id: "port", title: "Port 3306 is available", severity: .info, evidence: "No conflicting listener was found on the loopback interface.")
            ])
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
