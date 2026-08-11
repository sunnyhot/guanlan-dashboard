# FREE001. Zero Paid Dependency

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-2

## Context

Investment Intelligence V3.1 的目标是给个人投资者一个可信、可审计、可在本地长期运行的投资研判子系统。整个系统由一名开发者（含 AI 协作）维护，没有付费 API 预算，没有运维 SRE。

在此约束下，「付费数据源 / 付费 LLM / 付费基础设施」一旦引入会带来一系列连锁代价：

- **账单不可预测**：免费层调用频率受限，超出后要么硬降级要么按量计费。策略回测、归因重算、PIT 历史回填都会在短时间内产生大量请求。
- **可复现性破坏**：付费数据往往按订阅窗口返回不同字段或不同精度，导致同一查询在不同时间结果不一致，违反 ADR-DATA002（PIT Visibility）。
- **生命周期绑定**：账号一旦欠费或被封，整套数据通道与历史回放能力随之瘫痪。这与本项目「离线仍可回放任一历史决策」的核心承诺冲突。
- **隐私与合规**：付费数据 / 云端 LLM 通常要把用户持仓上传外部服务，与且慢 Cookie 本地化管理的现有隐私边界冲突（`AGENTS.md` 第 4 条）。

备选方案：

1. **引入付费 Provider 作为 primary**：体验好，但违反上面所有约束。
2. **混合策略：付费 Provider primary + 免费 fallback**：表面合理，实际让免费路径长期无人维护、与真实数据形态脱节，一旦付费断供直接裸奔。
3. **零付费（本决策）**：免费 Provider + 本地积累 + 用户自备 API key 的 LLM。所有路径一开始就按免费配额、降级、缓存设计。

## Decision

**Investment Intelligence V3.1 不允许引入任何付费依赖。** 具体含义：

1. **数据 Provider 全部免费**。允许的免费来源（带各自的可靠性档位，见 ADR-DATA006）：
   - 允许（reliabilityClass = `officialStable`）：交易所/官方公告、SEC EDGAR、FRED
   - 允许（`documentFreeAPI`）：Stooq（personal use）、Alpha Vantage（free tier 25/天）、FRED API（free tier）
   - 允许（`communityAggregated`）：天天基金（社区聚合披露）
   - 允许（`undocumentedPublicEndpoint`）：且慢平台公开接口（已有 `QiemanPlatformNativeClient`）
   - **禁止**：任何按月/按量计费的数据 API、任何需要付费 license 的指数/因子库

2. **LLM 接入必须支持「用户自备 key」**。模型网关（Epic 11 RES-1）只支持 OpenAI 兼容协议，密钥由用户配置，本项目不内置任何付费模型 token。无 key 时 LLM Research 子系统降级，Deterministic 路径（Factor / Exposure / Risk / Attribution / Decision）仍完整可用。

3. **基础设施零付费**。不使用云数据库、云函数、云对象存储。本地持久化用 GRDB（Epic 5，AGENTS.md 第 6 条会在此 Epic 起更新）；进程外 Collector 用本机 Python（见 ADR-DATA007）。

4. **强制配额感知**。每个免费 Provider 必须在 Adapter 层暴露：
   - 当前剩余配额（如 Alpha Vantage 的 25/天）
   - 触发降级的阈值
   - 配额耗尽时的兜底策略（local accumulation / secondary source / unavailable 三档，见 ADR-DATA006）

5. **允许清单 / 禁止清单**。任何新 Provider / 第三方库在 PR 中必须声明其许可与计费模型；PR description 对照本 ADR 做合规声明。新增 SPM 依赖必须零订阅、零按量计费。

## Consequences

- **Positive**：
  - 系统在任何断网、欠费、被风控场景下仍能离线回放历史决策
  - 成本曲线完全可控，可以放心做大量回测与 PIT 重算
  - 隐私边界清晰，用户持仓不外发
  - 强制把「降级 / 兜底 / 缓存」作为一等公民设计，反而提升了系统鲁棒性

- **Negative**：
  - 数据覆盖度、时效性、精度上限由免费 Provider 决定。例如美股日内分钟级数据、A股 Level-2、付费因子库都不在覆盖范围
  - AKShare / 天天基金等社区来源随时可能变更或被封，需要持续维护（见 ADR-DATA006 / DATA007）
  - LLM 质量受用户自带 key 的模型能力限制，且无 key 用户体验会降级
  - 全市场 universe 历史回填（SYNC-6b）受免费额度限制，只能分阶段补全

- **Neutral / Neutrality Risks**：
  - 若未来确实需要付费数据（如 PIT 因子回测需要专业数据库），必须先写新 ADR（如 `FREE002`）评估并 supersede 本条，不允许在 PR 里静默引入

## Compliance Check

后续 PR 证明遵守 FREE001 的检查项：

- **新增 Provider Adapter**（Epic 4）：PR description 显式列出 provider 的计费模型、配额、许可，并归类到 §Decision 1 的 reliabilityClass
- **新增 SPM 依赖**（任何 Epic）：PR description 声明该依赖「零订阅、零按量计费」，并在 `Package.swift` 注释中标注许可
- **LLM 相关代码**（Epic 11+）：模型密钥只能来自用户配置（Keychain / 设置面板），代码中禁止硬编码任何 token；`investment-agent` CLI 不带任何内置模型 key
- **基础设施**（Epic 5/13）：禁用任何云服务 client。GRDB 数据文件路径必须在本地应用沙盒目录内
- **Review checklist**：reviewer 看到 `import` 新增第三方库、新增 HTTP client、新增密钥常量时，必须对照本 ADR 拒绝违反项

测试层面：Epic 4 PROV-8 的 ProviderHealth 监控断言「quota 用完 → 降级标记」行为；Epic 11 RES-1 的 Model Gateway 断言「无 key 时降级」行为。

## References

- `docs/investment-intelligence-rollout.md` §2.3 目录约定、Epic 4 / Epic 11
- `AGENTS.md` 第 4 条（Cookie 本地化）、第 6 条（纯 JSON → Epic 5 起引入 GRDB）
- 关联 ADR：
  - ADR-DATA006（Free Provider Fragility）：免费 Provider 的失败降级路径
  - ADR-DATA007（External Collector Isolation）：本机 Python Collector 的隔离
  - ADR-DATA004（Local Accumulation）：免费配额不足时的本地累积策略
