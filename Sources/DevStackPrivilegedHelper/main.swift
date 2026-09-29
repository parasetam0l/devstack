import Foundation

@main
enum DevStackPrivilegedHelperMain {
    static func main() {
        FileHandle.standardError.write(Data("DevStack privileged helper is not intended to be launched directly.\n".utf8))
    }
}

