import AppKit
import DevStackCore
import SwiftUI

struct LocalDNSView: View {
    @EnvironmentObject private var model: AppModel

    private var running: Bool { model.helperStatus?.dnsEnabled == true }
    private var available: Bool { model.helperInstalled }
    private var addresses: [LocalNetwork.LocalAddress] { LocalNetwork.activeIPv4Addresses() }
    private var hostnames: [String] { model.localNetworkHostnames }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ServiceRowTitle(title: "DNS responder", symbol: "wifi.router",
                                    detail: "Port 53 · \(hostnames.count) hostname\(hostnames.count == 1 ? "" : "s") · everything else forwarded")
                    Spacer(minLength: 12)
                    StatusLabel(title: available ? (running ? "Running" : "Stopped") : "Unavailable",
                                color: running ? .green : Color(nsColor: .tertiaryLabelColor))
                    Button(running ? "Stop" : "Start") { Task { await model.setLocalNetworkAccess(!running) } }
                        .disabled(model.isBusy || !available)
                        .help(available ? "Answer DevStack hostnames for devices on this network" : "Needs the DevStack helper")
                        .accessibilityLabel(running ? "Stop local DNS" : "Start local DNS")
                }
                .padding(.vertical, 2)
                if !available {
                    NoticeRow(symbol: "lock.shield", title: "Needs the helper",
                              message: "The DNS responder runs inside DevStack's privileged helper.") {
                        Button("Settings…") { model.selectedSection = .settings }
                    }
                }
            } footer: {
                SectionFooter {
                    Text("Phones and other devices can use this Mac as their DNS server for DevStack hostnames. Every other domain resolves through your usual DNS servers.")
                }
            }

            Section {
                if addresses.isEmpty {
                    Text("No active Wi-Fi or Ethernet connection.").foregroundStyle(.secondary)
                } else {
                    ForEach(addresses, id: \.address) { entry in
                        CopyableValueRow(label: entry.interface, value: entry.address)
                    }
                }
            } header: {
                Text("Addresses")
            } footer: {
                SectionFooter {
                    Text("On a phone: Wi-Fi settings → Configure DNS → Manual → \(model.localNetworkAddress ?? "one of these addresses").")
                }
            }

            Section {
                ForEach(hostnames, id: \.self) { hostname in
                    LabeledContent {
                        Text(model.configuration.sites.contains { $0.hostname == hostname } ? "Site" : "DevStack")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(hostname).font(.body.monospaced())
                        if hostname.hasSuffix(".localhost") {
                            Text("Resolves on each device itself, not through this Mac")
                        }
                    }
                }
            } header: {
                Text("Hostnames")
            } footer: {
                SectionFooter {
                    Text("Use .test names for sites you open from other devices; names ending in .localhost always point at the device itself.")
                }
            }

            Section {
                if let address = model.localNetworkAddress {
                    CopyableValueRow(label: "CA certificate", value: "http://\(address):\(model.configuration.ports.webHTTPListen)/devstack-ca.crt")
                }
            } header: {
                Text("HTTPS on other devices")
            } footer: {
                SectionFooter {
                    Text("Open the CA certificate's address on the device and install it. On iOS, also turn on full trust in Settings → General → About → Certificate Trust Settings. Open sites by hostname, not IP address.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
