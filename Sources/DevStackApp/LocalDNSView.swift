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
        PanelPage {
            if !available {
                Banner(symbol: "lock.shield", title: "Local DNS needs the DevStack helper",
                       detail: "The DNS responder runs inside DevStack's privileged helper.") {
                    Button("Settings…") { model.selectedSection = .settings }
                }
            }

            Panel("Responder", note: "Devices that use this Mac as their DNS server resolve DevStack hostnames here; every other domain goes to your usual DNS servers.") {
                ServiceLine(symbol: "wifi.router", dot: running ? .green : Color(nsColor: .tertiaryLabelColor),
                            state: available ? (running ? "Running" : "Stopped") : "Needs helper", stateTint: available ? .secondary : .orange,
                            address: "port 53 · \(hostnames.count) hostname\(hostnames.count == 1 ? "" : "s")") {
                    Text("Local DNS").fontWeight(.medium)
                } controls: {
                    IconButton(title: running ? "Stop local DNS" : "Start local DNS", symbol: running ? "stop.fill" : "play.fill") {
                        Task { await model.setLocalNetworkAccess(!running) }
                    }
                    .disabled(model.isBusy || !available)
                } menuItems: {
                    Button(running ? "Stop" : "Start") { Task { await model.setLocalNetworkAccess(!running) } }
                        .disabled(model.isBusy || !available)
                }
            }

            Panel("Addresses", note: "On a phone: Wi-Fi settings → Configure DNS → Manual → \(model.localNetworkAddress ?? "one of these addresses").") {
                if addresses.isEmpty {
                    PanelRow { Text("No active Wi-Fi or Ethernet connection.").foregroundStyle(.secondary); Spacer() }
                } else {
                    ForEach(addresses, id: \.address) { entry in ValueRow(label: entry.interface, value: entry.address) }
                }
            }

            Panel("Hostnames", note: "Use .test names for sites you open from other devices; names ending in .localhost always point at the device itself.") {
                ForEach(hostnames, id: \.self) { hostname in
                    PanelRow {
                        Text(hostname).font(.callout.monospaced()).textSelection(.enabled)
                        if hostname.hasSuffix(".localhost") {
                            Text("resolves on each device itself").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Tag(text: model.configuration.sites.contains { $0.hostname == hostname } ? "Site" : "DevStack")
                    }
                }
            }

            Panel("HTTPS on Other Devices", note: "Open the CA certificate's address on the device and install it. On iOS, also turn on full trust in Settings → General → About → Certificate Trust Settings. Open sites by hostname, not IP address.") {
                if let address = model.localNetworkAddress {
                    ValueRow(label: "CA certificate", value: "http://\(address):\(model.configuration.ports.webHTTPListen)/devstack-ca.crt")
                } else {
                    PanelRow { Text("Connect to Wi-Fi or Ethernet first.").foregroundStyle(.secondary); Spacer() }
                }
            }
        }
    }
}
