# V1 → V2 投资智能功能损失审计清单

> 日期：2026-08-27
> 背景：2026-08-26 ba750e2（WF-4+WF-5）删除旧三条 AI 链路与 V1 Slice 0-7（含全部 UI），同日 P0-P4 建成 V2 产品展示层（v4.4.0）。
> 用途：逐项拍板「补回 V2 / 确认放弃 / 待定」。**本清单只陈述事实与建议，未做任何代码变更。**
> 处置标记说明：【补回】建议在 V2 上重建；【放弃】建议明确不做；【拍板】语义取舍需要用户决定。

---

## 处置结果（2026-08-27 同日落地）

用户拍板后已全部实施（仅 macOS UI，iOS 后续单独处理）：

| 项 | 处置 | 落地 |
|---|---|---|
| A1 收盘复盘 | 补回（计算 + LLM 增强） | `InvestmentIntelligenceV2/Workflows/MarketCloseReviewWorkflow.swift`（artifact kind MARKET_CLOSE_REVIEW，LLM 失败降级本地因子）+ `MarketCloseNarrativeSynthesizer` + `Core/AppModel/MarketCloseReviewV2.swift` + 复盘卡/详情 sheet + 菜单命令 |
| A2 决策事项跟踪 | 补回 | `InvestmentIntelligenceV2/Decision/DecisionCaseModels/Policy/Engine.swift`（四类建案 + 生命周期状态机 + 六选一复盘）+ `Persistence/DecisionCaseStore.swift`（user-intent 一案一文件）+ `Core/AppModel/DecisionCases.swift` + 决策事项卡/详情/复盘 sheet + 通知深链（NotificationDeepLinkType.intelligence） |
| A3 集中度接线 | 补回 | 随 A2 引擎落地（directHolding/lookThrough/overlap/sector 四维 + 覆盖不足降级）；V2 Risk/ConcentrationCalculator 保持原样（其输入链路 EXP 未接线，本期用 App 侧穿透快照映射） |
| A4 用户画像 | 暂缓（不急） | 用 V1 默认阈值表（DecisionCasePolicy），旧 user-decision-profile.json 保留不动 |
| A5 阅读指南 | 放弃 UI → 文档 | `docs/research-reading-guide.md` |
| A6 逐条证据查看 | 补回 | `ArtifactQueryService.researchEvidence`（最新 vintage）+ `ResearchEvidenceDigest` + `EvidenceDetailSheet`（研究卡信号可点「依据」） |
| B1 盘中调度 | 补回调度、放弃姿态语言 | `Core/IntelligenceAutomation.swift` + `Core/AppModel/IntelligenceAutomationLoop.swift`（60s 轮询、先标记后运行）；维持 HOLD/EXECUTE 语义 |
| B2 失效条件 | 补（反向信号与独立性展示仍暂缓） | 发现候选 `invalidationNote`（本地因子派生）+ 决策事项/行动案 trigger/invalidation 字段 |
| B3 行动候选承接 | 补回 | ResearchSummary.actionCandidates（最新决策胜者计划派生）→ 研究卡「加入跟踪」→ `addCaseFromActionCandidate` 建案 kind actionMigration |
| B4 双轨归因对照 | 放弃 | 持仓板块纯计算归因未删，维持现状 |
| B5 生成过程可见 | 补回 | runPortfolioResearch 接 RunEvent → 阶段推进（研究卡复用 IntelligenceRunningRow） |
| C1 总览浅链卡 | 补回 | `Views_macOS/Overview/IntelligenceTodayCard.swift`（只读 headline + 跳转） |
| C2 菜单栏姿态条目 | 不做 | 依赖姿态语言，随 B1 拍板放弃 |
| C3 资产浏览器 AI 观点 | 暂缓 | 等 V2 研究覆盖单资产 |
| C4 简报复盘警示 | 补回 | TodayBriefKind.closeReview + destination .intelligence（21:30 后未生成触发） |
| C5 分模块调度 | 补回 | 设置面板「自动运行」卡（总开关默认关 + 分模块开关；时刻表 09:00/盘中 6 槽/21:00/周日 20:00） |
| E 数据处置 | 随实施落地 | decision-cases.json（legacy-ai-backup/ 或根部）经 `LegacyDecisionCaseImport` 导入开放案；journals 手写复盘导入为复制语义、原文件保留；其余旧链路产物维持 LegacyAIDataMigration 归档；user-decision-profile.json 不动 |

语义演进（相对 V1，已在代码注释标注）：targetDeviation 从「单标的 vs 画像上限」改为「资产类占比 vs 战略目标」（V2 有真实用户意图 Target Store）；trendAction → actionMigration（来源改为 V2 决策产物）；exitReview 状态删除（引擎从不产出）；决策事项时间戳 String → Date、id UUID → 确定性摘要。

---

## A. 整功能域丢失（V2 完全无对应物）

| # | 丢失功能 | V1 能做什么 | V2 现状 | 建议处置 |
|---|---|---|---|---|
| A1 | **收盘复盘**（MarketCloseReview，每日 21:00 冻结） | 当日组合表现指标、逐持仓收盘归因、「明日关注」≤3 条、完整复盘（市场脉搏/强弱主题/数据边界）、新鲜度徽章、手动补做、归档丢失可从诊断日志恢复 | 无任何复盘概念；「最近记录」只是 artifact 审计表 | 【补回】每日闭环价值最高，V2 市场/持仓数据已具备 |
| A2 | **决策事项跟踪与复核**（DecisionCase） | 四类自动建案（集中度/回撤/目标偏离/行动迁移）、生命周期状态机、专项 AI 研究、复盘结论六选一 + 经验笔记、通知深链、历史列表 | 无任何跟踪/复核流；决策只读展示 | 【补回】与 A1 构成闭环；V2 artifact 表可作建案素材 |
| A3 | **集中度风险提示**（ConcentrationRiskEngine） | top1 占比/HHI/穿透集中度/行业集中度超标自动建案提示用户 | 引擎已存在（V2 `Risk/ConcentrationCalculator` 等）但**无任何 UI 引用，是死代码** | 【补回】成本最低：接线现有引擎即可 |
| A4 | **用户决策画像**（UserDecisionProfile） | 期限/风险偏好/自定义集中度与穿透重叠上限/是否允许强行动建议（约束系统输出强度） | 无；用户意图只剩「战略目标 + 持仓分类」 | 【拍板】与 V2 用户意图 Store 语义部分重叠，需决定合并方式还是重建 |
| A5 | **研究阅读指南**（怎么读研判/立场声明/术语速查） | 首次生成报告自动弹指南，解释三个关键数字 | 无 | 【放弃】改为文档/帮助页即可，不值得占 UI |
| A6 | **逐条证据查看**（证据明细 Sheet / Popover，按角色） | 每条结论可点开看证据明细与数据截至 | 研究卡只有 top3 信号 + 计数；盘中详情折叠区只有 ID/Δw | 【补回】可审计性是 V2 卖点，证据层已入库，缺的是读面 |

## B. 有近似物，但语义/体验缩水

| # | 功能 | V1 | V2 | 差距 | 建议处置 |
|---|---|---|---|---|---|
| B1 | 盘中研判 | 交易日内 6 档**自动**生成（09:15…14:50），姿态分级（防守/均衡/择机/进攻），优先动作 Top3 按置信度排序 | 手动/菜单触发，HOLD/EXECUTE + Δw（provenance 可审计），fail-closed | 丢：定时调度、姿态语言、动作置信度 | 【拍板】调度该补回（属基础设施）；姿态语言是否保留是产品口味 |
| B2 | 市场机会 | 三组方向卡（板块/宽基/大类资产），条件式结论 + 置信度 + **触发/失效条件 + 反向信号 + 来源独立性门槛（≥2 独立来源）** | top-K 候选 + 因子摘要 + 评分（本地因子先筛，架构更诚实） | 丢：失效条件、反向信号、证据独立性展示 | 【拍板】失效条件建议补；独立性展示看 V2 evidence 模型成熟度 |
| B3 | 长期研判 → 组合研究 | 短中长周期网格、持仓重点风险、行动候选「加入关注」直通跟踪清单 | 论点 + 关键信号 top3 + 计数 | 丢：行动候选无处承接（依赖 A2） | 【补回】依赖 A2 先行 |
| B4 | 当日归因双轨对照 | AI 研判页内 LLM 复盘与纯计算归因并列对照 | 无（注意：持仓板块的收益归因未删，仍在） | 丢的只是页内对照视图 | 【放弃】持仓板块已有纯计算版 |
| B5 | 生成过程可见性 | 实时日志面板（可复制/定位文件）、分阶段进度 | 盘中卡有 5 阶段进度；研究只有「研究中…」 | 研究过程黑盒 | 【补回】低成本：研究卡复用盘中卡的阶段进度样式 |

## C. 入口/触达面丢失（内容或近似物存在，但入口没了）

| # | 入口 | V1 | V2 现状 | 建议处置 |
|---|---|---|---|---|
| C1 | 总览页 AI 摘要卡（AITrendSummaryPanel） | 组合级 headline + 多周期方向 + 板块观点网格，总览页直看 | 无总览入口，全部收进投资智能板块 | 【拍板】可给总览加一张只读「今日结论」浅链卡 |
| C2 | 菜单栏 AI 姿态条目 | 姿态 + headline + 有效至 | 无 | 【拍板】依赖 B1 姿态语言去留 |
| C3 | 资产浏览器「AI 观点」区块 | 每资产判断方向/把握/操作建议/依据/失效条件 | 无 | 【拍板】等 V2 研究覆盖单资产后再议 |
| C4 | 今日简报「收盘复盘未完成」警示 | 未成功复盘提醒 + 手动补做深链 | 无（依赖 A1） | 随 A1 |
| C5 | 设置的分模块自动调度（雷达 09:00/复盘 21:00/长期周日 20:00） | 开关 + 时刻表 | 全手动（菜单命令） | 【补回】随 B1 调度一起 |

## D. V2 新增（V1 没有，平衡视角）

战略目标编辑器（五类、append-only 事件）、持仓资产分类编辑器（用户意图优先于系统识别）、系统状态 readiness 卡、Δw provenance + DecisionValidator 门禁、fail-closed 语义、最近记录 artifact 审计表、设置中心化的 Provider 管理（v4.4.1 已修复 Keychain 静默失败）。

## E. 搁浅的用户数据（磁盘遗留、无代码消费）

| 文件/目录（App 数据目录下） | 内容 | 处置选项 |
|---|---|---|
| `decision-cases.json` | 决策事项全量（含状态历史） | 若补回 A2 可迁移复用；否则归档 |
| `investment-intelligence/journals/` | 专项研究运行 + 复盘记录（用户手写结论） | **含用户手写内容，不可静默清理** |
| `market-close-review.json`、`next-hour-guidance.json`、`trend-analysis-report.json`、`trend-tracking-items.json`、`trend-agent-runs/`、`ai-analysis-logs/` | 旧链路产物 | 归档（V2 启动已有「旧版 AI 数据归档」提示） |
| `user-decision-profile.json` | 用户画像 | 随 A4 拍板结果处置 |

## F. 建议的拍板顺序

1. 先拍 A1+A2（复盘 + 跟踪闭环，互为依赖，工作量最大）
2. 再拍 B1 调度 + C5（自动化节奏，用户无感成本最低）
3. A3（集中度接线）随时可做，独立且便宜
4. A4（画像 vs 用户意图 Store）需要产品语义决策，不急
5. 其余 C 类入口问题跟随主功能拍板结果
