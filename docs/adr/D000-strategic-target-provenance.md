# D000. Strategic Target Provenance

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-4；Epic 10 DEC-1

## Context

「投资组合应该配成什么样」是这个系统的核心输出。在 V3.1 设计里，目标配置（Strategic Target Allocation）的来源非常敏感：

- 用户可能显式指定（「我想股 6 债 4」）
- 用户可能选择目录里的模板（晓磊「基金全磊打」、长赢、且慢投顾组合）
- LLM / Agent 可能「建议」某模板
- 数据变化、信号变化都可能诱导系统「顺手调一下目标」

如果让 LLM、Signal、Factor 都能改 Target，会产生：

- **目标漂移**：每次重平衡目标都变，组合变成追涨杀跌的「战术操作」而不是战略配置
- **不可审计**：今天的目标是 LLM 昨天改的，明天的目标是今天的 Signal 改的，无法回答「为什么是这个目标」
- **责任错位**：目标本应由用户/模板负责（战略层），系统擅改等于越权

现有代码（`Core/InvestmentIntelligence/`）的 DecisionCase + LLM Agent 让模型直接产生行动建议，是本计划要替代的核心问题之一——没有把「目标来源」单独防火墙出来。

V3.1 §46 / V2.2 把决策层切成多个 Cardinal（基数）量：Target、Δw（Sizing）、Criterion score、Comparison 结果、Decision 本身。本 ADR 是第一道防火墙：**Target 的来源必须显式、可审计、不可被非授权源修改**。

备选方案：

1. **Target 是 LLM 输出的一部分**：目标漂移、不可审计、责任错位三连
2. **Target 是数据派生（如市场均值）**：仍是「系统擅改目标」，且依赖数据可信度
3. **Target 显式 provenance + 修改门禁**（本决策）：Target 必须带 `TargetAllocationProvenance`，只允许 `explicitUserAllocation` / `userSelectedTemplate` 两类来源；Signal / Factor / LLM / Agent 都不能改 Target，Agent 只能「推荐目录里已有的模板」给用户确认

## Decision

**Strategic Target Allocation 必须带 TargetAllocationProvenance；只允许 explicitUserAllocation / userSelectedTemplate 两类来源；Signal/Factor/LLM/Agent 都不能改 Target。**

1. **TargetAllocationProvenance 类型**（DEC-1）：
   - `explicitUserAllocation`：用户显式配置（手输权重）
   - `userSelectedTemplate`：用户从目录选择的模板（晓磊 / 长赢 / 且慢投顾组合）
   - 两类都带 provenance 元数据（用户 ID / 选择时间 / 模板版本 / 是否经 Agent 推荐）

2. **Signal 不能改 Target**（D000 Cardinal Firewall 第一道）：
   - `InvestmentSignal` / `PortfolioRiskProfile` / `ExposureEstimate` 都是只读输入，Target 不依赖它们
   - 信号只能影响 Δw（Sizing，见 D001）和 Criterion（D002），不能反向改 Target
   - 即使是「风险信号超阈值」也只能触发 remediation（DEC-2），不能修改 Target

3. **Agent 只能推荐目录已有模板**：
   - Agent / LLM 可以建议用户「考虑晓磊模板」，但用户必须显式确认才写入 Target
   - Agent 不能凭空生成新 Target、不能混合多个模板生成「合成目标」
   - 模板目录本身是显式数据（Epic 10 DEC-1），不在 Agent 控制下

4. **StrategicAllocationValidator**（DEC-1）：
   - 校验 Target 配置完备（所有资产类有目标）
   - 校验 provenance 合法（不是 Signal / LLM 来源）
   - 校验权重和为 1（不允许「剩余配 cash」类隐式行为，必须显式）
   - Validator 失败时拒绝写入 Target，不让脏数据进系统

5. **Target 修改是显式事件**：每次 Target 变更带 (user/agent、新 provenance、变更时间、原因)。变更不可静默、不可批量、不可被数据更新触发。

## Consequences

- **Positive**：
  - Target 稳定可信，组合行为符合「战略层」语义
  - Target 100% 可审计：任何时候都能回答「这个目标是谁、何时、为什么定的」
  - 用户对战略配置有完全控制权，系统不越权
  - 与现有「主理人模板 / 投顾组合目录」用户心智一致（晓磊 / 长赢都是用户主动选）

- **Negative**：
  - Agent 不能自动优化 Target，体验上「不够智能」（但这是刻意的，Target 是战略层不应自动）
  - 用户改 Target 是手动操作，频繁度低；如果用户长期不改，Target 老化需要 UI 提醒
  - Validator 严格可能拒绝边界情况（如权重和 0.999），需要 UI 友好提示

- **Neutral**：
  - Target 不依赖数据，离线状态下战略层仍可运行
  - D001（Sizing）/ D002（Criterion）才是受 Signal / Factor 影响的 Cardinal，本 ADR 只锁定 Target

## Compliance Check

- **DEC-1 测试**：`StrategicAllocationPolicy` / `AllocationTarget` / `TargetAllocationProvenance` 三类型完整；`StrategicAllocationValidator` 拒绝非授权来源
- **D000 Cardinal Firewall 测试**：构造「Signal 改 Target」场景，Validator 拒绝
- **DEC-9 Decision Replay 测试**：同 mock Target + Signal → 同决策，Target 部分稳定
- **M7 验收**（rollout §4.5）：Cardinal Firewall 闭环，任何 Δw 可追溯到合法 provenance，Target provenance 必须在 D000 允许集合内
- **PR checklist**：
  - Target 写入路径出现 Signal / LLM 来源 → 拒绝
  - Agent 代码直接生成 Target（不经用户确认）→ 拒绝
  - Validator 被绕过（如直接写 Repository）→ 拒绝

## References

- rollout §3 Epic 10 DEC-1、§4.5 M7 验收
- V3.1 §46（Cardinal / Ordinal 区分）
- 关联 ADR：
  - DATA001（Canonical Identity）：Target 资产类的 Identity 锚点
  - D001（Sizing Provenance）：Δw 的来源门禁，是 Target 之外的另一个 Cardinal
  - D002（Criterion Provenance）、D003（Comparison Provenance）：信号驱动的 Cardinal
  - D004（Decision Replay Boundary）：决策重放引用 Target ID 不重算
