import Foundation

// SwiftPM's generated accessor looks beside the executable bundle. Packaged
// macOS apps keep their resource bundle in Contents/Resources instead.
enum DevStackResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("DevStack_DevStackApp.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        if Bundle.main.bundleURL.pathExtension == "app" {
            fatalError("DevStack resource bundle is missing from Contents/Resources.")
        }
        return Bundle.module
    }()
}
