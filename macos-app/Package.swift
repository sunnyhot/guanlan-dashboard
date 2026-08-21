// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QiemanDashboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Epic 5（GRDB-1）引入：Canonical Store 的 SQLite 层。FREE001 合规：
        // GRDB 是 MIT 开源、零服务费用；此前的「无 SQLite」约定（AGENTS.md 第 6
        // 条）已随 Epic 5 更新。ADR-DATA009：M2 已 Pass（2026-08-21），允许冻结
        // schema 进入持久化阶段。
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "QiemanDashboard",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
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
