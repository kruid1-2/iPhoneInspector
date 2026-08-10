// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "iPhoneInspector",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "iPhoneInspector", targets: ["iPhoneMonitor"])
    ],
    targets: [
        .target(
            name: "iPhoneMonitorCore",
            path: "Sources/iPhoneMonitorCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "iPhoneMonitor",
            dependencies: ["iPhoneMonitorCore"],
            path: "Sources/iPhoneMonitor",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "iPhoneMonitorCoreTests",
            dependencies: ["iPhoneMonitorCore"],
            path: "Tests/iPhoneMonitorCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
