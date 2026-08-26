# 投资智能 V2 产品展示层重构技术方案

> 日期：2026-08-26  
> 基线：`main` / v4.3.0  
> 实施对象：macOS + iOS SwiftUI 客户端  
> 目标：保留 Investment Intelligence V2 的 Research / Decision / Artifact 架构，重建可理解、可操作、可验证的产品展示层。

## 0. 给代码实现者的执行说明

本方案是实施约束，不是视觉建议。必须按 P0 → P4 顺序完成；P0 正确性门禁未通过前，不得先做 UI 美化并宣称完成。

完成定义：

1. “盘中决策”使用用户真实战略目标，不再用当前仓位复制目标仓位。
2. 主页面不再出现 `current-target`、`provenance`、`universe v1`、`Artifact ID`、`remote-staging-sync.json`、`Keychain` 等内部实现词。
3. 用户能看懂结论、原因、数据时效和下一步动作；失败必须有可执行的恢复入口。
4. AI Provider 配置移入设置中心，投资智能主页不直接展示 Base URL/API Key 表单。
5. View 不直接查询 SQLite、不重算决策；V2 产出统一经 `ArtifactQueryService` 和 Presentation DTO 读取。
6. macOS 与 iOS 同步交付，`swift test`、macOS build、iOS build 全部通过。

严禁：

- 恢复已删除的 `Core/TrendResearch/`、`Core/Trend/`、`Core/InvestmentIntelligence/` 或旧 `NextHourGuidance` 类型。
- 让 LLM 生成目标权重或直接决定 `Δw`。
- 为了让页面“有结果”而用 0、默认值、当前仓位或猜测值填补未知数据。
- 在 SwiftUI View 中直接访问 GRDB Repository、拼 SQL 或执行同步数据库查询。
- 修改已发布 migration；只能追加。
- 把 API Key 写入 UserDefaults、JSON、日志或同步档案。

## 1. 现状问题与根因

当前 `IntelligenceSectionView` 是工程接线验收面，不是产品页：

- 四张同权重大卡片纵向堆叠，缺少“今日结论 → 原因 → 行动”的主线。
- 市场数据缺口以内部诊断串直接暴露，用户看不到修复入口。
- AI 配置占据主页面核心空间。
- `latestIntelligenceError` 只写不展示，失败对用户不可见。
- 决策/研究只显示少量计数或 Artifact ID，没有证据、风险、有效期和历史。
- `LivePortfolioDecisionMaterials` 把当前资产类权重重新包装为 Target，导致 `current == target`，盘中决策天然倾向“持有不动”。
- 现有持仓只把股票映射为 `.equity`、所有基金映射为 `.alternative`，不具备可信的战略资产分类。

这次重构必须同时解决“决策输入不成立”和“结果不会表达”两类问题。

## 2. 产品目标与非目标

### 2.1 产品目标

- 首屏 10 秒内回答：今天结论是什么、为什么、是否需要动作、数据是否可信。
- 未准备好时回答：缺什么、为什么不能运行、用户下一步点哪里。
- 把研究、市场机会、盘中执行组织成一条连续链路，而不是三个独立按钮。
- 保留 V2 的可审计性，但将技术溯源放入详情层，不污染摘要层。
- macOS 使用桌面信息密度与键盘操作；iOS 保持相同语义，采用单列布局。

### 2.2 非目标

- 不恢复旧版 UI 的旧数据模型和旧调度链。
- 不在本轮新增自动交易、券商下单或后台无人值守买卖。
- 不让模型自行修改战略目标。
- 不重写 Research、Decision、Factor、ConstraintGate 算法。
- 不引入新的第三方 UI 框架。

## 3. 不可破坏的架构约束

1. `InvestmentIntelligenceV2/` 不引用 SwiftUI、AppKit、AppModel。
2. `DecisionNarrator` / `ResearchNarrator` 只解释现有 Artifact，不重新打分或重跑 Planner。
3. `PortfolioDecisionArtifact` 写库前继续强制通过 `DecisionValidator`。
4. Target 只允许 `explicitUserAllocation` 或 `userSelectedTemplate`，遵守 ADR-D000。
5. `Δw` 只允许 target / remediation / user 三类 provenance，遵守 ADR-D001。
6. UI 读取 V2 结果只经 `ArtifactQueryService`；AppModel 负责异步加载并发布 Presentation DTO。
7. 所有日期按用户 Locale 显示；持久化仍使用既有 UTC 毫秒格式。
8. 涨跌与风险颜色使用 `AppPalette`，遵守中国市场红涨绿跌；颜色不能成为唯一状态线索。
9. API Key 只存 `KeychainHelper.Account.openAIKey`；保存时空 Key 保留旧值，显式清除必须单独操作。
10. macOS/iOS 新文件都要进入 Xcode 工程；修改 `project.yml` 后执行 `xcodegen generate`。

## 4. 新页面信息架构

### 4.1 macOS 页面结构

内容区最大宽度 1320pt，居中显示；窗口较宽时使用两列，窄窗口自动退化为单列。不要继续让四张卡片无限拉满整屏。

```text
┌ 投资智能 ─────────────────────────── 最近更新 20:42  [刷新] [开始研究] ┐
│ 今日结论：维持配置 / 建议再平衡 / 暂不可判断                         │
│ 一句话原因 + 有效期 + 数据可信度                                      │
└───────────────────────────────────────────────────────────────────────┘

┌ 战略配置与偏差（主卡，2/3 宽） ─────────────┐ ┌ 系统状态（1/3 宽） ┐
│ 股票   当前 62%  目标 55%  +7%             │ │ 持仓分类  已完成    │
│ 固收   当前 28%  目标 35%  -7%             │ │ 市场数据  24/31    │
│ 现金   当前 10%  目标 10%   0%   [编辑目标] │ │ AI 模型   已配置    │
└──────────────────────────────────────────────┘ └─────────────────────┘

┌ 盘中执行建议 ───────────────────────────────┐ ┌ 市场机会 ──────────┐
│ 结论、持有/调整原因、可执行动作、有效期      │ │ Top 候选及入选原因 │
│ [重新评估] [查看详情]                        │ │ [更新机会] [详情]  │
└──────────────────────────────────────────────┘ └─────────────────────┘

┌ 组合研究 ────────────────────────────────────────────────────────────┐
│ 组合论点、主要风险、关键信号、证据数量与更新时间                     │
│ [开始研究/重新研究] [查看证据]                                        │
└───────────────────────────────────────────────────────────────────────┘

┌ 最近记录 ────────────────────────────────────────────────────────────┐
│ 类型 | 结论 | 生成时间 | 有效状态                              [查看] │
└───────────────────────────────────────────────────────────────────────┘
```

### 4.2 iOS 页面结构

- 保持同样的顺序和状态语义，全部单列。
- “编辑目标”“持仓分类”“结果详情”使用 sheet/navigation destination。
- 主要按钮最小触控面积 44×44；复杂详情不塞进首页卡片。
- 不在 iOS 首页放 Provider 表单，统一进入设置页。

### 4.3 用户可见状态矩阵

| 条件 | 首页结论 | 主动作 | 禁止行为 |
|---|---|---|---|
| 尚无 Target | 先设定战略配置 | `设置目标` | 不允许运行盘中执行决策 |
| 有未分类持仓 | N 项持仓待归类 | `完善分类` | 不用 `.alternative` 静默兜底 |
| 资产分类/估值过期 | 当前配置数据不足 | `更新持仓数据` | 不生成可执行计划 |
| 市场数据覆盖不足 | 市场机会准备中 | `继续更新数据` | 不显示“暂无机会”误导用户 |
| AI 未配置 | 研究功能尚未配置 | `前往设置` | 不展示无解释的置灰按钮 |
| Workflow 运行中 | 展示阶段和已耗时 | `取消`（若底层支持） | 不重复提交同一任务 |
| Workflow 失败 | 人话错误 + 恢复动作 | `重试/前往设置` | 不只写日志、不展示 raw error |
| Artifact 已过期 | 显示“已过期” | `重新评估` | 不把旧报告冒充最新结论 |
| 结论为 HOLD | 显示“维持配置”及具体原因 | `查看依据` | 不把 HOLD 当失败或空状态 |

## 5. 数据与状态架构

### 5.1 总体数据流

```text
用户持仓 + 用户战略目标 + 持仓资产分类
                │
                ▼
LivePortfolioDecisionMaterials（真实 target，不再自复制）
                │
       Research / Discovery / Intraday Workflows
                │
                ▼
        DecisionValidator → Artifact 落库
                │
                ▼
ArtifactQueryService + Narrators
                │
                ▼
InvestmentIntelligenceDashboardSnapshot（纯 Presentation DTO）
                │
                ▼
AppModel @Published state → macOS/iOS SwiftUI Views
```

### 5.2 Dashboard Presentation DTO

新增：

`macos-app/InvestmentIntelligenceV2/Presentation/InvestmentIntelligenceDashboardSnapshot.swift`

建议类型：

```swift
struct InvestmentIntelligenceDashboardSnapshot: Sendable, Equatable {
    let generatedAt: Date
    let headline: Headline
    let allocation: AllocationSummary
    let readiness: ReadinessSummary
    let intraday: IntradaySummary?
    let discovery: DiscoverySummary?
    let research: ResearchSummary?
    let history: [HistoryItem]
}
```

要求：

- DTO 只包含 UI 所需的结构化字段，不包含预拼接的调试串。
- 状态使用 enum，不使用 `String` 判断，例如 `.ready/.missingTarget/.stale/.failed`。
- UI 文案由 Presentation 层的稳定格式化器生成，View 只负责布局。
- `HistoryItem` 使用稳定 Artifact ID 作为内部 id，但首页不直接显示 ID。
- `ArtifactQueryService` 新增 `dashboardSnapshot(...)` 或等价聚合 API；内部可调用现有 typed fetch、`DecisionNarrator`、`ResearchNarrator`。
- 查询失败 fail-closed；AppModel 捕获后映射为用户可见错误状态。

### 5.3 AppModel 状态

把 V2 UI 状态从 `AppModel.swift` 的零散字段收拢到新文件：

`macos-app/Core/AppModel/InvestmentIntelligenceV2Dashboard.swift`

建议状态：

```swift
enum IntelligenceDashboardLoadState {
    case idle
    case loading
    case loaded(InvestmentIntelligenceDashboardSnapshot)
    case failed(IntelligenceUserFacingError)
}

enum IntelligenceOperationState {
    case idle
    case running(startedAt: Date, stage: Stage)
    case failed(IntelligenceUserFacingError)
}
```

要求：

- 市场发现、盘中决策、组合研究分别维护 operation state，不能共用一个模糊错误串。
- 每次 workflow 成功后统一调用 `refreshIntelligenceDashboard()`，不要手工更新多个 Published 字段造成状态撕裂。
- bootstrap 完成后自动加载最新 snapshot；页面重新进入时只做轻量刷新，不自动消耗 LLM 配额。
- 旧的 `latestIntelligenceError`、`latestResearchArtifactID` 等字段在新页面完全切换后删除，避免双状态源。

## 6. P0：先修决策输入正确性

### 6.1 战略目标持久化

当前没有可供生产 UI 使用的 Target Store。新增：

- `macos-app/InvestmentIntelligenceV2/Persistence/StrategicAllocationTargetStore.swift`
- `macos-app/Tests/QiemanDashboardTests/InvestmentIntelligenceV2/StrategicAllocationTargetStoreTests.swift`

Target 是用户意图，不是可从 Provider spool 重放的派生行情数据，因此不要只写入可重建的 `canonical.sqlite3`。采用 V2 工作目录内的 append-only 文件事实源：

```text
investment-intelligence-v2/
└── user-intent/
    └── allocation-targets/
        ├── <target-id>.json       # 不可变事件，一对象一文件
        └── current.json           # 当前 target 指针，原子替换
```

每个事件至少包含：

- `schemaVersion`
- 完整 `AllocationTarget`
- `supersedesTargetID`
- `changeReason`
- `recordedAt`

写入纪律：

1. 必须先经 `StrategicAllocationPolicy` 和 `StrategicAllocationValidator`。
2. target 文件使用 atomic write；成功后再原子更新 `current.json`。
3. 已存在同 ID 同内容视为幂等；同 ID 不同内容 fail-closed。
4. 不提供 update/delete；历史永久保留。
5. current 指针损坏时扫描合法事件，按 `createdAt + id` 确定性恢复，并记录诊断日志。
6. 文件不包含任何 API Key。

同时修正 `StrategicAllocationValidator`：Target 必须显式包含 `AssetClass.allCases` 五类，允许某类权重为 0，但不允许缺类。新增 `missingAssetClasses` 校验错误及边界测试。

升级兼容规则：已有 Artifact 中由 `维持当前配置（对照检查漂移）` 生成的临时 Target 不得导入 Target Store，也不得继续作为首页有效结论。Dashboard 只展示其 target ID 能在合法 Target 历史中解析的执行/决策报告；旧 Artifact 保留用于审计，不删除、不伪装成用户配置。

### 6.2 持仓战略资产分类

Planner 要把资产类偏差按类内持仓 pro-rata 分配，因此每个可交易持仓必须有可信 `AssetClass`。不得继续把所有基金默认成 `.alternative`。

新增：

- `macos-app/InvestmentIntelligenceV2/Persistence/StrategicAssetClassAssignmentStore.swift`
- `macos-app/Core/AppModel/InvestmentIntelligenceV2Materials.swift`
- `macos-app/Tests/QiemanDashboardTests/InvestmentIntelligenceV2/StrategicAssetClassAssignmentTests.swift`

解析优先级：

1. 用户显式分类。
2. 直接股票确定为 `.equity`。
3. 基金披露中单一资产类占比 ≥80% 且披露未过期，可作为“系统识别”，同时记录来源日期。
4. 其他情况为 unresolved，禁止生成执行计划，并引导用户分类。

分类 Store 同样使用 V2 `user-intent/` 下的一对象一文件事件，记录 subjectKey、AssetClass、来源、时间和备注。系统识别不伪装成用户选择。

必须新增纯函数 `LivePortfolioSnapshotBuilder`：

- 输入：`personalAssetRows`、分类结果、估值时间、真实 `AllocationTarget`。
- 输出：`PortfolioSnapshot`、`ActionDomain`、分类覆盖率、未分类 subject 列表。
- 权重精确归一，残差只用于 Decimal 舍入修正，不能掩盖未知持仓。
- 有任意正权重持仓 unresolved 时，返回 readiness blocker，不生成 planner run。
- subjectKey 必须继续对应真实可交易持仓，不能把一只混合基金拆成不可交易的虚拟 subject。

### 6.3 Runtime 行为修改

修改 `Core/AppModel/InvestmentIntelligenceV2Runtime.swift`：

- 删除“把当前配置生成 Target”的代码和 `note: 维持当前配置`。
- `runIntradayDecision()` 必须读取当前 Target；没有 Target 时直接进入 `.missingTarget`，不写 Artifact。
- `runPortfolioResearch()` 当前会产出 Decision Artifact，因此本轮同样要求 Target 就绪；若以后需要“只研究不决策”，另开 workflow，不在这里写半截状态。
- 持仓分类未完成、估值陈旧或 ActionDomain 不完整时 fail-closed，并给出可恢复状态。
- workflow 成功后从 Query Service 重新加载 dashboard snapshot。
- 原始错误写诊断日志；UI 只显示映射后的 `IntelligenceUserFacingError`。

P0 验收用例：

1. 当前 60% 股票/40% 固收，Target 50%/50%，产出非零 target provenance 调整，而不是恒 HOLD。
2. current 与 target 相同且在 5% 容忍带内，明确 HOLD。
3. 无 Target、Target 缺类、存在未分类持仓、估值陈旧时均不写执行 Artifact。
4. LLM/Signal 无法构造或修改 Target。
5. App 重启后能恢复 current Target 和用户分类历史。

## 7. P1：补齐 Presentation 查询面

### 7.1 ArtifactQueryService 扩展

修改 `InvestmentIntelligenceV2/Presentation/PresentationLayer.swift`，必要时按职责拆文件，避免继续扩大单文件。

新增能力：

- 查询最新有效盘中报告及最近历史报告。
- 查询最新市场发现、候选原因、覆盖率和更新时间。
- 查询最新 PortfolioDecisionArtifact 完整对象，并经 `DecisionNarrator` 生成解释。
- 查询相关 theses、signals、evidence 摘要，经 `ResearchNarrator` 生成研究故事。
- 聚合 `InvestmentIntelligenceDashboardSnapshot`。

不得：

- 在 Query Service 里重新执行 planner、factor 或 comparison。
- 用 raw SQL payload 在 View 中二次解码。
- 遇到损坏行后静默跳过并显示正常状态；必须 fail-closed。

### 7.2 用户错误映射

新增 `IntelligenceUserFacingError`：

```swift
struct IntelligenceUserFacingError: Equatable {
    let title: String
    let message: String
    let recovery: Recovery
    let diagnosticCode: String
}
```

至少覆盖：

- Provider 未配置 → 前往 AI 设置。
- API Key/鉴权失败 → 检查密钥。
- 市场数据不足 → 更新数据或查看数据源设置。
- Target 未配置 → 设置战略目标。
- 持仓未分类 → 完善分类。
- Runtime/数据库初始化失败 → 重试并提供打开日志入口。
- 网络/限流 → 保留本地结果，提示稍后重试。

主页面不得直接显示 `error.localizedDescription`；`diagnosticCode` 可在详情中复制，用于排查。

## 8. P2：重建 macOS SwiftUI 页面

保留 `IntelligenceSectionView` 作为页面壳，拆分为独立 View 文件：

```text
Views_macOS/Intelligence/
├── IntelligenceSectionView.swift
├── IntelligenceOverviewCard.swift
├── StrategicAllocationCard.swift
├── IntradayDecisionCard.swift
├── MarketDiscoveryCard.swift
├── PortfolioResearchCard.swift
├── IntelligenceHistoryCard.swift
├── AllocationTargetEditor.swift
├── AssetClassAssignmentEditor.swift
└── IntelligenceStatusViews.swift
```

### 8.1 页面壳

- 只处理布局、sheet 选择和键盘焦点，不包含业务计算。
- 宽度 ≥1100 时主内容两列；小于 1100 时单列。优先使用 `ViewThatFits` 或明确的自适应 Layout，不使用 `UIScreen.main.bounds`。
- 页面宽度上限 1320，水平 24、垂直 22，间距统一取 `AppPalette`。
- 加载时使用稳定 skeleton/progress，不让卡片整体跳动。

### 8.2 今日结论卡

- 页面视觉第一层，只显示一个结论。
- 状态包括：建议再平衡、维持配置、暂不可判断、尚未准备。
- 显示一句主因、报告有效期、数据更新时间、可信度提示。
- 主动作根据 readiness 动态变化：设置目标 / 完善分类 / 更新数据 / 开始研究 / 重新评估。

### 8.3 战略配置卡与编辑器

- 每类显示中文名、当前占比、目标占比、偏差。
- 中国市场颜色规则只用于收益涨跌；配置偏差使用 warning/info，不用红绿暗示涨跌。
- Target 编辑器始终展示五个资产类，百分比总和实时显示。
- 只有总和精确为 100%、所有字段合法时允许保存。
- 保存前显示变更摘要；保存即创建新 Target 事件，不能覆盖旧 Target。
- Return 触发安全的保存动作，Esc 取消；表单完整支持键盘 Tab。

### 8.4 盘中执行卡

- 显示 HOLD/EXECUTE 的产品文案，不显示 enum raw value。
- EXECUTE 时展示每个真实持仓的增减方向、目标变化和 provenance 的人话来源。
- HOLD 时展示具体原因，例如“当前配置与战略目标差异均小于 5%”。
- 过期报告明显标注“已过期”，并给“重新评估”。
- 详情 sheet 才展示 target ID、artifact ID、完整约束和审计信息。

### 8.5 市场机会卡

- 展示 Top 5：名称、排名、入选理由、关键因子方向、数据日期。
- “无候选”和“数据不足”必须是两个不同状态。
- 覆盖缺口收纳进 `DisclosureGroup("数据准备情况")`，默认折叠。
- 主页面文案只说“A 股数据源尚未启用，14 个标的暂未参与”，不显示配置文件名。
- 操作名称改为“更新市场机会”，因为按钮实际包含维护数据 + 运行筛选。

### 8.6 组合研究卡

- 展示 `ResearchNarrative.headline`、组合论点、3 条主要风险/信号、证据数量和更新时间。
- 有结果时主动作是“重新研究”，次动作是“查看证据”。
- 没配置 Provider 时显示可点击引导，不出现无解释的 disabled 按钮。
- Artifact ID 仅存在于详情的“技术信息”折叠区。

### 8.7 最近记录

- 使用 `Table`（macOS）展示类型、结论、时间、有效性。
- 支持键盘上下选择、Return 打开详情、右键复制诊断 ID。
- 默认 20 条，Query Service 控制 limit；View 不自行查库分页。

### 8.8 macOS 命令与可访问性

- 在 App commands 增加“投资智能”菜单，至少提供“刷新结果”“运行市场发现”“运行组合研究”，并根据 readiness 动态禁用。
- 给常用操作配置不冲突的快捷键；按钮 tooltip 中显示快捷键。
- 所有图标按钮必须有文字 label/VoiceOver label。
- 支持 Increase Contrast、Reduce Motion、Reduce Transparency。
- 窗口 900×700、1280×800、1600×1000 均不得出现截断或巨量空白。

## 9. P3：把配置移入设置中心

新增：

- `Views_macOS/SettingsIntelligencePanel.swift`
- `Views_iOS/IOSSettingsIntelligencePanel.swift`

修改 `SettingsFocus`，增加 `.intelligence`：

- 标题：`投资智能`
- 副标题：`AI 模型、市场数据与隐私`
- 状态：`已就绪 / 缺少模型 / 数据准备中`

设置面板分三组：

1. **AI 模型**：Provider 预设、Base URL、模型名、API Key、保存、显式清除。
2. **研究数据源**：Tavily、Alpha Vantage、远程 A 股增强通道的状态与配置入口。
3. **隐私与诊断**：哪些数据会发送给模型、打开数据目录、打开诊断日志。

要求：

- Provider 可提供智谱/OpenAI/DeepSeek/自定义预设；预设只填 Base URL 和建议模型，不改已有 Key。
- Base URL 必须是合法 HTTPS URL；模型名非空；Key 只展示“已保存/未保存”。
- 清除 Key 必须二次确认，保存成功用 inline Toast，不弹成功 Alert。
- 主页面点击“前往设置”应直接定位 `.intelligence` 分区，不只打开设置首页。
- `remote-staging-sync.json` 文件名只允许出现在“高级诊断”折叠区。

为支持跨页面精确跳转，把当前 View 私有的 `SettingsFocus` 收敛为 macOS/iOS 可共用的 `AppSettingsSection`（放在 Core 的 App 导航模型中）；AppModel 只发布待跳转 section，Settings View 消费后清空，避免 Core 反向引用 SwiftUI View 类型。

## 10. P4：iOS 同步与收尾

重写 `Views_iOS/IOSIntelligenceSectionView.swift`，复用同一 Dashboard DTO 和文案 formatter：

- 单列呈现今日结论、战略配置、盘中执行、市场机会、组合研究、最近记录。
- Target 编辑和分类编辑使用 sheet/navigation。
- iOS 与 macOS 对同一 Artifact 必须展示相同结论、原因和有效状态。
- iOS 不复制业务判断，不单独维护另一套状态矩阵。

## 11. 文件级改动清单

### 11.1 新增

- `InvestmentIntelligenceV2/Persistence/StrategicAllocationTargetStore.swift`
- `InvestmentIntelligenceV2/Persistence/StrategicAssetClassAssignmentStore.swift`
- `InvestmentIntelligenceV2/Presentation/InvestmentIntelligenceDashboardSnapshot.swift`
- `InvestmentIntelligenceV2/Presentation/IntelligencePresentationFormatter.swift`
- `Core/AppModel/InvestmentIntelligenceV2Dashboard.swift`
- `Core/AppModel/InvestmentIntelligenceV2Materials.swift`
- `Views_macOS/Intelligence/` 下 8 个拆分 View（见 §8）
- `Views_macOS/SettingsIntelligencePanel.swift`
- `Views_iOS/IOSSettingsIntelligencePanel.swift`
- 对应 Target Store、分类、Dashboard projector、错误映射和 UI 回归测试文件

### 11.2 修改

- `InvestmentIntelligenceV2/Decision/StrategicAllocationPolicy.swift`
- `InvestmentIntelligenceV2/Presentation/PresentationLayer.swift`（或拆分后缩小）
- `Core/AppModel/InvestmentIntelligenceV2Runtime.swift`
- `Core/AppModel.swift`
- `Core/Models/AppEnums.swift`（增加共用的 `AppSettingsSection` 路由）
- `InvestmentIntelligenceV2/Persistence/CanonicalStorePaths.swift`
- `Views_macOS/Intelligence/IntelligenceSectionView.swift`
- `Views_macOS/SettingsSectionView.swift`
- `Views_iOS/IOSIntelligenceSectionView.swift`
- `Views_iOS/SettingsSectionView.swift`
- `QiemanDashboardApp.swift`
- `project.yml`（如 XcodeGen 未自动覆盖新文件）

### 11.3 删除/迁移完成后清理

- 当前页面内 `providerConfigCard`、`LabeledTextField`。
- `latestIntelligenceError` 等被新 Dashboard state 取代的零散 Published 字段。
- 所有主页面 raw diagnostics 文案。
- `LivePortfolioDecisionMaterials` 中当前权重复制成 Target 的逻辑。

## 12. 测试方案

### 12.1 Core / Persistence

- Target 五类完备、权重和、重复类、负数、ID 自洽校验。
- Target append-only 写入、幂等、current 指针恢复、损坏文件 fail-closed。
- 旧“当前配置伪 Target”不会被导入，也不会出现在有效 Dashboard 结果中。
- 用户分类、系统识别、未解析分类的优先级与持久化。
- 当前持仓权重精确归一；未知分类不被默认为 `.alternative`。
- 重启恢复 Target 与分类。

### 12.2 Runtime / Workflow

- 无 Target 不运行 WF1/WF3、不写 Artifact、返回 recovery `.configureTarget`。
- 60/40 → 50/50 产生 target provenance 的非零动作。
- 偏差在 5% 内产生 HOLD，原因稳定可读。
- workflow 成功后 Dashboard snapshot 一次性刷新。
- workflow 失败不会残留 running 状态，也不会覆盖上一次有效结果。

### 12.3 Presentation

- never-run、missing-target、unclassified、data-gap、provider-missing、running、failed、expired、hold、execute 全状态 golden tests。
- Query Service kind 隔离、时间倒序、limit、损坏行 fail-closed。
- Narrator 不改变 decision status、plans、score 或 target。
- 中文日期随 Locale 输出；技术 ID 不进入首页 DTO 的 display text。

### 12.4 UI 回归

扩展 `UIExperienceRegressionTests`：

- 投资智能主页面源码不得包含：`remote-staging-sync.json`、`universe v`、`current − target`、`provenance 全程可溯`、`最新决策 Artifact`、`API Key（Keychain）`。
- Provider 表单只能存在于 Settings Intelligence Panel。
- macOS/iOS 均引用统一 Dashboard DTO。
- 页面壳不得直接引用 `GRDBRepository` 或 `.queue.read`。
- 所有 disabled 主动作旁必须存在可见原因或 recovery action。

### 12.5 构建验证

按顺序执行：

```bash
cd macos-app && swift test
cd macos-app && swift build -c release
xcodegen generate
xcodebuild -project QiemanDashboard.xcodeproj -scheme QiemanDashboard -configuration Debug build
xcodebuild -project QiemanDashboard.xcodeproj -scheme QiemanDashboard-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

若本机 AppLaunch 类测试仍命中既有环境崩溃，必须单独记录 HEAD 对照；不得用该理由跳过其他失败。

## 13. 分批提交建议

每批必须独立编译、测试全绿：

1. `fix(intelligence-v2): 接入真实战略目标与持仓资产分类`
2. `feat(intelligence-v2): 增加统一 dashboard presentation snapshot`
3. `feat(macOS): 重构投资智能产品主页`
4. `feat(settings): 迁移投资智能模型与数据源配置`
5. `feat(iOS): 同步投资智能 V2 产品展示层`
6. `test(intelligence-v2): 补齐状态矩阵与双端体验回归`

不得把 P0-P4 全塞进一个无法审查的超大提交。

## 14. 最终验收清单

- [ ] 首页第一屏能看到明确结论、理由、有效期和下一步。
- [ ] 没有战略目标时不会生成伪“持有不动”结论。
- [ ] 所有基金不再无条件归为“其他/另类”。
- [ ] 用户能设置五类战略目标并查看历史。
- [ ] 市场数据不足和确实没有机会被明确区分。
- [ ] Workflow 错误可见、可恢复、可复制诊断码。
- [ ] AI 配置已移入设置，Key 只存 Keychain。
- [ ] 主页面没有 raw Artifact/config/file-name/debug 文案。
- [ ] 研究结果能查看论点、信号、证据摘要和历史。
- [ ] macOS 键盘、VoiceOver、深浅色和窄窗口通过。
- [ ] iOS 与 macOS 状态语义一致。
- [ ] `swift test`、release build、macOS/iOS xcodebuild 全绿。

## 15. 参考约束

- `docs/adr/D000-strategic-target-provenance.md`
- `docs/adr/D001-sizing-provenance.md`
- `docs/adr/D004-decision-replay-boundary.md`
- `docs/design-system.md`
- `docs/investment-intelligence-rollout.md` Epic 12 / PRES-1
- `AGENTS.md` 的 V2 唯一链路、DecisionValidator、迁移只追加、双端同步约定
