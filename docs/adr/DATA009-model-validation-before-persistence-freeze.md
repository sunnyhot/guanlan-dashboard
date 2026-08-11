# DATA009. Model Validation Before Persistence Freeze

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；M2 是 go/no-go 节点

## Context

Investment Intelligence V3.1 是一个 ~340 点数的大计划，SQLite schema（GRDB，Epic 5）是单向投入：

- schema 一旦冻结，迁移代价随用户增长指数上升
- V3.1 §37 的领域模型 / §13 的 identity resolution / §46 的 PIT 都是未经真实数据验证的设计假设
- 现有 `Core/InvestmentIntelligence/` 用字符串 ID + JSON 文件，是前车之鉴——直接持久化导致架构问题不可逆

如果直接进 Epic 5（GRDB schema）而不先验证模型，会：

- **schema 错位**：真实数据形状与设计不符（如基金代码映射规则、PIT availableAt 推导）
- **Identity 假设落空**：跨 Provider 映射在真实数据上跑不通
- **PIT 假设落空**：availableAt 推导规则在真实 Provider 数据上不准

整个项目失败风险最高的是这一步。

备选方案：

1. **直接进 Epic 5，schema 不对再迁移**：迁移代价高，且真实数据形状未验证前 schema 必错
2. **跳过 M2 验收**：等于放弃 go/no-go 节点，blind 投入
3. **InMemory + 真实 Provider 跑通 M2 再冻结 schema**（本决策）：先用 InMemory Repository 接两个真实 Provider 验证 identity + PIT 假设，跑通 5 个场景才进 Epic 5

## Decision

**M2 验收通过前不冻结 SQLite schema、不碰 Factor。这是整个项目的 go/no-go 节点（rollout §1.1 铁律）。**

1. **M2 前用 InMemory**（Epic 3）：
   - REPO-2 用 Dictionary-backed InMemoryRepository 验证 Repository 协议
   - REPO-6/7 接 Qieman + 天天基金两个真实 Provider（不修改现有 client），产出 ProviderRecord
   - REPO-4/4b/5 完成 IdentityResolver + 初始 identity 映射 + TemporalNormalizer

2. **M2 五个验收场景**（rollout §4.1）必须全过：
   - 场景 1：同一基金跨 Provider 代码不同 → 解析到同一 InstrumentID
   - 场景 2：同一股票跨 Provider symbol 不同 → 解析到同一 ListingID
   - 场景 3：基金 Q2 持仓 7-20 公告 → `economicKnowledge(asOf: 7-10)` 查不到
   - 场景 4：Provider 故障 8-01 抓到 → `availableAt = nextTradingDay(7-20) = 7-22`（2024 中国日历，7-20 周六）、`ingestedAt = 8-01`；`economicKnowledge(asOf: 7-22)` 可见
   - 场景 5：模拟 v1→v2 revision → 历史 vintage 查询仍看到 v1

3. **M2 不过的应对**：
   - 不进 Epic 5（GRDB schema 冻结）
   - 不碰 Factor Engine
   - 修订 DOM / REPO 设计，重跑 M2
   - 严重时修订上游 ADR（DATA001 / DATA002 / DATA005），但不能跳过验证

4. **M2 通过后才能冻结 schema**：
   - Epic 5 GRDB-1 起 schema 设计基于 M2 真实数据形状
   - schema 设计可审计：每个表 / 字段有 M2 验收证据支撑
   - Factor Engine（Epic 7）依赖 schema 稳定，M2 通过才开始

5. **铁律适用范围**：M2 节点对 Epic 4-13 全部生效。任何 Epic 在 M2 通过前试图持久化 schema 或实现 Factor 都违反本 ADR。

## Consequences

- **Positive**：
  - schema 设计有真实数据支撑，减少迁移代价
  - 项目最高风险节点有明确 go/no-go，避免 blind 投入
  - M2 跑通后所有下游 Epic 有信心基础

- **Negative**：
  - M2 前不能用 GRDB，InMemory 阶段性能受限（但 M2 是验证性测试，性能不关键）
  - M2 跑不通会推迟整个项目，可能需要数轮修订
  - 开发者纪律要求高：M2 通过前不能「提前」写 schema

- **Neutral**：
  - M2 是阶段性 gate，通过后此 ADR 主要价值是「不能再回头」的纪律
  - 若 M2 后 schema 仍需修订，GRDB 迁移框架（GRDB-1）提供机制保障

## Compliance Check

- **M2 验收脚本**（rollout §4.1）：5 场景必须全过，有对应测试
- **Epic 5 起的 PR**：description 必须引用 M2 通过证据（commit / CI 状态）
- **Epic 7 起的 PR**：Factor 实现必须依赖 schema 已冻结
- **PR checklist**：
  - M2 未通过的 PR 引入 SQLite / GRDB → 拒绝
  - M2 未通过的 PR 实现 Factor → 拒绝
  - M2 验收场景被「暂时跳过」→ 拒绝

## References

- rollout §1.1（M2 是 go/no-go 铁律）、§3 Epic 2-3、§4.1 M2 验收脚本、§5 推荐起点
- 关联 ADR：
  - DATA001（Canonical Identity）：M2 验证 identity 假设
  - DATA002（PIT Visibility）：M2 验证 PIT 假设
  - DATA005（Economic Availability Semantics）：M2 验证 availableAt 推导
  - DATA008（Observation Revision）：M2 验证 vintage 多版本
