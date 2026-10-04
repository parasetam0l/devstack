// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DevStack",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DevStackCore", targets: ["DevStackCore"]),
        .executable(name: "DevStack", targets: ["DevStackApp"]),
        .executable(name: "DevStackPrivilegedHelper", targets: ["DevStackPrivilegedHelper"]),
        .executable(name: "DevStackRuntimePackager", targets: ["DevStackRuntimePackager"]),
        .executable(name: "DevStackRuntimeChecks", targets: ["DevStackRuntimeChecks"]),
        .executable(name: "DevStackCoreChecks", targets: ["DevStackCoreChecks"])
    ],
    dependencies: [
        // App updates, as in DevStack's sibling apps (SemiVPN, LocalDesktop).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "DevStackCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "DevStackApp",
            dependencies: ["DevStackCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "DevStackPrivilegedHelper",
            dependencies: ["DevStackCore"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "DevStackRuntimePackager",
            dependencies: ["DevStackCore"]
        ),
        .executableTarget(name: "DevStackRuntimeChecks", dependencies: ["DevStackCore"]),
        .executableTarget(
            name: "DevStackCoreChecks",
            dependencies: ["DevStackCore"]
        )
    ]
)
