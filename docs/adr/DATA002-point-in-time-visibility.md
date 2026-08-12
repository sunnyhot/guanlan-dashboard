# DATA002. Point-in-Time (PIT) Visibility

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-4/6；Epic 3 REPO-5a；Epic 7 FAC-8

## Context

回测与「今天该怎么做决策」是同一个问题的两面：**给定某个历史时刻 T，系统当时到底知道什么、不知道什么**。如果这个语义不清，会产生一系列「lookahead bias」幻觉：

- 用 Q2 持仓（7-20 才公告）去算 7-10 的归因 → 假装 7-10 就知道持仓
- 用今天才修过的 vintage 数据去重算历史决策 → 用未来信息污染过去
- 把「现在能查到」当成「当时能查到」 → 因子回测全是幸存者偏差

现有代码（`Core/InvestmentIntelligence/` 和 `TrendResearch`）没有显式 PIT 语义，所有数据按「最新值」消费，无法做可信回测。

备选方案：

1. **每个查询都带时间戳，让 Provider 自己判断可见性**：Provider 不可能知道用户「当时」是否真看到了，且 Provider 自己也在修订历史数据，不可靠
2. **只存最新值，回测用近似**：等价于放弃回测可信度，Factor/Risk/Attribution 全部不可信
3. **三种 query mode + 四时间戳包裹**（本决策）：每个观测有 `TemporalEnvelope`（effectiveAt / publishedAt / availableAt / ingestedAt），查询用 `KnowledgeContext` 显式声明「客观经济可知 / 本机实际已知 / 精确 vintage」三种模式之一

## Decision

**每个 CanonicalObservation 必须带 TemporalEnvelope，Repository 每个 API 必须强制 KnowledgeContext 入参。**

1. **TemporalEnvelope 四时间**（DOM-4）：
   - `effectiveAt`：观测值描述的经济事件发生时间（如 2024-06-30 基金持仓的实际日期）
   - `publishedAt`：数据源对外公布的时间（如基金季报 2024-07-20 公告）
   - `availableAt`：**客观经济可知**时间——数据客观上进入公开世界的最早时间（由 AvailabilityPolicy 推导，可能晚于 publishedAt）
   - `ingestedAt`：**本机实际已知**时间——本系统实际抓到并入库的时间（受 Provider 故障 / 抓取调度影响）
   - **`availableAt` 与 `ingestedAt` 之间不存在固定顺序**（§Decision 4）：保守策略可能把 availableAt 推迟到下一交易日而本机当天就抓到（availableAt > ingestedAt），Provider 故障也可能让 ingestedAt 远晚于 availableAt（availableAt < ingestedAt）。两者是语义不同的时间戳，不建立全序。

2. **三种 Query Mode**（DOM-6 `DataQueryMode`）：
   - `economicKnowledge(asOf: T)`：客观经济可知——只返回 `availableAt ≤ T` 的观测，**不看 ingestedAt**。回测 / 历史重算 / 历史决策重放必须用此模式，保证「同一外部信息集 → 同一决策」
   - `operationalKnowledge(asOf: T)`：本机实际已知——返回同时满足 `availableAt ≤ T` **且** `ingestedAt ≤ T` 的观测。用于实时 UI / 历史界面还原「当时 App 实际能给用户看什么」，承认本机可能滞后于客观可知
   - `exactSnapshot(at: T)`：精确 vintage 查询——返回 `effectiveAt = T` 的所有 vintage（DATA008 revision 场景用）

3. **Repository API 强制入参**（REPO-1）：每个 Observation 类 Repository 方法签名必须带 `KnowledgeContext`，不允许「无上下文查询」存在。没有 `KnowledgeContext` 入参的 Observation 查询通不过协议审查。
   - **例外（Identity / Calendar 域）**：`InstrumentRepository`（Instrument / Listing / LegalEntity / FundProduct / FundShareClass 查询）和 `CalendarRepository`（交易日历）**不带 KnowledgeContext**。这些实体的定义本身是 timeless 的（Instrument 的发行人、Listing 的交易所、法域节假日历），不随 effectiveAt 变化。Identity 的「修订」走新 InstrumentID（而非新 vintage），Calendar 是静态参考数据。若未来某 Identity 字段需要历史追溯（如变更过交易所的 Listing），会另立带版本号的实体，而非给本协议加 context。此例外在 REPO-1 协议注释 + 本 ADR 显式声明，PR 审查不再就 Identity / Calendar 缺 context 提异议。

4. **availableAt 与 ingestedAt 解耦**：`TemporalEnvelope.validate()` 只校验客观事件链 `effectiveAt ≤ publishedAt ≤ availableAt`，**不校验 `availableAt ≤ ingestedAt`**。两个语义不同的时间戳由不同 query mode 分别消费：economicKnowledge 只看 availableAt，operationalKnowledge 同时看两者。

5. **PIT 标注由 TemporalNormalizer 完成**（REPO-5a）：ProviderRecord → CanonicalObservation 时，基于 AvailabilityPolicy（DOM-7）自动计算 `availableAt`，不让 Provider 自己声明。例如基金 Q2 持仓 `effectiveAt = 2024-06-30`、`publishedAt = 2024-07-20`，AvailabilityPolicy 推导 `availableAt = nextTradingDay(2024-07-20) = 2024-07-22`（2024 中国日历，7-20 周六）。Provider 故障延迟到 `ingestedAt = 2024-08-01` 时，availableAt 仍记客观的 7-22。

## Consequences

- **Positive**：
  - 回测 / 历史重算 / 决策重放有可信的「客观可知」语义（economicKnowledge），消除 lookahead bias
  - 实时 UI / 历史界面有「本机实际已知」语义（operationalKnowledge），如实反映「App 当时能看到什么」
  - 同一份历史数据可在不同 vintage 下重算（配合 DATA008），因子 golden test 成为可能（FAC-8）
  - 决策可审计：任何一笔历史决策都能回答「当时你依据的是哪些观测」

- **Negative**：
  - 查询代价更高：每次都要带 context，索引也要按 vintage 多版本组织（GRDB-3/4 multi-vintage schema）
  - 开发者负担：忘记传 context 是常见错误，必须靠 Repository 协议签名强制
  - Provider 故障、修订、补披露都需要在 ingestedAt/availableAt 上精确处理，维护成本高
  - 两种「可知」语义可能让开发者混淆，需要文档与命名明确区分

- **Neutral**：
  - 99.9% 的实时查询（今天该怎么做）走 `economicKnowledge(asOf: now)` 或 `operationalKnowledge(asOf: now)`，两者在 Provider 正常时结果一致
  - 0.1% 的回放/回测走 explicit vintage，这部分慢但可信

## Compliance Check

- **DOM-4 测试**：`TemporalEnvelope` 的四时间字段齐全，Codable round-trip；validate() **不校验** availableAt ≤ ingestedAt
- **DOM-6 测试**：`KnowledgeContext` 三种 mode 的 API 不可互换；operationalKnowledge 同时校验 availableAt + ingestedAt
- **REPO-1 协议审查**：Repository 协议每个方法签名都有 `KnowledgeContext` 参数；编译期不可省略
- **REPO-5a 测试**：`TemporalNormalizer` 把 ingestedAt 与 availableAt 分开标注；M2 验收场景 4 通过
- **FAC-8 golden test**：固定历史序列 → 固定 factor 输出，跨 vintage 一致
- **M2 验收场景 3**：基金 Q2 持仓 7-20 公告（→ availableAt = 7-22），`economicKnowledge(asOf: 7-10)` 查不到（rollout §4.1）
- **PR checklist**：任何业务层代码直接读「最新值」、绕过 KnowledgeContext，直接拒绝；任何代码假设 `availableAt ≤ ingestedAt` 恒成立，直接拒绝

## References

- rollout §3 Epic 2 DOM-4/6、Epic 3 REPO-1/5、Epic 7 FAC-8
- rollout §4.1 M2 验收场景 3/4/5
- 关联 ADR：
  - DATA001（Canonical Identity）：PIT 查询的稳定锚点
  - DATA005（Economic Availability Semantics）：`availableAt` 的经济可知语义
  - DATA008（Observation Revision）：vintage 多版本与 exactSnapshot 模式
  - DATA009（Model Validation Before Persistence Freeze）：M2 验收通过才能冻结 schema
