# DATA006. Free Provider Fragility

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-8；Epic 4 PROV-8；Epic 6 SYNC-7

## Context

FREE001 决定了系统只能用免费 Provider，但免费 Provider 不可靠：

- Alpha Vantage 25/天配额，用完 401 / 429；高峰时段限流；API 字段偶尔变更
- AKShare / 天天基金无 SLA，偶发 403 / 400016 风控（现有代码已经踩过，见 `AGENTS.md` 坑点 13 雪球被 WAF 拦）
- SEC / FRED 偶尔超时，大查询受限
- Stooq 历史长度不固定，CSV 字段偶尔漂移
- 且慢平台（`QiemanPlatformNativeClient`）接口随时可能变更（`AGENTS.md` 坑点 9）

如果系统假设 Provider 一定可用，会产生：

- **同步任务频繁崩**：一次抓取失败就整批回滚
- **决策基础不稳**：今天能看到的数据明天可能看不到，因子无法稳定计算
- **用户感知不可控**：界面一会显示数据一会不显示，且没有降级说明

现有代码（`Core/InvestmentIntelligence/`）的 Provider 调用没有统一降级路径，是本计划要替代的核心问题。

备选方案：

1. **失败即重试**：免费 Provider 风控时段重试也失败，且会触发更严风控
2. **失败即崩溃 / 失败即跳过**：跳过会让数据缺口在业务层变成 0 / 默认值，错误传播
3. **三档降级 + unknown 显式**（本决策）：ProviderHealth 持续监控，失败时按 local → secondary → unavailable 三档降级，缺口在业务层表现为 unknown 而非 0

## Decision

**免费 Provider 失败是常态，系统必须显式三档降级 + 业务层看到 unknown 而非默认值。**

1. **ProviderReliabilityClass 四档**（DOM-8）：
   - `officialStable`：交易所、SEC、FRED（监管或官方，但仍可能超时）
   - `documentFreeAPI`：Stooq、Alpha Vantage、FRED API（有文档的免费 API）
   - `communityAggregated`：天天基金、AKShare（社区聚合，字段易变）
   - `undocumentedPublicEndpoint`：且慢平台（无文档的公开端点）

2. **ProviderHealth 持续监控**（PROV-8）：每个 Provider 跟踪
   - 最近 N 次调用成功 / 失败比
   - 当前剩余 quota（如 Alpha Vantage 25/天）
   - 触发风控 / 限流的次数与时点
   - 最近 schema 漂移

3. **三档降级**（SYNC-7）：
   - **Local 兜底**：Provider 失败时优先用 Local Accumulation（DATA004）已积累的历史数据，缺口段标 unavailable
   - **Secondary**：若 Primary Provider 失败，尝试 Secondary Provider（如 Alpha Vantage 失败用 Stooq）
   - **Unavailable**：两个 Provider 都失败，数据段标 unavailable，不写默认值

4. **业务层看到 unknown 而非 0**（联动 RISK-2）：
   - 因子计算输入不足时返回 unknown，不猜；SignalPolicy 对 unknown 产 uncertain signal
   - Risk / Attribution 看到 unknown coverage 时降级措辞（如 ATTR-3「coverage < 50%」时不输出归因结论）
   - Decision 子系统看到 unknown 时不强制决策（DEC-2 remediation 不基于 unknown）

5. **配额耗尽自动降级**：Alpha Vantage 用完 25/天，自动切到 Stooq / local；Tavily 月额度用完，Research 子系统降级到「无 web 搜索」模式。

## Consequences

- **Positive**：
  - 系统在 Provider 不稳时仍能运行，不会硬崩
  - 业务层永远知道哪些数据是 unknown，决策可解释
  - ProviderHealth 提供运维视图，能提前发现 schema 漂移 / 风控

- **Negative**：
  - 三档降级路径复杂，每个 Provider 都要维护 secondary 配置
  - unknown 传播需要在每层（Factor / Risk / Attribution / Decision）显式处理，代码冗长
  - 用户体验：Provider 长期不可用时部分功能降级，需要 UI 明确标注

- **Neutral**：
  - 99% 时间 Provider 正常，降级路径是保险，平时不触发
  - 1% Provider 故障期间系统降级而非瘫痪，符合 FREE001 离线承诺

## Compliance Check

- **DOM-8 测试**：`DataQuality` / `ProviderHealth` / `ProviderReliabilityClass` 四档齐全
- **PROV-8 测试**：ProviderHealth 监控成功/失败/quota；触发降级阈值正确
- **SYNC-7 测试**：三档降级路径各自有测试；缺口段标 unavailable 而非默认值
- **RISK-2 测试**：correlation 输入不足 → unknown，不猜
- **ATTR-3 测试**：coverage 分级措辞（≥80% / 50-80% / <50%）正确
- **PR checklist**：
  - Provider 失败处理出现「用 0 / 默认值兜底」→ 拒绝（应标 unavailable）
  - 新增 Provider 未声明 reliabilityClass → 拒绝
  - 业务层对 unknown 做隐式假设（如把 unknown 当 0）→ 拒绝

## References

- rollout §3 Epic 2 DOM-8、Epic 4 PROV-8、Epic 6 SYNC-7
- `AGENTS.md` 坑点 9（且慢 API 易变）、坑点 13（雪球 WAF 不可行）
- 关联 ADR：
  - FREE001（Zero Paid Dependency）：免费是 fragility 的根因
  - DATA004（Local Accumulation）：local 兜底依赖本地积累
  - DATA003（Raw Market Canonicalization）：Secondary Provider 也走 Pipeline
  - DATA007（External Collector Isolation）：Collector 进程外失败不影响主进程
