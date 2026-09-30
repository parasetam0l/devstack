import Darwin
import Foundation

public enum LocalNetwork {
    /// The primary LAN IPv4 address (Wi-Fi or Ethernet), when one is active.
    public static func primaryIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, address: String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let socketAddress = interface.pointee.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPrivateIPv4(address), !address.hasPrefix("127."), !address.hasPrefix("169.254.") else { continue }
            let name = String(decoding: UnsafeRawBufferPointer(start: interface.pointee.ifa_name, count: Int(strlen(interface.pointee.ifa_name))), as: UTF8.self)
            candidates.append((name, address))
        }
        return candidates.first(where: { $0.name.hasPrefix("en") })?.address ?? candidates.first?.address
    }

    public static func isPrivateIPv4(_ address: String) -> Bool {
        var raw = in_addr()
        guard inet_pton(AF_INET, address, &raw) == 1 else { return false }
        let value = UInt32(bigEndian: raw.s_addr)
        let first = UInt8((value >> 24) & 0xFF)
        let second = UInt8((value >> 16) & 0xFF)
        switch first {
        case 10, 127: return true
        case 172: return (16...31).contains(second)
        case 192: return second == 168
        case 169: return second == 254
        default: return false
        }
    }

    /// Loopback, link-local or private-range sources. Services exposed on the LAN
    /// only accept clients from these ranges so a router port-forward cannot
    /// publish them to the internet.
    public static func isLocalSource(_ address: String) -> Bool {
        let value = address.split(separator: "%").first.map(String.init) ?? address
        if value == "::1" { return true }
        if isPrivateIPv4(value) { return true }
        let lower = value.lowercased()
        for prefix in ["fc", "fd", "fe8", "fe9", "fea", "feb"] where lower.hasPrefix(prefix) { return true }
        return false
    }
}
