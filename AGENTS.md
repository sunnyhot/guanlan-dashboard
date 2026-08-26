# AGENTS.md — 且慢主理人看板 (qieman-manager-dashboard)

## 项目概览

macOS / iOS 原生 SwiftUI 应用 + Swift CLI，管理且慢（Qieman）投资平台数据。
- 本地 dashboard 展示基金持仓、净值走势、社区动态
- Swift 原生客户端抓取且慢平台数据，SwiftUI 前端渲染
- 支持 App 内手工维护持仓、自动更新、菜单栏小组件
- 支持今日简报、主理人动态摘要、数据新鲜度、基金详情抽屉
- 支持持仓分析：组合诊断、基金对比、收益归因、基金穿透（look-through）
- 支持平台分析：主理人策略雷达、交易时间总览、平台持仓概览
- 支持 alfa 投顾组合调仓与持仓（晓磊「基金全磊打」等），平台板块「长赢调仓/投顾组合」切换，多组合汇总展示 + chip 筛选 + 当前持仓（目标配置占比）+ 组合目录选择/手动添加
- 支持 AI 投资研判（Investment Intelligence V2，Epic 12 起唯一链路）：Portfolio Research Workflow（Research→Thesis→Signals→Decision）、Market Discovery（本地因子先筛+选择性研究）、Intraday 执行决策（D001：Δw 唯一来源 planner provenance）、Presentation 层（Narrator 只解释不重决 + ArtifactQueryService 统一读面）。旧三条 AI 链路（TrendResearch/NextHourGuidance/TrendTracking）与 V1 Slice 0-7 已于 2026-08-26 删除
- 中国股市惯例：红色涨、绿色跌

**技术栈**: SwiftUI + AppKit/UIKit + Foundation (macOS 14+ / iOS) | SPM 测试/校验 + swiftc 打包
**数据通道**: Swift 原生 API 直连；Agent 技能统一调用原生 `qieman-cli`
**当前发布版本**: v4.4.0（GitHub Release + `releases/macos/latest.json`）

> 规模提示：下文行数/文件数为 2026-08-05 核对值。项目仍在快速演进，做大改动前建议先用 `find macos-app -name "*.swift" -not -path "*/.build/*" | wc -l` 复核，不要直接采信本文档数字。

## 目录结构与行数

### 原生命令行
| 文件/目录 | 职责 |
|---|---|
| `macos-app/CLI/main.swift` | `qieman-cli` 入口 |
| `macos-app/Core/QiemanCommandLine.swift` | 命令路由、JSON 契约与增量巡检 |
| `scripts/build_qieman_cli.sh` | 构建原生 CLI |
| `scripts/qieman` | CLI 启动器 |

### macos-app/ — SwiftUI 原生 App（约 297 个 Swift 文件，约 76688 行，2026-08-05 核对）

> 双端结构：macOS 视图在 `Views_macOS/`，iOS 视图在 `Views_iOS/`；核心逻辑在 `Core/` 两端共用。`QiemanDashboardApp_iOS.swift` 是 whole-file `#if os(iOS)`，SPM 构建时编译为空。

#### 入口与配置
| 文件 | 行数 | 职责 |
|---|---|---|
| `macos-app/main.swift` | ~40 | **双模式入口（AGENT-2）**：默认 GUI（`QiemanDashboardApp.main()`）；`--agent <command>` 或已知 agent 子命令在 SwiftUI 起跑前分流到 `InvestmentAgentCLI` 并退出（普通 Finder/-psn 启动不命中命令集） |
| `QiemanDashboardApp.swift` | 866 | macOS App（**@main 已移至 main.swift，勿加回**——加回会与 main.swift 顶层代码冲突） |
| `QiemanDashboardApp_iOS.swift` | 95 | iOS 入口（`#if os(iOS)`，SPM 排除；iOS Xcode target 不含 main.swift） |
| `Package.swift` | 24 | SPM 配置（仅 macOS target，排除 Views_iOS/CLI/Tests） |

#### Core/ 核心逻辑（约 137 个 Swift 文件，约 36176 行）
| 文件 | 行数 | 职责 |
|---|---|---|
| `Core/Models/` | 2660 (14 文件) | 数据模型：基金、持仓、净值、交易记录等。按域拆为 AppEnums/PersonalAssetEnums/Query/ManagerWatchSettings/SnapshotPayloads/PlatformPayloads/PersonalAsset/UserPortfolio/PersonalTrade/PersonalPlan/PersonalWatchlist/AlfaPortfolioCatalogItem/AlfaHoldingPart/PortfolioValuationAlert |
| `Core/QiemanPlatformNativeClient.swift` | 1789 | 且慢平台原生客户端（最大 API 客户端，大类保留，仅 actor 和 Array/String private extension 内聚） |
| `Core/QiemanNativeClient.swift` | 648 | 且慢原生 API 客户端 |
| `Core/Platform/` | 224 (3 文件) | 外移平台层：NativePlatformError / PlatformActionAssetBuckets / NativePlatformDTOs（注：原列的 QiemanPlatformCache 已不在该目录） |
| `Core/QiemanRequestSigning.swift` | 40 | 共享请求签名工具：`x-sign`（SHA256 时间戳）/ `x-request-id`，三个客户端共用，消除既有重复 |
| `Core/Alfa/QiemanAlfaClient.swift` | 559 | 且慢 alfa 投顾线客户端（GraphQL `POST /alfa/v1/graphql` + 动态签名 + groups/parts 拍平映射 + 缓存） |
| `Core/AlfaPortfolioStore.swift` | 39 | 投顾组合列表持久化（纯函数 load/save，默认预置晓磊 SI000192） |
| `Core/FundLookThrough.swift` | 944 | **基金穿透计算**：披露抓取/缓存、底层证券、行业暴露、资产类别暴露、覆盖率、陈旧披露警告。返回 `PortfolioLookThroughSnapshot` |
| `Core/AppModel.swift` | 714 | **核心状态容器**：@MainActor ObservableObject |
| `Core/AppModel/` | — | AppModel 子功能拆分。最大几块：ManagerWatch / PortfolioCRUD / PersonalWatchlistActions / AssetAggregation / Validation / Alfa / InvestmentPlan / PortfolioRefresh / ComputedProperties / Auth / Automation / PendingTrade 等（旧 TrendAnalysis/NextHourGuidanceController/TrendTracking/InvestmentIntelligence* 已随链路下线删除）。完整清单见目录 |
| `Core/CLI/` | 369+ (3 文件) | Contract(74, snake_case encoder/decoder、NullDouble 包装) + DTOs(295, 命令输出 DTO) + **InvestmentAgentCLI（AGENT-2：investment-agent 无 GUI CLI，V3.1 §97 命令面；凭据走环境变量、数据目录 `--data-dir` 与 App 共库）** |
| `Core/QiemanCommandLine.swift` | （在 Core/ 下） | 命令路由、JSON 契约与增量巡检（注：CLI 逻辑文件在 Core/ 顶层，非 Core/CLI/ 子目录） |
| `Core/Clients/` | — | 外部数据源 + LLM API 客户端（通用基础设施，V2 Research/Provider 层复用）：AlphaVantageClient / SECOfficialSourceClient / TavilySearchClient / OpenAICompatibleAgentClient + **WF-4 迁入的契约层**（AgentClientContract.swift：AgentChatMessage/AgentToolCall 等协议形状；AIAgentDiagnosticLog.swift：诊断日志；DataSourceSettings.swift：TrendAIProvider/Tavily/SEC/AlphaVantage 配置值类型——原属旧链路，删除时随消费方救回归位）。`Core/TrendResearch/` 与 `Core/Trend/` 目录已删除 |
| `Core/NativeSnapshotStore.swift` | 246 | 数据快照持久化（注：是规范化 Snapshot DTO 的文件 Store，**不是数据库**，不涉及 SQLite） |
| `Core/UserPortfolioStore.swift` | 351 | 用户持仓存储 |
| `Core/InvestmentPlansStore.swift` | 184 | 投资计划存储 |
| `Core/PendingTradesStore.swift` | 181 | 待处理交易存储 |
| `Core/PersonalAssetAutomation.swift` | 444 | 个人资产自动化 |
| `Core/PersonalAssetSorting.swift` | 88 | 资产排序 |
| `Core/ManagerWatchStore.swift` | 23 | 主理人关注存储 |
| `Core/LocalNotificationManager.swift` | 69 | 本地通知 |
| `Core/LaunchAtLoginAgent.swift` | 57 | 开机自启 LaunchAgent fallback |
| `Core/TodayBrief.swift` | 319 | 今日简报：待确认、计划、涨跌、动态入口 |
| `Core/PersonalAssetDetailSummary.swift` | 240 | 基金详情抽屉摘要 |
| `Core/PortfolioDiagnostics.swift` | 228 | 组合诊断：集中度、待确认、计划、波动、估值覆盖 |
| `Core/PersonalAssetComparison.swift` | 113 | 基金对比摘要 |
| `Core/ProfitAttribution.swift` | 145 | 收益归因 |
| `Core/StrategyRadar.swift` | 173 | 主理人策略雷达 |
| `Core/AppSelfUpdater.swift` | 359 | App 自动更新（GitHub Release） |
| `Core/AppUpdateChecker.swift` | 231 | 更新检查 |
| `Core/MenuBarTicker/` | 1346 (6 文件) | 菜单栏小组件：MenuBarTickerEntries/Kind/Settings/Types + MenuBarPortfolioRefreshDecision + PortfolioMenuBarTitle |
| `Core/ApplicationDataController.swift` | （在 Core/ 下） | 本地数据目录与 Cookie 路径管理 |

> 已删除文件（曾出现在旧版本文档，现已不存在，勿再引用）：`Core/AppModel/DataDirectory.swift`、`Core/QiemanCookieManager.swift`、`Core/DashboardInsight.swift`、`Views/QiemanLoginView.swift`、`Views/SettingsAccountPanel.swift`。Cookie/登录态管理已重构，搜索全仓库确认无 `QiemanCookieManager` 类型。

#### AI 研判子系统（`InvestmentIntelligenceV2/`，Epic 12 起唯一链路）
| 文件/目录 | 职责 |
|---|---|
| `InvestmentIntelligenceV2/Workflows/` | WF-1..3：PortfolioResearchWorkflow（Research→Thesis→Signals→Decision 全链，DecisionValidator 落库前强制门禁）/ MarketDiscoveryWorkflow（universe 策展 v1 + 本地因子打分 + top-K 选择性研究，替代固定八组 Tavily 盲扫）/ IntradayWorkflow（Signal+Eligibility+执行决策，非 LLM 猜仓位，validity=tradingSession）；含 ThesisStore / ResearchEvidencePersister |
| `InvestmentIntelligenceV2/Research/` | RES-1..9：ModelGateway / ResearchHarness（多轮 Tool Calling）/ 工具集 / SignalExtraction / Validation 管道 / SignalStore / EvidenceMatcher / StructuredGeneration |
| `InvestmentIntelligenceV2/Presentation/` | PRES-1：DecisionNarrator（只解释不重决）/ ResearchNarrator / ArtifactQueryService（UI 唯一读面）。产品展示层（2026-08-26 重构）：`InvestmentIntelligenceDashboardSnapshot`（双端共用 DTO，状态全 enum）+ `DashboardProjector.dashboardSnapshot`（聚合入口；盘中/决策报告按 target ID 可解析性过滤，旧自复制 Target 产物只留历史审计）+ `IntelligencePresentationFormatter`（稳定文案 + `IntelligenceUserFacingError` 七类错误映射与恢复动作） |
| `InvestmentIntelligenceV2/Decision/` | DEC-*：criterion 求值比较 / TargetRebalancePlanner（Δw 唯一来源，D001）/ ConstraintGate / PortfolioDecisionArtifact + DecisionValidator + Replayer |
| `InvestmentIntelligenceV2/Persistence/`（user-intent） | 用户意图文件事实源（2026-08-26 产品重构 P0，不进 SQLite、删库重放不丢）：`StrategicAllocationTargetStore`（战略目标 append-only 事件 + current 指针原子推进；五类完备写入门禁 `validateCompleteCoverage`，同 ID 异内容/伪 ID fail-closed）与 `StrategicAssetClassAssignmentStore`（持仓资产分类事件；用户桶恒优先于系统识别）。Target/分类只从用户动作产生（D000），LLM/Signal 无构造通道 |
| `Core/Clients/` | 数据源 + LLM 传输层（契约层与诊断日志在 WF-4 迁入归位） |

> 旧三条 AI 链路（`Core/TrendResearch/` + `Core/Trend/` + `Core/NextHourGuidance*`）与 V1 Slice 0-7（`Core/InvestmentIntelligence/`）已于 2026-08-26（WF-4+WF-5）全部删除；`FundLookThrough.swift` 刻意保留（双端穿透 UI 在用，切换 V2 计算器属后续 UI 迁移）。

#### Views_macOS/ 视图（54 文件，19722 行）
| 文件/目录 | 行数 | 职责 |
|---|---|---|
| `Views_macOS/Overview/` | — | 总览：OverviewSectionView / TodayBriefPanel（AITrendSummaryPanel 已随旧链路删除） |
| `Views_macOS/Platform/` | 1982 (9 文件) | 平台子视图：ForumRows / PlatformActionRow / StrategyRadarPanel / PlatformActionDetailCard / HoldingCard / PlatformHoldingsPieChart / PlatformMonthlyOverview / AlfaPlatformPanel / AlfaHoldingCard |
| `Views_macOS/PortfolioSectionView.swift` | 874 | 持仓首页、组合诊断、收益归因 |
| `Views_macOS/PersonalAssetBrowser.swift` | 762 | 个人资产浏览器、搜索/筛选/排序/基金对比 |
| `Views_macOS/MenuBarPortfolioView.swift` | 701 | 菜单栏持仓小组件 |
| `Views_macOS/SettingsMenuBarPanel.swift` | 857 | 菜单栏设置面板 |
| `Views_macOS/PersonalAssetCards.swift` | 680 | 资产卡片组件 |
| `Views_macOS/ContentView.swift` | 590 | 主内容视图 |
| `Views_macOS/PlatformSectionView.swift` | 458 | 平台板块 |
| `Views_macOS/SettingsWatchPanel.swift` | 433 | 关注设置面板 |
| `Views_macOS/SettingsSectionView.swift` | 410 | 设置主视图 |
| `Views_macOS/SharedComponents.swift` | 1089 | 通用 UI 组件 |
| `Views_macOS/SettingsComponents.swift` | 322 | 设置通用组件 |
| `Views_macOS/SettingsAppPanel.swift` | 223 | 应用设置面板 |
| `Views_macOS/ForumComponents.swift` | 262 | 论坛组件 |
| `Views_macOS/ForumSectionView.swift` | 252 | 论坛板块 |

#### Views_iOS/ 视图（31 文件，6794 行）— iOS 端，SPM 排除、Xcode 工程管理
| 说明 |
|---|
| 与 macOS 对应的轻量页：ContentView / OverviewSectionView / PortfolioSectionView / PlatformSectionView / EnhancementSectionView / 各类 IOS*Sheet/Panel/View（持仓详情、组合诊断、穿透、收益归因、平台动作、论坛等）。新增 macOS UI 时通常需同步补 iOS 对应页，避免双端体验割裂。 |

#### 其他
| 文件 | 行数 | 职责 |
|---|---|---|
| `Design/AppPalette.swift` | 471 | 设计系统：颜色/字体/间距（红涨绿跌在此） |
| `Support/ValueFormatting.swift` | 88 | 数值格式化工具 |
| `Support/KeychainHelper.swift` | 104 | Keychain 封装 |
| `Support/PlatformBridge.swift` | 70 | 平台桥接 |
| `Support/QRCodeHelper.swift` | 54 | 二维码工具 |
| `Tests/` | — | XCTest：更新、窗口、排序、简报、诊断、收益归因、策略雷达、InvestmentIntelligenceV2 全套（Research/Decision/Workflows/Presentation）、alfa 客顾客户端、FundLookThrough、CLI 契约快照等（旧链路约 50 个测试文件已随 WF-4/5 删除）。以 `swift test` 全绿为基线 |

### scripts/（435 行，6 文件）
| 文件 | 行数 | 职责 |
|---|---|---|
| `scripts/build_macos_app.sh` | 180 | Swift 编译构建脚本 |
| `scripts/build_qieman_cli.sh` | 51 | 构建原生 CLI（显式列举源文件，见坑点 6） |
| `scripts/render_macos_icon.swift` | 109 | App 图标生成 |
| `scripts/release_manifest.swift` | 57 | Release 清单生成 |
| `scripts/release_notes.swift` | 27 | Release notes 生成 |
| `scripts/qieman` | 11 | CLI 启动器 |

### releases/
| 文件 | 职责 |
|---|---|
| `releases/macos/latest.json` | 自动更新元数据（版本号、下载 URL） |

### skills/
Agent 技能层（qieman-manager-dashboard、qieman-alpha-signals、project-map）

## 构建与运行命令

```bash
# 构建 macOS App
APP_VERSION=3.16.2 bash scripts/build_macos_app.sh  # → dist/macos-app/QiemanDashboard.app

# 运行
open dist/macos-app/QiemanDashboard.app

# 构建/运行原生 CLI
bash scripts/build_qieman_cli.sh
scripts/qieman version

# 运行测试
swift test  # 在 macos-app/ 目录下
```

**构建要求**: macOS 14+, Xcode CLI Tools

## 架构与数据流

```
QiemanDashboardApp (@main, macOS / iOS 双端)
  └─ AppModel (@MainActor ObservableObject, @EnvironmentObject)
       ├─ ApplicationDataController (本地数据目录)
       ├─ QiemanNativeClient (且慢 API 直连, 主路径)
       ├─ QiemanPlatformNativeClient (平台 API)
       ├─ QiemanAlfaClient (alfa 投顾线 GraphQL)
       ├─ Views_macOS/ + Views_iOS/ (双端视图, Core 共用)
       │    ├─ ContentView → Overview/Portfolio/Platform/Forum/Settings 五板块
       │    ├─ OverviewSectionView (总览、今日简报、主理人摘要、AI 趋势摘要)
       │    ├─ PortfolioSectionView (持仓分析、组合诊断、收益归因)
       │    ├─ PersonalAssetBrowser (资产浏览器、基金对比)
       │    ├─ PlatformSectionView (平台调仓、策略雷达、alfa 投顾)
       │    └─ SettingsSectionView (设置面板)
       ├─ Insight Cores (TodayBrief / PortfolioDiagnostics / ProfitAttribution / StrategyRadar / FundLookThrough)
       ├─ MenuBarTicker (菜单栏小组件)
       └─ Stores (持仓/计划/交易/关注/快照/趋势报告/跟踪项, 各独立 JSON Store)
```

**数据通道**: App 和 CLI 复用 `QiemanNativeClient` / `QiemanPlatformNativeClient` / `QiemanAlfaClient`，直接访问且慢与行情源。

## 关键约定

1. **@MainActor + ObservableObject** — AppModel 是单一状态容器，所有 View 通过 @EnvironmentObject 访问
2. **中国股市惯例** — 红涨绿跌，所有涨跌颜色用 AppPalette 统一
3. **纯 Swift 运行时** — App、爬取能力、CLI 和 Agent 技能不依赖 Python 或 localhost HTTP 服务
4. **Cookie 认证** — 且慢登录态保存在本地受权限保护的 `qieman.cookie` 文件；`Support/KeychainHelper.swift` 提供 Keychain 封装（注：旧文档提及的 `QiemanCookieManager.swift` 已不存在，登录态管理已重构，改动前先搜全仓库确认现状）
5. **自动更新** — GitHub Release + latest.json，AppSelfUpdater 处理下载安装
6. **数据持久化** — 现有 App 数据仍为纯 JSON 文件 + 各独立 Store 类管理（高频追加对象用「一对象一文件 + index 摘要」而非单大 JSON 数组；`NativeSnapshotStore` 是 Snapshot DTO 的文件 Store）。**Investment Intelligence V2 的 Canonical Store 使用 GRDB/SQLite（Epic 5，2026-08-24 GRDB-2..6/9 全域落地；schema 六版：Identity 7 表 / Market 3 表 / Fund 3 表 / Fundamental+Macro 2 表 / Intelligence 10 表）**：依赖声明在 `macos-app/Package.swift` 与 `project.yml`（GRDB ≥ 6.29，`Package.resolved` 锁版本；macOS/iOS 双端 xcodebuild 构建通过，GRDB 静态链入 + 系统 libsqlite3）；DB lifecycle/迁移框架在 `InvestmentIntelligenceV2/Persistence/CanonicalDatabase.swift`（**迁移只追加不改写**，`schemaVersion` 与迁移清单数量一致性有测试守护），各域 schema + 行编解码在 `Persistence/{Identity,Market,Fund,FundamentalMacro,Intelligence}Schema.swift`，列编解码约定在 `Persistence/CanonicalColumnCodec.swift`（时间戳 ISO8601 UTC 毫秒 TEXT、字典序=时间序可 SQL 直接比较；Decimal 走 TEXT；枚举列 fail-closed 解码不回落默认值）。库文件落 App 数据目录 `investment-intelligence-v2/canonical.sqlite3`（与 remote-staging spool 同住 V2 工作目录——spool 是事实源、库是派生物，删库重放走 spool，ADR-DATA004），目录规划与生产库打开入口在 `Persistence/CanonicalStorePaths.swift`。V2 以外的存储仍是 JSON Store，**不要**在 V2 之外新引 SQLite。注意：GRDB 的 `SQL` 类型是 ExpressibleByStringInterpolation，会污染同模块内无类型标注的字符串闭包推断（见坑点 17）
7. **AppModel 拆分** — 核心状态在 AppModel.swift，子功能拆到 AppModel/ 子目录
8. **分析模块纯派生** — 今日简报、组合诊断、收益归因、策略雷达优先基于本地已聚合数据计算，不在 View 内写业务计算
9. **AI 行动跟踪单一路径** — 今日研判行动候选由用户主动加入跟踪清单；旧 TradeSignal 设置/通知链已删除
10. **Release notes** — GitHub Actions 从 tag 间 commit 标题生成更新内容；面向用户的提交标题要清晰、可读
11. **V2 决策 artifact 写库前必须过 DecisionValidator** — `PortfolioDecisionArtifact` 经 `assemble` 产出后、`ArtifactRow.write` 落库前，接线方必须先 `DecisionValidator().validate(artifact:resolvers:)`（DEC-9 接线/Epic 9 时执行；当前 validator 只有测试调用点——不闭环它就是死代码，损坏决策会直接落库）。同理 `DecisionReplayer`/`replayWhatIf` 的 resolver 材料属外部数据，入口全部 fail-closed 抛错、不得崩进程

## 已知坑点

1. **OverviewSectionView.swift 等总览视图拆分** — 已按子视图拆到 `Views_macOS/Overview/`（OverviewSectionView/TodayBriefPanel；AITrendSummaryPanel 与 TrendDashboardSummaryTests 已随旧链路删除）
2. **PlatformComponents.swift 已拆分** — 平台行、详情、月度概览、策略雷达、持仓卡、饼图分别落到 `Views_macOS/Platform/` 9 文件
3. **QiemanPlatformNativeClient.swift (1789 行) 大类保留** — 只有 7 个 public 方法，~50 个 private helper 互相紧耦合，未拆 extension；外围的 DTO/Error/AssetBuckets 已外移到 `Core/Platform/`（3 文件），大类内部 private/fileprivate 维持原封装
4. **Models.swift 已按域拆分** — 14 文件落到 `Core/Models/`，自定义 CodingKeys 跟随所属 struct
5. **CLI JSON 契约已 DTO 化** — 19 个命令输出走 `Core/CLI/DTOs.swift` 的 Codable DTO，由 `QiemanCLI.encoder`（`convertToSnakeCase`）统一序列化；契约快照测试在 `CLIContractSnapshotTests.swift`，新增/改字段需补快照。`run()` 返回 `Data`，`main.swift` 直接写 stdout
6. **build_qieman_cli.sh 显式列举源文件** — 拆分/新增 CLI 相关文件必须同步更新该列表，否则 CLI 二进制构建失败（SPM 自动发现，但 swiftc 不行）
7. **updates-watch 状态文件用字面 snake_case CodingKeys** — `CLIWatchState` 的磁盘格式不走 `convertToSnakeCase`，避免迁移期键名漂移
8. **CLI 契约 null-vs-zero 语义** — `valuation` 命令的 `current_valuation`/`change_pct` 用 `NullDouble` 包装，nil 输出 `null`（不是 0 也不是缺键）；改动时务必同步 `CLIContractSnapshotTests.testNullDoublePreservesNullVsZero`
9. **且慢 API 非公开** — 随时可能变更需维护
10. **alfa GraphQL query 必须完整原版** — `QiemanAlfaClient.adjustmentQuery` 是 HAR 抓包的字节级原文，服务端做 query 完整性校验：精简字段（即使删除 `preferences`/`dicts` 等 `@include(if:false)` 不会查询的片段）会被 `GRAPHQL_VALIDATION_FAILED` 拒绝。改 query 字段前务必先用真实请求验证
11. **alfa 签名纯时间戳驱动** — `x-sign = ts + SHA256(floor(1.01*ts))[:32]`，不绑定请求体/路径，无需登录态；`x-request-id` 前缀按客户端区分（社区/长赢用 `albus.`，alfa 用 `zeus.`）。统一在 `QiemanRequestSigning`
12. **alfa 调仓是百分比语义 + 多组合汇总** — 投顾组合（如晓磊 SI000192）调仓按持仓比例（`beforePercent`/`afterPercent`），与长赢的份数（`tradeUnit`）不同。拍平映射在 `QiemanAlfaClient.flattenAdjustments`，side 由 before/after 推导；`PlatformActionPayload.isPercentBased` 控制 UI 分支渲染。面板默认并发抓取所有已添加组合调仓并合并（`fetchAllAlfaPayloads`），按 `sourcePoCode` 字段 chip 筛选；`PlatformActionRow.titlePrefix` 注入来源组合名前缀。**alfa 持仓不能从调仓反推**（无份数/净值），需单独调 `PoFundComposition` GraphQL query（`fetchAlfaComposition`），返回百分比口径的 `AlfaHoldingPart`（占比+净值+日涨跌），UI 用 `AlfaHoldingCard`（非长赢的 `HoldingCard`）
13. **雪球（望京博格/螺丝钉）不可行** — 阿里云 WAF JS 挑战，纯原生客户端无法执行 JS 获取 token，所有 API 返回 400016/403。本项目架构上不接入雪球
14. **社区动态筛选面板已移除** — 原 filterMode（主理人订阅/精确参数）双模式切换及配套的 awesome-list 抓取基础设施（fetchManagerIndex/fetchMultiGroupSnapshot/ManagerSummary）已全部删除。论坛/平台板块不再有筛选 UI，论坛默认抓长赢同路人（prodCode=LONG_WIN → groupId 43），由 `QueryFormState` 默认值驱动，展示串「长赢指数投资计划主理人·长赢同路人」由数据动态拼出
15. **旧 AI 链路与 V1 已删除（2026-08-26，WF-4+WF-5）** — `Core/TrendResearch/`、`Core/Trend/`、`Core/NextHourGuidance*`、`Core/InvestmentIntelligence/`（V1 Slice 0-7）、「AI研判」板块（AppSection.enhancement）已全部删除。`Core/Clients/` 里的 AgentClientContract / AIAgentDiagnosticLog / DataSourceSettings / TrendWebSearchAvailabilityBlockReason 是删除时从旧链路救回的公共契约层（消费方仍在），勿再引用已删类型；`FundLookThrough.swift` 刻意保留（双端穿透 UI 在用）。同步档案不再传输 AI 配置（Keychain 本机管理）。
16. **build_macos_app.sh 走 SPM 构建** — Epic 5 引入 GRDB 后脚本已从裸 swiftc 改为 `swift build -c release` + 拷贝产物进 .app（源文件排除规则/最低系统版本以 `macos-app/Package.swift` 为单一事实源）。**新增 App 源文件不再需要动脚本**（SPM 自动发现）；但新增 SPM 外部依赖必须同步 `Package.swift` + `project.yml`（packages + 各 target dependencies，product 名为 GRDB 非 GRDB.swift）并 `xcodegen generate` 重生成工程
17. **GRDB `SQL` 类型污染类型推断** — GRDB 的 `SQL` 遵循 ExpressibleByStringInterpolation，同模块内无显式类型的字符串字面量闭包链（`map { "\(x)" }.joined(separator:)`）可能被推断成 `SQL`（GRDB 给 Sequence 加了 `joined(separator:)` 的 SQL 版扩展）。遇到莫名的 "cannot convert 'SQL' to 'String'" 时给变量显式标注 `: String`（先例：TrendLiveLogPanel.copyLogs）
18. **GRDB 迁移只追加不改写** — `CanonicalDatabase.makeMigrations()` 已发布的 migration id 永不改名/删除/重排（老库按 id 记账，改写 = 全量重跑破坏数据）；新增表只追加新 migration 并同步 `schemaVersion`（有测试守护两侧一致）
19. **macOS 入口是 main.swift 双模式（AGENT-2）** — `@main` 已从 `QiemanDashboardApp` 移到 `macos-app/main.swift`（GUI 默认 + `--agent` 分流）；**不要给 QiemanDashboardApp 加回 `@main`**（与 main.swift 顶层代码冲突编译失败）。iOS Xcode target 不含 main.swift（其入口仍是 `QiemanDashboardApp_iOS.swift` 的 `@main`）。investment-agent 的实现/凭据/数据目录约定见 `Core/CLI/InvestmentAgentCLI.swift` 文件头（凭据只走环境变量；副作用命令必须经 `WorkflowRegistry` 提交，不得绕过作业纪律）
20. **InvestmentIntelligenceV2 暂不抽独立 package** — 决策记录 `docs/adr/PKG001`（按实测依赖形状评估：V2 依赖 Core/Clients、Core/Clients 同时被 App 非 V2 路径消费）；边界靠目录 + review + 测试维持，V2 内不得引用 SwiftUI/AppKit/AppModel

## Agent 工作指南

- 修改 UI 时注意涨跌颜色用 AppPalette（红涨绿跌）
- CLI 命令修改：DTO 在 `Core/CLI/DTOs.swift`，路由/handler 在 `Core/QiemanCommandLine.swift`；新增命令需同步：① 加 DTO（或复用现有，如 `alfa-actions` 复用 `CLIPlatformActionsOutput`）② 加 case + handler ③ 加 `CLIContractSnapshotTests` 快照 ④ 若新增 Swift 文件需更新 `scripts/build_qieman_cli.sh`
- alfa 投顾组合：客户端在 `Core/Alfa/QiemanAlfaClient.swift`，AppModel 逻辑在 `Core/AppModel/Alfa.swift`，UI 在 `Views_macOS/Platform/AlfaPlatformPanel.swift`（iOS 对应 `Views_iOS/IOSAlfaPlatformPanel.swift`）；组合持久化在 `alfa-portfolios.json`
- Swift App 入口在 `macos-app/main.swift`（双模式：GUI / `--agent` CLI，见坑点 19；App 结构体本体在 `QiemanDashboardApp.swift`）
- investment-agent CLI（AGENT-2）：命令实现全在 `Core/CLI/InvestmentAgentCLI.swift`（SPM + Xcode macOS target 自动编入，**不在 build_qieman_cli.sh 的显式列表里**——那是 qieman-cli 的）；启动器 `scripts/investment-agent`；测试 `InvestmentAgentCLITests`（run(arguments:) 可测入口）
- AppModel 是全局状态中心，拆分子文件在 `macos-app/Core/AppModel/`
- 构建必须指定版本号：`APP_VERSION=x.y.z bash scripts/build_macos_app.sh`
- 发布流程：提交功能代码 → 打 tag（如 `v3.16.3`）→ 推送 `main` 和 tag → GitHub Actions 构建 zip、创建 Release、回写 `releases/macos/latest.json`
- 发布后本地执行 `git pull --ff-only`，拉回 Actions 自动提交的 `release: update vX.Y.Z`
- 新增功能优先补 XCTest；当前基线以 `swift test` 全绿为准
- 新增持仓分析能力优先放 Core 纯计算模型，再由 SwiftUI 面板展示
- 不要把 `.claude/`、`.agents/`、本地统计日志等个人工作区文件提交进项目
- 参考 `PROJECT_MAP.md` 获取更详细的架构说明
- AI 投资研判统一走 `InvestmentIntelligenceV2/`（Epic 12 后唯一链路）；决策 artifact 落库前必须过 DecisionValidator（关键约定 11）；UI 读 V2 产出只经 `ArtifactQueryService`
