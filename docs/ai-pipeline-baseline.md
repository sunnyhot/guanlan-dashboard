# AI 研判管线基线文档

> 本文档冻结 2026-08-05 的三条 AI 链路行为契约,作为「投资智能改造」(Investment Intelligence)的安全网。
> 任何改造这些链路的 PR,都应先读本文档 + 对应的 `*CharacterizationTests.swift`,确认不会无声破坏既有契约。
> 行数/字段以代码为准,本文档过期时以 `swift test` 中的 characterization 测试为最终事实来源。

## 目录

1. [三条链路总览](#1-三条链路总览)
2. [链路 A:趋势研究(TrendResearch)](#2-链路-a趋势研究trendresearch)
3. [链路 B:下一小时盘中研判(NextHourGuidance)](#3-链路-b下一小时盘中研判nexthourguidance)
4. [链路 C:AI 趋势跟踪清单(TrendTracking)](#4-链路-c-ai-趋势跟踪清单trendtracking)
5. [磁盘文件契约](#5-磁盘文件契约)
6. [Evidence ID 生成规则](#6-evidence-id-生成规则)
7. [SubmitTrendReportTool 校验链](#7-submittrendreporttool-校验链)
8. [时间尺度隔离机制](#8-时间尺度隔离机制)
9. [投资智能改造的复用边界](#9-投资智能改造的复用边界)

---

## 1. 三条链路总览

```
┌─────────────────────────────────────────────────────────────────┐
│  链路 A:趋势研究(分模块错峰/手动)                                  │
│  AppModel.generateTrendAnalysis(scope:)                           │
│    → TrendResearchAgent.run(多轮 Tool Calling)                   │
│    → SubmitTrendReportTool(校验+归一化)                           │
│    → TrendAnalysisReportStore 落盘                                │
│    → TrendTrackingItem 的唯一数据源                                │
├─────────────────────────────────────────────────────────────────┤
│  链路 B:下一小时盘中研判(60s 轮询,intraday)                        │
│  NextHourGuidanceController → generateNextHourGuidance           │
│    → NextHourGuidanceAgent.run(独立循环,不复用 A 的 Ledger)        │
│    → NextHourGuidanceStore 落盘                                   │
│    ← 单向接收 A 的最新报告作为「旧研判边界」参考                      │
├─────────────────────────────────────────────────────────────────┤
│  链路 C:AI 趋势跟踪清单(用户驱动)                                   │
│  用户在链路 A 的行动候选上点击「加入跟踪」                            │
│    → AppModel.addTrackingItem(from: TrendActionCandidate)        │
│    → TrendTrackingStore 落盘                                      │
│    ← 数据只来自链路 A,与链路 B 无数据互通                            │
└─────────────────────────────────────────────────────────────────┘
```

**关键不变量(改造时不得破坏)**:
- 链路 A 与链路 B **双向互斥**:任一运行中,另一不启动(见第 8 节)。
- 链路 B 的结果**不会**创建 TrendTrackingItem(模型不兼容:NextHourGuidanceAction vs TrendActionCandidate)。
- **P5 回指契约(2026-08-19 增补)**:盘中 context 可含 `lastCloseReview`(仅昨天/上一交易日的复盘「明日关注」,周末跨度 ≤3 天);提交工具新增**可选** `followup_reviews`(item_index/status/note/evidence_ids);净化规则——confirmed 必须挂**当日**有效证据(昨日发布的外部证据不算),否则强制降级 inconclusive;越界/重复丢弃;回指与 actions 校验解耦,回指问题不 fail 提交;无 lastCloseReview 时行为与旧版逐字节一致。输出 `NextHourGuidanceReport.followupReviews`,旧存档解码为空。详见 docs/2026-08-19-p5-followup-review-contract-change.md。
- 链路 C 的唯一创建入口是 `addTrackingItem(from:report:)`,无自动条件求值。
  > **2026-08-19 sunset 注记(方案 A,总计划 #12)**:链路 C 进入退场。UI 写入入口已切换——行动候选「加入关注」按钮改为 `addDecisionCase(from:report:)` 直接创建 DecisionCase(kind=.trendAction,caseKey `trend:` 前缀,与迁移键 `legacy:` 互为去重);旧清单 UI 移出页面,通知深链改路由到案例详情(迁移保持 ID 稳定)。`addTrackingItem` 模型函数与落盘格式保留(N+2 移除),本条不变量在模型层仍然成立。

---

## 2. 链路 A:趋势研究(TrendResearch)

### 2.0 分模块运行与调度

链路 A 不再在每个定时点生成整份报告，而是用 `TrendResearchRunScope` 增量更新并在本地合并上一份已校验报告：

| scope | 自动时刻 | 本次生成 | 复用 |
|---|---|---|---|
| `marketRadar` | 每日 09:00 | marketOutlook / sectors / opportunities | 组合、持仓、行动 |
| `closeReview` | 每日 21:00 | assetTrends（当日涨跌归因） | 市场雷达、组合长期判断、行动 |
| `longTerm` | 每周日 20:00（错过后下一个 20:00 窗口补跑） | portfolio / horizons / assetTrends / keyAssets / actions | 市场雷达 |
| `full` | 首次无基线或显式完整分析 | 全部模块 | 无 |

盘中链路 B 仍按原交易时段运行。`TrendReportDraftStore` 以旧报告预填非本次模块，旧 evidence 同步写入新运行 Ledger；最终仍必须经过 `SubmitTrendReportTool` 统一归一化和完整 Validator。市场雷达若检测到持仓代码已经变化、增量合并无法保持完整性，会一次性回退为 `full`。

各模块的新鲜度时间独立保存在 `TrendAnalysisSettings.lastModuleGeneratedAt`。增量更新只推进当前模块时间；`full` 同时推进三项。旧配置首次加载时用旧报告 `generatedAt` 初始化三项，避免早晨市场雷达更新后把昨晚的收盘复盘误标为“今天已复盘”。

收盘复盘采用同日、非补跑语义：21:00 后当日自动窗口至多尝试一次，错过后不会在次日启动时补做。完成后把当晚报告和当晚组合涨跌冻结到独立的 `market-close-review.json`；次日 21:00 前页面只展示这份上一交易日快照，不读取启动后刷新的盘中持仓，也不受次日市场雷达覆盖共享趋势报告的影响。收盘复盘以冻结组合涨跌和逐只持仓归因为主，不依赖「全市场机会雷达」的 marketWide 结论；同时点已有的市场环境只作为可选补充。标题随快照日期显示为「今日收盘复盘」「昨日收盘复盘」或「最近收盘复盘」。旧版本若尚无冻结快照、生成了「无全市场结论」空快照，或共享报告已被次日模块覆盖，会从本地 `ai-analysis-logs/*-closeReview-*.jsonl` 的 `run_completed` 恢复已校验报告，并从同次运行的 `get_portfolio_assets` 结果恢复当晚冻结持仓，全程不发起网络或模型请求。自动窗口在发起前即持久化尝试键，失败后不会被 60 秒轮询或反复启动 App 重试；用户仍可手动更新。

**2026-08-19 复盘生成提速注记(#1/#2/#3/#5)**:①分批批量 5→8(`TrendReportDraftStore.assetBatchSize`,schema/描述/prompt 均随常量);②submit 拒批后,校验错误以「拒批教训」correction 前移注入(每条去重一次、单次最多两条),避免后续批次重复同类拒批;③已接受的 asset batch 提交,其 assistant tool_call 参数在后续上下文中替换为短桩(id/名称保留,callID 链不断;诊断日志仍存全量);④closeReview 且持有基金 ≥12 时,Agent 先走**批次并行 fan-out**:harness 预取只读数据 → 每批一次并行单轮生成 → 复用同一提交校验与组装终检链;任何环节失败返回 nil 回退原交互循环(草稿已暂存的批次保留,按 remaining 继续)——行为契约不变,仅生成方式并行化。fan-out 的 E2E 测试缺口暂以契约源码断言 + 生产运行验证覆盖。

中间数据按来源复用：基金披露磁盘缓存 24 小时、Tavily 语义目标缓存 6 小时、SEC/Alpha Vantage 按接口时效缓存；同一运行内工具签名继续去重。`closeReview` 不调用 Tavily，`marketRadar` 不读取个人持仓工具。

### 2.1 调用图

```
UI / 定时器 / 手动
  └─ AppModel.startTrendAnalysis(userInitiated:scope:)
       └─ Task { generateTrendAnalysis(userInitiated:createdAt:scope:) }
            ├─ checkTrendAIConnection / capability probe       (must supportToolCalls, fail-closed)
            ├─ refreshTrendResearchMarketData(...)             [:201, :450]
            ├─ fundLookThroughClient.fetchDisclosures          [:228]
            ├─ makeTrendResearchSnapshot(...)                  [:368]
            │     → TrendResearchSnapshot (runID, assets, marketQuotes, sectors,
            │       expectedFundCodes, privacyMode, dataAsOf ...)
            ├─ TrendAgentRunLogStore().beginRun(...)           [:159]  (覆盖写 trend-agent.log)
            ├─ AIAgentDiagnosticRecorder                       (每次运行独立 JSONL)
            │     → <dataDir>/ai-analysis-logs/<date>-<scope>-<runID>.jsonl
            └─ trendResearchAgent.run(snapshot:settings:...eventHandler:)   [:290]
                 ↑ AppModel.trendResearchAgent: any TrendResearchAgentProtocol
                   ↓ TrendResearchAgent.run                        [TrendResearchAgent.swift:220]
                     - 新建 in-memory TrendEvidenceLedger (actor) + TrendReportDraftStore
                     - while 循环: client.complete(...) → 处理 toolCalls → registry.execute
                     - submit_trend_report 返回 .report(TrendAnalysisReport) 即 return
                     - 失败/取消: makeFailure artifact + .auditArtifactReady 事件
            ├─ eventHandler:
            │    ├─ .auditArtifactReady → saveTrendAgentRunArtifact       [:298,:798]
            │    │     → TrendAgentRunArtifactStore.save
            │    │       写 <dataDir>/trend-agent-runs/<YYYY-MM-DD>-<runID>.json
            │    │       原子写 + 0o600,保留最近 20 个
            │    └─ 其他事件 → handleTrendAgentEvent → appendTrendProgress
            ├─ 成功: saveTrendAnalysisReport(report)            [:306,:313]
            │     → TrendAnalysisReportStore.save
            │       写 <dataDir>/trend-analysis-report.json (单文件最新覆盖,无历史)
            └─ saveTrendAnalysisSettings()
```

### 2.2 Agent 协议(注入点)

```swift
// Core/TrendResearch/TrendResearchAgent.swift:11
protocol TrendResearchAgentProtocol: Sendable {
    func run(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings,
        officialSourceSettings: OfficialSourceSettings,
        alphaVantageSettings: AlphaVantageSettings,
        scope: TrendResearchRunScope,
        baselineReport: TrendAnalysisReport?,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) -> Void
    ) async throws -> TrendAnalysisReport
}
```

AppModel 持有 `var trendResearchAgent: any TrendResearchAgentProtocol`(默认 `TrendResearchAgent()`)。
测试用 `FakeTrendResearchAgent`(`TrendAnalysisAppModelTests.swift:201`)注入,不走真实网络。

### 2.3 运行预算(TrendResearchRunPolicy)

定义在 `TrendResearchAgent.swift:42`。这些常量被 `AgentRunPolicyCharacterizationTests` 冻结:

| 常量 | 值 | 说明 |
|---|---|---|
| `maxTurns` | 18 | 基础轮次上限 |
| `expandedMaxTurns` | 48 | 扩张后硬上限 |
| `maxToolCalls` | 40 | 基础工具调用上限 |
| `expandedMaxToolCalls` | 96 | 扩张后硬上限 |
| `preferredWebSearches` | 6 | 期望搜索次数 |
| `maxWebSearches` | 10 | 基础搜索上限 |
| `expandedMaxWebSearches` | 12 | 扩张后搜索上限 |
| `reservedSubmitToolCalls` | 8 | 研究阶段不可消耗的结构化提交预留预算；触及边界后停止搜索并进入提交 |
| `maxInvalidSubmissions` | 4 | 无效提交上限(第 5 次抛错) |
| `maxPlainTextResponses` | 2 | 纯文本响应上限 |
| `perRequestTimeoutSeconds` | 180 | 单请求超时 |
| `totalTimeoutSeconds` | 1800 | 总超时 |
| `temperature` | 0.2 | 采样温度 |
| `maxToolResultBytes` | 32KB | 单工具结果截断 |

`effectiveLimits` 随 assetCount/sectorCount/reportAssetCount 扩张,但被 expanded 硬上限钳制。

### 2.4 Harness 强制不变量

submit 前必须满足(否则 submit 被拒并要求重试):
- `get_portfolio_overview` 已读
- `assetCoverageComplete`
- `lookThroughCoverageComplete`(若有穿透快照)
- `get_market_snapshot` 已读(快照存在指数、基金估值或底层证券行情时；用于当日涨跌归因)
- `official_sec_research`(若 SEC 配置且有美股标的)
- `alpha_vantage_research`(若配置)
- `web_search`(若 Tavily 配置,至少一次)
- `web_search` 全市场机会覆盖（若 Tavily 配置且可用，必须完成 assetClass / index，并逐一完成科技成长、医药消费、金融地产、制造新能源、周期资源、防御价值六个 sector 分组；聚合目标固定使用“大类资产配置”与“大盘宽基指数”；候选来自受控研究池，不要求已在当前持仓中）
- Tavily 额度、鉴权或服务不可用时进入安全降级：停止重复联网请求，保留本地行情/穿透/官方证据形成复盘，但强制清空 `opportunities` 与 `actions`，不得用模型记忆或持仓长期观点填充全市场机会。
- 基金 F10 `statistical_industries` 属于宽泛统计行业口径，只用于披露结构说明；不得直接生成投资板块卡片或作为 `sectors` 名称，投资板块必须结合底层证券、ETF/基金主题和持仓来源归纳。
- `assetTrends.impactText` 必须提供带底层证券行情/外部研究证据的「涨跌归因」，或明确输出「原因待确认」；不得用市值、累计盈亏、持仓占比、穿透名单或净值涨跌本身替代原因。

工具结果按 `executedByID`/`executedBySignature` 缓存复用；受控全市场目标按结构化 `research_target` 使用跨运行磁盘缓存，不因模型改写查询文案而重复消耗额度；web_search 不可恢复失败会熔断，额度/鉴权失败还会跨运行冷却。

### 2.5 失败/取消契约

任何错误或取消,都**先**发 `.auditArtifactReady(makeFailure(...))` **再**发 `.failed`/`.cancelled`。
`makeFailure` artifact 含 toolCalls / canonicalEvidence / message 字段(被 `AgentRunPolicyCharacterizationTests.testFailureArtifactContainsStructuredFields` 冻结)。

---

## 3. 链路 B:下一小时盘中研判(NextHourGuidance)

### 3.1 调用图

```
NextHourGuidanceController.restartNextHourGuidanceSchedulerLoop
  每 60s 轮询 → runNextHourGuidanceIfNeeded()
    NextHourGuidanceSchedule.default.dueSlot(at:lastAttemptedSlotKey:)   // 交易窗口判定
    → generateNextHourGuidance(slot:generatedAt:userInitiated:)
        1. 刷新持仓 + 大盘指数
        2. nextHourEligibleRows(for: slot)          // 按窗口筛选 A股/场内/场外基金
        3. trendCapabilityProbe(provider)           // 验证模型支持工具调用
        4. makeNextHourLookThrough()                // 基金穿透快照
        5. makeNextHourGuidanceContext()            // 组装 context(含链路 A 的旧研判边界)
        6. makeNextHourResearchSnapshot()
        7. nextHourGuidanceAgent.run(...) → NextHourGuidanceReport
        8. saveTrendAgentRunArtifact(makeNextHour(...))   // 审计产物
        9. nextHourGuidanceArchive.report = report; saveNextHourGuidanceArchive()
       10. nextHourGuidanceNotificationSender(report)

手动入口: startNextHourGuidance() → dueSlot 或 manualSlot → generateNextHourGuidance(userInitiated: true)
```

### 3.2 Agent 内部

`NextHourGuidanceAgent.run`(`Core/NextHourGuidance.swift:612`):
- 每次运行**新建** `TrendEvidenceLedger()`(actor,非持久化,**不复用**链路 A 的 ledger)
- 工具:`get_live_market_context` / `get_fund_lookthrough` / `official_sec_research` / `web_search` / `submit_next_hour_guidance`
- 预算:`maxTurns=10` / `maxToolCalls=20` / `maxWebSearches=4` / `minimumWebSearchAttempts=2` / `totalTimeoutSeconds=300`
- Tavily 与长期趋势研究共享跨启动磁盘缓存，但盘中链路只接受 10 分钟内结果
- 校验:`validate()` + `TrendClaimEvidencePolicy().validateExecution()` 双层把关

### 3.3 调度窗口(NextHourGuidanceSchedule)

| 窗口 | scope |
|---|---|
| 09:15 / 10:15 / 11:15 / 13:15 / 14:15 | 盘中(market),不含场外基金 |
| 14:50 | 收盘(closing),**含场外基金** |

午休(11:30-13:00)和周末不运行。同日重复 slot 去重。手动 slot 跨午夜有效。

### 3.4 与链路 A 的单向数据流

`NextHourGuidanceContext` 的 `latestTrendHeadline` / `latestTrendActions` / `latestAssetConclusions` 字段**单向**来自链路 A 的 `trendReport`(`TrendAnalysisReport`),作为 prompt 的「旧研判边界」参考。
**没有反向数据流**:链路 B 的结果不写回链路 A 的任何对象。

---

## 4. 链路 C:AI 趋势跟踪清单(TrendTracking)

### 4.1 调用图

```
用户在「今日研判」行动候选上点击「加入跟踪」
  EnhancementTodayPanel.swift:356  model.addTrackingItem(from: action, report: report)
    → addTrackingItem(from: TrendActionCandidate, report: TrendAnalysisReport) -> Bool
        dedupeKey 去重(同标的+动作+isActive) → insert → saveTrendTrackingItems()
```

### 4.2 状态管理(全部人工触发,无自动条件求值)

| 方法 | 行为 |
|---|---|
| `markTrackingItem(id:status:note:)` | 通用状态变更 + statusHistory append |
| `snoozeTrackingItem(id, days)` | → `.processed` + snoozeUntil |
| `resumeTrackingItem(id)` | → `.observing` |
| `endTrackingItem(id)` | → `.ended` |
| `removeTrackingItem(id)` | 物理删除 + 清空 selectedTrendTrackingItemID |
| `recoverSnoozedTrackingItems(now:)` | 启动/刷新时暂缓到期自动恢复为 `.observing` |
| `hasActiveTrackingItem(for:)` | UI 按钮态判定(按 assetName/assetCode/assetKey 三路匹配) |

**关键不变量**:`triggerConditions` / `invalidatingConditions` 是**自然语言字符串数组**,代码注释明确「第一版人工管理,不根据自然语言条件伪造自动触发」。任何 status 变更都由用户手动触发。

### 4.3 TrendTrackingItem 字段表

定义在 `Core/Trend/TrendTrackingModels.swift:64`。**无 schemaVersion**,向后兼容纯靠 Codable `decodeIfPresent ?? 默认值`。

| 字段 | 类型 | 可空 | 默认/编解码行为 |
|---|---|---|---|
| `id` | `UUID` | 否 | decode 缺失则 `UUID()` |
| `sourceReportID` | `UUID` | 否 | 缺失则 `UUID()` |
| `sourceGeneratedAt` | `String` | 否 | 缺失则 `""` |
| `assetKey` | `String?` | 是 | encodeIfPresent |
| `assetName` | `String` | 否 | 缺失则 `""` |
| `assetCode` | `String?` | 是 | encodeIfPresent |
| `action` | `TrendActionKind` | 否 | 缺失则 `.watch` |
| `reason` | `String` | 否 | 缺失则 `""` |
| `confidence` | `TrendConfidence` | 否 | 缺失则 `score:0, label:"低"` |
| `triggerConditions` | `[String]` | 否 | **自然语言**,缺失则 `[]` |
| `invalidatingConditions` | `[String]` | 否 | **自然语言**,缺失则 `[]` |
| `createdAt` | `String` | 否 | 缺失则 `""` |
| `status` | `TrendTrackingStatus` | 否 | 缺失则 `.observing` |
| `snoozeUntil` | `String?` | 是 | encodeIfPresent;status≠.processed 时被清空 |
| `statusHistory` | `[TrendTrackingStatusChange]` | 否 | 缺失则 `[]` |

派生属性:`isActive`(status≠.ended)、`dedupeKey`(assetKey 或 `name|code` lowercased 兜底 + `|` + action.rawValue)

`status` 枚举:observing / approaching / triggered / invalidated / staleData / processed / ended

`statusHistory` 元素 `TrendTrackingStatusChange`:`at: String` / `from: TrendTrackingStatus?` / `to: TrendTrackingStatus` / `note: String`

---

## 5. 磁盘文件契约

所有文件 URL 定义在 `Core/AppModel/ComputedProperties.swift:62-88`,基于 `dataDirectoryURL`。

| 文件 | 路径 | 编码 | 权限 | schemaVersion | 历史 | Store |
|---|---|---|---|---|---|---|
| 趋势报告 | `trend-analysis-report.json` | prettyPrinted + sortedKeys | **0o600** | `currentSchemaVersion=2`,解码宽容 | **单文件覆盖写,无历史** | `TrendAnalysisReportStore` |

> 2026-08-27(W4.2):TrendHorizonView/TrendSectorView/TrendOpportunity/TrendActionCandidate 新增 `whatWouldChange: String`,旧报告 `decodeIfPresent ?? ""` 兜底,**未 bump schemaVersion**;UI 对空值降级用 counterSignals 首条。
| 收盘复盘冻结快照 | `market-close-review.json` | prettyPrinted + sortedKeys | **0o600** | 3 | 单文件覆盖，只保留最近一次成功复盘 | `MarketCloseReviewArchiveStore` |
| 趋势设置 | `trend-analysis-settings.json` | prettyPrinted | **0o600** | 无 | 单文件覆盖 | `TrendAnalysisSettingsStore`(API Key 在 Keychain) |
| Agent 日志 | `trend-agent.log` | 文本 | **0o600** | 无 | 每次运行覆盖写 header + append 进度 | `TrendAgentRunLogStore` |
| AI 完整诊断日志 | `ai-analysis-logs/<YYYY-MM-DD>-<scope>-<runID>.jsonl` | 每行独立 JSON + sortedKeys | **0o600**（目录 0o700） | 无 | 最近 20 份且总量不超过 200 MB；始终保留最新一份 | `AIAgentDiagnosticRecorder` |
| Agent 审计产物 | `trend-agent-runs/<YYYY-MM-DD>-<runID>.json` | prettyPrinted | **0o600** | 无 | **最近 20 个**,超出按 mtime 删除 | `TrendAgentRunArtifactStore` |
| 下一小时研判 | `next-hour-guidance.json` | prettyPrinted + sortedKeys | **0o600** | **无** | 单文件覆盖 | `NextHourGuidanceStore` |
| 跟踪清单 | `trend-tracking-items.json` | prettyPrinted + sortedKeys | **0o600** | **无** | 单文件覆盖 | `TrendTrackingStore` |
| 基金穿透缓存 | `fund-look-through-cache.json` | — | — | — | — | `FundLookThroughClient` |
| Tavily 搜索缓存 | `~/Library/Caches/QiemanDashboard/AIResearch/Tavily/*.json` | prettyPrinted + sortedKeys | **0o600** | 1 | 每请求一文件，最多 64 个；长期 6 小时、盘中读取门槛 10 分钟 | `TrendWebSearchResponseCache` |
| (已预留)组合洞察快照 | `portfolio-insight-snapshots.json` | — | — | — | — | URL 已定义,暂无 Store 消费 |

完整诊断日志通过 `AIAgentDiagnosticLog.recorder` TaskLocal 贯穿趋势研究、市场雷达、收盘复盘、长期研判、盘中 V1/V2 子 Agent 与 DecisionCase 专项研究。按执行顺序保存：运行元数据、完整模型 messages/tools 请求、完整 assistant 响应、工具参数、工具原始结果、实际回灌模型的结果、校验错误、重试以及最终报告或失败状态。API Key、Authorization、Cookie、Token、Secret 和 Password 字段递归替换为 `[redacted]`；为了定位持仓归因问题，其余业务数据会保留，因此日志只应在本机受控范围内使用。设置页“AI 研判 → 完整诊断日志”可直接打开目录。

### 当前已知不一致(改造时需注意)

1. **`next-hour-guidance.json` 与 `trend-tracking-items.json` 无 schemaVersion**。向后兼容纯靠 Codable 默认值兜底,任何字段重命名都会静默吞掉旧数据。投资智能改造若引入 DecisionCase,应从一开始就带 schemaVersion。

---

## 6. Evidence ID 生成规则

Evidence ID 由 **App 生成**(非模型创造),对同一快照**确定性可复现**。`TrendResearchToolTests.testToolsRecordStableEvidenceIDs` 是此契约的快照验证。

| 来源 | ID 模板 | 出处 |
|---|---|---|
| 组合概览 | `portfolio:overview:<runID>` | TrendResearchToolRegistry:71 |
| 持仓标的 | `portfolio:asset:<asset.id>` | TrendResearchToolRegistry:191 |
| 基金穿透聚合 | `portfolio:look-through:<runID>` | TrendResearchToolRegistry:293 |
| 单基金穿透 | `fund:look-through:<fundCode>:<asOf>` | TrendResearchToolRegistry:370 |
| 行情(指数) | `market:index:<kind>:<quotedAt>` | TrendResearchSnapshot:398 |
| 行情(基金估值) | `market:fund-estimate:<code>:<quotedAt>` | TrendResearchSnapshot:423 |
| 行情(基金底层证券) | `market:stock:<code>:<quotedAt>` | TrendResearchSnapshotBuilder，由公开披露持仓筛选并刷新当日行情 |
| 平台信号 | `platform:<source>:<platformActionID>` | TrendResearchSnapshot:328 |
| 主理人信号 | `manager:<kind>:<targetID??eventID>` | TrendResearchSnapshot:355 |
| SEC 官方 | `official:sec:filing:<accessionNumber.lowercased()>` | SECOfficialResearchTool:235 |
| Alpha Vantage | 由 client 生成 `evidenceID` | AlphaVantageResearchTool:198/273/367 |
| Tavily | `web:tavily:...`(client 给 `evidenceID`,SHA256 前缀去重) | TavilyWebSearchTool:247 |

**特征**:均由「来源类型 + 业务主键 (+ runID/时间戳)」拼接。

---

## 7. SubmitTrendReportTool 校验链

定义在 `Core/TrendResearch/SubmitTrendReportTool.swift`。这是链路 A 的安全闸口,投资智能改造最核心的复用/参考对象。

### 7.1 完整流程

```
execute(argumentsJSON, context)
  1. 取出 report 对象(JSONSerialization)
  2. 解码 TrendAnalysisReport(自定义 init(from:) 对缺失字段宽容)
     → 失败: validationFailure
  3. schemaVersion == currentSchemaVersion(=2)?
     → 否: validationFailure("旧结构不能绕过 Claim-Evidence 安全门")
  4. collectReferencedEvidenceIDs(report)
     → 收集 sectors/marketOutlook/opportunities 引用的所有 evidenceID
  5. 证据归一化:
     for id in referencedIDs:
       ledger.canonical(for: id) 存在? → 保留;不存在 → **静默丢弃**(不报错)
     report.evidence = canonical(只含 ledger 真实产出)
  6. externalSignalStatus(for: canonical):
     只有 canonical 含 external research 证据(SEC/Tavily)才置 .available
  7. normalizedSourceStatuses:
     由 ledger 真实证据派生每个数据源状态(覆盖模型自报)
  8. insufficientEvidenceReasons(数据不足检测,见 7.2)
     → 任一 reason 存在:
        normalizedActions = [](清空所有行动)
        disposition = .insufficientEvidence
        short horizon/资产 short 方向强制降 uncertain + exemptionReason
  9. TrendClaimEvidencePolicy 关联性降级:
     sector/market/opportunity 的 direction≠.uncertain 但 claimEvidence 不含同 key 关联证据
     → 降级 uncertain + warning
  10. TrendAnalysisValidator.validate(最终校验,见 7.3)
      → 失败: validationFailure + submitValidationError 信封 + remainingRepairAttempts
      → 成功: 返回 .report(normalizedReport),Agent 结束
```

### 7.2 数据不足检测(insufficientEvidenceReasons)（2026-08-28 起无 webSearch 项）

任一条件成立即触发清空行动 + 降级:

| 检测项 | 触发条件 |
|---|---|
| 持仓报价 | source 非 success |
| 主要指数(上证综指/沪深300/创业板) | 非 success **或** 不满足当前时段新鲜度(fresh/previousSessionClose) |
| 基金披露 | itemCount < 期望基金数 |

> **2026-08-31 SEC 移除**：官方源子系统整体下线（客户端/工具/设置字段/UI）。officialSource 状态恒 notConfigured；
> externalSignalStatus 仅由 AlphaVantage 驱动；枚举 case 保留仅供旧报告解码。
>
> **2026-08-28 Tavily 移除**：联网搜索子系统整体下线（客户端/工具/Governor/设置/同步）。
> webSearch 不再参与数据不足检测；opportunities 无条件清空（不得用记忆填充）；
> 链路 B 盘中买卖门禁改为永久生效（无联网源 → 只能 hold）；`sourceKind=.webSearch`
> 与 `TrendDataSource.webSearch` 枚举 case 保留仅供旧报告解码。

### 7.3 TrendAnalysisValidator 校验项

> **2026-08-31 终审爆量四修复（v4.8.0 后首个真实运行实证）**：模块入库级 `TrendReportEvidenceSanitizer`
> 前置完成终审规则——①幻觉证据 ID 剔除(对照账本)；②周期缺关联支持证据→App 降 uncertain+补
> exemptionReason/待观察信号/whatWouldChange；③行动无本地事实证据→整条剔除，keyAssets 补
> counterSignals，disclaimer 自动补写「非投资建议」，TrendWarning 解码 impact→detail 回退；
> ④修复预算随基金数缩放(基础+每 8 只基金 1 次)；⑤新工具 `get_evidence_index` 随时可查真实证据 ID。

定义在 `Core/Trend/TrendAnalysisValidator.swift:21`。`validate(_:expectedFundCodes:expectedPrivacyMode:) -> TrendValidationResult` 检查:

- 三个 horizon(short/medium/long)齐全且各一次
- rationale / counterSignals 非空
- disclaimer 含「非投资建议」
- `externalSignalStatus==available ⇔ 存在外部证据`
- 引用的 evidenceID 全部存在于 report.evidence
- confidence score ∈ [0,100];schemaVersion≥2 时 label 必须由 score 派生
- disposition 校验:insufficientEvidence 必须禁用全部行动 + short 降 uncertain
- privacyMode 与快照一致
- marketOutlook 与 sectors 至少一项且不可同名重复
- 所有 `expectedFundCodes` 必须出现在 assetTrends
- 行动候选必须有 trigger/invalidating 条件
- **禁用绝对化措辞**:`必须买入/必须卖出/一定上涨/一定卖出/保证上涨/保证收益`
- **W4 结论明确性契约(2026-08-27 起)**:
  1. horizons/sectors/marketOutlook/opportunities 的 rationale 首句必须命中 `TrendAnalysisValidator.directionLeadWords`(看多/看空/看涨/看跌/看淡/看好/偏强/偏弱/偏乐观/偏谨慎/偏防守/偏进攻/中性/观望/防御/防守/进攻/择机/暂不明确),零信息量开头拒批;
  2. `direction==uncertain` 的 rationale 必须含「待观察信号:…」出口;
  3. horizons/sectors/opportunities/actions 的 `whatWouldChange`(作废/升级条件)非空(marketOutlook 无此字段)。
  配套机制:
  - **App 强制降级补写**:`SubmitTrendReportTool.normalized(forceShortUncertainReasons:)` 把短期降为 uncertain 时,由 App 在 rationale 末尾追加「待观察信号:…」并在 whatWouldChange 为空时兜底——降级场景不依赖模型补写。
  - **基线复用补丁**:`TrendBaselineContractPatch`(增量运行复用旧基线数据时,由 App 补方向词前缀/待观察信号/作废条件),防止旧报告把增量运行的新报告整份拒批;模型本次提交的新数据不做静默修补。
  - **2026-08-28 拒批死循环双修复(v4.7.0 线上实证,基金 000369/019524)**:
    1. `storeAssetBatch` 一批内全部基金错误一次性返回(首错即 throw 时期每轮只报一只,整批重交每轮 2-3.5 分钟);
    2. 「涨跌归因：」+无因果证据(`market:stock:`/`vendor:alphavantage:` 前缀)→ App 入库前自动降级为「原因待确认：(缺少可佐证的底层证券当日行情或外部研究证据。原描述：…)」——Tavily 下线后 40 只行情上限外的基金零路径通关,结构性拒批必然复发,此兜底为治本。
    3. 提交前 upfront 告知：prompt(收盘复盘/长期/全量三处契约)注入 `TrendResearchPromptBuilder.attributionCoverageHint`——列出本轮无因果行情路径的基金(`TrendAssetDailyAttributionPolicy.fundCodesLackingCausalEvidence`：无披露/纯债/40 上限未覆盖/抓取失败,美股+AV 已配置除外),要求其 impactText 直接写「原因待确认：」。
  - **v4.6.1 待确认边界 App 兜底(2026-08-28 真实运行实证)**:`TrendAssetDailyAttributionPolicy` 的六词边界表(缺少/未取得/未提供/无法/不足/没有)曾把语义合规的「原因待确认」拒到修复预算耗尽;现在 `TrendReportDraftStore.storeAssetBatch` 入库前经 `appendingMissingEvidenceBoundaryIfNeeded` 补写缺失证据说明(前缀不变、不宣称因果),不再拒批。
  - prompt 侧契约(`TrendResearchPromptBuilder.clarityContract`)同步注入 full 与增量 scope 的提交契约,含 hedge 禁表(可能有机会/不排除/有待观察/建议关注/需持续跟踪/需密切关注/视情况而定)与首句 ≤40 字、全文 ≤120 字约束(长度仅 prompt 约束,Validator 不校验)。

---

## 8. 时间尺度隔离机制

链路 A(长期)与链路 B(intraday)的隔离通过**双向互斥 guard**实现,在同一个 60s 轮询 loop 中顺序 await。

### 8.1 互斥 guard

```
// NextHourGuidanceController.swift:39
runNextHourGuidanceIfNeeded():
  guard trendGenerationState != .generating   // 链路 A 运行中 → 链路 B 不启动

// TrendAnalysis.swift:357
runDailyTrendAnalysisIfNeeded():
  guard nextHourGuidanceGenerationState != .generating   // 链路 B 运行中 → 链路 A 不启动
```

### 8.2 数据层隔离

- 链路 B **单向接收**链路 A 的报告(经 NextHourGuidanceContext),无反向数据流
- 链路 B 的结果(NextHourGuidanceReport)与链路 C 的对象(TrendTrackingItem)**模型不兼容**,无转换路径
- 链路 B 每次运行**新建** TrendEvidenceLedger,不复用链路 A 的 ledger

### 8.3 投资智能改造的影响

改造后若引入 `DecisionCase`,必须保留:
- 长期组合决策(shortTerm/mediumTerm/longTerm)与 intraday 决策的**时间尺度隔离**
- 不允许一个时间尺度自动覆盖另一个
- UI 必须并列展示两者及其关系(如「盘中 sell + 长期 watch」标注「短期防守、长期逻辑待观察」)

---

## 9. 投资智能改造的复用边界

> 这一节是改造的「北极星」参考,沉淀自 Slice 0 评估。

### 9.1 可复用(无需重写)

| 能力 | 出处 | 复用方式 |
|---|---|---|
| 多轮 Tool Calling Harness 循环 | `TrendResearchAgent`(821 行) | 参考循环模式,但**勿提前抽取通用 Harness**(耦合度高) |
| 工具注册表 | `TrendResearchToolRegistry`(576 行) | 直接复用工具集(get_portfolio_overview/assets、get_fund_lookthrough 等) |
| Evidence 登记/溯源/稳定 ID/并发安全 | `actor TrendEvidenceLedger` | 直接复用登记能力 |
| 运行前数据冻结 + 隐私过滤 | `TrendResearchSnapshot`(460 行) | 复用冻结模式 |
| 报告校验 + 数据不足清空行动 | `SubmitTrendReportTool` + `TrendAnalysisValidator` | 参考校验链设计 |
| AlphaVantage 研究工具 | `Core/TrendResearch/` 各工具 | 直接复用（SEC/Tavily 已移除） |
| 基金穿透(行业/资产类别/覆盖率) | `FundLookThrough.swift`(944 行) | 直接复用 `PortfolioLookThroughSnapshot` |
| Fake Agent 注入模式 | `FakeTrendResearchAgent` | 测试复用 |

### 9.2 需新建(现有能力不足)

| 能力 | 原因 |
|---|---|
| 来源独立性 / 同源去重 | 现有 Ledger 只登记,不做独立性判定 |
| 时效评分(per-source 衰减) | 现有只有 freshness 状态,无评分 |
| Claim 级权重 | 现有只做关联性校验,无 claim 级证据权重 |
| 证据冲突检测 | 现有只有 supports/counters 区分,无冲突图 |
| 跨运行持久化证据图谱 | 现有 Ledger 是 in-memory,运行结束即销毁 |
| DecisionCase 状态机 | 全新,现有 TrendTrackingItem 无状态机 |
| 结构化触发条件求值 | 现有 triggerConditions 是自然语言,不可自动求值 |

### 9.3 Harness 抽取策略(重要)

`TrendResearchAgent`(821 行)与 Prompt/HarnessState/ToolRegistry/SubmitTool **强耦合**。

**推荐路径**:新建 `DecisionCaseResearchAgent` 时,先**复制受控子集**(参考 `NextHourGuidanceAgent` 的做法,它就是独立循环而非抽取的通用框架),等三条工作流(TrendResearch / NextHour / DecisionCase)都稳定后,再基于真实共同部分反向抽取。

> **勿提前抽象**——根据想象中的共性提前重构,容易得到参数极多、仍耦合的伪通用框架。

### 9.4 落地路径(垂直切片)

按单一 Case 类型走通完整链路(Models → Store → Policy → UI)再扩展,避免横向 Phase 产生半成品:

- Slice 1:`concentrationRisk` 闭环(含最小 UserDecisionProfile)
- Slice 2:`sectorConcentrationRisk`(复用 FundLookThrough)
- Slice 3:为单 Case 加专项研究(DecisionCaseResearchAgent)
- Slice 4:最小 Evidence Intelligence
- Slice 5:决策状态 + 用户约束
- Slice 6:替换 Tracking 主写入路径(含 sunset)
- Slice 7:复盘 + 更多 Case 类型

---

## 10. 投资决策引擎链路（2026-08-28 新增，M1-M9）

> 蓝图与里程碑详见 `docs/2026-08-28-investment-decision-engine-master-plan.md`。
> 本节冻结已落地链路的行为契约。

### 10.1 模块与依赖

```
Core/MarketData/                    # L1 数据引擎（通用基础设施，不挂 II flag）
  MarketDataEngine(actor)           # fallback 门面：行情[腾讯→东财]/K线[东财→腾讯]/快照[东财→新浪]/NewsNow
  MarketBoardRule                   # 板块识别 + 涨跌停价（BSE30%/科创创业20%/主板ST5%/主板10%）
  MarketBreadthCalculator           # 广度统计（本地计算：涨跌/涨停/成交额）
  TechnicalAnalysisEngine           # L2 规则技术分析（纯函数，六模块 100 分制）
Core/InvestmentIntelligence/
  DecisionContract/                 # L3：CanonicalDecisionScale / MarketPhase(7态) / 结构稳定器 / 数据质量封顶
  MarketSignals/                    # L6：信号模型/抽取/结算/胜率校准/Store(market-signals/*.json + index)
  StrategySkills/                   # L4：15 技能常量库 + 注入器 + regime 路由
  MarketResearchPipeline/           # L7：四档流水线 + 风险否决状态机 + 确定性兜底
Core/Backtest/StrategyRuleBacktester.swift   # L8：技能规则级回测
Core/TrendResearch/
  TrendResearchArgumentCanonicalizer # M7 参数规范化签名
```

### 10.2 Agent 工具新增（TrendResearchToolRegistry）

- `get_market_breadth`：全市场广度（TTL 10 分钟，首算约 15-30s），登记证据 `market:breadth:{date}`
- `get_daily_kline`：日 K + **TA 摘要**（评分/均线/量价/支撑压力/理由），非原始 K 线数组；证据 `ta:{code}:{date}`

### 10.3 信号闭环契约

- 抽取源：① `MarketSignalExtractor`（趋势报告行动候选，kind→方向映射 + 价格正则）；② `MarketResearchPipeline.candidateSignal`（仪表盘狙击点直填）
- 结算口径：**同根 K 线双触先止损**；跳空穿越按开盘价；到期未触发 = expiredUnresolved（计入样本不计入胜率分子）
- 胜率校准：桶 ≥30 可结算样本才干预；factor = clamp(1 + (winRate − 0.7), 0.3, 1.2)（70% 胜率中性锚）
- 反向失效：同标的出现反方向 active 信号 → 旧信号 invalidated(superseded)
- 红线：信号不自动建 DecisionCase、不自动交易；与 Case 正交（Signal=标的级市场判定，Case=组合级决策事项）

### 10.4 护栏链顺序（不可调换）

Decision LLM 输出 → `RiskOverrideStateMachine`（风险否决，单向保守：仅压进攻方向）→ `DecisionGuardrailPipeline`（结构稳定器 → 市场阶段护栏 → 数据质量置信度封顶）。每次修正落 `DecisionScoreCalibration` 审计字段。

### 10.5 M7 运行时增量（不破坏第 2/7 节既有契约）

- 工具签名 = sorted-keys JSON + **参数值级代码规范化**（`0700.HK`≡`hk700`≡`HK00700`）→ 等价调用共享缓存与非重试语义
- `budgetSkipBeforeRequest`：剩余预算 <8s 止损终止（区别于 totalTimeout，不发计费请求）
- `get_market_snapshot` scope guard：请求代码与冻结快照完全无交集 → `scope_violation` 错误（部分缺失仍走 warning）

### 10.6 App 集成接线（2026-08-31 完成，余一项）

核心库与 Agent 工具已完成；App 侧接线已落地：
- **L6 信号闭环全自动**：趋势报告落盘自动 ingest（`saveTrendAnalysisReport` → 抽取/去重/反向失效/胜率校准，`MarketSignalActions.ingestMarketSignalsFromReport`）；每日盘后 15:35 起 60s 轮询触发 `settleDueSignals`（每天一次，UserDefaults `qieman.marketSignals.lastSettleDay` 记日）；Store 落在 `investment-intelligence/market-signals/`
- **L7 流水线 UI 入口**：AI 指引页「市场信号与研究」面板（`Views_macOS/InvestmentIntelligence/MarketSignalSection.swift`），输入标的 + 四档深度手动触发（`runMarketResearch`）；`marketResearchState` 纳入四向互斥 guard（趋势/下一小时/专项研究/流水线，guard 顺序遵守第 8 节）；candidateSignal 自动入库进 L6
- **L8 回测入口**：同面板策略技能 Picker + 标的 → `runStrategyBacktest` 拉约一年日 K 规则回测（纯本地计算，无 LLM、不占互斥）
- **展示**：活跃/最近结算信号列表 + 全局胜率记忆摘要；方向与结算红涨绿跌走 `AppPalette.marketGain/marketLoss`

仍待做：广度预暖与 NextHourGuidanceContext 广度注入（V2 子 Agent 已可经 `get_market_breadth` 工具取用，App 侧预暖属性能优化非功能缺口）；iOS 端对应面板（当前仅 macOS）。
