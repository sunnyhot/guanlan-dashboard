# D004. Decision Replay Boundary

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-4；Epic 10 DEC-9

## Context

「这个决策是怎么做的」需要在事后能精确回答。如果每次重算都要重跑 Research / Factor / Criterion / Comparison，会产生：

- **LLM 调用浪费**：Research 是最贵的步骤（RES-1 model gateway），重算时不需要再问 LLM
- **不可复现**：LLM 是非确定的，同一 prompt 不同时间可能给不同 Signal
- **时序错乱**：重算时数据已变（如新 vintage），结果与「当时的决策」不符
- **审计失败**：事后无法精确回答「当时依据的是哪些 Signal、哪些 criterion version」

V3.1 §38 / V2.2 §83 强调：决策必须可重放，且重放时引用 Signal / criterion version 的 ID，不重跑上游。本 ADR 把这一原则变成可执行的 Cardinal Firewall。

现有代码（`Core/InvestmentIntelligence/`）的 DecisionCase 重算时重新跑 LLM Agent，是本计划要替代的核心问题之一——没有「重放边界」概念。

备选方案：

1. **每次决策都全链路重跑**：LLM 浪费、不可复现、时序错乱
2. **只存最终决策结果**：无法回答「为什么」、无法 partial 重算
3. **决策引用上游 ID，重放只跑被引用的部分**（本决策）：Decision artifact 引用 Signal IDs / criterion versions / factor snapshots，重放时按引用取，不重跑 Research

## Decision

**Decision artifact 引用上游 IDs（Signal / Criterion version / Factor snapshot）；重放时按引用取，不重跑 Research。**

1. **PortfolioDecisionArtifact 结构**（DEC-9）：
   - 引用层：`signalIDs` / `criterionVersions` / `factorSnapshotIDs` / `targetVersion` / `indifferenceBandVersion`
   - 结果层：胜出的 PortfolioActionPlan（含 Δw + SizingProvenance，D001）+ comparison 结果（D003）
   - 元数据：决策时间、决策上下文（KnowledgeContext，DATA002）

2. **DecisionValidator**（DEC-9）：
   - 校验 artifact 完备：所有引用 ID 都能解析到具体实例
   - 校验 provenance 闭环：Δw 可追溯到 target/remediation/user（D001），criterion 可追溯到 deterministic evaluator（D002），comparison 可追溯到 IndifferenceBand version（D003）
   - 校验 Target provenance 合法（D000）
   - Validator 失败时拒绝产出 artifact

3. **Replay 边界**：
   - 重放 = 按 artifact 引用的 IDs 取当时的 Signal / criterion / factor / Target / band，重新跑 DecisionPlanner
   - 重放**不重跑** Research（不调 LLM）、不重抓数据、不重算 factor
   - 同 IDs → 同决策（DEC-9 replay test）

4. **引用 IDs 不可变**：
   - artifact 一旦写入，引用 IDs 永不更改
   - 上游实例（Signal / criterion version）被 supersede 时，旧 artifact 仍引用旧 ID（DATA008 vintage 语义）
   - 不允许「重放时用最新 version 替换引用」（破坏复现性）

5. **重放支持的范围**：
   - 完整重放：所有引用 IDs → 重跑 Planner → 同决策
   - Partial 重放：替换部分引用（如换 Signal ID）→ 跑 Planner → 看差异（用于 what-if 分析）
   - Partial 重放结果作为新 artifact，不影响原 artifact

6. **LLM 重放豁免**：LLM 的非确定性通过「引用 Signal ID 不重跑 Research」隔离。Signal 本身进 Signal Store（RES-6），跨运行可查、可引用。

## Consequences

- **Positive**：
  - 决策 100% 可重放，事后能精确回答「为什么」
  - LLM 调用最小化，重放不烧 token
  - 支持 what-if 分析（partial 重放），提升决策可信度
  - 审计完备：artifact + 引用 IDs + 上游实例完整链路可查

- **Negative**：
  - artifact 结构复杂（引用层 + 结果层 + 元数据），开发成本高（DEC-9 是 3 点但前置依赖多）
  - 上游实例必须永久保留（Signal / criterion version 不能删），存储成本
  - partial 重放需要 UI 支持，否则用户不会用

- **Neutral**：
  - 重放是确定性算法，离线 / 无 LLM 仍能运行
  - 这是 Cardinal Firewall 的最后一道（D004），闭环 D000-D003

## Compliance Check

- **DEC-9 测试**：`PortfolioDecisionArtifact` 含引用层 + 结果层 + 元数据；`DecisionValidator` 校验闭环
- **D004 replay 测试**：同 mock inputs（Signal / criterion / factor / Target / band IDs）→ 同决策
- **引用不可变测试**：artifact 写入后引用 IDs 不更改；上游 supersede 时旧 artifact 仍引用旧 ID
- **M7 验收**（rollout §4.5）：same mock inputs → same decision；Cardinal Firewall 闭环
- **PR checklist**：
  - Decision artifact 缺引用 IDs（只存最终结果）→ 拒绝
  - 重放代码重跑 Research / LLM → 拒绝（必须按引用取）
  - 上游实例被 supersede 时旧引用被改 → 拒绝
  - 引用 IDs 指向不存在的实例 → Validator 拒绝

## References

- rollout §3 Epic 10 DEC-9、Epic 11 RES-6（Signal Store）、§4.5 M7 验收
- V3.1 §38（Decision Replay）、V2.2 §83
- 关联 ADR：
  - D000（Strategic Target Provenance）：artifact 引用 Target version
  - D001（Sizing Provenance）：artifact 含 Δw + SizingProvenance
  - D002（Criterion Provenance）：artifact 引用 criterion versions
  - D003（Comparison Provenance）：artifact 引用 IndifferenceBand version + comparison 结果
  - DATA002（PIT Visibility）：artifact 元数据含 KnowledgeContext
  - DATA008（Observation Revision）：上游 vintage 永久保留支撑引用
