import Darwin
import Foundation

/// Best-effort checks that a TCP port can be bound before the stack starts.
public enum PortAvailability {
    /// True when a TCP listener can bind the port on all interfaces right now.
    /// The socket is closed again immediately.
    public static func isFree(_ port: UInt16) -> Bool {
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// True when something accepts TCP connections on 127.0.0.1 at the port,
    /// whoever owns it: unlike lsof, this also sees listeners owned by root,
    /// such as the helper's forwarders on ports 80 and 443.
    public static func isListening(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The first port from `start` up that nothing listens on, that can be
    /// bound, and that is not in `excluded`.
    public static func firstFree(from start: UInt16, excluding excluded: Set<UInt16>, limit: Int = 500) -> UInt16? {
        var port = Int(start)
        for _ in 0..<limit {
            guard port <= Int(UInt16.max) else { return nil }
            let candidate = UInt16(port)
            if !excluded.contains(candidate), !isListening(candidate), isFree(candidate) { return candidate }
            port += 1
        }
        return nil
    }
}
