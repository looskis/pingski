// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pingski",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "pingski",
            path: "Sources/pingski",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "pingskiTests",
            dependencies: ["pingski"],
            path: "Tests/pingskiTests"
        ),
    ]
)
