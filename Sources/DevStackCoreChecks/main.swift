import DevStackCore
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

@main
enum DevStackCoreChecks {
    static func main() throws {
        try expect(
            HostnameValidator.validate(" Example.TEST. ") == "example.test",
            "Hostname normalization failed"
        )
        try expect(
            HostnameValidator.shadowsPublicDomain("example.com"),
            "Public domain warning was not detected"
        )
        try expect(
            !HostnameValidator.shadowsPublicDomain("example.test"),
            "Reserved .test domain was incorrectly flagged"
        )
        print("DevStackCoreChecks: all checks passed")
    }
}
