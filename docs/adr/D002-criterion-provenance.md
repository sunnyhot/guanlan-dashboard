# D002. Criterion Provenance

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-4；Epic 10 DEC-7

## Context

「为什么 A 比 B 好」需要可解释的评价标准（Criterion）。Criterion 极易黑箱化：

- 用「分数」直接比较（如 A 得 8.5 分、B 得 7.2 分），但分数怎么算的不清
- 用 LLM 直接产出「分数」或「偏好」，黑箱不可审
- 用「机器学习模型」打分，模型权重不可解释
- 同一 criterion 在不同时间用不同公式，比较结果漂移

如果 criterion 黑箱，会产生：

- **不可审计**：无法回答「为什么选 A 不选 B」
- **不可重放**：criterion 公式变了，历史决策无法复现
- **不可争议**：用户对决策有异议时，系统无法解释，只能「相信模型」

V3.1 §46 明确区分 Cardinal（基数）和 Ordinal（序数）：Criterion 是 cardinal 量（带具体数值和单位），由 deterministic evaluator 算出，不允许黑箱。本 ADR 把这一原则变成可执行的门禁。

现有代码（`Core/InvestmentIntelligence/`）的 DecisionCase 用 LLM 产出「评分 / 优先级」，是本计划要替代的核心问题之一。

备选方案：

1. **LLM 直接产 criterion 分数**：黑箱不可审，违反 V3.1 铁律
2. **ML 模型打分**：权重不可解释，且违反 FREE001（训练 / 推理基础设施）
3. **deterministic evaluator + provenance**（本决策）：每个 criterion 必须有 versioned deterministic evaluator + inputReferences，黑箱 criterion 禁止

## Decision

**每个 Criterion 必须有 versioned deterministic evaluator + inputReferences；黑箱 criterion（LLM/ML 直接产分）禁止。**

1. **CriterionDefinition 类型**（DEC-7）：
   - 含 `id` / `version` / `evaluator` / `inputReferences`
   - `evaluator` 是 deterministic 函数：给定明确输入产出明确 cardinal 值（Decimal + 单位）
   - `inputReferences` 引用具体 observation / factor / signal 的 ID，可追溯
   - criterion 公式变更走新 version，旧决策重放用旧 version

2. **CriterionEvaluator 是 deterministic**（DEC-7）：
   - 同输入同输出，无随机性
   - 输入只能是 Cardinal 量（factor metric / observation value），不能是 ordinal signal 直接打分
   - ordinal signal（如「momentum 偏弱」）必须先经 SignalPolicy（FAC-2）转 cardinal（如具体 return 值）才能进 evaluator

3. **黑箱 criterion 禁止**：
   - 不允许 LLM 直接产 criterion 分数（LLM 只产 Signal / Thesis / Narrative）
   - 不允许 ML 模型打分（违反 FREE001 + 不可解释）
   - 不允许「专家权重」类手工常数（除非 provenance 标注为 heuristic policy，类似 IndifferenceBand）

4. **LLM 的合法路径**：LLM 通过 Signal → Criterion 间接影响：
   - LLM 产 Signal（ordinal，如「该标的 momentum 偏弱」）
   - SignalPolicy 转 cardinal（FAC-2，如具体 return = -2.3%）
   - CriterionEvaluator 用 cardinal 算分
   - 这条路径里 LLM 影响被显式约束在 ordinal → cardinal 转换，不直接产分

5. **Criterion 是 cardinal 量**（V3.1 §46）：
   - 不进 ordinal 运算（不直接比较「强 / 弱」）
   - 单位明确（return % / volatility / drawdown）
   - 进入 Comparison（D003）的是 cardinal 值，不是 ordinal 排名

## Consequences

- **Positive**：
  - 任何 criterion 分数可审计：公式、输入、版本全可追溯
  - 决策可重放（DEC-9）：同输入 + 同 criterion version → 同分数
  - LLM 影响被显式约束，不黑箱决定结果
  - 用户对决策有异议时，系统能解释「这个分是这样算的」

- **Negative**：
  - criterion 公式必须显式编写，开发成本高（DEC-7 是 5 点）
  - LLM「智能性」受限，不能直接打分（但这是刻意的）
  - heuristic policy 常数（如阈值）需要 provenance 标注，不能随手写

- **Neutral**：
  - Criterion 是确定性算法，离线 / 无 LLM 仍能运行
  - D003（Comparison）是 criterion 之上的比较层，本 ADR 只锁定 criterion 本身

## Compliance Check

- **DEC-7 测试**：`CriterionEvaluator` + `CriterionDefinition` 含 id/version/evaluator/inputReferences；deterministic 测试（同输入同输出）
- **D002 黑箱 criterion 测试**：构造「LLM 直接产分」场景，Evaluator 拒绝
- **FAC-2 SignalPolicy 测试**：ordinal signal → cardinal 转换可追溯
- **DEC-9 replay 测试**：同输入 + 同 criterion version → 同分数
- **M7 验收**（rollout §4.5）：Cardinal Firewall 闭环，任何 criterion 分数可追溯到 deterministic evaluator
- **PR checklist**：
  - Criterion evaluator 出现 LLM / ML 调用 → 拒绝
  - Criterion 分数缺 provenance（公式 / 输入 / 版本）→ 拒绝
  - Ordinal signal 直接进 criterion 比较（不经 SignalPolicy 转 cardinal）→ 拒绝
  - heuristic 常数无 provenance 标注 → 拒绝

## References

- rollout §3 Epic 10 DEC-7、Epic 7 FAC-2、§4.5 M7 验收
- V3.1 §46（Cardinal / Ordinal 区分）
- 关联 ADR：
  - D001（Sizing Provenance）：Δw 的来源门禁
  - D003（Comparison Provenance）：Criterion 之上的比较
  - D004（Decision Replay Boundary）：Criterion 重放引用 version 不重算
  - DATA003（Raw Market Canonicalization）：Criterion 输入的 Cardinal 强类型
