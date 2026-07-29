# CLAUDE.md — 且慢主理人看板 (qieman-manager-dashboard)

## 项目概览

macOS 原生 SwiftUI 应用 + Swift CLI，管理且慢（Qieman）投资平台数据。
- 本地 dashboard 展示基金持仓、净值走势、社区动态
- Swift 原生客户端抓取且慢平台数据，SwiftUI 前端渲染
- 支持 App 内手工维护持仓、自动更新、菜单栏小组件
- 中国股市惯例：红色涨、绿色跌

**技术栈**: SwiftUI + AppKit + Foundation (macOS 14+) | SPM 测试/校验 + swiftc 打包
**数据通道**: Swift 原生 API 直连；Agent 技能调用原生 `qieman-cli`
**当前发布版本**: v3.10.4（GitHub Release + `releases/macos/latest.json`）

## 目录结构与行数

### 原生命令行
`macos-app/Core/QiemanCommandLine.swift` 提供登录、动态、评论、调仓、持仓、估值和巡检命令；`scripts/qieman` 为启动器。

### macos-app/ — SwiftUI 原生 App（258 个 Swift 文件，~69000 行）

> 行数随开发持续变动，以下按模块给出职责地图；精确行数用 `wc -l` 查询。

#### 入口与配置
- `QiemanDashboardApp.swift`（~870 行）— App 入口 @main
- `Package.swift` — SPM 配置：executableTarget path=`.`，递归收集所有 `.swift`；`Tests/`、`CLI/` 排除。同 target 内移动文件无需改 import / Package.swift

#### Core/ 核心逻辑（按子目录组织）
- `Core/AppModel/`（23 文件）— 核心状态容器 `AppModel` 的功能拆分：PortfolioCRUD、TrendAnalysis、ManagerWatch、NextHourGuidanceController、EnhancementCenter、Validation、Auth 等
- `Core/Models/` — 数据模型（已从单一 `Models.swift` 拆分）：基金、持仓、净值、交易记录、快照等
- `Core/QiemanPlatformNativeClient.swift`（~1770 行）— 且慢平台原生客户端：持仓/动态/关注列表抓取 + 基金估值/股票行情多源回退；HTTP/签名/解析/时间格式化等通用工具层已抽到 `Core/QiemanPlatformNativeClientSupport.swift`
- `Core/QiemanNativeClient.swift`（~650 行）— 且慢原生 API 客户端（论坛动态/评论）
- `Core/Alfa/QiemanAlfaClient.swift` — 且慢 Alfa 客户端
- `Core/Trend/`（11 文件）— 趋势分析：模型/存储/校验/摘要/上下文/标签（TrendAnalysis*、TrendTracking*、TrendDashboardSummary 等）
- `Core/TrendResearch/`（23 文件）— AI 趋势研究子系统：TrendResearchAgent + 工具集（AlphaVantage / SEC 官方源 / Tavily / OpenAI 兼容客户端）
- `Core/Platform/` — 平台板块专用模型与展示
- `Core/MenuBarTicker/` — 菜单栏小组件（Entries/Settings/Kind/Types）
- `Core/Filters/`、`Core/CLI/` — 筛选器与命令行支持
- 其他 Core 散文件：`NextHourGuidance`、`FundLookThrough`、`FundSearchClient`、`PersonalWatchlistStore`、`TradeSignal*`、`MonthlyReport*`、`AppSelfUpdater`、`NativeSnapshotStore`、`QiemanRequestSigning`（请求签名共享层）、`QiemanText`（响应文本归一化共享层）等

#### Views/ 视图
- 主板块：`ContentView` → Overview / Portfolio / Platform / Forum
- `PersonalAssetBrowser.swift` + `Views/PersonalAsset/` — 个人资产浏览器（已拆出子目录：表格行/详情/价格趋势/投资计划/待交易）
- `EnhancementTrendPanel` / `EnhancementCenterView` / `TrendComponents` — 增强/趋势视图
- `SettingsSectionView` + 各 Settings 面板、`SharedComponents`、`PlatformComponents`、`CommandPaletteView`

#### 其他
- `Design/AppPalette.swift` — 设计系统：颜色（红涨绿跌）/字体/间距
- `Support/ValueFormatting.swift` — 数值格式化工具
- `Tests/QiemanDashboardTests/`（40+ 测试文件）— 覆盖客户端、展示、排序、月报、趋势研究、菜单栏等

### scripts/
| 文件 | 职责 |
|---|---|
| `scripts/render_macos_icon.swift` | App 图标生成 |
| `scripts/build_macos_app.sh` | Swift 编译构建脚本（递归 find 收集 macos-app 下所有 .swift） |

### releases/
| 文件 | 职责 |
|---|---|
| `releases/macos/latest.json` | 自动更新元数据（版本号、下载 URL） |

### skills/
Agent 技能层（qieman-manager-dashboard、qieman-alpha-signals、project-map）

## 构建与运行命令

```bash
# 构建 macOS App
APP_VERSION=3.10.4 bash scripts/build_macos_app.sh  # → dist/macos-app/QiemanDashboard.app

# 运行
open dist/macos-app/QiemanDashboard.app

# 构建/运行原生 CLI
bash scripts/build_qieman_cli.sh
scripts/qieman version

# 编译校验主模块（本机无 Xcode 时 swift test 跑不了 XCTest，用 swift build 把关）
cd macos-app && swift build

# 运行测试（需 Xcode）
swift test  # 在 macos-app/ 目录下
```

**构建要求**: macOS 14+, Xcode CLI Tools

## 架构与数据流

```
QiemanDashboardApp (@main)
  └─ AppModel (@MainActor ObservableObject, @EnvironmentObject)
       ├─ ApplicationDataController (本地数据目录)
       ├─ QiemanNativeClient (且慢 API 直连, 主路径)
       ├─ QiemanPlatformNativeClient (平台 API + 行情多源回退)
       ├─ Views/
       │    ├─ ContentView → Overview/Portfolio/Platform/Forum 四板块
       │    ├─ PersonalAssetBrowser (资产浏览器)
       │    └─ SettingsSectionView (设置面板)
       ├─ MenuBarTicker (菜单栏小组件)
       └─ Stores (持仓/计划/交易/关注/快照, 各独立 Store)
```

**数据通道**: App 和 CLI 直接复用 Swift 原生客户端。

## 关键约定

1. **@MainActor + ObservableObject** — AppModel 是单一状态容器，所有 View 通过 @EnvironmentObject 访问
2. **中国股市惯例** — 红涨绿跌，所有涨跌颜色用 AppPalette 统一（Views 层无硬编码颜色）
3. **纯 Swift 运行时** — 不依赖 Python、本地 HTTP 服务、OCR 或表格导入
4. **Cookie 认证** — 且慢登录态通过 QiemanCookieManager 管理，当前保存为本地受权限保护的 `qieman.cookie` 文件；后续可迁移 Keychain
5. **自动更新** — GitHub Release + latest.json，AppSelfUpdater 处理下载安装
6. **数据持久化** — SQLite/JSON 文件混合，通过各 Store 类管理
7. **AppModel 拆分** — 核心状态在 AppModel.swift，子功能拆到 AppModel/ 子目录
8. **共享工具层** — 请求签名走 `QiemanRequestSigning`，JSON 文本归一化走 `QiemanText`；`QiemanPlatformNativeClient` 的 HTTP/解析工具在 `+Support.swift` extension。新增客户端优先复用这些共享层，避免重复实现

## 已知坑点

1. **QiemanPlatformNativeClient.swift 较大**（~1770 行）— 且慢 API 与行情多源回退逻辑集中；通用工具层已拆到 `QiemanPlatformNativeClientSupport.swift`，剩余基金估值 / 股票行情块如需可继续按数据源拆 extension
2. **CLI JSON 契约** — Agent 消费 snake_case 字段，修改需补契约测试
3. **且慢 API 非公开** — 随时可能变更需维护
4. **本机无 Xcode** — XCTest 跑不了，重构后用 `swift build` 把关主模块；纯文件移动 / extension 抽取不改运行时行为，相对安全

## Agent 工作指南

- 修改 UI 时注意涨跌颜色用 AppPalette（红涨绿跌）
- CLI 修改优先定位 `Core/QiemanCommandLine.swift`，保持 snake_case JSON 契约
- Swift App 入口在 `macos-app/QiemanDashboardApp.swift`
- AppModel 是全局状态中心，拆分子文件在 `macos-app/Core/AppModel/`
- 构建必须指定版本号：`APP_VERSION=x.y.z bash scripts/build_macos_app.sh`
- 发布流程：构建 → GitHub Release 上传 zip → 更新 `releases/macos/latest.json`
- 参考 `PROJECT_MAP.md` 获取更详细的架构说明
