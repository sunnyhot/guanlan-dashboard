# Architecture Decision Records (ADR)

本目录记录 Investment Intelligence V3.1（`macos-app/InvestmentIntelligenceV2/`）的架构决策。每条 ADR 描述一个不可轻易撤销的设计决策的 Context / Decision / Consequences / Compliance。

## 编号空间

- `FREE0xx` — 依赖与许可（免费/付费、外部进程隔离）
- `DATA0xx` — 数据与时间语义（Identity / PIT / Canonicalization / Revision / Model Validation）
- `D0xx` — 决策层 Cardinal Firewall（Target / Sizing / Criterion / Comparison / Replay）

编号一旦写入即冻结，不再复用；新决策追加新编号。

## ADR 模板

新建 ADR 请复制 `_template.md`。强制章节：

1. **Status**（Proposed / Accepted / Superseded by NNNN / Deprecated）
2. **Context**（为什么需要决策，约束与备选）
3. **Decision**（最终选择）
4. **Consequences**（带来什么正面/负面后果）
5. **Compliance Check**（后续 PR 如何验证仍然遵守本 ADR）

## 当前清单

| ADR | 标题 | 状态 |
|---|---|---|
| FREE001 | Zero Paid Dependency | Accepted |
| DATA001 | Canonical Identity | Accepted |
| DATA002 | Point-in-Time Visibility | Accepted |
| DATA003 | Raw Market Canonicalization | Accepted |
| DATA004 | Local Accumulation | Accepted |
| DATA005 | Economic Availability Semantics | Accepted |
| DATA006 | Free Provider Fragility | Accepted |
| DATA007 | External Collector Isolation | Accepted |
| DATA008 | Observation Revision Policy | Accepted |
| DATA009 | Model Validation Before Persistence Freeze | Accepted |
| DATA010 | Remote Public-Data Collector | Proposed |
| D000 | Strategic Target Provenance | Accepted |
| D001 | Sizing Provenance | Accepted |
| D002 | Criterion Provenance | Accepted |
| D003 | Comparison Provenance | Accepted |
| D004 | Decision Replay Boundary | Accepted |

参见 `docs/investment-intelligence-rollout.md` Epic 1。
