# AGENTS.md — 且慢主理人看板 (qieman-manager-dashboard)

## 项目概览

macOS 原生 SwiftUI 应用 + Swift CLI，管理且慢（Qieman）投资平台数据。
- 本地 dashboard 展示基金持仓、净值走势、社区动态
- Swift 原生客户端抓取且慢平台数据，SwiftUI 前端渲染
- 支持 App 内手工维护持仓、自动更新、菜单栏小组件
- 支持今日简报、主理人动态摘要、数据新鲜度、基金详情抽屉
- 支持持仓分析：组合诊断、基金对比、收益归因
- 支持平台分析：主理人策略雷达、交易时间总览、平台持仓概览
- 支持 alfa 投顾组合调仓与持仓（晓磊「基金全磊打」等），平台板块「长赢调仓/投顾组合」切换，多组合汇总展示 + chip 筛选 + 当前持仓（目标配置占比）+ 组合目录选择/手动添加
- 中国股市惯例：红色涨、绿色跌

**技术栈**: SwiftUI + AppKit + Foundation (macOS 14+) | SPM 测试/校验 + swiftc 打包
**数据通道**: Swift 原生 API 直连；Agent 技能统一调用原生 `qieman-cli`
**当前发布版本**: v3.5.0（GitHub Release + `releases/macos/latest.json`）

## 目录结构与行数

### 原生命令行
| 文件/目录 | 职责 |
|---|---|
| `macos-app/CLI/main.swift` | `qieman-cli` 入口 |
| `macos-app/Core/QiemanCommandLine.swift` | 命令路由、JSON 契约与增量巡检 |
| `scripts/build_qieman_cli.sh` | 构建原生 CLI |
| `scripts/qieman` | CLI 启动器 |

### macos-app/ — SwiftUI 原生 App（104 个 Swift 文件，约 28800 行）

#### 入口与配置
| 文件 | 行数 | 职责 |
|---|---|---|
| `QiemanDashboardApp.swift` | 359 | App 入口 @main |
| `Package.swift` | 19 | SPM 配置（极简） |

#### Core/ 核心逻辑（约 60 个 Swift 文件，约 15000 行）
| 文件 | 行数 | 职责 |
|---|---|---|
| `Core/Models/` | 1841 (12 文件) | 数据模型：基金、持仓、净值、交易记录等。按域拆为 AppEnums/Query/ManagerWatchSettings/SnapshotPayloads/PlatformPayloads/PersonalAsset/UserPortfolio/PersonalTrade/PersonalPlan/PersonalWatchlist/AlfaPortfolioCatalogItem/AlfaHoldingPart |
| `Core/QiemanPlatformNativeClient.swift` | 1773 | 且慢平台原生客户端（最大 API 客户端，大类保留，仅 actor 和 Array/String private extension 内聚） |
| `Core/Platform/` | 224 (4 文件) | 外移平台层：NativePlatformError / QiemanPlatformCache / PlatformActionAssetBuckets / NativePlatformDTOs |
| `Core/QiemanRequestSigning.swift` | 40 | 共享请求签名工具：`x-sign`（SHA256 时间戳）/ `x-request-id`，三个客户端共用，消除既有重复 |
| `Core/Alfa/QiemanAlfaClient.swift` | 456 | 且慢 alfa 投顾线客户端（GraphQL `POST /alfa/v1/graphql` + 动态签名 + groups/parts 拍平映射 + 缓存） |
| `Core/AlfaPortfolioStore.swift` | 40 | 投顾组合列表持久化（纯函数 load/save，默认预置晓磊 SI000192） |
| `Core/AppModel/Alfa.swift` | 104 | AppModel 的投顾逻辑：加载/拉取调仓/添加/移除/目录发现（hand-picked） |
| `Core/CLI/Contract.swift` | 74 | CLI 输出契约：snake_case encoder/decoder、NullDouble 包装 |
| `Core/CLI/DTOs.swift` | 323 | 20 个命令的输出 DTO（与 App 模型 Codable 隔离） |
| `Core/QiemanNativeClient.swift` | 1103 | 且慢原生 API 客户端 |
| `Core/AppModel.swift` | 283 | **核心状态容器**：@MainActor ObservableObject |
| `Core/AppModel/PortfolioCRUD.swift` | 612 | 持仓 CRUD 操作 |
| `Core/AppModel/Validation.swift` | 432 | 数据验证 |
| `Core/AppModel/AssetAggregation.swift` | 354 | 资产汇总计算 |
| `Core/AppModel/ManagerWatch.swift` | 326 | 主理人关注 |
| `Core/AppModel/InvestmentPlan.swift` | 264 | 投资计划模型 |
| `Core/AppModel/Auth.swift` | 238 | 认证逻辑 |
| `Core/AppModel/Import.swift` | 234 | 导入逻辑 |
| `Core/AppModel/PendingTrade.swift` | 176 | 待处理交易 |
| `Core/AppModel/PortfolioRefresh.swift` | 144 | 持仓刷新 |
| `Core/AppModel/DataDirectory.swift` | 82 | 数据目录管理 |
| `Core/AppModel/ComputedProperties.swift` | 192 | 计算属性 |
| `Core/AppModel/Update.swift` | 99 | 更新逻辑 |
| `Core/ApplicationDataController.swift` | 本地数据目录与 Cookie 路径管理 |
| `Core/AppSelfUpdater.swift` | 357 | App 自动更新（GitHub Release） |
| `Core/AppUpdateChecker.swift` | 210 | 更新检查 |
| `Core/NativeSnapshotStore.swift` | 365 | 数据快照持久化 |
| `Core/UserPortfolioStore.swift` | 353 | 用户持仓存储 |
| `Core/InvestmentPlansStore.swift` | 180 | 投资计划存储 |
| `Core/PendingTradesStore.swift` | 169 | 待处理交易存储 |
| `Core/PersonalAssetAutomation.swift` | 444 | 个人资产自动化 |
| `Core/PersonalAssetSorting.swift` | 88 | 资产排序 |
| `Core/ManagerWatchStore.swift` | 23 | 主理人关注存储 |
| `Core/QiemanCookieManager.swift` | 148 | Cookie 管理（且慢登录态） |
| `Core/LocalNotificationManager.swift` | 65 | 本地通知 |
| `Core/LaunchAtLoginAgent.swift` | 47 | 开机自启 LaunchAgent fallback |
| `Core/TodayBrief.swift` | 339 | 今日简报：待确认、计划、涨跌、动态入口 |
| `Core/DashboardInsight.swift` | 354 | 主理人动态摘要、数据新鲜度/失败状态 |
| `Core/PersonalAssetDetailSummary.swift` | 177 | 基金详情抽屉摘要 |
| `Core/PortfolioDiagnostics.swift` | 231 | 组合诊断：集中度、待确认、计划、波动、估值覆盖 |
| `Core/PersonalAssetComparison.swift` | 113 | 基金对比摘要 |
| `Core/ProfitAttribution.swift` | 145 | 收益归因 |
| `Core/StrategyRadar.swift` | 173 | 主理人策略雷达 |
| `Core/MenuBarTicker/` | 989 | 菜单栏小组件（Entries/Settings/Kind/Types） |

#### Views/ 视图（约 36 个 Swift 文件，约 11000 行）
| 文件 | 行数 | 职责 |
|---|---|---|
| `Views/Overview/` | 3 文件 | 总览：OverviewSectionView / TodayBriefPanel / AITrendSummaryPanel |
| `Views/Platform/` | 1193 (9 文件) | 平台子视图：ForumRows / PlatformActionRow / StrategyRadarPanel / PlatformActionDetailCard / HoldingCard / PlatformHoldingsPieChart / PlatformMonthlyOverview / AlfaPlatformPanel / AlfaHoldingCard |
| `Views/PortfolioSectionView.swift` | 持仓首页、组合诊断、收益归因 |
| `Views/PersonalAssetBrowser.swift` | 680 | 个人资产浏览器、搜索/筛选/排序/基金对比 |
| `Views/QiemanLoginView.swift` | 778 | 登录视图 |
| `Views/SettingsMenuBarPanel.swift` | 760 | 菜单栏设置面板 |
| `Views/PersonalAssetCards.swift` | 629 | 资产卡片组件 |
| `Views/ContentView.swift` | 565 | 主内容视图 |
| `Views/PlatformSectionView.swift` | 351 | 平台板块 |
| `Views/MenuBarPortfolioView.swift` | 362 | 菜单栏持仓小组件 |
| `Views/ForumComponents.swift` | 252 | 论坛组件 |
| `Views/SharedComponents.swift` | 300 | 通用 UI 组件 |
| `Views/ForumSectionView.swift` | 219 | 论坛板块 |
| `Views/SettingsSectionView.swift` | 218 | 设置主视图 |
| `Views/SettingsComponents.swift` | 231 | 设置通用组件 |
| `Views/SettingsWatchPanel.swift` | 182 | 关注设置面板 |
| `Views/SettingsAccountPanel.swift` | 133 | 账户设置面板 |
| `Views/SettingsAppPanel.swift` | 79 | 应用设置面板 |

#### 其他
| 文件 | 行数 | 职责 |
|---|---|---|
| `Design/AppPalette.swift` | 74 | 设计系统：颜色/字体/间距 |
| `Support/ValueFormatting.swift` | 80 | 数值格式化工具 |
| `Tests/` | XCTest | 更新、窗口、排序、简报、诊断、收益归因、策略雷达、AI 研判、alfa 投顾客户端等 |

### scripts/（287 行）
| 文件 | 行数 | 职责 |
|---|---|---|
| `scripts/render_macos_icon.swift` | 151 | App 图标生成 |
| `scripts/build_macos_app.sh` | 136 | Swift 编译构建脚本 |

### releases/
| 文件 | 职责 |
|---|---|
| `releases/macos/latest.json` | 自动更新元数据（版本号、下载 URL） |

### skills/
Agent 技能层（qieman-manager-dashboard、qieman-alpha-signals、project-map）

## 构建与运行命令

```bash
# 构建 macOS App
APP_VERSION=3.2.0 bash scripts/build_macos_app.sh  # → dist/macos-app/QiemanDashboard.app

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
QiemanDashboardApp (@main)
  └─ AppModel (@MainActor ObservableObject, @EnvironmentObject)
       ├─ ApplicationDataController (本地数据目录)
       ├─ QiemanNativeClient (且慢 API 直连, 主路径)
       ├─ QiemanPlatformNativeClient (平台 API)
       ├─ Views/
       │    ├─ ContentView → Overview/Portfolio/Platform/Forum/Settings 五板块
       │    ├─ OverviewSectionView (总览、今日简报、主理人摘要)
       │    ├─ PortfolioSectionView (持仓分析)
       │    ├─ PersonalAssetBrowser (资产浏览器、基金对比)
       │    ├─ PlatformSectionView (平台调仓、策略雷达)
       │    └─ SettingsSectionView (设置面板)
       ├─ Insight Cores (TodayBrief / DashboardInsight / PortfolioDiagnostics / ProfitAttribution / StrategyRadar)
       ├─ MenuBarTicker (菜单栏小组件)
       └─ Stores (持仓/计划/交易/关注/快照, 各独立 Store)
```

**数据通道**: App 和 CLI 复用 `QiemanNativeClient` / `QiemanPlatformNativeClient`，直接访问且慢与行情源。

## 关键约定

1. **@MainActor + ObservableObject** — AppModel 是单一状态容器，所有 View 通过 @EnvironmentObject 访问
2. **中国股市惯例** — 红涨绿跌，所有涨跌颜色用 AppPalette 统一
3. **纯 Swift 运行时** — App、爬取能力、CLI 和 Agent 技能不依赖 Python 或 localhost HTTP 服务
4. **Cookie 认证** — 且慢登录态通过 QiemanCookieManager 管理，当前保存为本地受权限保护的 `qieman.cookie` 文件；后续可迁移 Keychain
5. **自动更新** — GitHub Release + latest.json，AppSelfUpdater 处理下载安装
6. **数据持久化** — SQLite/JSON 文件混合，通过各 Store 类管理
7. **AppModel 拆分** — 核心状态在 AppModel.swift，子功能拆到 AppModel/ 子目录
8. **分析模块纯派生** — 今日简报、组合诊断、收益归因、策略雷达优先基于本地已聚合数据计算，不在 View 内写业务计算
9. **AI 行动跟踪单一路径** — 今日研判行动候选由用户主动加入跟踪清单；旧 TradeSignal 设置/通知链已删除
10. **Release notes** — GitHub Actions 从 tag 间 commit 标题生成更新内容；面向用户的提交标题要清晰、可读

## 已知坑点

1. **OverviewSectionView.swift 等总览视图拆分** — 已按子视图拆到 `Views/Overview/` 4 文件；改动相关测试 `TrendDashboardSummaryTests` 通过 `overviewSectionSources()` 汇总整个目录源码做断言，再拆分不会破坏
2. **PlatformComponents.swift 已拆分** — 平台行、详情、月度概览、策略雷达、持仓卡、饼图分别落到 `Views/Platform/` 7 文件
3. **QiemanPlatformNativeClient.swift (1773 行) 大类保留** — 只有 7 个 public 方法，~50 个 private helper 互相紧耦合，未拆 extension；外围的 DTO/Cache/Error/AssetBuckets 已外移到 `Core/Platform/`，大类内部 private/fileprivate 维持原封装
4. **Models.swift 已按域拆分** — 9 文件落到 `Core/Models/`，4 处自定义 CodingKeys 跟随所属 struct
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

## Agent 工作指南

- 修改 UI 时注意涨跌颜色用 AppPalette（红涨绿跌）
- CLI 命令修改：DTO 在 `Core/CLI/DTOs.swift`，路由/handler 在 `Core/QiemanCommandLine.swift`；新增命令需同步：① 加 DTO（或复用现有，如 `alfa-actions` 复用 `CLIPlatformActionsOutput`）② 加 case + handler ③ 加 `CLIContractSnapshotTests` 快照 ④ 若新增 Swift 文件需更新 `scripts/build_qieman_cli.sh`
- alfa 投顾组合：客户端在 `Core/Alfa/QiemanAlfaClient.swift`，AppModel 逻辑在 `Core/AppModel/Alfa.swift`，UI 在 `Views/Platform/AlfaPlatformPanel.swift`；组合持久化在 `alfa-portfolios.json`
- Swift App 入口在 `macos-app/QiemanDashboardApp.swift`
- AppModel 是全局状态中心，拆分子文件在 `macos-app/Core/AppModel/`
- 构建必须指定版本号：`APP_VERSION=x.y.z bash scripts/build_macos_app.sh`
- 发布流程：提交功能代码 → 打 tag（如 `v3.3.0`）→ 推送 `main` 和 tag → GitHub Actions 构建 zip、创建 Release、回写 `releases/macos/latest.json`
- 发布后本地执行 `git pull --ff-only`，拉回 Actions 自动提交的 `release: update vX.Y.Z`
- 新增功能优先补 XCTest；当前基线以 `swift test` 全绿为准
- 新增持仓分析能力优先放 Core 纯计算模型，再由 SwiftUI 面板展示
- 不要把 `.claude/`、`.agents/`、本地统计日志等个人工作区文件提交进项目
- 参考 `PROJECT_MAP.md` 获取更详细的架构说明
