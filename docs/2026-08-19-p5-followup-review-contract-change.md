# P5 · 盘中研判「昨日关注回指」契约变更方案(#13 + #8)

> 日期:2026-08-19 · 状态:**S1-S4 已实施并全量 659 绿(2026-08-19);S5 usage 捕获待做**(评审通过后先更新基线与 characterization,再动实现)
> 前置阅读:`docs/ai-pipeline-baseline.md` §3(链路 B 冻结契约)、`docs/2026-08-19-ai-research-ux-optimization-master-plan.md` Phase 5
> 调研结论(本文档的事实基础已逐条对过代码):链路 B 已有「链路 A 旧研判边界」的单向注入机制
> (`NextHourGuidanceContext.latestTrend*` 三字段 → prompt),P5 是**扩展该既有模式**,不是新开数据通道

## 1. 目标与用户价值

昨晚复盘输出「明日三件事」,今天盘中研判对它逐条回指:**已出现 / 未出现 / 无法确认 + 当日证据**。
用户打开盘中指引即见「昨日关注回顾」,不再需要自己缝合昨晚承诺与今天观察。

非目标:不改复盘生成逻辑、不改调度窗口、不引入反向数据流(链路 B 仍不写回链路 A 对象)。

## 2. 契约变更清单(先改这里,再写实现)

| # | 基线文档位置 | 现状 | 变更 |
|---|---|---|---|
| 1 | §3.1 调用图第 5 步 | `makeNextHourGuidanceContext()` 组装 context(含链路 A 边界) | 注入来源**增加** `marketCloseReviewArchive` 的 `tomorrowWatch`(存在且为上一交易日/当日快照时) |
| 2 | §3.2 提交模型 | `submit_next_hour_guidance` schema:headline/posture/summary/actions/risk_checks | **新增可选** `followup_reviews` 数组(见 §3);不提供时行为与现状逐字节一致 |
| 3 | §3.2 校验链 | `validate()` + `TrendClaimEvidencePolicy` 双层 | validate 新增回指规则(见 §4):**confirmed 必须挂当日有效证据,否则强制降级 inconclusive** |
| 4 | §3.4 数据流 | 链路 A 单向注入 latestTrend* | 同一节追加:收盘复盘快照(`MarketCloseReviewArchive`)同属单向注入,方向与链路 A 边界一致 |
| 5 | §3.2 输出模型 | `NextHourGuidanceReport` 固定字段 | 新增 `followupReviews: [NextHourFollowupReview]`,`decodeIfPresent` 向后兼容旧存档 |
| 6 | §3.2 V2 | 3+1 子 Agent 编排 | **只改汇总决策层**的 submit schema 与 prompt,三个子 Agent(行情/新闻/持仓)不动,缩小爆炸半径 |
| 7 | #8 附带 | 流式 usage 尾包在 `StreamAggregator.append` 被丢弃(OpenAICompatibleAgentClient.swift:685) | 尾包 `usage` 字段捕获 → `AgentCompletionResult.usage` → artifact 落盘(见 §7) |

Characterization 测试更新原则:现有断言**全部保留**(无昨晚快照时新旧行为一致,characterization 本身应继续通过);新增「有快照时」的基线用例。`NextHourGuidanceCharacterizationTests` 预计新增 3-4 个用例而非改写。

## 3. 数据与 Schema 设计

### 3.1 注入(Core)

```swift
// NextHourGuidanceContext 新增(全部可选,无值时与现状一致):
let lastCloseReview: LastCloseReviewContext?

struct LastCloseReviewContext: Codable, Hashable, Sendable {
    let generatedAt: String        // 昨晚复盘生成时间
    let tomorrowWatch: [String]    // 明日关注(通常 ≤3 条)
}
```

组装规则(`makeNextHourGuidanceContext`):`marketCloseReviewArchive` 存在、`generatedAt` 为**当前日期的前一个交易日或当日**(不注入更早的陈旧复盘)、`tomorrowWatch` 非空 → 注入;否则 nil。数据零新增存储(复用 P1 批次依赖的同一冻结快照)。

### 3.2 提交模型(模型输出)

```json
"followup_reviews": [
  { "item_index": 0,
    "status": "confirmed" | "not_seen" | "inconclusive",
    "note": "红利板块午后放量,成交额较昨日同期 +18%",
    "evidence_ids": ["market:live:..."] }
]
```

- 全字段可选解码(`decodeIfPresent` + 容错),`item_index` 必须对应注入的明日关注下标
- `NextHourGuidanceReport.followupReviews: [NextHourFollowupReview]`,旧存档解码为 `[]`

### 3.3 Prompt 增量(V1 system prompt + V2 汇总层各加一段)

> 若上下文含 last_close_review 的明日关注:必须在 followup_reviews 中逐条回指。
> status=confirmed 必须引用**今日**证据(行情快照/搜索结果),仅凭记忆或推断一律用 inconclusive;
> not_seen 表示明确查过但未出现;无法查询的用 inconclusive。没有 last_close_review 时不要提交该字段。

## 4. 校验规则(防幻觉核心,写进 validate)

1. `item_index` 越界或重复 → 整条丢弃并计入 warnings(不 fail 整个提交,回指是增强不是门槛)
2. `status == confirmed` 但 `evidence_ids` 为空或全部不在 ledger → **强制降级为 inconclusive**,warnings 记录「回指缺证据已降级」
3. `confirmed` 引用的证据 `publishedAt/采集时间` 早于当日 00:00 → 降级(昨日证据不能证明今日出现)
4. 注入了 N 条关注但回指数 > N → 越界部分丢弃
5. followup_reviews 与 actions 校验**相互独立**:回指不合格不影响买卖建议的有效性(主流程稳定性优先)

## 5. UI 呈现(2026-08-19 评审决定:放更靠下)

`NextHourGuidanceDecisionConsole` 底部、**「查看完整依据」操作行之后、免责声明之前**插入「昨日关注回顾」块
(评审决定:不插在姿态行与优先动作之间,不打扰主结论):
- 每行:`✓/○/?` 图标 + 关注原文(截断)+ 状态词(已出现/未出现/无法确认)+ note(一行)+ 证据可点(复用 EvidencePopover)
- 全部 inconclusive/not_seen 时块仍显示——如实呈现"昨晚的关注今天没兑现"本身就是信息
- 样式对齐 `NextHourGuidancePriorityActionsView`;macOS 先行,iOS 次批
- 其余评审点默认采纳方案原设计:confirmed 无证据→强制降级 inconclusive;V2 合入后实跑 3-5 个交易时段对比再定去留

## 6. 测试计划

| 层 | 用例 |
|---|---|
| Context 组装 | 有当日/上一交易日快照→注入;无快照/陈旧(>1 交易日)/空 watch→nil |
| 解码 | followup_reviews 缺失→[];字段容错;item_index 越界丢弃 |
| validate | confirmed 无证据→降级;昨日证据→降级;正常 confirmed 保留;回指问题不影响 actions |
| Report 兼容 | 旧 JSON 存档解码通过且 followupReviews==[] |
| V2 | 汇总层透传回指;子 Agent 输入输出不变(既有 V2 测试全绿即为证明) |
| Prompt | 源码断言:V1/V2 汇总 prompt 含回指指令段落 |
| Characterization | 新增「有快照」基线用例 3-4 个;**现有用例零修改**(无快照路径行为不变) |

## 7. #8 成本可观测(同批附带,可独立砍掉)

链路:`StreamAggregator.append` 捕获 usage 尾包(`chunk.usage` 的 prompt/completion_tokens)→ `AgentCompletionResult` 新增 `usage: AgentTokenUsage?` → Agent 循环内按 tool call 累计 → `TrendAgentRunArtifact` 落盘(新增可选字段,旧 artifact 兼容)→ 复盘卡/雷达卡脚注「上次研究 ~X.X 万 tokens」。
注意:供应商不回 usage 尾包时字段为 nil,UI 不显示——不硬求。

## 8. 实施切分(每步独立提交,顺序即依赖)

| 步 | 内容 | 回滚点 |
|---|---|---|
| S1 | 基线文档 §3 更新 + characterization 新用例(此时红) | 文档 |
| S2 | Core:context 注入 + schema/解码 + validate 规则 + Report 字段 | 纯增量,无 prompt 改动→模型不会输出该字段→线上无行为变化 |
| S3 | Prompt(V1 + V2 汇总层)+ 降级链路 | 模型开始实际回指;异常时回退 S3 单个提交即可 |
| S4 | UI 回顾块 + iOS(次批) | 纯展示 |
| S5 | #8 usage 链路 | 独立,可砍 |

关键安全设计:**S2 合入后即使 S3 未合,系统行为与现在完全一致**(模型不会输出未要求的字段);真正的行为切换只在 S3。

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| 模型幻觉回指(没查就说 confirmed) | validate 强制证据门槛 + 当日时效校验;降级而非放行 |
| 回指失败拖垮主流程 | 回指与 actions 校验解耦;丢弃而非 fail |
| V2 汇总层 prompt 复杂化导致整体质量回退 | 只改汇总层不动子 Agent;S3 合入后对比 3-5 个交易时段的输出再定去留 |
| 陈旧复盘误导(周末/假期) | 注入窗口限定上一交易日/当日;更早不注入 |
| prompt token 增量 | 明日关注 ≤3 条短句,增量 <100 token,可忽略 |

## 10. 验收标准

1. 有昨晚复盘的交易时段:盘中研判含 followupReviews,每条 confirmed 挂当日有效证据,UI 可见三件事兑现状态
2. 无昨晚复盘/周末:行为与当前版本完全一致(characterization 证明)
3. 人为构造「confirmed 无证据」的提交:被降级为 inconclusive 且 warnings 有记录
4. 旧 `next-hour-guidance` 存档:正常解码,followupReviews 为空
5. 全量 swift test 通过;基线文档与 characterization 与实现同 PR 更新
