# 四防火墙总览（One-Pager）

**状态**：Accepted（M0 里程碑产出）
**对应**：rollout §1.1 / Epic 1 / ADR-5
**维护**：本页是四防火墙的入口索引，新增决策先看本页定位归属，再读对应 ADR 细则。

---

## 一句话

Investment Intelligence V3.1 用**四道防火墙**把「不可信的免费数据 / 不可复现的 LLM / 易越权的决策」隔离在系统外，让上层 Factor / Risk / Attribution / Decision 只消费可信、可审、可重放的输入。

```
外部世界（不可信）                          系统内部（可信）
─────────────────                          ─────────────────
免费 Provider  ──┐                   ┌── 业务层只读 Canonical
LLM (用户 key) ──┤                   │
本机 Python ─────┤── 四防火墙 ──────┼── Factor/Risk/Attribution
用户操作 ────────┤                   │── Decision (Target/Δw/Criterion)
                 │                   │
                 ▼                   ▼
            [隔离层]              [决策 Cardinal]
```

---

## 四道防火墙

| # | 防火墙 | 隔离什么 | 对应 ADR | 在哪里强制 |
|---|---|---|---|---|
| 1 | **Identity 防火墙** | Provider 原始代码 ↔ Canonical Identity | [DATA001](DATA001-canonical-identity.md) | IdentityResolver + Repository API |
| 2 | **Temporal 双 query mode 防火墙** | 「当时可知」↔ 「精确快照」 | [DATA002](DATA002-point-in-time-visibility.md) / [DATA005](DATA005-economic-availability-semantics.md) | KnowledgeContext 入参 + AvailabilityPolicy |
| 3 | **Semantic-Cardinal 防火墙** | LLM / Signal（ordinal）↔ Decision（cardinal） | [D000-D004](D000-strategic-target-provenance.md) | DecisionPlanner + Validator |
| 4 | **Paid-Dependency 防火墙** | 付费依赖 ↔ 整个系统 | [FREE001](FREE001-zero-paid-dependency.md) | PR review + Package.swift |

辅助 ADR（支撑前 3 道防火墙的物质基础）：
- [DATA003](DATA003-raw-market-canonicalization.md) Raw Market Canonicalization（Pipeline 5 步）
- [DATA004](DATA004-local-accumulation.md) Local Accumulation（永久入库 + 增量同步）
- [DATA006](DATA006-free-provider-fragility.md) Free Provider Fragility（三档降级 + unknown）
- [DATA007](DATA007-external-collector-isolation.md) External Collector Isolation（本地进程外 Python，PROV-3a 备选）
- [DATA008](DATA008-observation-revision-policy.md) Observation Revision（multi-vintage）
- [DATA009](DATA009-model-validation-before-persistence-freeze.md) Model Validation Before Freeze（M2 go/no-go）
- [DATA010](DATA010-remote-public-data-collector.md) Remote Public-Data Collector（远程 VPS，PROV-3b 默认，FREE001 受控让步）

---

## 1. Identity 防火墙（DATA001）

**隔离**：Provider 原始代码（且慢 prodCode / 天天基金 6 位码 / ISIN / CIK）↔ Canonical Identity（LegalEntity / Instrument / Listing / FundProduct / FundShareClass 五层）。

**为什么**：同一只标的在不同 Provider 代码不同，跨源合并、去重、对账会出错；A/C 类、ETF/Index、多挂牌混淆会让收益归因失真。

**怎么强制**：
- 4 条正式映射路径（provider authoritative / exchange+symbol / ISIN/CIK / manual verified）
- fuzzy 匹配只产 candidate，必须经 Verification
- Repository API 强制只出现 Canonical ID，Provider 代码只活在 Adapter + Resolver 内
- 业务层（Factor / Risk / Attribution / Decision）出现 Provider 代码 → PR 拒绝

**首次落地**：Epic 2 DOM-1..3、Epic 3 REPO-4、Epic 5 GRDB-2、M2 验收场景 1/2

---

## 2. Temporal 双 query mode 防火墙（DATA002 + DATA005）

**隔离**：「站在 T 做决策当时可知」（economicKnowledge）↔「精确查询某 vintage 快照」（exactSnapshot）。

**为什么**：回测 / 历史重算 / 决策重放必须用「当时可知」语义，否则 lookahead bias；availableAt 不等于 publishedAt 或 ingestedAt（Provider 故障延迟会让 ingestedAt 晚）。

**怎么强制**：
- 每个观测带 TemporalEnvelope 四时间（effectiveAt / publishedAt / availableAt / ingestedAt）
- Repository 每个 API 强制 `KnowledgeContext` 入参，无上下文查询不存在
- `availableAt` 由版本化 AvailabilityPolicy 推导，保守优先（次交易日而非当日）
- TemporalNormalizer 在 ProviderRecord → Canonical 时算 availableAt，不让 Provider 自己声明

**首次落地**：Epic 2 DOM-4/6/7、Epic 3 REPO-5a、M2 验收场景 3/4/5、Epic 7 FAC-8 golden test

---

## 3. Semantic-Cardinal 防火墙（D000-D004）

**隔离**：LLM / Signal（ordinal，序数语义，如「momentum 偏弱」）↔ Decision（cardinal，基数语义，如具体 Δw、具体 criterion 分）。

**为什么**：LLM 是非确定、黑箱、易越权的；如果让 LLM 直接决定 Target / Δw / criterion 分 / 胜者，决策不可审计、不可重放、不可争议。

**五道 Cardinal 子防火墙**：

| 子防火墙 | 锁定什么 | 合法来源 | 禁止 |
|---|---|---|---|
| [D000](D000-strategic-target-provenance.md) Target | Strategic Target | explicitUserAllocation / userSelectedTemplate | Signal / LLM / Agent 改 Target |
| [D001](D001-sizing-provenance.md) Sizing | Δw（仓位调整） | target / remediation / user | LLM / Agent / Signal 直接产 Δw |
| [D002](D002-criterion-provenance.md) Criterion | 评价分数 | versioned deterministic evaluator | LLM / ML 黑箱打分 |
| [D003](D003-comparison-provenance.md) Comparison | plan 间胜负 | Pareto + IndifferenceBand + Partial Policy | 加权平均 / LLM 直接产胜者 |
| [D004](D004-decision-replay-boundary.md) Replay | 决策重放 | artifact 引用上游 IDs | 重跑 Research / LLM |

**LLM 的合法路径**（被显式约束）：
```
LLM → Research/Thesis → Signal (ordinal)
                          ↓ SignalPolicy 转 cardinal (FAC-2)
                        cardinal value
                          ↓ CriterionEvaluator (D002)
                        criterion score
                          ↓ CriterionComparator (D003)
                        comparison
                          ↓ DecisionPlanner (受 D000/D001 约束)
                        PortfolioDecisionArtifact (D004 引用上游)
```
LLM 在这条路径里只能影响「Signal」，不能直接改 Target / Δw / 分数 / 胜者。

**首次落地**：Epic 10 DEC-1..9、Epic 11 RES-1..9、Epic 12 WF-1..5、M7/M8/M9 验收

---

## 4. Paid-Dependency 防火墙（FREE001）

**隔离**：付费依赖（付费数据 / 付费 LLM / 付费基础设施）↔ 整个系统。

**为什么**：本项目由一名开发者维护、无预算、无 SRE；付费依赖会带来账单不可预测、可复现性破坏、生命周期绑定、隐私合规冲突。

**怎么强制**：
- 数据 Provider 全部免费（4 档 reliabilityClass，见 DATA006）
- LLM 必须支持用户自备 key，无 key 时降级
- 基础设施零付费（本地 GRDB，Epic 5 起 AGENTS.md 第 6 条更新）
- 每个新 Provider / SPM 依赖在 PR 声明许可与计费模型
- reviewer 看到 `import` 新库、新 HTTP client、新密钥常量时对照 FREE001 拒绝违反项

**首次落地**：Epic 4 PROV-1..8、Epic 5 GRDB-1、Epic 11 RES-1

---

## 防火墙之间的关系

```
[4 Paid-Dependency]  ─── 整个系统的外部边界
         │
         ▼
[1 Identity]  ─── 数据进入系统的第一关
         │
         ▼
[2 Temporal]  ─── 数据被业务层消费时的 PIT 边界
         │
         ▼
[3 Semantic-Cardinal]  ─── 数据 + LLM 影响决策时的语义边界
         │
         ▼
     Decision / Artifact / Replay
```

- 防火墙 4 是**外部边界**：拦截付费依赖
- 防火墙 1、2 是**数据层**：拦截 Provider 不可信
- 防火墙 3 是**决策层**：拦截 LLM 不可复现 / 易越权

任何业务计算（Factor / Risk / Attribution / Decision）的输入必须**已经穿过 1 + 2**；任何决策输出必须**穿过 3**；整个系统必须**遵守 4**。

---

## 与现有代码的关系

- 现有 `Core/InvestmentIntelligence/`（Slice 0-7）和 `Core/TrendResearch/` / `NextHourGuidance` **不满足**本四防火墙：字符串 ID 违反 1、无 PIT 违反 2、LLM 直接产 Δw 违反 3
- 本计划（V3.1 新建 `macos-app/InvestmentIntelligenceV2/`）是**首次满足四防火墙**的实现
- Epic 12 一次性切换并删除旧代码（rollout WF-4/WF-5）
- 双轨期（Epic 9 起）两套并存、互不依赖

---

## Compliance：PR Review Checklist

每个 PR 必须在 description 声明遵守的相关 ADR，reviewer 对照本页检查：

- [ ] **FREE001**：新增依赖 / Provider / 密钥常量是否零付费？
- [ ] **DATA001**：业务层是否只用 Canonical ID？Provider 代码是否只活在 Adapter + Resolver？
- [ ] **DATA002 / DATA005**：Repository 调用是否带 KnowledgeContext？availableAt 是否由 Policy 推导？
- [ ] **DATA003**：Provider Adapter 是否只产 ProviderRecord？Pipeline 是否完整 5 步？
- [ ] **DATA004**：同步是否增量补缺口？是否覆盖旧 vintage？
- [ ] **DATA006**：Provider 失败是否走三档降级？缺口是否标 unavailable 而非 0？
- [ ] **DATA007 / DATA010**：本地 Collector 是否进程外？远程 Collector 是否只做公开数据？iOS 是否不含 Collector？远程方案是否在 PR 声明 FREE001 让步？
- [ ] **DATA008**：修订是否走新 vintage？vintage 是否可删？
- [ ] **DATA009**：M2 未通过前是否引入 SQLite / Factor？
- [ ] **D000**：Target 是否只来自 explicitUserAllocation / userSelectedTemplate？
- [ ] **D001**：Δw 是否只来自 target / remediation / user？
- [ ] **D002**：Criterion 是否 deterministic evaluator？LLM/ML 是否被拒？
- [ ] **D003**：Comparison 是否 Pareto？unresolvedTradeoff 是否可触发？
- [ ] **D004**：artifact 是否引用上游 IDs？重放是否不重跑 Research？

违反任一项 → PR 拒绝（或先修订对应 ADR）。

---

## 参考

- 完整 ADR 列表：`docs/adr/README.md`
- 实施计划：`docs/investment-intelligence-rollout.md`
- ADR 模板：`docs/adr/_template.md`
