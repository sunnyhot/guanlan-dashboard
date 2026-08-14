# DATA005. Economic Availability Semantics

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-4/7；Epic 3 REPO-5a

## Context

DATA002 定义了 `availableAt` 是「客观上数据进入公开世界的最早时间」，但「客观最早」是什么意思，不同数据类型差别很大：

- 基金 Q2 持仓：`effectiveAt = 2024-06-30`，但公告日是 2024-07-18（110022 真实公告日）。07-18 当天几点可查？07-17 晚 23:59 公告的算 07-18 还是 07-17？
- 美股日线：7-20 收盘后哪个时刻算「available」？盘后清算？次日凌晨数据源更新？
- 宏观数据：FRED GDP 三次修订，第一次（advance）、二次（second）、三次（third）各算不同 availableAt？
- 公司行动：ex-date / record-date / pay-date 哪个是 availableAt？

如果没有明确规则，每次重算历史决策时「当时能看到这条数据」的判断都靠人脑，回测不可重现。

现有代码用「数据本身的时间戳」当 availableAt（比如基金净值用净值日期 7-10 当 availableAt），实际上 7-10 收盘后要到 7-11 凌晨才公布，导致 7-10 决策被假装能看到 7-10 净值。

备选方案：

1. **用 publishedAt 当 availableAt**：偏乐观，Provider 故障延迟到 8-01 才抓到的数据会被假装 7-20 就能看到
2. **用 ingestedAt 当 availableAt**：偏悲观，且把 Provider 故障惩罚给用户，7-21 决策看不到本应可得的 7-20 数据
3. **AvailabilityPolicy 化的语义**（本决策）：每类数据有明确的「经济可知」规则集，独立计算 availableAt，与 publishedAt / ingestedAt 分离

## Decision

**`availableAt` 是经济可知语义，由版本化的 AvailabilityPolicy 计算，不等于 publishedAt 也不等于 ingestedAt。**

1. **AvailabilityPolicy 结构**（DOM-7）：
   - 每条 policy 含 `id` / `version` / `rule` / `provenance`，可审计
   - V1 保守规则集覆盖三类数据（rollout DOM-7）：
     - **Fund NAV**：`availableAt = navDate + 1 trading day 00:00 (local exchange)`。即 T 日净值 T+1 日才可知
     - **Market Close**：`availableAt = tradingDay + 1 trading day 00:00`，且确认数据源已发布（盘后清算 + 数据源更新延迟）
     - **Fund Disclosure**：`availableAt = announcementDate + 1 trading day 00:00`，公告日次日才可知

2. **TemporalNormalizer 用 Policy 算 availableAt**（REPO-5a）：
   - ProviderRecord 不带 availableAt，由 TemporalNormalizer 基于 AvailabilityPolicy 推导
   - Provider 故障延迟到 8-01 抓到的 07-18 公告数据，`availableAt` 仍记为 `nextTradingDay(07-18)`。以 2024 中国日历为例，07-18 是周四，`availableAt = 2024-07-19`（客观）；`ingestedAt` 记为 8-01。周末公告的跨交易日语义由真实 Q1 样本覆盖：公告 2024-04-20（周六）→ `availableAt = 2024-04-22`（周一）
   - 7-19 的决策回放用 `economicKnowledge(asOf: 7-19)` 仍能看到这条数据（M2 场景 3）。注意：若用 `operationalKnowledge(asOf: 7-19)` 则看不到（本机 8-01 才抓到）——这正是两种 mode 的区别

3. **Conservative 优先**：当规则模糊时（如盘后数据确切发布时刻不清），用更保守的 availableAt（次交易日），宁可少算不可多算。回测 lookahead bias 是单向错误，宁可错过不可假装看到。

4. **Policy 是版本化的**：规则集修订走新 version，旧 vintage 数据保留旧 version 的 availableAt 标注（配合 DATA008），重算历史决策时用当时的 policy version，不用最新 policy。

5. **Macro vintage 显式**（DATA008 联动）：FRED GDP 三次修订分别记三条 vintage，每条带自己的 availableAt（advance / second / third 各不同），`economicKnowledge(asOf: T)` 只返回 T 时刻可知的最新 vintage。

## Consequences

- **Positive**：
  - 回测 / 决策重放有明确「当时可知」边界，消除 lookahead bias
  - AvailabilityPolicy 可审计，规则修订有版本可追溯
  - 保守规则保护用户：宁可决策基于更少数据，不假装有未来信息

- **Negative**：
  - AvailableAt 推导增加 commit pipeline 复杂度
  - 保守规则意味着用户决策看到的「最新数据」比 Provider 公告晚 1 天，需要 UI 明确告知
  - Policy 维护成本：交易所节假日、披露规则变更需要更新 policy

- **Neutral**：
  - V1 保守集可能偏紧，后续可基于真实 Provider 观测修订（如确认某 Provider 总是 T 日 22:00 前发布，可放宽 policy）。修订必须先评估 lookahead 风险。

## Compliance Check

- **DOM-7 测试**：`AvailabilityPolicy` 结构含 id/version/rule/provenance；V1 三类规则各自有测试
- **REPO-5a 测试**：`TemporalNormalizer` 基于 policy 算 availableAt；测试断言「ingestedAt ≠ availableAt」
- **M2 验收场景 3**（rollout §4.1）：Provider 故障 8-01 抓到的 07-18 公告数据（110022 真实公告日，周四），`availableAt = nextTradingDay(07-18) = 2024-07-19`、`ingestedAt = 8-01`；`economicKnowledge(asOf: 07-19)` 可见，`operationalKnowledge(asOf: 07-19)` 不可见
- **M2 验收场景 2**：基金 Q2 持仓 07-18 公告，`availableAt = 07-19`，`economicKnowledge(asOf: 7-10)` 查不到；同基金真实 Q1 样本公告 04-20（周六）→ `availableAt = 04-22`（跨周末）
- **PR checklist**：
  - 任何代码用 publishedAt 或 ingestedAt 当 availableAt → 拒绝
  - AvailabilityPolicy 修订未增 version → 拒绝
  - Policy rule 出现「当日可知」类乐观假设 → 拒绝

## References

- rollout §3 Epic 2 DOM-4/7、Epic 3 REPO-5a
- rollout §4.1 M2 验收场景 3/4
- 关联 ADR：
  - DATA002（PIT Visibility）：availableAt 是 economicKnowledge 模式的核心字段
  - DATA008（Observation Revision）：macro vintage 的 availableAt 分别标注
  - DATA004（Local Accumulation）：availableAt 是「缺口」判断的边界
