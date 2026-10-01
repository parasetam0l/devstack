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

    enum Step: Int, CaseIterable {
        case welcome, helper, certificate, ports, done
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .helper: "Helper"
            case .certificate: "Certificate"
            case .ports: "Ports"
            case .done: "Done"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .welcome: welcomeStep
                case .helper: helperStep
                case .certificate: certificateStep
                case .ports: portsStep
                case .done: doneStep
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 560)
        .interactiveDismissDisabled(true)
        .onChange(of: step) { _, newStep in
            if newStep == .ports { syncPorts() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandIcon(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up DevStack").font(.system(size: 16, weight: .semibold))
                    Text("A few one-time steps so local sites, HTTPS and ports 80/443 just work.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    let current = candidate.rawValue <= step.rawValue
                    Text(candidate.title)
                        .font(.system(size: 10, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? DevStackDesign.accent : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(current ? DevStackDesign.accent.opacity(0.14) : Color.clear))
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if step != .welcome, step != .done {
                Button("Back") { goBack() }
                    .buttonStyle(DevStackGlassButtonStyle())
                    .disabled(model.isBusy || startingStack)
            }
            Button(primaryTitle) { Task { await primaryAction() } }
                .buttonStyle(DevStackProminentButtonStyle())
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
        case .welcome: "Get Started"
        case .helper:
            if model.helperInstalled || helperIsImpossible { "Continue" } else { "Set Up Helper" }
        case .certificate: model.localCATrusted ? "Continue" : "Install Certificate"
        case .ports: model.hasRunningServices ? "Continue" : "Apply and Continue"
        case .done: "Finish"
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
        VStack(alignment: .leading, spacing: 14) {
            bullet("lock.shield", "Install the privileged helper",
                   "Needed for ports 80/443, /etc/hosts entries and the local DNS responder. macOS asks for approval once in Login Items & Extensions.")
            bullet("checkmark.seal", "Create and trust the DevStack certificate authority",
                   "HTTPS stops warning on every DevStack site. macOS asks for your administrator password once.")
            bullet("network", "Choose your web ports",
                   "Use 80 and 443 so site URLs have no port number, or keep 8080/8443 to run without the helper.")
            Text("Everything runs on this Mac. The helper only listens on loopback and your local network.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow(
                title: model.helperInstalled ? "Helper is ready" : (model.helperSetupState == .requiresApproval ? "Waiting for approval" : "Helper not set up yet"),
                detail: model.helperInstalled
                    ? "Authorized and responding. Ports below 1024, custom domains and local DNS are available."
                    : model.helperSetupState.message,
                ok: model.helperInstalled
            )
            if !model.helperInstalled {
                Text("Approve DevStack in System Settings → General → Login Items & Extensions → Allow in the Background. This window updates automatically once the helper answers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.helperSetupState == .requiresApproval {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(DevStackGlassButtonStyle())
                }
                if model.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the helper…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if model.isPreviewBuild {
                Label("This preview build cannot drive the helper. Install the signed build in Applications.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text("You can continue without the helper and use ports 8080/8443 with .localhost domains.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var certificateStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow(
                title: model.localCATrusted ? "Certificate is trusted" : "Certificate not trusted yet",
                detail: model.localCATrusted
                    ? "Every user and browser on this Mac accepts DevStack HTTPS certificates."
                    : "Installs the DevStack local CA into the system trust store. macOS asks for your administrator password once; credentials never pass through DevStack.",
                ok: model.localCATrusted
            )
            if let certificateError {
                Label(certificateError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !model.localCATrusted {
                Text("Alternatively you can trust the CA for this user only from the SSL page, without an administrator prompt.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var portsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose where the web server answers. With the helper you can use the standard 80 and 443 so site URLs drop the port number.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("HTTP port").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    TextField("80", text: $httpPort).textFieldStyle(.roundedBorder).frame(width: 90).disabled(model.hasRunningServices)
                    hint(for: httpPort, configured: model.configuration.ports.webHTTP)
                }
                GridRow {
                    Text("HTTPS port").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    TextField("443", text: $httpsPort).textFieldStyle(.roundedBorder).frame(width: 90).disabled(model.hasRunningServices)
                    hint(for: httpsPort, configured: model.configuration.ports.webHTTPS)
                }
            }
            if model.hasRunningServices {
                Label("Stop the stack to change ports; the current ports stay in place.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let portError {
                Label(portError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet(model.helperInstalled ? "checkmark.circle.fill" : "circle.dashed",
                   model.helperInstalled ? "Helper ready" : "Helper skipped",
                   model.helperInstalled ? "Ports below 1024, custom domains and local DNS are available." : "You can set it up later in Settings → System integration.")
            bullet(model.localCATrusted ? "checkmark.circle.fill" : "circle.dashed",
                   model.localCATrusted ? "Certificate trusted" : "Certificate skipped",
                   model.localCATrusted ? "HTTPS sites open without warnings." : "Trust the CA later from the SSL page.")
            bullet("network", "Web ports \(model.configuration.ports.webHTTP) / \(model.configuration.ports.webHTTPS)",
                   model.configuration.ports.webHTTP < 1024
                   ? "Site URLs have no port number."
                   : "Site URLs include the port, for example http://localhost:\(model.configuration.ports.webHTTP).")
            Divider()
            HStack(spacing: 8) {
                Button("Start Stack") {
                    startingStack = true
                    Task {
                        await model.startAll()
                        startingStack = false
                    }
                }
                .buttonStyle(DevStackGlassButtonStyle())
                .disabled(model.isBusy || startingStack || model.stackIsRunning)
                Text(model.stackIsRunning ? "Stack is running." : "Optional — you can start it any time from the toolbar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pieces

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(DevStackDesign.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(title: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16)).foregroundStyle(ok ? DevStackDesign.success : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hint(for text: String, configured: UInt16) -> some View {
        Group {
            if let value = UInt16(text), value > 0, value < 1024, !model.helperInstalled {
                Text("Needs the helper · without it sites answer on \(ServicePorts.webHTTPFallback)/\(ServicePorts.webHTTPSFallback)")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            } else if let value = UInt16(text), value > 0, value != configured, !PortAvailability.isFree(value) {
                // The current port may be held by DevStack's own helper
                // forwarding, so only other ports are checked.
                Text("Port \(value) is already in use by another app")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
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
            step = .helper
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
                httpPort = String(ports.webHTTP)
                httpsPort = String(ports.webHTTPS)
            }
        }
    }
}
