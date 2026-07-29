# PROJECT_MAP — Qieman Manager Dashboard

## Architecture

The project is macOS-only and uses a pure Swift runtime.

```text
QiemanDashboardApp (SwiftUI)
  └─ AppModel (@MainActor)
      ├─ QiemanNativeClient              community/auth/comments
      ├─ QiemanPlatformNativeClient      trades/holdings/NAV/estimates
      ├─ ApplicationDataController       local data directory and Cookie path
      ├─ Stores                          portfolio/plans/trades/snapshots
      └─ Views                           overview/portfolio/platform/forum/workbench/settings

qieman-cli (Swift)
  └─ QiemanCommandLine
      ├─ shares the native clients and models
      └─ emits stable snake_case JSON for Agent skills
```

There is no Python Web dashboard, localhost HTTP service, Python crawler, OCR, image import, or spreadsheet import.

## Important paths

| Path | Responsibility |
|---|---|
| `macos-app/QiemanDashboardApp.swift` | App entry |
| `macos-app/Core/AppModel.swift` | Main state container |
| `macos-app/Core/QiemanNativeClient.swift` | Qieman community native client |
| `macos-app/Core/QiemanPlatformNativeClient.swift` | Platform, quote and valuation native client（HTTP/签名/解析/时间格式化工具层见 QiemanPlatformNativeClientSupport.swift） |
| `macos-app/Core/Platform/` | 外移的平台层类型：NativePlatformError / QiemanPlatformCache / PlatformActionAssetBuckets / NativePlatformDTOs |
| `macos-app/Core/Models/` | 共享领域模型，按域拆 9 个文件（AppEnums / Query / ManagerWatchSettings / SnapshotPayloads / PlatformPayloads / PersonalAsset / UserPortfolio / PersonalTrade / PersonalPlan） |
| `macos-app/Core/CLI/Contract.swift` | CLI 契约基础设施：snake_case encoder/decoder、NullDouble 包装 |
| `macos-app/Core/CLI/DTOs.swift` | 19 个命令的输出 DTO（不复用 App 模型 Codable） |
| `macos-app/Core/QiemanCommandLine.swift` | CLI commands and JSON contracts |
| `macos-app/CLI/main.swift` | CLI process entry |
| `macos-app/Core/ApplicationDataController.swift` | App data directory management |
| `macos-app/Views/Overview/` | 总览子视图（OverviewSectionView / TodayBriefPanel / AITrendSummaryPanel / ManagerWatchControlCard） |
| `macos-app/Views/Platform/` | 平台子视图（ForumRows / PlatformActionRow / StrategyRadarPanel / PlatformActionDetailCard / HoldingCard / PlatformHoldingsPieChart / PlatformMonthlyOverview） |
| `macos-app/Views/` | SwiftUI views |
| `macos-app/Tests/QiemanDashboardTests/` | XCTest suite（含 CLIContractSnapshotTests） |
| `scripts/build_macos_app.sh` | Release-compatible App build |
| `scripts/build_qieman_cli.sh` | Native CLI build（显式列举编译文件，拆分后需同步） |
| `scripts/qieman` | CLI launcher |
| `skills/qieman-alpha-signals/` | Atomic Agent command routing |
| `skills/qieman-manager-dashboard/` | Native App/CLI Agent routing |

## Commands

```bash
cd macos-app && swift test
bash scripts/build_qieman_cli.sh
scripts/qieman version
APP_VERSION=3.10.4 bash scripts/build_macos_app.sh
```

## Contracts

- App persisted JSON remains Codable and backward compatible.
- Agent CLI JSON uses snake_case field names.
- Cookie defaults to `~/Library/Application Support/QiemanDashboard/qieman.cookie` and must never be printed.
- Chinese market colors remain red-up and green-down through `AppPalette`.
