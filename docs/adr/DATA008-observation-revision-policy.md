# DATA008. Observation Revision Policy

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 5 GRDB-3/4；Epic 2 DOM-5

## Context

数据会修订：

- 基金季度持仓首次披露 → 之后修订
- 公司年报首次发布 → 之后重述
- 宏观数据（FRED GDP）advance → second → third 三次修订
- 行情数据偶发后补 / 修正（如交易所盘后调整）
- 基金净值偶发事后修正

如果修订直接覆盖旧值，会：

- **历史决策无法重放**：2024-07-21 的决策当时基于 v1 持仓，今天用 v2 重算会得到不同结果，但「当时的决策」已经发生
- **回测不可重现**：跨 vintage 重算结果漂移，Factor golden test（FAC-8）失效
- **审计失败**：事后无法回答「这个决策当时依据的是哪个版本」

现有代码用「最新值覆盖」语义（local accumulation 是 Epic 5 才引入），无法支持 vintage 多版本。

DATA002 已经要求 PIT Visibility，但 PIT 只是「当时可知」，没解决「同一可知时点看到的是哪个 vintage」。本 ADR 补这一层。

备选方案：

1. **只存最新值**：放弃重放 / 回测可信度
2. **每个 vintage 都存但无策略**：数据膨胀，查询复杂，何时取 v1 何时取 v2 不清
3. **多 vintage + revision policy**（本决策）：按数据类型分别定义 revision 行为，schema 支持多版本，查询按 vintage 显式取

## Decision

**Canonical Store 按 (canonicalID, effectiveAt, vintage) 多版本存储；修订走新 vintage 不覆盖旧值；查询按 vintage 显式取。**

1. **schema 多版本**（GRDB-3/4）：
   - `daily_bars`：99.9% 走简单查询（同一交易日 1 个 vintage，DATA008 行情单 vintage 简化），偶发修订追加 vintage
   - `holding_snapshots` / `allocation_snapshots`：multi-vintage 必备（基金披露常修订）
   - `nav_observations`：偶发修订走 vintage
   - `corporate_actions`：multi-vintage（公司行动重述）
   - `macro_observations`：对齐 FRED vintage（advance / second / third）

2. **vintage 含义**：vintage 是「某次公布 / 修订的版本号」，由 (announcementDate, publisherVersion) 唯一。同一 effectiveAt 可有多 vintage，每个 vintage 带自己的 TemporalEnvelope（availableAt 不同）。

3. **PIT 查询语义**（联动 DATA002 / DATA005）：
   - `economicKnowledge(asOf: T)`：返回 T 时刻可知的最新 vintage（availableAt ≤ T 中最新）
   - `exactSnapshot(at: T)`：返回 effectiveAt = T 的所有 vintage（用于跨 vintage 对比、回测）

4. **修订走新 vintage，不覆盖**：
   - 基金 Q2 持仓首次披露 v1（announcementDate 2024-07-20），后续修订 v2（announcementDate 2024-08-15）
   - 写入 v2 不删除 v1；7-21 决策回放仍取 v1，9-01 决策取 v2
   - M2 验收场景 5（rollout §4.1）：模拟一次 revision，历史 vintage 查询仍看到 v1

5. **vintage 不可删除**：一旦写入永久保留（联动 DATA004 local accumulation），即使修订是「修正错误」也保留旧版本作为审计证据。

## Consequences

- **Positive**：
  - 历史决策 100% 可重放，回测跨 vintage 一致
  - Factor golden test（FAC-8）可信：固定序列 → 固定输出
  - 审计完备：任何时候都能回答「这个决策基于哪个 vintage」
  - 数据修订透明，不掩盖错误

- **Negative**：
  - 磁盘占用增加（multi-vintage 数据量 × 修订次数）
  - 查询复杂度上升（需要明确 vintage 选择策略）
  - 写入路径要处理 vintage 唯一性、防止重复写

- **Neutral**：
  - 行情类数据 99.9% 单 vintage，性能影响可忽略
  - 基金持仓 / 公司行动 / 宏观修订频繁，但数据量本身小，总开销可控

## Compliance Check

- **GRDB-3/4 schema 测试**：multi-vintage 表有 (canonicalID, effectiveAt, vintage) 唯一索引
- **DOM-5 测试**：每个 CanonicalObservation 类型支持 vintage 字段
- **M2 验收场景 5**（rollout §4.1）：模拟 v1→v2 revision，历史 vintage 查询仍看到 v1
- **FAC-8 测试**：固定历史序列 + 跨 vintage 重算，输出一致
- **PR checklist**：
  - 写入路径出现「覆盖旧 vintage」→ 拒绝
  - 业务层查询未指定 vintage 选择策略 → 拒绝
  - 删除 vintage 的代码 → 拒绝

## References

- rollout §3 Epic 2 DOM-5、Epic 5 GRDB-3/4、Epic 7 FAC-8
- rollout §4.1 M2 验收场景 5
- 关联 ADR：
  - DATA002（PIT Visibility）：vintage 是 PIT 查询的第二维
  - DATA003（Raw Market Canonicalization）：raw + adjustment 分离支撑 vintage 重算
  - DATA004（Local Accumulation）：vintage 永久保留
  - DATA005（Economic Availability Semantics）：每个 vintage 带自己的 availableAt
