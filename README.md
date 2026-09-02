# 观澜 / Guanlan（原「且慢主理人看板」）

> 原生 macOS / iOS SwiftUI App：且慢（Qieman）投资平台的个人看板——持仓管理、主理人动态追踪、AI 投资研判，纯 Swift 实现，无 Python、无本地 HTTP 服务。

## 功能

### 持仓与资产
- **个人持仓** — App 内手工维护持仓、待确认买入、定投计划；组合总览、今日简报、数据新鲜度提示
- **持仓分析** — 组合诊断（集中度/估值覆盖/待确认）、基金对比、收益归因、基金穿透（底层证券/行业暴露/覆盖率，基于定期报告披露）
- **导入** — 且慢持仓一键导入、CSV 导入

### 平台动态
- **主理论坛** — 长赢同路人等社区动态浏览、评论查看
- **调仓追踪** — 长赢指数投资计划调仓（份数语义）、alfa 投顾组合调仓与当前持仓（百分比语义，如「基金全磊打」），多组合汇总 + 来源筛选
- **策略雷达** — 主理人行为模式概览

### AI 投资研判（自带模型 Key，支持 OpenAI 兼容接口）
- **盘中实时指引** — 交易时段每小时更新下一小时操作参考，收盘前窗口覆盖场外基金
- **今日收盘复盘** — 每日 21:00 自动生成：大盘/大类资产强弱 + 逐只持仓当日涨跌归因，附**昨日判断验证**（上次复盘的方向判断 vs 今日实际行情的确定性对账）
- **组合长期研判** — 每周日组合结论、短/中/长期周期判断、逐只持仓趋势
- 多轮 Tool Calling Agent + 证据账本（Evidence Ledger）：每条结论须引用工具返回的真实证据 ID，格式缺陷由 App 确定性兜底而非拒批循环
- 行情数据引擎：腾讯/东财/新浪多源行情与 K 线、全市场广度、规则技术分析，熔断限速缓存

### 常驻体验
- **菜单栏小组件** — 总资产/今日涨跌/单只持仓实时估值常驻菜单栏，可排序
- **系统通知** — 调仓/发言巡检、AI 研判完成提醒，点击深链直达详情
- **自动更新** — 启动检查 GitHub Release，一键安装新版本

### 原生命令行
```bash
scripts/qieman version                     # 首次调用自动编译
scripts/qieman platform-holdings --prod-code LONG_WIN
scripts/qieman following-posts --user-name "ETF拯救世界"
```
提供登录、动态、评论、调仓、持仓、估值与增量巡检等命令，JSON 输出。

## 隐私与数据

所有数据保存在本地（App 沙盒内 JSON 文件，敏感文件 0600 权限）；且慢登录态保存在本地受权限保护的 cookie 文件；AI 模型 Key 存本地，仅在你触发生成时直连你所配置的模型服务。完整诊断日志（含业务数据）只落本机，API Key 等敏感字段递归脱敏。

## 构建

要求：macOS 14+，完整 Xcode（CommandLineTools 工具链缺 SwiftUI 宏插件，需 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）。

```bash
# macOS App（产物 dist/macos-app/QiemanDashboard.app，分发包输出 /tmp/）
APP_VERSION=4.9.2 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_macos_app.sh

# 运行测试（macos-app/ 目录下）
cd macos-app && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# iOS target 由 Xcode 工程管理（xcodegen 生成），UI 在 Views_iOS/
```

界面遵循中国股市惯例：红涨绿跌。

## 发布流程

由 `.github/workflows/release.yml` 自动完成。推送 `v*` tag 后 Actions 构建 App、创建 GitHub Release、上传 zip、回写 `releases/macos/latest.json`（App 依赖它检查更新）：

```bash
VERSION=4.9.3
git tag -a "v$VERSION" -m "v$VERSION"
git push origin main "v$VERSION"
# Actions 完成后拉回回写提交
git pull --rebase origin main
```

发版后可验证更新源：

```bash
curl -fsSL "https://github.com/sunnyhot/qieman-manager-dashboard/releases/latest/download/latest.json"
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
