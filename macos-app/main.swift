#if os(macOS)
import Foundation

// MARK: - 双模式入口（AGENT-2）
//
// 默认 GUI（SwiftUI App）。`--agent <command>`（或直接以已知 agent 子命令
// 启动二进制 / scripts/investment-agent 启动器）在 SwiftUI 启动前分流到
// investment-agent CLI 并退出——「不启动 SwiftUI 能跑 research/sync/
// factor/attribution/decision」。
//
// 普通启动（Finder / open / login item）不会命中 agent 命令集（含历史
// -psn_ 前缀参数），一律走 GUI。

let agentCommands: Set<String> = [
    "data-sync", "health", "identity-inspect", "market-research",
    "portfolio-review", "attribution", "decision-replay",
    "jobs", "resume", "recover", "version",
]

let launchArguments = Array(CommandLine.arguments.dropFirst())
var agentArguments: [String]?
if let index = launchArguments.firstIndex(of: "--agent") {
    agentArguments = Array(launchArguments[(index + 1)...])
} else if let first = launchArguments.first, agentCommands.contains(first) {
    agentArguments = launchArguments
}

if let agentArguments {
    exit(InvestmentAgentCLI.main(arguments: agentArguments))
} else {
    QiemanDashboardApp.main()
}
#endif
