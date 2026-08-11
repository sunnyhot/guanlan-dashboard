# D003. Comparison Provenance

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-4；Epic 10 DEC-8

## Context

「为什么这个 plan 比那个 plan 好」（Comparison）是决策的最后一步。Comparison 极易产生不可解释的结果：

- 用「加权平均分」直接比较，但权重怎么来的不清
- 用「Pareto 优超」但忽略 incomparable / unknown 情况
- 用「排序取第一」但忽略非传递性（A > B, B > C, C > A）
- 用 LLM 直接产「偏好」或「胜者」，黑箱

如果 comparison 黑箱或语义不清，会产生：

- **不可解释的胜者**：选了 A 但说不清为什么
- **不可重放**：比较规则变了，历史决策无法复现
- **unresolvedTradeoff 被吞掉**：明明应该让用户裁决的场景被系统强行决定，掩盖真实的多目标权衡
- **非传递性被忽略**：A > B > C > A 时强行取「最优」会得到任意结果

V3.1 §46 / V2.2 §50 强调：Comparison 必须显式处理 incomparable / unknown / 非传递性；unresolvedTradeoff 是真实存在的决策状态，不是装饰枚举。本 ADR 把这一原则变成可执行的 Cardinal Firewall。

现有代码（`Core/InvestmentIntelligence/`）的 DecisionCase 用 LLM 产出「优先级排序」，是本计划要替代的核心问题之一——没有显式处理非传递性和 unresolvedTradeoff。

备选方案：

1. **加权平均分取最高**：权重黑箱、忽略非传递性、吞掉 unresolvedTradeoff
2. **LLM 直接产胜者**：黑箱不可审
3. **Pareto + IndifferenceBand + Partial DecisionPolicy**（本决策）：显式处理 incomparable / unknown / 非传递性，unresolvedTradeoff 可触发

## Decision

**Comparison 必须显式处理 incomparable / unknown / 非传递性；unresolvedTradeoff 是真实决策状态，可触发。**

1. **CriterionComparator 是 deterministic**（DEC-8）：
   - 输入：多个 PortfolioActionPlan 各自的 Criterion scores（来自 D002）
   - 输出：Pareto dominance 关系（A dominate B / B dominate A / incomparable）
   - 不允许「加权平均」类聚合（权重黑箱），只允许 Pareto 语义

2. **IndifferenceBand**（DEC-8）：
   - 当两个 plan 在某 criterion 上差异 < band 时视为 indifferent
   - band 是 heuristic policy，**必须显式标注 provenance**（version / 阈值 / 理由）
   - 类似 FAC-2 SignalPolicy 的阈值标注，heuristic 不允许静默

3. **Pareto Filter（Effective Dominance）**（DEC-8）：
   - A effective dominate B：A 在所有非 indifferent criterion 上 ≥ B，且至少一个严格 >
   - incomparable：A、B 各有优势，无 dominance
   - unknown：某 criterion 输入是 unknown（联动 DATA006），阻断 dominance（不能假装 unknown = 0）
   - 多个 plan 互相 incomparable 时，不强行取唯一胜者

4. **Partial DecisionPolicy 处理非传递性**（DEC-8）：
   - 非传递性（A > B > C > A）明确处理：不强行打破循环
   - 输出 Partial Decision（部分序），不强制 total order
   - 非传递性场景下可输出 multiple admissible plans，交 Presentation 层（PRES-1）解释

5. **unresolvedTradeoff 可触发**（V2.2 §50）：
   - 当 comparison 结果是 incomparable / 非传递性循环 / unknown 阻断时，系统输出 `unresolvedTradeoff` 状态
   - unresolvedTradeoff 不是错误，是真实决策状态，交 Presentation 层 / 用户裁决
   - 系统不允许「假装决定」（如强行取第一个、取最高分）来吞掉 unresolvedTradeoff

## Consequences

- **Positive**：
  - 决策结果可解释：能说清「A dominate B 因为 …」或「incomparable 因为 …」
  - unresolvedTradeoff 被尊重，用户介入多目标权衡有明确入口
  - 决策可重放（DEC-9）：同 criterion scores + 同 IndifferenceBand version → 同 comparison 结果
  - 非传递性 / unknown 被显式处理，不产生任意结果

- **Negative**：
  - Comparison 逻辑复杂（DEC-8 是 8 点），开发成本高
  - 用户可能期待「系统直接给最优解」，unresolvedTradeoff 让用户多决策（但这是刻意的）
  - IndifferenceBand 阈值需要 provenance 维护，不能随手调

- **Neutral**：
  - Comparison 是确定性算法，离线 / 无 LLM 仍能运行
  - D004（Decision Replay）是 comparison 之上的重放边界，本 ADR 只锁定 comparison 本身

## Compliance Check

- **DEC-8 测试**：`CriterionComparator` + `IndifferenceBand` + Pareto Filter + Partial DecisionPolicy 各自有测试
- **D003 unresolvedTradeoff 测试**：构造 incomparable / 非传递性 / unknown 场景，系统输出 unresolvedTradeoff 而非强行决定
- **IndifferenceBand provenance 测试**：band 阈值必须带 version / 理由，heuristic 不静默
- **DEC-9 replay 测试**：同 criterion scores + 同 band version → 同 comparison 结果
- **M7 验收**（rollout §4.5）：unresolvedTradeoff 在构造的真实场景中可触发（非装饰枚举）
- **PR checklist**：
  - Comparison 出现「加权平均」聚合 → 拒绝（只允许 Pareto 语义）
  - LLM / Agent 直接产胜者 → 拒绝
  - unknown 被当成 0 / 默认值 → 拒绝（必须阻断 dominance）
  - unresolvedTradeoff 被吞掉（强行取唯一胜者）→ 拒绝
  - IndifferenceBand 阈值无 provenance → 拒绝

## References

- rollout §3 Epic 10 DEC-8、§4.5 M7 验收
- V3.1 §46（Cardinal / Ordinal / 非传递性）、V2.2 §50（unresolvedTradeoff）
- 关联 ADR：
  - D002（Criterion Provenance）：Comparison 的输入是 criterion scores
  - D001（Sizing Provenance）：Comparison 比的是 PortfolioActionPlan，其 Δw 来自 D001
  - D004（Decision Replay Boundary）：Comparison 重放引用 version 不重算
  - DATA006（Free Provider Fragility）：unknown 阻断 dominance 的来源
