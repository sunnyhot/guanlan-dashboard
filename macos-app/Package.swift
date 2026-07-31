// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QiemanDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QiemanDashboard",
            path: ".",
            // SPM serves the macOS build only. Views_iOS/ holds the iOS target's
            // UI (managed by the Xcode project), and QiemanDashboardApp_iOS.swift
            // is whole-file `#if os(iOS)` so it compiles to nothing here. We still
            // exclude Views_iOS/ to avoid same-filename source collisions.
            exclude: ["Package.swift", "Tests", "CLI", "Views_iOS"]
        ),
        .testTarget(
            name: "QiemanDashboardTests",
            dependencies: ["QiemanDashboard"],
            path: "Tests/QiemanDashboardTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
