# 观澜 / Guanlan

[![Release](https://img.shields.io/github/v/release/sunnyhot/guanlan-dashboard?label=Release)](https://github.com/sunnyhot/guanlan-dashboard/releases/latest)
[![CI](https://github.com/sunnyhot/guanlan-dashboard/actions/workflows/ci.yml/badge.svg)](https://github.com/sunnyhot/guanlan-dashboard/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

> 原生 macOS / iOS SwiftUI App：且慢（Qieman）投资平台的个人投资看板——持仓管理、平台动态追踪、**有证据约束的 AI 投资研判**。纯 Swift 实现，无 Python、无本地 HTTP 服务；所有数据本地存储，AI 直连你自己的模型服务。

**观澜**，取「观市场之澜」——看板负责让你看见潮起潮落，研判负责告诉你为什么。

## 为什么是观澜

- **纯原生**：SwiftUI + AppKit/UIKit 双端实现，无 Electron、无脚本胶水层；行情抓取、平台 API、AI Agent 全部 Swift 原生
- **本地优先**：持仓、净值、研判报告、登录态全部落本机文件（敏感数据 0600 权限），不经过任何第三方服务器
- **AI 有据可查**：研判结论必须引用工具返回的真实证据 ID（Evidence Ledger），买卖建议有硬性证据门槛——模型不能凭记忆说话
- **自带模型 Key**：支持任意 OpenAI 兼容接口（智谱 / DeepSeek / OpenAI / 本地模型均可），请求直连你配置的服务

## 功能总览

### 持仓与资产管理
- **个人持仓** — 手工维护持仓、待确认买入、定投计划；组合总览、今日简报、数据新鲜度提示
- **组合诊断** — 集中度、估值覆盖、待确认与计划风险一页看清
- **基金对比 / 收益归因** — 多基金横向对比，收益来源拆解
- **基金穿透（look-through）** — 基于定期报告披露，穿透到底层证券、行业暴露、资产类别暴露与覆盖率，披露陈旧自动警示
- **导入** — 且慢持仓一键导入、CSV 导入

### AI 投资研判（三条链路）
| 链路 | 时点 | 产出 |
| --- | --- | --- |
| 盘中实时指引 | 交易时段每小时槽位 + 14:50 收盘窗口 + 手动 | 下一小时操作参考（buy/sell/hold），每条附触发与失效条件 |
| 今日收盘复盘 | 每日 21:00 自动 | 大盘/板块强弱 + 逐只持仓当日涨跌归因 + **昨日判断验证**（上次复盘的方向判断 vs 今日行情对账） |
| 组合长期研判 | 定期自动 + 手动 | 组合结论、短/中/长期周期判断、逐只持仓趋势与关键资产提醒 |

- **证据约束**：多轮 Tool Calling Agent 只能引用本次运行工具返回的真实证据 ID；App 侧确定性兜底格式缺陷，避免无意义的拒批循环
- **买卖门禁**：买入/卖出建议须同时满足本地行情新鲜度、≥2 条彼此独立的外部事件证据（本地财经热榜：财联社/华尔街见闻/雪球）、基金穿透证据、仓位表述与置信度门槛——不满足只能 hold
- **新闻面**：盘中事件归因来自本地拉取的 NewsNow 财经热榜，免 token、失败静默降级
- **可观测**：完整诊断日志落本机（模型请求/工具调用/校验错误全记录，敏感字段递归脱敏）；链路前置阶段限时保护，网络异常快速失败而非挂死

### 平台动态
- **调仓追踪** — 长赢指数投资计划调仓（份数语义）、alfa 投顾组合调仓与当前持仓（百分比语义，如「基金全磊打」），多组合汇总 + 来源筛选
- **主理论坛** — 长赢同路人等社区动态浏览、评论查看
- **策略雷达** — 主理人行为模式概览

### 行情数据引擎
腾讯/东财/新浪多源快照与 K 线双源、全市场广度统计、NewsNow 财经热榜、规则技术分析（百分制六模块），带熔断限速与缓存——AI 研判与看板共用同一套本地行情。

### 常驻体验
- **菜单栏小组件** — 总资产/今日涨跌/单只持仓实时估值常驻菜单栏，可排序
- **系统通知** — 调仓/发言巡检、AI 研判完成提醒，点击深链直达详情区段
- **自动更新** — 启动检查 GitHub Release，一键安装；检测到 Homebrew 安装时自动让位给 `brew upgrade`

### iOS 端
与 macOS 同源核心（Core/ 共用）的 iPhone/iPad 版本：总览、持仓、平台动态、AI 研判浏览，由 Xcode 工程管理（`Views_iOS/`）。

### 原生命令行 qieman-cli
```bash
scripts/qieman version                     # 首次调用自动编译
scripts/qieman platform-holdings --prod-code LONG_WIN
scripts/qieman following-posts --user-name "ETF拯救世界"
```
19 个命令覆盖登录、动态、评论、调仓、持仓、估值与增量巡检，稳定 JSON 契约——也是 Agent 技能层（`skills/`）的统一数据通道。

## 安装

推荐 Homebrew（自动跟随最新 Release，且不受 Gatekeeper 未公证拦截）：

```bash
brew tap sunnyhot/tap
brew install --cask sunnyhot/tap/guanlan
```

或从 [GitHub Releases](https://github.com/sunnyhot/guanlan-dashboard/releases/latest) 下载 zip 解压到 /Applications。

> 更新：应用会自动检测 Homebrew 安装——brew 装的提示用 `brew upgrade`、不再应用内覆盖安装；手动下载安装的使用应用内自动更新。

## 快速上手

1. **导入持仓** — 设置中一键导入且慢持仓，或 CSV 导入、手工添加
2. **配置模型**（用 AI 研判才需要）— 设置 → AI 研判：填 OpenAI 兼容接口的地址、模型名与 API Key（只存本机，请求直连该服务）
3. **日常使用** — 总览页看今日简报；交易时段点「更新盘中研判」；每晚 21:00 自动生成收盘复盘，次日复盘可看到对昨晚判断的验证

## 隐私与数据

所有数据保存在本地（JSON 文件，敏感文件 0600 权限）；且慢登录态保存在本地受权限保护的 cookie 文件；AI 模型 Key 存本地，仅在你触发生成时直连你所配置的模型服务。完整诊断日志（含业务数据）只落本机，API Key 等敏感字段递归脱敏。

## 构建

要求：macOS 14+，完整 Xcode（CommandLineTools 工具链缺 SwiftUI 宏插件，需 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）。

```bash
# macOS App（产物 dist/macos-app/QiemanDashboard.app，分发包输出 /tmp/）
APP_VERSION=<x.y.z> DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_macos_app.sh

# 运行测试（macos-app/ 目录下）
cd macos-app && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# iOS target 由 Xcode 工程管理（xcodegen 生成），UI 在 Views_iOS/
```

界面遵循中国股市惯例：红涨绿跌。

## 发布流程

由 `.github/workflows/release.yml` 自动完成。推送 `v*` tag 后 Actions 构建 App、创建 GitHub Release、上传 zip、回写 `releases/macos/latest.json`（App 依赖它检查更新）：

```bash
VERSION=<x.y.z>
git tag -a "v$VERSION" -m "v$VERSION"
git push origin main "v$VERSION"
# Actions 完成后拉回回写提交
git pull --rebase origin main
```

发版后可验证更新源：

```bash
curl -fsSL "https://github.com/sunnyhot/guanlan-dashboard/releases/latest/download/latest.json"
```

CI（`.github/workflows/ci.yml`）对 main 与 PR 跑全量测试。正常发版不要手动上传 zip 或手改 `latest.json`，以免与 Actions 自动流程不一致。

## 仓库结构

```
├── macos-app/           # SwiftUI 原生 App 源码
│   ├── Core/            # 原生 API 客户端、状态、存储、AI 研判子系统（macOS/iOS 共用）
│   ├── Views_macOS/     # macOS 视图
│   ├── Views_iOS/       # iOS 视图（Xcode 工程管理）
│   └── CLI/             # qieman-cli 入口
├── scripts/             # App/CLI 构建与 qieman 启动器
├── docs/                # 行为契约基线与设计文档
└── releases/macos/      # latest.json 更新清单
```

## 文档

- `CHANGELOG.md` — 版本历史
- `AGENTS.md` — 架构与约定（面向贡献者的仓库指南）
- `PROJECT_MAP.md` — 详细架构地图
- `docs/ai-pipeline-baseline.md` — AI 研判三条链路的行为契约基线
