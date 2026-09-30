import Darwin
import Foundation

public struct DNSQuestion: Equatable, Sendable {
    public var id: UInt16
    public var name: String
    public var type: UInt16
    public var klass: UInt16

    public init(id: UInt16, name: String, type: UInt16, klass: UInt16) {
        self.id = id
        self.name = name
        self.type = type
        self.klass = klass
    }
}

/// Minimal DNS wire format support: parse a single-question query, build a local
/// A answer (or NODATA), and build failure responses. Everything else is relayed
/// to the system resolvers untouched.
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28
    public static let classIN: UInt16 = 1
    public static let rcodeServerFailure: UInt16 = 2

    public static func parseQuestion(_ message: Data) -> DNSQuestion? {
        let bytes = [UInt8](message)
        guard bytes.count >= 12 else { return nil }
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard flags & 0x8000 == 0 else { return nil }
        let questionCount = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        guard questionCount >= 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while true {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            if length == 0 {
                offset += 1
                break
            }
            guard length & 0xC0 == 0, offset + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
        guard offset + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        let klass = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        return DNSQuestion(id: id, name: labels.joined(separator: ".").lowercased(), type: type, klass: klass)
    }

    /// A direct A answer for a managed hostname. AAAA and other types answer
    /// NODATA so remote clients fall back to IPv4 instead of guessing addresses.
    public static func localResponse(for question: DNSQuestion, address: String, ttl: UInt32 = 30) -> Data {
        var data = Data()
        appendUInt16(question.id, to: &data)
        let answerCount: UInt16 = question.type == typeA && ipv4Octets(address) != nil ? 1 : 0
        appendUInt16(0x8180, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(answerCount, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendName(question.name, to: &data)
        appendUInt16(question.type, to: &data)
        appendUInt16(question.klass, to: &data)
        if answerCount == 1, let octets = ipv4Octets(address) {
            appendUInt16(0xC00C, to: &data)
            appendUInt16(typeA, to: &data)
            appendUInt16(classIN, to: &data)
            appendUInt32(ttl, to: &data)
            appendUInt16(4, to: &data)
            data.append(contentsOf: octets)
        }
        return data
    }

    public static func failureResponse(for question: DNSQuestion?, rcode: UInt16) -> Data {
        var data = Data()
        appendUInt16(question?.id ?? 0, to: &data)
        appendUInt16(0x8180 | (rcode & 0x000F), to: &data)
        appendUInt16(question == nil ? 0 : 1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        if let question {
            appendName(question.name, to: &data)
            appendUInt16(question.type, to: &data)
            appendUInt16(question.klass, to: &data)
        }
        return data
    }

    public static func ipv4Octets(_ address: String) -> [UInt8]? {
        var raw = in_addr()
        guard inet_pton(AF_INET, address, &raw) == 1 else { return nil }
        let value = UInt32(bigEndian: raw.s_addr)
        return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value >> 16), to: &data)
        appendUInt16(UInt16(value & 0xFFFF), to: &data)
    }

    private static func appendName(_ name: String, to data: inout Data) {
        for label in name.split(separator: ".") where !label.isEmpty {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0)
    }
}

public enum DNSUpstreams {
    public static func parseResolvConf(_ contents: String) -> [String] {
        contents.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, parts[0] == "nameserver" else { return nil }
            return parts[1]
        }
    }

    /// System resolvers that can safely receive forwarded queries: no loopback
    /// entries (they would loop back into this server) and nothing on the
    /// excluded list (the Mac's own LAN addresses).
    public static func usableResolvers(contents: String, excluding excluded: Set<String>) -> [String] {
        parseResolvConf(contents).filter { resolver in
            guard !excluded.contains(resolver) else { return false }
            return !resolver.hasPrefix("127.") && resolver != "::1"
        }
    }
}
