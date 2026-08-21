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
- 支持 AI 投资研判：趋势研究 Agent（多轮 Tool Calling + Evidence Ledger）、下一小时盘中研判、AI 趋势跟踪清单
- 中国股市惯例：红色涨、绿色跌

**技术栈**: SwiftUI + AppKit/UIKit + Foundation (macOS 14+ / iOS) | SPM 测试/校验 + swiftc 打包
**数据通道**: Swift 原生 API 直连；Agent 技能统一调用原生 `qieman-cli`
**当前发布版本**: v3.16.2（GitHub Release + `releases/macos/latest.json`，2026-08 核对）

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
| `QiemanDashboardApp.swift` | 866 | macOS App 入口 @main |
| `QiemanDashboardApp_iOS.swift` | 95 | iOS 入口（`#if os(iOS)`，SPM 排除） |
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
| `Core/NextHourGuidance.swift` | 1398 | 下一小时盘中研判（intraday 决策通道，独立于长期组合决策） |
| `Core/AppModel.swift` | 714 | **核心状态容器**：@MainActor ObservableObject |
| `Core/AppModel/` | 6411 (28 文件) | AppModel 子功能拆分。最大几块：TrendAnalysis(880) / ManagerWatch(657) / PortfolioCRUD(581) / NextHourGuidanceController(534) / PersonalWatchlistActions(386) / AssetAggregation(340) / Validation(432) / Alfa(311) / InvestmentPlan(244) / PortfolioRefresh(225) / ComputedProperties(207) / Auth(200) / TrendTracking(172) / Automation(165) / PendingTrade(153) 等。完整清单见目录 |
| `Core/CLI/` | 369 (2 文件) | Contract(74, snake_case encoder/decoder、NullDouble 包装) + DTOs(295, 命令输出 DTO) |
| `Core/QiemanCommandLine.swift` | （在 Core/ 下） | 命令路由、JSON 契约与增量巡检（注：CLI 逻辑文件在 Core/ 顶层，非 Core/CLI/ 子目录） |
| `Core/Clients/` | 1559 (4 文件) | 外部数据源 + LLM API 客户端（通用基础设施，从 TrendResearch/ 移出归位）：AlphaVantageClient(279，含 quota/cache/budget) / SECOfficialSourceClient(161，SEC EDGAR HTTP) / TavilySearchClient(349，web search) / OpenAICompatibleAgentClient(770，OpenAI 兼容 LLM)。被 TrendResearch 工具、NextHourGuidance、InvestmentIntelligence、V2 Provider 层跨子系统复用 |
| `Core/TrendResearch/` | 8367 (22 文件) | **AI 趋势研究子系统**：TrendResearchAgent(821) 多轮 Tool Calling Harness / TrendResearchToolRegistry(576) / TrendResearchSnapshot(460) / SubmitTrendReportTool / TrendAnalysisValidator / TrendEvidenceLedger（actor，在 TrendResearchTool.swift 内）/ TrendClaimEvidencePolicy(261) / TrendEvidenceMetadata / SEC+AlphaVantage+Tavily \*ResearchTool（调用 `Core/Clients/` 的 client）/ TrendSourceFreshnessPolicy。数据源 client 已移至 `Core/Clients/`。详见下方「AI 研判子系统」 |
| `Core/Trend/` | 3519 (11 文件) | 趋势数据层：TrendAnalysisStore / TrendTrackingModels / TrendTrackingStore / TrendAnalysisValidator / TrendReportModuleTools / TrendSourceStatus 等趋势报告与跟踪持久化和校验 |
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

#### AI 研判子系统（Core/TrendResearch/ + Core/Trend/，共约 12304 行；数据源 client 见 `Core/Clients/`）— 投资智能方案的核心复用基础
| 文件 | 行数 | 职责 |
|---|---|---|
| `TrendResearch/TrendResearchAgent.swift` | 821 | 多轮 Tool Calling 主循环：预算/超时/取消/缓存/搜索熔断/上下文裁剪/校验修复/审计。**强耦合**，通用 Harness 抽取风险高，宜先复制受控子集再反向抽取 |
| `Clients/OpenAICompatibleAgentClient.swift` | 770 | OpenAI 兼容 API 客户端（从 TrendResearch/ 移至 `Core/Clients/`） |
| `TrendResearch/TrendResearchToolRegistry.swift` | 576 | 工具注册表：get_portfolio_overview/assets、get_fund_lookthrough、get_market_snapshot、official_sec_research、alpha_vantage_research、web_search |
| `TrendResearch/TrendResearchSnapshot.swift` | 460 | 运行前数据冻结 + 隐私过滤 + 稳定 Evidence ID + 只读研究 |
| `TrendResearch/TrendResearchTool.swift` | 148 | 工具协议 + **`actor TrendEvidenceLedger`**（独立 actor：record/contains/canonical/allIDs/allEvidence，被 Agent/NextHour/SubmitTool/SEC/AlphaVantage/Lookthrough/Tavily 共用） |
| `TrendResearch/TrendClaimEvidencePolicy.swift` | 261 | Evidence 关联校验、支持/反证/背景区分、不足降级 uncertain、资金动作高证据门槛 |
| `TrendResearch/TrendEvidenceMetadata.swift` | 230 | sourceTier/sourceKind 等元数据 |
| `TrendResearch/SubmitTrendReportTool.swift` | 720 | 报告提交工具 + TrendAnalysisValidator + TrendReportDisposition（数据不足自动清空行动，App 覆盖模型自报时间/来源/Evidence） |
| `TrendResearch/{SEC,AlphaVantage,Tavily}ResearchTool.swift` | — | 外部研究工具（对应 Client 已移至 `Core/Clients/`） |
| `Trend/TrendAnalysisStore.swift` 等 11 文件 | 3519 | 趋势报告持久化、跟踪项模型/存储、报告模块工具、来源状态、新鲜度策略 |

> 复用边界（投资智能改造必读）：可复用 = Harness 循环模式、Tool Registry、Evidence Ledger（登记/溯源/ID 稳定/并发安全）、Snapshot 冻结、Validator、研究工具。**需新建** = 来源独立性/同源去重/时效评分/Claim 级权重/证据冲突/跨运行持久化图谱（即 Evidence Intelligence Engine 的评分与冲突部分）。

#### Views_macOS/ 视图（54 文件，19722 行）
| 文件/目录 | 行数 | 职责 |
|---|---|---|
| `Views_macOS/Overview/` | 806 (3 文件) | 总览：OverviewSectionView / TodayBriefPanel / AITrendSummaryPanel |
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
| 与 macOS 对应的轻量页：ContentView / OverviewSectionView / PortfolioSectionView / PlatformSectionView / EnhancementSectionView / 各类 IOS*Sheet/Panel/View（持仓详情、组合诊断、穿透、收益归因、平台动作、论坛、AI 趋势跟踪等）。新增 macOS UI 时通常需同步补 iOS 对应页，避免双端体验割裂。 |

#### 其他
| 文件 | 行数 | 职责 |
|---|---|---|
| `Design/AppPalette.swift` | 471 | 设计系统：颜色/字体/间距（红涨绿跌在此） |
| `Support/ValueFormatting.swift` | 88 | 数值格式化工具 |
| `Support/KeychainHelper.swift` | 104 | Keychain 封装 |
| `Support/PlatformBridge.swift` | 70 | 平台桥接 |
| `Support/QRCodeHelper.swift` | 54 | 二维码工具 |
| `Tests/` | 12208 (66 文件) | XCTest：更新、窗口、排序、简报、诊断、收益归因、策略雷达、AI 研判（TrendResearchAgent/Validator/Credibility）、alfa 客顾客户端、FundLookThrough、NextHourGuidance、CLI 契约快照等。约 410 个测试方法 |

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
       ├─ AI 研判子系统 (Core/TrendResearch/ + Core/Trend/)
       │    ├─ TrendResearchAgent (多轮 Tool Calling, 长期趋势研究)
       │    ├─ NextHourGuidance (intraday 盘中研判, 独立通道)
       │    ├─ TrendEvidenceLedger (actor, 证据登记/溯源)
       │    └─ TrendTracking (AI 趋势跟踪清单)
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
6. **数据持久化** — 现有 App 数据仍为纯 JSON 文件 + 各独立 Store 类管理（高频追加对象用「一对象一文件 + index 摘要」而非单大 JSON 数组；`NativeSnapshotStore` 是 Snapshot DTO 的文件 Store）。**Investment Intelligence V2 的 Canonical Store 引入 GRDB/SQLite（Epic 5，2026-08-21 GRDB-1 起，M2 已 Pass 后按 ADR-DATA009 解锁）**：依赖声明在 `macos-app/Package.swift` 与 `project.yml`（GRDB ≥ 6.29，`Package.resolved` 锁版本）；DB lifecycle/迁移框架在 `InvestmentIntelligenceV2/Persistence/CanonicalDatabase.swift`（迁移只追加不改写），库文件落 App 数据目录 `investment-intelligence-v2/canonical.sqlite3`。V2 以外的存储仍是 JSON Store，**不要**在 V2 之外新引 SQLite。注意：GRDB 的 `SQL` 类型是 ExpressibleByStringInterpolation，会污染同模块内无类型标注的字符串闭包推断（见坑点 21）
7. **AppModel 拆分** — 核心状态在 AppModel.swift，子功能拆到 AppModel/ 子目录
8. **分析模块纯派生** — 今日简报、组合诊断、收益归因、策略雷达优先基于本地已聚合数据计算，不在 View 内写业务计算
9. **AI 行动跟踪单一路径** — 今日研判行动候选由用户主动加入跟踪清单；旧 TradeSignal 设置/通知链已删除
10. **Release notes** — GitHub Actions 从 tag 间 commit 标题生成更新内容；面向用户的提交标题要清晰、可读

## 已知坑点

1. **OverviewSectionView.swift 等总览视图拆分** — 已按子视图拆到 `Views_macOS/Overview/` 3 文件（OverviewSectionView/TodayBriefPanel/AITrendSummaryPanel）；改动相关测试 `TrendDashboardSummaryTests` 通过 `overviewSectionSources()` 汇总整个目录源码做断言，再拆分不会破坏
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
15. **AI 研判子系统的复用边界（投资智能改造必读）** — `Core/TrendResearch/` + `Core/Trend/` 共约 11917 行是「投资智能」类改造的复用基础，但复用面常被高估或低估：
    - **可复用**：`TrendResearchAgent`(821) 的 Harness 循环模式、`TrendResearchToolRegistry`(576) 的工具集、`actor TrendEvidenceLedger`（登记/溯源/稳定 ID/并发安全，定义在 `TrendResearchTool.swift` 内）、`TrendResearchSnapshot`(460) 的运行前冻结、`TrendAnalysisValidator`、SEC/AlphaVantage/Tavily 研究工具
    - **需新建（不是复用）**：来源独立性、同源去重、时效评分、Claim 级权重、证据冲突、跨运行持久化图谱——即 Evidence Intelligence Engine 的评分与冲突部分。现有 Ledger 只做运行内登记溯源，不等于完整 Evidence Intelligence
    - **Harness 抽取风险高**：`TrendResearchAgent` 与 Prompt/状态/提交模块强耦合，新建 Agent 时宜先复制受控子集（参考 `NextHourGuidance` 做法），等三条工作流稳定再反向抽取，**勿提前抽象**
    - **`FundLookThrough.swift`(944) 已较成熟**：能算 industries/assetClasses/coverage/unknown weight/陈旧披露，返回 `PortfolioLookThroughSnapshot`，组合暴露类改造可直接复用，不必从 `PortfolioDiagnostics` 退化起步
    - **改造宜垂直切片**：单一 Case 类型（如 concentrationRisk）走通完整链路（Models→Store→Policy→UI）再扩展，避免横向 Phase 产生长期无人消费的半成品
16. **build_macos_app.sh 走 SPM 构建** — Epic 5 引入 GRDB 后脚本已从裸 swiftc 改为 `swift build -c release` + 拷贝产物进 .app（源文件排除规则/最低系统版本以 `macos-app/Package.swift` 为单一事实源）。**新增 App 源文件不再需要动脚本**（SPM 自动发现）；但新增 SPM 外部依赖必须同步 `Package.swift` + `project.yml`（packages + 各 target dependencies，product 名为 GRDB 非 GRDB.swift）并 `xcodegen generate` 重生成工程
17. **GRDB `SQL` 类型污染类型推断** — GRDB 的 `SQL` 遵循 ExpressibleByStringInterpolation，同模块内无显式类型的字符串字面量闭包链（`map { "\(x)" }.joined(separator:)`）可能被推断成 `SQL`（GRDB 给 Sequence 加了 `joined(separator:)` 的 SQL 版扩展）。遇到莫名的 "cannot convert 'SQL' to 'String'" 时给变量显式标注 `: String`（先例：TrendLiveLogPanel.copyLogs）
18. **GRDB 迁移只追加不改写** — `CanonicalDatabase.makeMigrations()` 已发布的 migration id 永不改名/删除/重排（老库按 id 记账，改写 = 全量重跑破坏数据）；新增表只追加新 migration 并同步 `schemaVersion`（有测试守护两侧一致）

## Agent 工作指南

- 修改 UI 时注意涨跌颜色用 AppPalette（红涨绿跌）
- CLI 命令修改：DTO 在 `Core/CLI/DTOs.swift`，路由/handler 在 `Core/QiemanCommandLine.swift`；新增命令需同步：① 加 DTO（或复用现有，如 `alfa-actions` 复用 `CLIPlatformActionsOutput`）② 加 case + handler ③ 加 `CLIContractSnapshotTests` 快照 ④ 若新增 Swift 文件需更新 `scripts/build_qieman_cli.sh`
- alfa 投顾组合：客户端在 `Core/Alfa/QiemanAlfaClient.swift`，AppModel 逻辑在 `Core/AppModel/Alfa.swift`，UI 在 `Views_macOS/Platform/AlfaPlatformPanel.swift`（iOS 对应 `Views_iOS/IOSAlfaPlatformPanel.swift`）；组合持久化在 `alfa-portfolios.json`
- Swift App 入口在 `macos-app/QiemanDashboardApp.swift`
- AppModel 是全局状态中心，拆分子文件在 `macos-app/Core/AppModel/`
- 构建必须指定版本号：`APP_VERSION=x.y.z bash scripts/build_macos_app.sh`
- 发布流程：提交功能代码 → 打 tag（如 `v3.16.3`）→ 推送 `main` 和 tag → GitHub Actions 构建 zip、创建 Release、回写 `releases/macos/latest.json`
- 发布后本地执行 `git pull --ff-only`，拉回 Actions 自动提交的 `release: update vX.Y.Z`
- 新增功能优先补 XCTest；当前基线以 `swift test` 全绿为准
- 新增持仓分析能力优先放 Core 纯计算模型，再由 SwiftUI 面板展示
- 不要把 `.claude/`、`.agents/`、本地统计日志等个人工作区文件提交进项目
- 参考 `PROJECT_MAP.md` 获取更详细的架构说明
- AI 研判三条链路(趋势研究 / 下一小时研判 / 跟踪清单)的行为契约见 `docs/ai-pipeline-baseline.md`;改造这些链路前必读,对应的 `*CharacterizationTests.swift` 是行为冻结基线
- 投资智能系统(Investment Intelligence)新代码用 `InvestmentIntelligence.enabled` flag gate(Slice 0 默认 false,见 `Core/InvestmentIntelligence/InvestmentIntelligenceFeatureFlag.swift`)
