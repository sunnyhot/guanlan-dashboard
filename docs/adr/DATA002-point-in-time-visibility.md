# DATA002. Point-in-Time (PIT) Visibility

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-4/6；Epic 3 REPO-5；Epic 7 FAC-8

## Context

回测与「今天该怎么做决策」是同一个问题的两面：**给定某个历史时刻 T，系统当时到底知道什么、不知道什么**。如果这个语义不清，会产生一系列「lookahead bias」幻觉：

- 用 Q2 持仓（7-20 才公告）去算 7-10 的归因 → 假装 7-10 就知道持仓
- 用今天才修过的 vintage 数据去重算历史决策 → 用未来信息污染过去
- 把「现在能查到」当成「当时能查到」 → 因子回测全是幸存者偏差

现有代码（`Core/InvestmentIntelligence/` 和 `TrendResearch`）没有显式 PIT 语义，所有数据按「最新值」消费，无法做可信回测。

备选方案：

1. **每个查询都带时间戳，让 Provider 自己判断可见性**：Provider 不可能知道用户「当时」是否真看到了，且 Provider 自己也在修订历史数据，不可靠
2. **只存最新值，回测用近似**：等价于放弃回测可信度，Factor/Risk/Attribution 全部不可信
3. **双 query mode + 四时间戳包裹**（本决策）：每个观测有 `TemporalEnvelope`（effectiveAt / publishedAt / availableAt / ingestedAt），查询用 `KnowledgeContext` 显式声明「经济可知」还是「精确快照」两种模式

## Decision

**每个 CanonicalObservation 必须带 TemporalEnvelope，Repository 每个 API 必须强制 KnowledgeContext 入参。**

1. **TemporalEnvelope 四时间**（DOM-4）：
   - `effectiveAt`：观测值描述的经济事件发生时间（如 2024-06-30 基金持仓的实际日期）
   - `publishedAt`：数据源对外公布的时间（如基金季报 2024-07-20 公告）
   - `availableAt`：客观上数据进入公开世界的最早时间（可能晚于 publishedAt，如 Provider 故障延迟）
   - `ingestedAt`：本系统实际抓到并入库的时间（永远 ≥ availableAt，受 Provider 故障影响）

2. **两种 Query Mode**（DOM-6 `DataQueryMode`）：
   - `economicKnowledge(asOf: T)`：模拟「站在 T 时刻做决策」，只返回 `availableAt ≤ T` 的观测。**回测 / 历史重算 / 历史决策重放必须用此模式**，防止 lookahead bias
   - `exactSnapshot(at: T)`：精确查询某一 vintage 的快照（DATA008 revision 场景用），返回 `effectiveAt = T` 的所有 vintage

3. **Repository API 强制入参**（REPO-1）：每个 Repository 方法签名必须带 `KnowledgeContext`，不允许「无上下文查询」存在。没有 `economicKnowledge(at:)` 入参的查询通不过协议审查。

4. **PIT 标注由 TemporalNormalizer 完成**（REPO-5）：ProviderRecord → CanonicalObservation 时，基于 AvailabilityPolicy（DOM-7）自动计算 `availableAt`，不让 Provider 自己声明。例如基金 Q2 持仓 `effectiveAt = 2024-06-30`，AvailabilityPolicy 推导 `availableAt = 2024-07-20`（公告日），即使 `ingestedAt = 2024-08-01`。

5. **ingestedAt ≠ availableAt 是一等语义**：M2 验收场景 4 明确要求 Provider 故障延迟到 8-01 抓到时，`availableAt` 仍记为 7-20（客观），`ingestedAt` 记为 8-01。7-21 的决策回放用 `economicKnowledge(asOf: 7-21)` 仍能看到这条数据。

## Consequences

- **Positive**：
  - 回测 / 历史重算 / 决策重放有可信的「当时可知」语义，消除 lookahead bias
  - 同一份历史数据可在不同 vintage 下重算（配合 DATA008），因子 golden test 成为可能（FAC-8）
  - 决策可审计：任何一笔历史决策都能回答「当时你依据的是哪些观测」

- **Negative**：
  - 查询代价更高：每次都要带 context，索引也要按 vintage 多版本组织（GRDB-3/4 multi-vintage schema）
  - 开发者负担：忘记传 context 是常见错误，必须靠 Repository 协议签名强制
  - Provider 故障、修订、补披露都需要在 ingestedAt/availableAt 上精确处理，维护成本高

- **Neutral**：
  - 99.9% 的实时查询（今天该怎么做）走 `economicKnowledge(asOf: now)`，等价于「最新可知」语义，性能与「最新值」查询无差
  - 0.1% 的回放/回测走 explicit vintage，这部分慢但可信

## Compliance Check

- **DOM-4 测试**：`TemporalEnvelope` 的四时间字段齐全，Codable round-trip
- **DOM-6 测试**：`KnowledgeContext` 两种 mode 的 API 不可互换
- **REPO-1 协议审查**：Repository 协议每个方法签名都有 `KnowledgeContext` 参数；编译期不可省略
- **REPO-5 测试**：`TemporalNormalizer` 把 ingestedAt 与 availableAt 分开标注；M2 验收场景 4 通过
- **FAC-8 golden test**：固定历史序列 → 固定 factor 输出，跨 vintage 一致
- **M2 验收场景 3**：基金 Q2 持仓 7-20 公告，`economicKnowledge(asOf: 7-10)` 查不到（rollout §4.1）
- **PR checklist**：任何业务层代码直接读「最新值」、绕过 KnowledgeContext，直接拒绝

## References

- rollout §3 Epic 2 DOM-4/6、Epic 3 REPO-1/5、Epic 7 FAC-8
- rollout §4.1 M2 验收场景 3/4/5
- 关联 ADR：
  - DATA001（Canonical Identity）：PIT 查询的稳定锚点
  - DATA005（Economic Availability Semantics）：`availableAt` 的经济可知语义
  - DATA008（Observation Revision）：vintage 多版本与 exactSnapshot 模式
  - DATA009（Model Validation Before Persistence Freeze）：M2 验收通过才能冻结 schema
