# AI 研判页体验优化 · 总修改计划(含已完成批次)

> 日期:2026-08-19 · 基线:v4.0.0 后 main(a95ac41+),测试基线 **651 全绿**(595 → 651;A +12、B +7、P1 +12、P2 +5、P3 +1、P4 +12、#12 +5)
> **第二轮计划(2026-08-27,上手向导/信息架构/触达/结果明确性/信任与成本)见 [2026-08-27-ai-research-ux-optimization-round2-plan.md](./2026-08-27-ai-research-ux-optimization-round2-plan.md)**;本文件候选池中与其重叠的条目(#8/#14/#16/#19/#22/#23)已在第二轮计划内细化升级。
> 范围:AI 研判子系统(macOS `InvestmentIntelligenceDashboardView` 及注入链路、设置、菜单栏、iOS 对应页)、收盘复盘契约呈现、今日简报
> 总原则:**工程契约(调度/落盘/校验/行为基线)零改动,只做呈现层与纯派生逻辑**;Phase 5 例外(单独评审)

## 0. 背景诊断

普通用户体验分析确认三道断崖,全部修改点据此展开:

- **配置断崖**:新用户面对 Base URL/模型名/Key/超时五项手填 + 四个可选数据源,最大流失点
- **理解断崖**:术语密度高(把握/触发失效/三方约束/穿透覆盖…),分数无解释,产品克制未被翻译
- **习惯断崖**:错峰时间模型(9:00 雷达/盘中 60s/21:00 复盘/周日 20:00 长期)只存在于设置页文字,用户不知道何时回来看什么;复盘「同日不补跑」等契约对用户完全隐性

叠加问题:单页 7 区段密度过载、双端体验割裂(画像编辑 iOS 独有、术语双端不同步)。

---

## 批次 A(已完成)· 复盘隐性时间契约显性化

**问题**:21:00 自动复盘「同日至多尝试一次、失败不重试、错过不跨日补跑」契约只存在于工程层,UI 只给「今日/昨日/最近收盘复盘」标题和永远同文案的「更新复盘」按钮——用户不知道为什么是昨日、现在能做什么、失败何时发生过。

### A.1 改动清单

| # | 文件 | 动作 | 内容 |
|---|---|---|---|
| 1 | `Core/InvestmentIntelligence/MarketCloseReviewArchive.swift` | 修改 | 新增 `MarketCloseReviewFreshness`:`Phase`(generatedToday(timeText)/waitingForTonight/tonightUnfinished(autoAttempted))+ `lastGeneratedAtText` + `autoAnalysisEnabled` + `autoTimeText`;纯函数 `evaluate(generatedAt:currentTimestamp:autoAttemptedKey:autoAnalysisEnabled:)`;派生 `badgeText/subtitleText/actionTitle`;自带 day/time/minute 解析工具 |
| 2 | `Core/InvestmentIntelligence/MarketCloseReviewSnapshot.swift` | 修改 | AppModel 扩展新增 `marketCloseReviewFreshness` 计算属性(输入与 `marketCloseReviewTitle` 同源:archive ?? moduleGeneratedAt(.closeReview)) |
| 3 | `Views_macOS/InvestmentIntelligence/MarketCloseReviewSection.swift` | 修改 | ①trailing 加 `InvestmentStateBadge` 状态徽章(生成中隐藏);②subtitle 动态化(生成中保留 displaySnapshot 的「正在更新·暂时展示」);③按钮语义化:重新生成/现在生成/补做今日复盘;④provider 未配置时内容顶部加警告 Label(原仅置灰无解释);⑤`freshnessTint` 颜色映射 |
| 4 | `Core/TodayBrief.swift` | 修改 | `TodayBriefKind.closeReviewMissed` + `TodayBriefDestination.aiResearch` + `TodayBriefContext.closeReviewAutoMissed`(默认 false,既有调用零改动)+ builder 条目(priority 32,介于待确认交易 30 与定投计划 40 之间)+ AppModel 接线(phase 判定) |
| 5 | `Views_macOS/Overview/OverviewSectionView.swift` | 修改 | `openBrief` 补 `.aiResearch → selectedSection = .enhancement` |
| 6 | `Views_iOS/OverviewSectionView.swift` | 修改 | `handleTodayBriefTap` 同步补 case |
| 7 | `Views_iOS/EnhancementSectionView.swift` | 修改 | AI 页复盘标题由写死「今日收盘复盘」改为 `model.marketCloseReviewTitle`(修双端不一致) |
| 8 | `Tests/QiemanDashboardTests/MarketCloseReviewFreshnessTests.swift` | 新增 | 10 个用例 |
| 9 | `Tests/QiemanDashboardTests/TodayBriefBuilderTests.swift` | 修改 | +2 个用例 |

### A.2 关键设计决策

- **「状态 + 原因 + 动作」三件套**是本批次确立的隐性契约翻译模式,后续阶段(P4 错误分诊等)沿用
- **自动失败的精确信号**:调度器启动前即落盘 `lastModuleAutoAnalysisKeys["<日> 21:00"]`、成功才推进 `moduleGeneratedAt`——因此「今晚 key 已标记但未生成」= 自动尝试过且失败,无需新增任何状态存储
- 文案矩阵:今日已复盘(绿,重新生成)/白天展示昨日(蓝,今晚 21:00 更新,现在生成)/21:00 后自动失败(黄,待手动补做)/自动未开启(灰,不承诺自动)
- `displayTitle` 对「从未生成」默认「今日收盘复盘」是被既有测试冻结的历史行为,**不改**,一致性测试排除 nil 用例并注明原因
- attempt key 的 `"<yyyy-MM-dd> 21:00"` 格式与 `TrendModuleAutoAnalysisSchedule.dueSlot` 生成保持一致(测试中有格式锁定用例)

### A.3 测试与验证结果

- 10 用例覆盖:各状态文案、白天手动生成也算今日、昨天的 key 不算今晚尝试、attempt key 过期、与 displayTitle 一致性(4 组非 nil 输入双向断言)
- TodayBrief:自动失败出现(warning/aiResearch/排序)、未失败不出现
- 全量 609 全绿(基线 597 + 12);未触碰 CLI 清单与 characterization 契约
- **状态:代码在工作区,未提交**;本批含 `Views_iOS` 两处改动(不在 SPM 目标内),合并前须经 Xcode 工程构建验证(见全局约束 3)

---

## 批次 B(已完成)· 术语统一与人话解释

**问题**:同一 0-100 确定性语义在相邻区段叫「把握」(四档)和「置信度」(裸数字)两个名字、两套阈值;「三方判断约束」「独立来源」「穿透覆盖」等自造词无任何解释;普通用户读不懂结果页。

### B.1 改动清单

| # | 文件 | 动作 | 内容 |
|---|---|---|---|
| 1 | `Core/InvestmentIntelligence/ResearchTermGlossary.swift` | 新增 | `ResearchTerm` 六术语(confidence/triggerInvalidation/teamConstraints/independentSources/lookThroughCoverage/posture),每条 title + plainExplanation + example;`ConfidenceGrade` 四档(85/75/45 → 很高/较高/中等/偏低)+ `badgeText(score:)`「把握 中等 65」 |
| 2 | `Views_macOS/InvestmentIntelligence/InvestmentIntelligenceStyle.swift` | 修改 | `tint(for: ConfidenceGrade)` 色彩映射;`TermHelpView`(小问号,点击 popover + `.help` 悬停兜底 + accessibility)+ `TermHelpPopoverContent`(宽 300,词面/人话/例子) |
| 3 | `Views_macOS/InvestmentIntelligence/NextHourGuidancePriorityActionRow.swift` | 修改 | 徽章改 `ConfidenceGrade.badgeText` + 统一 tint;把握徽章与触发/失效区挂 `.help`;删除私有 confidenceText/confidenceTint |
| 4 | `Views_macOS/InvestmentIntelligence/InvestmentDirectionCard.swift` | 修改 | 「置信度 N%」→「把握 档位 N」胶囊;「N 个独立来源」→「来自 N 个不同渠道」+ `.help` |
| 5 | `Views_macOS/InvestmentIntelligence/InvestmentDirectionDetailSheet.swift` | 修改 | 详情头部同步换把握徽章(与卡片一致) |
| 6 | `Views_macOS/TrendComponents.swift` | 修改 | `TrendConfidenceMeter` 胶囊内「置信度N」→「把握N」+ `.help`(75/45 色带阈值不动) |
| 7 | `Views_macOS/InvestmentIntelligence/NextHourGuidanceTeamInsightsView.swift` | 修改 | 标题挂 `TermHelpView(.teamConstraints)` + 常驻人话 caption「行情、新闻、持仓三个独立角度给出的限制…」 |
| 8 | `Views_macOS/InvestmentIntelligence/NextHourGuidanceDecisionConsole.swift` | 修改 | 姿态徽章旁挂 `TermHelpView(.posture)` |
| 9 | `Views_macOS/InvestmentIntelligence/InvestmentIntelligenceDashboardView.swift` | 修改 | 研判基础脚注挂 `TermHelpView(.lookThroughCoverage)` |
| 10 | `Tests/QiemanDashboardTests/ResearchTermGlossaryTests.swift` | 新增 | 7 个用例 |

### B.2 关键设计决策

- **词表放 Core**:一处定义、macOS/iOS 共用;「新增术语不登记解释视为遗漏」由测试强制(防回潮)
- **嵌套按钮约束**:卡片本身是 Button 的场景(优先动作行/雷达卡)用 `.help()` 悬停解释,避免嵌套按钮;非按钮上下文(三方标题/姿态/研判基础)用可点击 `TermHelpView` popover
- **落盘契约不动**:`TrendConfidence.label`(高/中/低,75/45)参与磁盘编解码,保持原样;UI 统一四档只在呈现层
- **阈值与色带对齐**:四档阈值取 85/75/45,刻意与 `TrendConfidenceMeter` 色带(75/45)及磁盘 label 边界对齐——≥75 绿=较高、45-74 黄=中等、<45 红=偏低、85+ 为「很高」顶级。消除文字档位与色带颜色打架(旧 55/70/85 会在 50-54「偏低却黄」、70-74「较高却黄」)
- 「把握不是涨跌概率」的误读必须在解释里显式否认(测试断言含「概率」与「不是」)
- iOS 端仍为旧文案(置信度),接入在 Phase 3(词表/档位在 Core 已就绪)

### B.3 测试与验证结果

- 7 用例:词表完整性(title/人话/例子「例:」前缀)、核心六词注册、把握否认概率、触发失效双向解释、四档边界(85/84/75/74/45/44/0)、badgeText 档位前数字后
- 全量 616 全绿;既有源码断言(「三方判断约束」等)全部保留未动
- **状态:代码在工作区,未提交**;四档阈值已按 85/75/45 对齐色带(本次评审修正),边界测试同步更新,合并前重跑全量验证

---

## 总览:全部修改点

| # | 修改点 | 阶段 | 状态 | 主要文件 | 优先级 |
|---|---|---|---|---|---|
| A | 复盘时间契约显性化 + 失败外显 | 已完成 | 工作区未提交 | 见 A.1 | — |
| B | 术语统一(把握四档)+ 人话解释机制 | 已完成 | 工作区未提交 | 见 B.1 | — |
| 1 | 今日研判摘要头(含未生成引导态) | P1 | **已完成·工作区未提交** | 新 `InvestmentTodayResearchSummary.swift`、新 `InvestmentTodaySummaryCard.swift`、dashboard 接入 | 高 |
| 2 | 「怎么读这份研判」帮助 sheet(首次自动弹) | P1 | **已完成·工作区未提交** | 新 `ResearchReadingGuideSheet.swift`、`AppStorageKeys.swift` | 高 |
| 3 | 配置向导化(预设/引导/分层/隐私说明) | P2 | **已完成·工作区未提交** | 新 `TrendProviderPreset.swift`、`SettingsTrendPanel.swift`、`IOSTrendSettingsView.swift` | 高 |
| 4 | macOS 决策画像编辑入口 | P3 | **已完成·工作区未提交** | 新 `UserDecisionProfilePanel.swift`、dashboard 研判基础卡入口 | 高(功能债) |
| 5 | iOS 术语/摘要接入 | P3 | **术语+词表已完成·摘要卡留候选** | `Views_iOS/EnhancementSectionView.swift`、`IOSTrendTrackingListView.swift`、新 `IOSResearchTermGlossaryView.swift` | 中 |
| 6 | 错误分诊人话化 | P4 | **已完成·工作区未提交** | 新 `TrendErrorTriage.swift`、日志面板/盘中错误行/设置 ToastBar | 中 |
| 7 | 菜单栏姿态触达 | P4 | **已完成·工作区未提交** | `MenuBarTickerKind/Entries`、`SettingsMenuBarPanel.swift` | 中 |
| 8 | 成本可观测(tokens) | P4 | **已关闭(调研结论:数据不可得)** — 流式 usage 尾包到达但在 `OpenAICompatibleAgentClient.swift:685` 被丢弃;展示需改造 Agent 完成链路,超出呈现层原则,移交 P5 评估 | — | 低 |
| 9 | MarketOpportunityEngine memo | P1 | 并入 P1 | `EnhancementTodayPanel.swift`、AppModel 缓存 | 低(技术) |
| 10 | 实时日志收纳为状态条 | P4 | **已完成·工作区未提交**(运行结束自动收起为单行;失败态显示分诊人话) | `TrendLiveLogPanel.swift` | 中 |
| 11 | 摘要行锚点滚动 | P1 | 并入 P1(随摘要卡交付) | dashboard + `EnhancementCenterView`(ScrollViewReader) | 低 |
| 12 | 旧趋势跟踪清单 sunset | P4 | **已完成·方案 A(2026-08-19)** | `DecisionCase.swift`(kind+case)、`InvestmentIntelligenceActions.swift`(新入口)、删 `EnhancementTrackingPanel.swift`、`EnhancementTodayPanel/CenterView` | 低 |
| 13 | 跨时段连贯性(盘中回指昨晚三件事) | P5 | 远期备忘 | NextHourGuidance prompt/models(**动行为契约,须过 characterization 基线**) | 远期 |
| 14 | 复盘完成/失败本地通知(唯一建议默认开) | P4 | 候选 | `LocalNotificationManager`、AppModel 接线 | 中 |
| 15 | 盘中姿态突变通知(默认关) | P4 | 候选 | `NextHourGuidanceController`、通知 | 低 |
| 16 | 生成进度摘要替代日志首屏 | P4 | 候选 | `TrendLiveLogPanel`、生成状态 | 中 |
| 17 | 首次「待复盘」新手提示 | P4 | 候选 | dashboard recordsSection | 低 |
| 18 | 非交易时段空态引流 | P1 | 并入 P1 | 盘中区段空态视图(`EnhancementTodayPanel` 等) | 低 |
| 19 | 区段级新鲜度小字 | P4 | 候选 | 各 SectionCard 标题行 | 低 |
| 20 | 盘中研判过期视觉降级 | P4 | 候选(建议做) | 盘中区段容器 | 中 |
| 21 | 「所以呢」行动闭环(区段尾下一步) | P4 | 候选 | 各研判区段尾部 | 中 |
| 22 | 示例演示报告(脱敏预览) | P5 | 候选 | 新演示数据 + 只读渲染 | 中 |
| 23 | iOS 推送配套(#14/#15 iOS 端) | P3 | 候选(与 iOS 补齐同批评估) | `Views_iOS`、通知权限 | 中 |
| 24 | 命令面板快捷入口 | P4 | 候选 | `CommandPaletteView`、路由 | 低 |
| 25 | 区段标题人话化 | P5 | 候选(单独文案评审批次) | 各 SectionCard 标题 | 中 |

每阶段一个独立提交/PR,全量 `swift test` 全绿后进入下一阶段;A/B 两批合并为一次提交(标题建议:「feat: 收盘复盘状态显性化与 AI 研判术语人话化」)。

---

## Phase 1 · 摘要头 + 怎么读指南(已完成,2026-08-19)

> 实施结果与计划的偏差,均已回写:①复盘行收录条件由 `!headline.isEmpty` 改为按 `state` 判(占位快照的 headline 非空);②盘中 validUntil 存在 "HH:mm"(固定槽)与 "yyyy-MM-dd HH:mm"(手动槽)两种格式,过期判定与展示统一走 `shortTimeText` 折算;③ memo 需缓存 Optional 结果,key 命中即返回(含 nil),不能 `if let` 解包判缓存。新增测试 12 个(派生 9 + memo 2 + 源码断言 1),全量 628 绿。锚点高亮为 1 秒描边后自动消退。

### 1.1 改动清单

| # | 文件 | 动作 | 职责 |
|---|---|---|---|
| 1 | `Core/InvestmentIntelligence/InvestmentTodayResearchSummary.swift` | 新增 | 摘要行纯派生模型(Core,可测,iOS 可复用) |
| 2 | `Core/AppStorageKeys.swift` | 修改 | 新增 `researchReadingGuideShown` 键 |
| 3 | `Views_macOS/InvestmentIntelligence/InvestmentTodaySummaryCard.swift` | 新增 | 摘要卡(含引导态 + 「怎么读」入口 + 行点击锚点滚动) |
| 4 | `Views_macOS/InvestmentIntelligence/ResearchReadingGuideSheet.swift` | 新增 | 帮助 sheet |
| 5 | `Views_macOS/InvestmentIntelligence/InvestmentIntelligenceDashboardView.swift` | 修改 | `TrendLiveLogPanel()` 前插入摘要卡;外层接 `ScrollViewReader`、区段加滚动 id(原 P4.6 并入) |
| 6 | `Tests/QiemanDashboardTests/InvestmentTodayResearchSummaryTests.swift` | 新增 | 派生逻辑测试 |
| 7 | `Tests/QiemanDashboardTests/UIExperienceRegressionTests.swift` | 修改 | 追加源码断言(摘要卡/指南 sheet/锚点 id) |
| 8 | `Core/AppModel/`(TrendAnalysis 扩展,与摘要计算属性同文件) | 修改 | `MarketOpportunityEngine.analyze` 结果 memo 化:输入 `trendReport` + `moduleGeneratedAt` 变化时失效;`EnhancementTodayPanel` 与摘要计算属性统一走该缓存(原 P4.9 并入,消除双处调用与 body 重算) |
| 9 | `Tests/QiemanDashboardTests/MarketOpportunityMemoTests.swift` | 新增 | memo 单测:同输入复用、输入变化重算 |
| 10 | 盘中区段空态视图(`EnhancementTodayPanel`/`NextHourGuidanceProgressView` 区域) | 修改 | 非交易时段空态引流:除「将在下一个交易时段自动生成」外,附一句「现在适合看:昨晚复盘 / 组合中期」并把有内容区段可点击跳转(原候选 #18 并入) |

### 1.2 Core 派生模型

```swift
struct InvestmentTodayResearchRow: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable { case closeReview, intraday, marketRadar, longTerm }
    let kind: Kind; let title: String; let headline: String; let footnote: String
    var id: String { kind.rawValue }
}
struct InvestmentTodayResearchSummary: Hashable, Sendable {
    let rows: [InvestmentTodayResearchRow]
    var hasAnyContent: Bool { !rows.isEmpty }
}
```

纯函数构建器 `make(closeReview:closeReviewTitle:intraday:marketAnalysis:trendReport:currentTimestamp:)`,行规则:

| 行 | 收录条件 | title | headline | footnote |
|---|---|---|---|---|
| 复盘 | `state ∉ {noScan, scanning}`(占位态的 headline 是提示文案而非结论,不能用 `!headline.isEmpty` 判——noScan 快照 headline 为「今天还没有可用的收盘复盘」) | `closeReviewTitle`(今日/昨日/最近,复用现有) | `closeReview.headline` | 明日关注第 1 条;无则「持仓 N 项」 |
| 盘中 | report 存在 | 「盘中指引」 | `posture.displayName · 首个动作(标的+动作)`;无动作退回 `report.headline` | 未过期「有效至 HH:mm」/过期「已过期」 |
| 雷达 | `marketSignalCount > 0` | 「全市场机会」 | 最强信号(`recommendation.priority` 升序→confidence 降序):`name · displayName` | 「共 N 个方向 · 更新 HH:mm」 |
| 长期 | horizons 含 `.medium` | 「组合中期」 | `direction.assetTagText · rationale` | 「生成于 yyyy-MM-dd」 |

AppModel 计算属性 `investmentTodayResearchSummary` 接线(输入:`marketCloseReview/Title`、`nextHourGuidanceReport`、`marketOpportunities`(memo,见 1.1#8)、`trendReport`、`timestampString`)。

### 1.3 视图

- **摘要卡**:`SectionCard(title:"今日研判", icon:"sparkles", trailing:「怎么读」按钮)`;行 = 区段同款图标(`sunset.fill`/`clock.arrow.circlepath`/`scope`/`briefcase.fill`)+ title(caption 粗)+ headline(body)+ footnote(caption muted)
- **行点击 = 锚点滚动**:dashboard 外层 `ScrollViewReader`,区段挂 id;点击摘要行滚动到对应区段并短暂高亮(highlight 用 `AppPalette` 描边动效)。非交互摘要卡在 6-7 区段长页里价值有限,锚点与摘要卡同批交付(原 P4.6 提前,`EnhancementCenterView` 贯通后续可选)
- **引导态**:`hasAnyContent == false` → `InvestmentEmptyState` +「去设置配置模型」(`model.selectedSection = .settings`),全页统一引导位第一步
- **空态引流(全页统一)**:盘中区段非交易时段空态不只给状态文案,附「现在适合看:昨晚复盘 / 组合中期」并把有内容区段做成可点击跳转(1.1 #10);避免空档期整页无看点
- **指南 sheet**(宽 ~480,三段):①立场三条(给依据不给指令/证据不足宁可明说/结论有时效)②三个关键数字(渲染 `ResearchTerm.confidence/.triggerInvalidation/.independentSources`)③术语速查(`ResearchTerm.allCases`)
- **首次自动弹**:`@AppStorage` + 触发条件为「首个报告完整落盘后内容首次出现」(实现以 `trendGenerationState == .succeeded` 且 `hasAnyContent` 首次为真为准,避免生成中/切换页时弹窗),一次后落键

### 1.4 测试与验收

- 逻辑测试:空输入、空壳复盘不收录、有效期/过期 footnote、最强信号选择、medium horizon、固定行序
- memo 测试:同输入复用、输入变化(trendReport/moduleGeneratedAt)重算
- 源码断言:dashboard 含 `InvestmentTodaySummaryCard()` 与区段滚动 id;指南 sheet 含「不替你做买卖决定」与 `ResearchTerm.allCases`
- 验收:有数据首屏四行可读可映射区段,点击行可定位并高亮;无数据统一引导;非交易时段空态含引流文案且可跳转;「怎么读」常驻+首个报告落盘后首弹一次;全量测试全绿(616+)

### 1.5 本阶段不做

日志收纳、配置向导、iOS、画像入口(分属 P2–P4);通知触达类候选见 4.8;空态引流已并入本阶段(1.1 #10)。

---

## Phase 2 · 配置向导化(已完成,2026-08-19)

> 实施补充:①预设文件落在 `Core/TrendResearch/TrendProviderPreset.swift`(智谱/OpenAI/DeepSeek,应用预设只填供应商/BaseURL/模型,Key 与超时不动);②隐私说明为按模式动态文案,事实来自 `TrendAnalysisContextBuilder` 核实——sanitized 模式所有金额字段(总市值/待确认/计划/敞口)不发送、只发百分比占比;③新增治理约束:本仓 `DisclosureInteractionPresentationTests` 要求所有 DisclosureGroup 必须带 `.disclosureGroupStyle(FullRowDisclosureGroupStyle())`,高级收纳两组已合规;④iOS 端以 Picker 快速选择 + 取 Key Link 同步(仍需 Xcode 构建验证)。新增测试 5 个,全量 633 绿。

### 2.1 目标

新用户从设置页「选供应商 → 贴 Key → 保存」三步完成,不再面对五个裸字段与四个数据源开关。

### 2.2 改动

| 文件 | 内容 |
|---|---|
| 新 `Core/TrendResearch/TrendProviderPreset.swift` | 预设表:`名称 / baseURL / 默认模型 / 控制台 URL(获取 Key 引导)/ 文档 URL`。首发:智谱、OpenAI、DeepSeek(模型名随预设填入仍可改) |
| `Views_macOS/SettingsTrendPanel.swift` | ①「模型连接」卡顶部加预设 chips/Picker,选中即填 baseURL+默认模型;②「获取 API Key →」按钮打开控制台 URL;③**分层**:`服务超时秒数` 与 SEC/AlphaVantage/Tavily 三卡收进「高级数据源」`DisclosureGroup`(默认收起,Tavily 保留「不配置则全市场雷达不可用」说明);④卡顶一句隐私说明 |
| `Views_iOS/IOSTrendSettingsView.swift` | 同步预设 chips(文案级,Xcode 验证) |

### 2.3 隐私说明文案(前置调研项)

写文案前先核实 `TrendResearchSnapshot` 各 privacyMode 实际脱敏字段(输出一句:「研判会把【脱敏后的持仓与行情摘要】发送给你配置的模型服务商,sanitized 模式不含成本价与金额」——以代码核实为准,不承诺未实现的行为)。

### 2.4 测试与验收

- 预设表单测:非空、baseURL 为 https、每条含控制台 URL;选择预设后 `TrendAIProviderSettings` 填充正确
- 面板源码断言:预设 UI 存在、高级组默认收起
- 验收:新账号路径三步完成配置;高级项不可见但不丢失(老配置升级后仍在)

---

## Phase 3 · 双端补齐(已完成,2026-08-19)

> 实施补充:①入口选择「研判基础卡 trailing 按钮」(未定制时显示「设置决策偏好」),面板字段与 iOS 完全对齐,另加「恢复默认」;②iOS 术语统一后以源码断言锁死——`EnhancementSectionView`/`IOSTrendTrackingListView` 不得再出现「置信度」字样,档位一律走 `ConfidenceGrade`;③iOS「怎么读」词表入口放在智能分段 Picker 旁的问号按钮,内容与 macOS 同源 `ResearchTerm.allCases`;④iOS 紧凑版摘要卡(可选项)未做,留候选池。新增测试 1 个(源码断言),全量 634 绿;Views_iOS 改动仍待 Xcode 构建验证。

### 3.1 macOS 决策画像入口(#4)

- 新 `Views_macOS/InvestmentIntelligence/UserDecisionProfilePanel.swift`:表单字段对齐 iOS(`IOSUserDecisionProfileEditor`):投资期限、风险偏好(segmented)、可选单标的上限/重叠度上限(slider)、是否允许主动再平衡建议;读写 `UserDecisionProfileStore`(Core 已有,含测试)
- 入口:研判基础卡旁「决策偏好」按钮弹 sheet(或并入设置→AI 研判,二选一,实现时按信息架构就近原则定)
- 测试:面板源码断言 + store 读写既有测试复跑

### 3.2 iOS 术语/摘要接入(#5)

- `Views_iOS/EnhancementSectionView.swift` 「置信度 \(label)」→ `ConfidenceGrade.badgeText`;`IOSTrendTrackingListView` 「置信度」→「把握」
- 词表解释:iOS 无 hover,用点击展开(info 按钮弹同款内容 sheet,组件可直接复用 Core 词表)
- (可选)摘要卡:Core 派生模型直接驱动 iOS 紧凑版
- **验证方式**:Views_iOS 不在 SPM 目标内,需 `xcodebuild`/Xcode 工程构建验证——本仓 CI 或手动,实施时明确执行者
- 测试:iOS 视图改动以源码断言为主(Tests 可读 Views_iOS 源文件)

---

## Phase 4 · 触达与打磨(#6–#12;仅剩 #12 待决策,2026-08-19)

> 首批实施补充(#6/#10,+#8 调研关闭):①`TrendErrorTriage` 按消息字符串分诊——耦合用「真实错误 → errorDescription → 分诊」全链路测试锁定,客户端文案改动会先红测试;接入三处:日志面板失败头部(含「去设置」按钮)、盘中错误行、设置页 ToastBar;②日志收纳实现为「运行结束自动收起为单行状态条 + 空闲标题『上次…运行』」(未用 popover,行内展开保留);③#8 关闭:usage 尾包在客户端被丢弃,展示需改 Agent 完成链路,移交 P5。
>
> #7 实施补充(第二批):`MenuBarTickerKind.aiPosture` 条目三态如实呈现——无报告「AI·暂无盘中研判」、有效「AI·均衡·至14:50」、过期「AI·均衡·已过期」(过期判定复用 P1 的 isIntradayExpired,兼容固定槽/手动槽双格式);设置面板新增「AI 研判姿态」分组,默认关(default.selections 不含,有测试锁定);条目构建测试用过去/未来完整日期规避真实时钟边界。第二批 +5,全量 646 绿。
>
> P4 剩余:#12 旧跟踪清单 sunset,阻塞在数据保留方式决策(归档进决策案例 or 只读隐藏)。
>
> **#12 实施记录(方案 A,2026-08-19 完成)**:①存量迁移早已自动跑(Slice 6 的 `migrateLegacyTrackingIfNeeded`,启动时按 caseKey 增量去重),无需额外动作;②写入切换:行动候选「加入跟踪」→「加入关注」,新入口 `addDecisionCase` 直接建 DecisionCase(新 kind `.trendAction`,caseKey `trend:` 前缀,与旧迁移键 `legacy:` **互为去重**——同一动作无论迁移还是新加只保留一案);自然语言条件进 detail 标注人工复核,复查时间不预设;③旧清单 UI 整体退场(删 `EnhancementTrackingPanel.swift` + 底部区段 + 展开状态);④通知深链改路由到案例详情(迁移保持 ID 稳定所以旧通知仍可达);⑤`DecisionMetricResolver` 补 trendAction 分支(建案时快照指标,不运行时解析);⑥`addTrackingItem` 模型函数与落盘保留(N+2 再移除),characterization 测试全部仍绿;基线文档链路 C 加 sunset 注记。+5 测试,全量 651 绿。**Phase 4 至此全部完成。**

### 4.1 错误分诊人话化(#6)

- 新 `Core/TrendResearch/TrendErrorTriage.swift`:`classify(error) → (人话原因, 建议动作)`;映射:401→Key 无效(去设置检查)、403→Key 权限不足或额度/区域限制(去控制台核实)、404→Base URL 路径不对(检查是否少了 `/v1` 等后缀)、429→额度/限流(稍后再试或换供应商)、5xx→服务商故障(稍后再试)、超时→模型服务响应慢(重试或延长超时)、URLError/网络层错误→网络不通、解析失败→模型不兼容(确认支持 Tool Calling)
- 呈现:Toast/lastTrendError/盘中错误行统一走分诊;原始错误收进「详情」;**建议动作可点击**(如「去设置」直接跳转),不只给文字
- 前置调研:`OpenAICompatibleAgentClientError` 错误类型枚举清单(当前无独立 URLError case,网络错误可能裹在 `requestFailed(statusCode: nil)` 或底层 NSError,分诊入口需覆盖这两条路径)
- 测试:每类错误→文案映射单测

### 4.2 菜单栏姿态触达(#7)

- `MenuBarTickerKind` 新增 `posture` case:文案「AI·均衡偏防守 · 有效至 14:50」(无报告时「AI·暂无盘中研判」)
- 数据:同进程 AppModel 的 `nextHourGuidanceReport`;`SettingsMenuBarPanel` 加开关,默认关
- 测试:Kind 文案与默认排序单测;面板源码断言

### 4.3 成本可观测(#8,依赖调研)

- 前置调研:确认客户端是否已从流式响应收集 usage tokens(`OpenAICompatibleAgentClient`/诊断日志)
- 若有:雷达/复盘卡脚注加「上次 ~X.X 万 tokens」;若无:标记「数据不可得」,本项关闭不硬做

### 4.4 引擎 memo(#9)

- **已并入 P1(见 1.1 #8/#9)**:memo 与摘要计算属性同批落地,不再单独排期。

### 4.5 日志收纳(#10)

- `TrendLiveLogPanel` 空闲态收成单行状态条(上次运行 时间·成功/失败·查看日志),详情转 popover;生成中行为不变(自动展开)
- 与 P1 摘要卡配合后首屏再减一整块;设计参照设计稿方案 C;若实施 #16(进度摘要),本项与其合并设计,避免连续两次改日志面板

### 4.6 锚点滚动(#11)

- **已并入 P1(见 1.3)**:摘要行点击锚点滚动 + 高亮随摘要卡交付;`EnhancementCenterView` 贯通保留为后续可选。

### 4.7 旧跟踪清单 sunset(#12,需决策)

- 前提:Slice 6 迁移完成满一个观察期(建议 v4.2 后)
- 决策点:历史项归档进决策案例 or 只读隐藏。默认方案:`legacyTrackingDisclosure` 从页面移除,数据保留磁盘,入口移到设置→AI 研判「历史数据」

### 4.8 触达与新手候选(#14–#17,普通用户视角新增,未排期)

计划原触达只覆盖「用户已在 App 内」;习惯断崖的另一半是「不在 App 内时永远想不起来」。以下候选先入池,不做承诺,实施前单独确认:

- **#14 复盘完成/失败本地通知(唯一建议默认开)**:21:00 自动复盘成功落盘后发「今日复盘已生成,点击查看」;失败发「未完成,可手动补做」。信号与 A 批次 TodayBrief 同源(attempt key + moduleGeneratedAt),零新状态;`LocalNotificationManager` 已有基础设施。这是把错峰时间模型交给系统叫用户,而不是让用户记时间
- **#15 盘中姿态突变通知(默认关)**:姿态档位发生防御↔进取翻转时通知。先上菜单栏(#7)观察使用,通知后置,避免打扰
- **#16 生成进度摘要替代日志首屏**:实时日志对普通用户是噪音;生成中首屏只显示「正在分析持仓归因(3/5)」式进度,日志收进详情。与 #10 合并设计
- **#17 首次「待复盘」新手提示**:recordsSection 首次出现待复盘 case 时给一句人话 tooltip(「复盘=回看当时的判断对不对,帮下次判断更准」),`@AppStorage` 一次后不再出现

其余第二轮新增候选(#19–#21、#24 等)见下方「候选池 · 第二轮评审新增体验点」。

---

## 候选池 · 第二轮评审新增体验点(#18–#25)

> 第二轮评审(从普通用户视角)新增。除 #18 已并入 P1 外,其余按阶段归类为候选,实施前单独确认:

| # | 候选 | 阶段 | 说明 |
|---|---|---|---|
| 19 | 区段级新鲜度小字 | P4 | P1 摘要卡 footnote 的「更新 HH:mm / 生成于 日期」若反馈好,下沉到每个区段标题旁,任何位置都知道数据新旧 |
| 20 | 盘中研判过期视觉降级 | P4(建议做) | 过了「有效至」时间后整区段加弱化徽章/描边,不只 footnote 一行字,防止拿过期判断做新决策 |
| 21 | 「所以呢」行动闭环 | P4 | 每个研判区段尾部固定一行「下一步」:复盘→「设今晚提醒」(配合 #14)、盘中→「加入跟踪清单」(已有入口)、长期→「回看上次判断复盘」。与 Phase 5 呼应但不碰 prompt |
| 22 | 示例演示报告 | P5 | 配置完成后可预览一份脱敏演示研判,解决「配置半天不知道能得到什么」;需一份静态演示数据 + 只读渲染 |
| 23 | iOS 推送配套 | P3 | #14/#15 的 iOS 端:UNUserNotification + 通知设置 UI,与 P3 iOS 补齐同批评估(iOS 天然期望推送) |
| 24 | 命令面板快捷入口 | P4 | `CommandPaletteView` 已存在,加「查看今日复盘/盘中研判」指令,高频回访路径 |
| 25 | 区段标题人话化 | P5 | 「下一小时研判」→「接下来一小时怎么看」类改写;全站文案+源码断言联动面大,单独文案评审批次,不塞进功能阶段 |

---

## Phase 5 · 远期:跨时段连贯性(修改点 #13,行为契约变更)

盘中研判注入昨晚复盘的「明日关注」作为输入,输出显式回指(「昨日关注①红利放量:已出现/未出现」),把四个功能串成一条决策流。

- **影响面**:`NextHourGuidance` prompt + 输出模型 + 快照来源,**触碰 ai-pipeline-baseline.md 链路 B 行为契约**,须先更新基线文档与 characterization 测试再动实现
- 单独评审、单独 PR,不与其他阶段合并

---

## 全局约束(所有阶段适用)

1. **构建脚本**:新增 Core/Views_macOS 文件由 SPM 与 `build_macos_app.sh`(find 全量)自动包含;**任何 CLI 相关新文件必须同步 `scripts/build_qieman_cli.sh`**(批次 A/B 与 P1–P4 均不涉及 CLI;P4.3 若动 client 需核查)
2. **测试基线**:每阶段收尾全量 `swift test` 全绿;当前 616。**验证环境约束**:本机 `xcode-select` 指向 CommandLineTools,直接 `swift test` 会在 actool 资源编译步骤失败;Xcode 已安装在 `/Applications/Xcode.app`,须以 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 运行(2026-08-19 已以此方式全量验证 616 绿)。每阶段记录验证环境;不要以「编译不过/跑不了测试」为由回退改动
3. **源码断言**:改文案先查 `UIExperienceRegressionTests`/`TrendDashboardSummaryTests`/`MarketCloseReviewSnapshotTests` 等源码断言,同步更新(批次 B 已验证「三方判断约束」等断言兼容)。**iOS 编译验证**:`Views_iOS` 不在 SPM 目标内,任何含 Views_iOS 改动的提交(批次 A 已有两处)合并前须经 Xcode 工程构建验证并记录执行者,源码断言不能替代编译验证
4. **落盘契约**:`TrendConfidence.label`、Snapshot schema、`x-sign`、`displayTitle` nil 默认等契约行为一律不动
5. **红涨绿跌**:一切新增涨跌色走 `AppPalette`
6. **提交规范**:每阶段独立提交,标题面向用户可读(Release notes 由 commit 标题生成);A/B 两批合并提交
7. **文档**:每阶段收尾更新本文档状态列;本文档随 A/B 合并提交一并入库(正式计划文档,与代码同步演进);全部完成后刷新 AGENTS.md 规模数字与本文件链接
