// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DevStack",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "DevStackCore", targets: ["DevStackCore"]),
        .executable(name: "DevStack", targets: ["DevStackApp"]),
        .executable(name: "DevStackPrivilegedHelper", targets: ["DevStackPrivilegedHelper"]),
        .executable(name: "DevStackRuntimePackager", targets: ["DevStackRuntimePackager"]),
        .executable(name: "DevStackCoreChecks", targets: ["DevStackCoreChecks"])
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
            dependencies: ["DevStackCore"],
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
        .executableTarget(
            name: "DevStackCoreChecks",
            dependencies: ["DevStackCore"]
        )
    ]
)
