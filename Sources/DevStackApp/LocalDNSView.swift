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
        WorkspacePage {
            PageHeading(title: "Local DNS", subtitle: "Serve DevStack hostnames to phones and other devices on this network.")
            SurfacePanel {
                HStack(spacing: 8) {
                    FeatureIcon(symbol: "wifi.router")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local DNS responder").font(.system(size: 13, weight: .semibold))
                        Text(verbatim: "Port 53 · answers \(hostnames.count) hostnames · other queries forwarded").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(
                        title: available ? (running ? "Running" : "Stopped") : "Unavailable",
                        color: available ? (running ? DevStackDesign.success : .secondary) : .secondary,
                        dot: true,
                        dotColor: running ? .green : nil
                    )
                    Button(running ? "Stop" : "Start") {
                        Task { await model.setLocalNetworkAccess(!running) }
                    }.buttonStyle(DevStackGlassButtonStyle())
                        .disabled(model.isBusy || !available)
                        .help(available ? "Answer DevStack hostnames for devices on this network" : "Requires the privileged helper")
                        .accessibilityLabel(running ? "Stop local DNS" : "Start local DNS")
                }
                if !available {
                    InfoNotice(symbol: "lock.shield", title: "Helper required", message: "Local DNS runs inside the privileged helper. Set it up in Settings → System integration.", color: .orange)
                } else if !running {
                    InfoNotice(symbol: "info.circle", title: "Not serving", message: "Start the responder to answer DevStack hostnames for this network.", color: .secondary)
                }
            }
            if available, running {
                SurfacePanel(title: "Addresses", subtitle: "Point each device's DNS at one of these addresses.") {
                    if addresses.isEmpty {
                        Text("No active Wi-Fi or Ethernet connection.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(addresses, id: \.address) { entry in
                            CopyValueRow(label: entry.interface, value: entry.address)
                        }
                        Divider()
                        Text("On a phone: Wi-Fi settings → Configure DNS → Manual → \(model.localNetworkAddress ?? "the address above").")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                SurfacePanel(title: "Hostnames", subtitle: "Answered with this Mac's address; everything else is forwarded.") {
                    ForEach(hostnames, id: \.self) { hostname in
                        HStack(spacing: 8) {
                            Text(hostname).font(.system(size: 12, design: .monospaced))
                            if hostname.hasSuffix(".localhost") {
                                StatusBadge(title: "Device-local", color: .secondary)
                            }
                            Spacer()
                            Text(model.configuration.sites.contains { $0.hostname == hostname } ? "Site" : "Management")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    Divider()
                    Text("Names ending in .localhost resolve on the device itself; use .test domains for sites you open from other devices.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SurfacePanel(title: "HTTPS", subtitle: "Devices need the DevStack CA before HTTPS stops warning.") {
                    if let address = model.localNetworkAddress {
                        CopyValueRow(label: "CA URL", value: "http://\(address):\(model.configuration.ports.webHTTPListen)/devstack-ca.crt")
                    }
                    Text("iOS: install the profile, then enable full trust in Settings → General → About → Certificate Trust Settings. Android: install it as a CA certificate. Use each site's hostname (not the IP) for HTTPS.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
