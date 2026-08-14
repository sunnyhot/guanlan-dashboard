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
            // InvestmentIntelligenceV2/Collector/ is the optional out-of-process
            // Python AKShare collector (ADR-DATA007 / PROV-3a): it ships as a
            // standalone script for advanced users and is excluded from the App
            // bundle and every target.
            exclude: ["Package.swift", "Tests", "CLI", "Views_iOS", "InvestmentIntelligenceV2/Collector"]
        ),
        .testTarget(
            name: "QiemanDashboardTests",
            dependencies: ["QiemanDashboard"],
            path: "Tests/QiemanDashboardTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
