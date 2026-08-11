# D001. Sizing Provenance

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-4；Epic 10 DEC-5

## Context

「具体每只标的该买多少 / 卖多少」（Sizing，Δw）是组合操作的核心数字。Δw 的来源极易失控：

- 用户可能显式调整（「我手动加仓 5% 沪深 300」）
- 系统可能算 remediation（「单仓过 30%，建议降到 20%」）
- Target 变更可能触发再平衡（「Target 改了，需要调」）
- LLM / Agent 可能「凭感觉」建议（「我觉得该减仓消费」）
- Factor / Risk 信号可能诱导调整

如果 Δw 来源不受控，会产生：

- **不可审计**：今天这个 Δw 是 LLM 凭感觉给的，明天那个是数据触发的，无法回答「为什么是这个数字」
- **责任错位**：LLM 越权决定仓位大小，与 V3.1「LLM 不决定 Δw」铁律冲突
- **重放失败**：同输入不同输出，决策不可复现

V3.1 §46 明确：**LLM 只做 Research / Event Interpretation / Thesis / Narrative；不直接写 DB、不改 Target、不决定 Δw、不算 Risk/Attribution、不生成 Confidence**。本 ADR 是把「Δw 不被 LLM 决定」变成可执行的 Cardinal Firewall。

现有代码（`Core/InvestmentIntelligence/`）的 DecisionCaseResearchAgent 让 LLM 直接产出行动建议（Δw 隐含其中），是本计划要替代的核心问题之一。

备选方案：

1. **LLM 直接产出 Δw**：违反 V3.1 铁律，不可审计
2. **Δw 来自单一来源（如纯 Target 跟随）**：忽略 remediation / 用户手动 / 信号诱导，覆盖不全
3. **Δw 必须带 SizingProvenance，限定合法来源集合**（本决策）：Δw 只能来自 target / remediation / user 三类；LLM / Agent / Signal 都不能直接产 Δw，只能通过影响这三类间接作用

## Decision

**所有 Δw（仓位调整）必须带 SizingProvenance；只允许 target / remediation / user 三类来源；LLM/Agent/Signal 不能直接产 Δw。**

1. **SizingProvenance 类型**（DEC-5）：
   - `target`：Δw 来自 Target 跟随（D000 的 Target 变化触发的再平衡）
   - `remediation`：Δw 来自状态约束修复（DEC-2 的 RemediationRequirement，如单仓过阈降仓）
   - `user`：Δw 来自用户显式操作（手动加仓 / 减仓）
   - 每条 Δw 必须能追溯到具体 provenance 实例（Target 版本 / Remediation 规则 / 用户操作事件）

2. **LLM / Agent / Signal 不能直接产 Δw**：
   - LLM 输出的 Research / Thesis / Signal 只能通过影响 Criterion（D002）间接影响决策
   - Signal 不能直接说「该减仓 5%」，只能说「该标的 momentum 偏弱」（ordinal），由 SignalPolicy 转 cardinal
   - Agent 不能凭空生成 Δw，只能基于 target / remediation / user 推导

3. **TargetRebalancePlanner 是 Δw 的唯一生产者**（DEC-5）：
   - 输入：PortfolioSnapshot + StrategicAllocationPolicy + StateConstraintEvaluator + 用户操作
   - 输出：PortfolioActionPlan，每条 action 带 SizingProvenance
   - Planner 是确定性算法（deterministic），同输入同输出（DEC-9 replay 基础）

4. **双层 Constraint Gate 保护 Δw**（DEC-6）：
   - action-level pruning：单条 action 违反约束（如最小交易单位、流动性）则裁剪
   - portfolio-level on ProjectedPortfolio：投影后的组合违反约束（总预算、相关性、再平衡零和）则重排
   - 两层 gate 都不引入新的 Δw 来源，只裁剪 / 重排已 provenanced 的 Δw

5. **Δw 的数学边界**：Decimal + 单位（权重变化，0-1 小数），不用 Double 隐式（联动 DATA003）。所有 Δw 计算必须可重算、可重放。

## Consequences

- **Positive**：
  - 任何 Δw 100% 可审计，能回答「这个数字来自哪」
  - LLM 责任边界清晰（Research / Thesis / Narrative），不越权决定仓位
  - 决策可重放（DEC-9），同 mock PortfolioSnapshot + Target + 用户操作 → 同 PortfolioActionPlan
  - Cardinal Firewall 闭环：D000 Target + D001 Sizing 是组合操作的两个核心 Cardinal，都被锁定

- **Negative**：
  - Δw 计算路径长（Planner + 双层 Gate），开发成本高（DEC-5 是 8 点）
  - LLM「智能性」受限，用户可能期待「LLM 直接告诉我买卖多少」（但这是刻意的）
  - remediation 规则集需要持续维护，规则不全则覆盖不全

- **Neutral**：
  - Δw 是确定性算法产出，离线 / 无 LLM 仍能正常运行
  - D002（Criterion）/ D003（Comparison）是 LLM 间接影响的 Cardinal，本 ADR 只锁定 Sizing

## Compliance Check

- **DEC-5 测试**：`TargetRebalancePlanner` 输出的每条 action 带 SizingProvenance；3 类来源各自有测试
- **D001 Cardinal Firewall 测试**：构造「LLM 直接产 Δw」场景，Planner 拒绝；LLM 输出只能走 Signal → Criterion 路径
- **DEC-6 测试**：双层 Constraint Gate 裁剪 / 重排不引入新来源
- **DEC-9 replay 测试**：同 mock 输入 → 同 PortfolioActionPlan（含 Δw + provenance）
- **M7 验收**（rollout §4.5）：Cardinal Firewall 闭环，任何 Δw 可追溯到合法 provenance
- **PR checklist**：
  - LLM / Agent 代码直接产 Δw → 拒绝
  - Signal 直接产 Δw → 拒绝（必须先转 Criterion）
  - Δw 不带 SizingProvenance → 拒绝
  - Constraint Gate 引入新 Δw 来源 → 拒绝

## References

- rollout §3 Epic 10 DEC-5/6/9、§4.5 M7 验收
- V3.1 §46（LLM 不决定 Δw 铁律）、§100（Research 链）
- 关联 ADR：
  - D000（Strategic Target Provenance）：target 类 Δw 的上游
  - D002（Criterion Provenance）：LLM/Signal 间接影响的入口
  - D003（Comparison Provenance）：Criterion 之上的比较
  - D004（Decision Replay Boundary）：Δw 重放引用 provenance ID 不重算 Planner
  - DATA003（Raw Market Canonicalization）：Δw 的 Decimal + 单位强类型
