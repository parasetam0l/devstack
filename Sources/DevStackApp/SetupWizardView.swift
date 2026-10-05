import AppKit
import DevStackCore
import ServiceManagement
import SwiftUI

/// First-run setup: privileged helper, system-wide certificate trust and the
/// web ports, each step with one clear action so macOS only ever asks for
/// approval or credentials once.
struct SetupWizardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var httpPort = ""
    @State private var httpsPort = ""
    @State private var portError: String?
    @State private var certificateError: String?
    @State private var startingStack = false
    @State private var optionalRuntimes: Set<String> = []
    @State private var runtimeError: String?

    enum Step: Int, CaseIterable {
        case welcome, runtimes, helper, certificate, ports, done

        var heading: String {
            switch self {
            case .welcome: "Welcome to DevStack"
            case .runtimes: "Download the Runtimes"
            case .helper: "Set Up the Helper"
            case .certificate: "Trust HTTPS"
            case .ports: "Choose the Web Ports"
            case .done: "You're All Set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "Set up your local development stack."
            case .runtimes: "The servers and tools your stack runs."
            case .helper: "For ports 80 and 443, custom hostnames and local DNS."
            case .certificate: "So browsers accept your sites' certificates."
            case .ports: "Where the web server answers."
            case .done: "Your stack is ready to start."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch step {
                case .welcome: welcomeStep
                case .runtimes: runtimesStep
                case .helper: helperStep
                case .certificate: certificateStep
                case .ports: portsStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(true)
        .onChange(of: step) { _, newStep in
            if newStep == .ports { syncPorts() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.heading).font(.title2.weight(.semibold))
                Text(step.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .welcome, step != .done {
                Button("Back") { goBack() }.disabled(model.isBusy || startingStack)
            }
            Spacer()
            if step == .runtimes, runtimeDownloadSize > 0 {
                Button("Skip for Now") { step = .helper }.disabled(model.isBusy)
            }
            if step == .helper, !model.helperInstalled, !helperIsImpossible {
                Button("Continue Without Helper") {
                    model.cancelHelperSetup()
                    step = .certificate
                }
                .disabled(startingStack)
            }
            if step == .certificate, !model.localCATrusted {
                Button("Skip for Now") { step = .ports }.disabled(model.isBusy)
            }
            Button(primaryTitle) { Task { await primaryAction() } }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .padding(16)
    }

    /// A preview build cannot register the helper at all; the wizard continues
    /// so setup can still finish and the helper can be added later from the
    /// signed /Applications build.
    private var helperIsImpossible: Bool { model.isPreviewBuild && model.runningTeamID == nil }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Continue"
        case .runtimes:
            runtimeDownloadSize > 0 ? "Install (\(ByteCountFormatter.string(fromByteCount: runtimeDownloadSize, countStyle: .file)))" : "Continue"
        case .helper:
            if model.helperInstalled || helperIsImpossible { "Continue" } else { "Set Up Helper" }
        case .certificate: model.localCATrusted ? "Continue" : "Trust Certificate"
        case .ports: model.hasRunningServices ? "Continue" : "Apply and Continue"
        case .done: "Done"
        }
    }

    private var primaryDisabled: Bool {
        if model.isBusy || startingStack { return true }
        if step == .ports, !model.hasRunningServices {
            return parsedPorts == nil
        }
        return false
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    BrandIcon(size: 56)
                    Text("A few one-time steps, so local sites, HTTPS and ports 80 and 443 just work. Everything runs on this Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                if !model.runtimePackCatalog.packs.isEmpty {
                    item("shippingbox", "Download the runtimes",
                         "Apache, PHP, MySQL and the others you choose, each checked against the signature this version of DevStack expects.")
                }
                item("lock.shield", "Set up the helper",
                     "For ports 80 and 443, custom hostnames and local DNS. macOS asks you to approve it once in Login Items & Extensions.")
                item("checkmark.seal", "Trust the DevStack certificate authority",
                     "So HTTPS works without warnings. macOS asks for your administrator password once.")
                item("network", "Choose the web ports",
                     "80 and 443 keep port numbers out of site addresses; 8080 and 8443 work without the helper.")
            }
        }
        .formStyle(.grouped)
    }

    /// Optional runtimes offered on top of the ones the stack always uses.
    private var optionalRuntimeIDs: [String] {
        ["nginx-1.30", "php-8.4", "postgresql-18", "php-7.4", "mysql-5.7"]
            .filter { model.runtimePackCatalog.pin(for: $0) != nil && !model.runtimePacksInUse.contains($0) }
    }

    private var runtimeDownloadSize: Int64 {
        model.runtimePackDownloadSize(model.runtimePacksInUse + optionalRuntimes.sorted())
    }

    private var runtimesStep: some View {
        Form {
            if model.runtimePackCatalog.packs.isEmpty {
                Section {
                    NoticeRow(symbol: "checkmark.circle.fill", title: "Runtimes are included",
                              message: "This copy of DevStack bundles its runtimes; there is nothing to download.", tint: .green)
                }
            } else {
                if let progress = model.runtimePackProgress {
                    Section { RuntimePackProgressPanel(progress: progress) }
                }
                if let runtimeError {
                    Section { NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Couldn't install", message: runtimeError) }
                }
                Section {
                    Text(model.runtimePacksInUse.compactMap { model.runtimePackCatalog.pin(for: $0)?.displayName }.joined(separator: ", "))
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Your stack")
                } footer: {
                    SectionFooter {
                        Text(runtimeDownloadSize == 0 ? "Everything your stack needs is installed." : "Each runtime is checked before it installs. Add or remove runtimes later on the Runtimes page.")
                    }
                }
                if !optionalRuntimeIDs.isEmpty {
                    Section("Also install") {
                        ForEach(optionalRuntimeIDs, id: \.self) { id in
                            if let pin = model.runtimePackCatalog.pin(for: id) {
                                let installed = model.runtimePackStatus(pin) != .notInstalled
                                Toggle(isOn: Binding(
                                    get: { installed || optionalRuntimes.contains(id) },
                                    set: { selected in if selected { optionalRuntimes.insert(id) } else { optionalRuntimes.remove(id) } }
                                )) {
                                    Text(pin.displayName + (pin.isLegacy ? " (legacy)" : ""))
                                    Text(installed ? "Installed" : ByteCountFormatter.string(fromByteCount: pin.size, countStyle: .file))
                                }
                                .disabled(installed || model.isBusy)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var helperStep: some View {
        Form {
            Section {
                LabeledContent("Helper") {
                    HStack(spacing: 10) {
                        if model.isBusy, !model.helperInstalled { ProgressView().controlSize(.small) }
                        StatusLabel(title: model.helperInstalled ? "Ready" : (model.helperSetupState == .requiresApproval ? "Waiting for approval" : "Not set up"),
                                    color: model.helperInstalled ? .green : .orange)
                    }
                }
                if !model.helperInstalled, model.helperSetupState == .requiresApproval {
                    LabeledContent("Approval") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: {
                SectionFooter {
                    Text(model.helperInstalled
                         ? "Ports below 1024, custom hostnames and local DNS are available."
                         : "Approve DevStack in System Settings → General → Login Items & Extensions → Allow in the Background. This window updates as soon as the helper answers. The approval survives app updates.")
                }
            }
            if model.isPreviewBuild {
                Section {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Preview build",
                              message: "This build cannot use the helper. Set it up from the signed copy in Applications.")
                }
            }
            Section {} footer: {
                SectionFooter { Text("You can continue without the helper and use ports 8080 and 8443 with .localhost names.") }
            }
        }
        .formStyle(.grouped)
    }

    private var certificateStep: some View {
        Form {
            Section {
                LabeledContent("DevStack Local CA") {
                    StatusLabel(title: model.localCATrusted ? "Trusted" : "Not trusted", color: model.localCATrusted ? .green : .orange)
                }
                if !model.localCATrusted {
                    LabeledContent {
                        Button("Trust for This User Only") {
                            Task {
                                certificateError = await model.trustForCurrentUserFromWizard()
                                if certificateError == nil, model.localCATrusted { step = .ports }
                            }
                        }
                        .disabled(model.isBusy)
                    } label: {
                        Text("For your account only")
                        Text("macOS asks for your login password instead of an administrator's.")
                    }
                }
            } footer: {
                SectionFooter {
                    Text(model.localCATrusted
                         ? "Browsers on this Mac accept DevStack's HTTPS certificates."
                         : "Trust Certificate trusts the DevStack CA for every app on this Mac. macOS asks for an administrator's password in its own dialog; it never passes through DevStack.")
                }
            }
            if let certificateError {
                Section { NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Couldn't trust the certificate", message: certificateError) }
            }
        }
        .formStyle(.grouped)
    }

    private var portsStep: some View {
        Form {
            Section {
                LabeledContent("HTTP port") {
                    TextField("HTTP port", text: $httpPort).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        .disabled(model.hasRunningServices)
                }
                LabeledContent("HTTPS port") {
                    TextField("HTTPS port", text: $httpsPort).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        .disabled(model.hasRunningServices)
                }
            } footer: {
                SectionFooter {
                    if model.hasRunningServices {
                        Text("Stop the stack to change ports; the current ports stay in place.")
                    } else if let note = portNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("With the helper, 80 and 443 keep port numbers out of site addresses.")
                    }
                    if let portError {
                        Label(portError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var doneStep: some View {
        Form {
            Section {
                LabeledContent("Helper") {
                    StatusLabel(title: model.helperInstalled ? "Ready" : "Skipped", color: model.helperInstalled ? .green : Color(nsColor: .tertiaryLabelColor))
                }
                LabeledContent("HTTPS certificate") {
                    StatusLabel(title: model.localCATrusted ? "Trusted" : "Skipped", color: model.localCATrusted ? .green : Color(nsColor: .tertiaryLabelColor))
                }
                LabeledContent("Web ports", value: "\(model.configuration.ports.webHTTPListen) and \(model.configuration.ports.webHTTPSListen)")
            } footer: {
                SectionFooter {
                    Text(model.helperInstalled && model.configuration.ports.webHTTP < 1024
                         ? "Site addresses have no port number."
                         : "Site addresses include the port, for example http://localhost:\(model.configuration.ports.webHTTPListen). Skipped steps are in Settings.")
                }
            }
            Section {
                LabeledContent {
                    Button(model.stackIsRunning ? "Running" : "Start Stack") {
                        startingStack = true
                        Task {
                            await model.startAll()
                            startingStack = false
                        }
                    }
                    .disabled(model.isBusy || startingStack || model.stackIsRunning)
                } label: {
                    Text("Start now")
                    Text("Or any time from the toolbar.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Pieces

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
        .padding(.vertical, 2)
    }

    /// A warning about the ports typed so far, if any.
    private var portNote: String? {
        for text in [httpPort, httpsPort] {
            guard let value = UInt16(text), value > 0 else { continue }
            if value < 1024, !model.helperInstalled {
                return "Ports below 1024 need the helper. Without it, sites answer on \(ServicePorts.webHTTPFallback) and \(ServicePorts.webHTTPSFallback)."
            }
            if value != model.configuration.ports.webHTTP, value != model.configuration.ports.webHTTPS, !PortAvailability.isFree(value) {
                // The current ports may be held by DevStack's own forwarding,
                // so only other ports are checked.
                return "Port \(value) is already in use by another app."
            }
        }
        return nil
    }

    // MARK: - Actions

    private var parsedPorts: (http: UInt16, https: UInt16)? {
        guard let http = UInt16(httpPort), let https = UInt16(httpsPort), http > 0, https > 0 else { return nil }
        return (http, https)
    }

    private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    private func primaryAction() async {
        switch step {
        case .welcome:
            step = .runtimes
        case .runtimes:
            if runtimeDownloadSize > 0 {
                runtimeError = await model.installRuntimePacks(model.runtimePacksInUse + optionalRuntimes.sorted())
                if runtimeError == nil { step = .helper }
            } else {
                step = .helper
            }
        case .helper:
            if model.helperInstalled || helperIsImpossible {
                step = .certificate
            } else {
                await model.setUpHelperForWizard()
                if model.helperInstalled { step = .certificate }
            }
        case .certificate:
            if model.localCATrusted {
                step = .ports
            } else {
                certificateError = await model.installSystemCertificate()
                if certificateError == nil, model.localCATrusted { step = .ports }
            }
        case .ports:
            if model.hasRunningServices {
                step = .done
                return
            }
            guard let ports = parsedPorts else { return }
            portError = await model.applyWizardPorts(http: ports.http, https: ports.https)
            if portError == nil { step = .done }
        case .done:
            await model.completeSetupWizard()
            dismiss()
        }
    }

    private func syncPorts() {
        let ports = model.configuration.ports
        if httpPort.isEmpty, httpsPort.isEmpty {
            if model.helperInstalled {
                httpPort = "80"
                httpsPort = "443"
            } else {
                // Without the helper, privileged ports cannot be forwarded;
                // preselect the working fallback listeners.
                httpPort = String(ports.webHTTP < 1024 ? ServicePorts.webHTTPFallback : ports.webHTTP)
                httpsPort = String(ports.webHTTPS < 1024 ? ServicePorts.webHTTPSFallback : ports.webHTTPS)
            }
        }
    }
}
