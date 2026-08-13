# Investment Intelligence Agent — 实施计划

**状态**：Active（v2，修正了 Story 拆分审查发现的问题）
**基线架构**：V3.1（待落地的 ADR 见 Epic 1；当前 `docs/adr/` 尚不存在，Epic 1 的产出就是创建它）
**产品定位**：Signal-aware Constrained Rebalancing System

---

## 与现有代码的关系（必读）

仓库里**已有两套投资智能相关代码**，本计划是第三套（V3.1），明确**替代前两套**：

### 现有代码 1：三条 AI 链路（`macos-app/Core/TrendResearch/` + `Core/NextHourGuidance*.swift` + `Core/FundLookThrough.swift`）
- TrendResearch（长期趋势研究，Agent 821 行）、NextHourGuidance（盘中研判）、FundLookThrough（基金穿透，944 行）
- 由 AppModel 的 60 秒调度 loop 驱动，产出 `TrendAnalysisReport` / `NextHourGuidanceReport`
- **本计划在 Epic 9（Attribution）起逐步替代，Epic 12 全部下线**

### 现有代码 2：Slice 0-7 投资智能（`macos-app/Core/InvestmentIntelligence/`）
- 随 v4.0.0 发布、`InvestmentIntelligenceFeatureFlag` 默认**开**、用户在用
- 含 DecisionCase（决策事项）+ DecisionCaseResearchAgent（第三条链路，508 行）+ ConcentrationRiskEngine + MarketCloseReview + Evidence 层（独立性/时效/ClaimAssessment）
- 约 118 个测试覆盖
- **本计划不沿用其架构**（字符串 identity、JSON 持久化、阈值表式 Policy、依赖 LLM 的归因都不符合 V3.1 ADR）
- **但保留到 Epic 12 完成**，Epic 12 一次性切换并删除。双轨期内两套并存、互不依赖。

### 本计划（V3.1 新建）
- 内联到 `macos-app/InvestmentIntelligenceV2/`（见 §2.3 目录约定），**不单独写 SPM package**
- 不复用 Slice 0-7 的代码，但可读它作参考（DecisionCase 状态机设计、Evidence 层思路有借鉴价值）
- Epic 13（最后）评估是否抽独立 package，届时真实依赖形状已清楚

---

## 0. 阅读顺序

1. §1 总览（里程碑 + 关键路径 + 规模估算）
2. §2 通用约定（点数/依赖/测试铁律/目录约定）
3. §3 Epic 详细展开（按执行顺序）
4. §4 里程碑验收脚本
5. 附录 A：架构 ADR 清单（Epic 1 产出）
6. 附录 B：命名与目录约定

---

## 1. 总览

### 1.1 里程碑与关键路径

```
M0 架构 ADR 落地
  └─ Epic 1 (ADR 写入 docs/adr/)
       │
M1 Domain Model 编译通过
  └─ Epic 2 (Domain Model，内联 macos-app)
       │
M2 Identity + PIT 真实验证通过  ★ go/no-go
  └─ Epic 3 (Repository + IdentityResolver，InMemory + 2 真实 Provider)
       │
       ├─── M3 Provider 层完整
       │    └─ Epic 4 (Adapters)
       │
       ├─── M4 Canonical Store 上线
       │    └─ Epic 5 (GRDB)
       │
       └─── M5 数据自给
            └─ Epic 6 (Sync + Backfill)
                 │
            M6 第一个完整 Workflow（Attribution）
              └─ Epic 7 (Factor) + Epic 8 (Exposure/Risk) + Epic 9 (Attribution)
                   │
            M7 Decision 子系统可独立运行（mock signals）
              └─ Epic 10 (Decision)
                   │
            M8 LLM Research 子系统可用（产真实 signals）
              └─ Epic 11 (LLM Research)
                   │
            M9 现有 AI 链路全替换 + Slice 0-7 下线
              └─ Epic 12 (Workflows + Presentation + 旧代码删除)
                   │
            M10 Agent 独立化
              └─ Epic 13 (Runtime + CLI + 可选 package 抽取)
```

**铁律**（来自 V3.1 ADR-DATA009）：M2 跑通真实 identity/PIT 之前，不冻结 SQLite schema、不碰 Factor。这是整个项目的 go/no-go 节点。

**依赖说明**：M7 Decision 用 mock Signal 测试（不阻塞），M8 Research 产真实 Signal，M9 Workflows 才真正串联 Research→Decision→输出。这是刻意的分层：先把 deterministic 的 Decision 做对，再接 LLM Research。

### 1.2 规模估算（Fibonacci 点数）

| 阶段 | 范围 | 估算点数 | 累计 |
|---|---|---|---|
| Phase 0 | Epic 1（ADR） | 5 | 5 |
| Phase 0.5 | Epic 2-3（到 M2） | ~52 | ~57 |
| Phase 1-3 | Epic 4-6（到 M5） | ~90 | ~147 |
| Phase 4-5 | Epic 7-9（到 M6） | ~60 | ~207 |
| Phase 6 | Epic 10（到 M7） | ~45 | ~252 |
| Phase 6.5 | Epic 11（到 M8，LLM Research） | ~34 | ~286 |
| Phase 7 | Epic 12（到 M9，Workflows + 下线） | ~33 | ~319 |
| Phase 8 | Epic 13（到 M10，Agent 独立） | ~18 | ~337 |

**注**：所有 Story 点数**含对应单元测试**（见 §2.2）；跨 Epic 的 golden test 套件单独列 Story。

### 1.3 风险排序（先做高价值低风险）

| 优先级 | 理由 |
|---|---|
| Epic 1-3 | 地基，零回归（不动现有代码），M2 验证架构假设 |
| Epic 4-6 | 数据自给，Factor 才有可信输入 |
| Epic 9（Attribution）| 第一个完整 Workflow，90% deterministic，最适合验证整条链 |
| Epic 7-8 | Factor/Exposure/Risk 是 Decision 的输入 |
| Epic 10（Decision）| 替代 LLM actions 和 Slice 0-7 的核心，用 mock signals 先跑通 |
| Epic 11（Research）| 产真实 signals，是 Workflows 的前置 |
| Epic 12-13 | 最后才替换现有 AI 链路 + 删 Slice 0-7 + Agent 独立化 |

---

## 2. 通用约定

### 2.1 点数语义

Fibonacci：1/2/3/5/8/13。1 = 半天以内，8 = 一周以上，13 = 必须再拆。**所有 Story 点数默认含对应单元测试**，除非显式标注「不含测试」。

### 2.2 测试铁律（贯穿所有 Epic）

- 每个 Story 完成的前置条件：`swift test` 全绿 + 该 Story 引入的新代码有对应单元测试
- 跨 Story / 跨 Epic 的 golden test 套件**单独列 Story**（如 FAC-8、RES-9、DEC 的 replay 测试）
- 重点 golden test 套件分布：
  - Identity（Epic 3，REPO-8 即 M2 验收）
  - PIT（Epic 3, 5）
  - Factor golden（Epic 7，FAC-8）
  - Constraint（Epic 10）
  - Decision replay（Epic 10）
  - Research extraction（Epic 11，RES-9）
  - Workflow 端到端（Epic 9, 12）

### 2.3 目录约定与隔离原则

新代码统一放 `macos-app/InvestmentIntelligenceV2/`（与现有 `macos-app/Core/InvestmentIntelligence/` 并列，互不依赖）：

```
macos-app/
├── Core/
│   ├── InvestmentIntelligence/      ← 现有 Slice 0-7，保留到 Epic 12 删除
│   ├── TrendResearch/               ← 现有链路 A，Epic 12 替换
│   ├── NextHourGuidance*.swift      ← 现有链路 B，Epic 12 替换
│   └── FundLookThrough.swift        ← 现有穿透，Epic 8 升级（新写 v2，旧代码 Epic 12 删）
└── InvestmentIntelligenceV2/        ← 本计划所有新代码
    ├── Identity/
    ├── Temporal/
    ├── Observations/
    ├── Repositories/
    ├── Providers/
    ├── Persistence/
    ├── Sync/
    ├── Factors/
    ├── Exposure/
    ├── Risk/
    ├── Attribution/
    ├── Decision/
    ├── Research/                    ← Epic 11
    ├── Presentation/                ← Epic 12（Renderer/Narrator）
    ├── Workflows/
    └── Agent/
```

**隔离原则**（靠目录 + ADR review + 测试维持，不靠编译期 package 隔离）：
- `InvestmentIntelligenceV2/` 内部不引用 `Core/InvestmentIntelligence/` 的任何类型
- 不引用 `Core/TrendResearch/` 的类型（Provider 层可调用现有 client 取数，但封装成 ProviderRecord 后切断依赖）
- App 层（AppModel/Views）在 Epic 9 之前不引用 V2 代码
- V2 代码不引用 SwiftUI/AppKit

### 2.4 ADR 合规

每个 PR 必须在 description 声明遵守的相关 ADR。新增架构决策必须先写 ADR 再写代码。

---

## 3. Epic 详细展开

### Epic 1 — Architecture ADR 落地（Phase 0）

**目标**：把 V3.1 的 15 条 ADR 写入 `docs/adr/`，建立后续所有 PR 的合规基线。当前 `docs/adr/` 不存在，Epic 1 创建它。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| ADR-1 | 建 `docs/adr/` 目录 + ADR 模板（Status/Context/Decision/Consequences/Compliance Check）| — | 1 | 模板可复用 |
| ADR-2 | 写 FREE001 Zero Paid Dependency | ADR-1 | 1 | 允许/禁止清单明确 |
| ADR-3 | 写 DATA001-009（Canonical Identity / PIT Visibility / Raw Market Canonicalization / Local Accumulation / Economic Availability / Free Provider Fragility / External Collector Isolation / Observation Revision / Model Validation）| ADR-1 | 3 | 9 条均可引用 |
| ADR-4 | 写 D000-004（Target Provenance / Sizing Provenance / Criterion Provenance / Comparison Provenance / Decision Replay Boundary）| ADR-1 | 2 | Cardinal Firewall 闭环 |
| ADR-5 | 写「四防火墙总览」一页文档（Identity / Temporal 双 query mode / Semantic-Cardinal / Paid-Dependency）| ADR-2,3,4 | 1 | 一页讲清 |

**里程碑 M0：架构 ADR 落地**。这之后总架构不再调整，所有 PR 对照 ADR review。

---

### Epic 2 — Canonical Domain Model（Phase 0.5 上半）

**目标**：实现 V3.1 §37 的纯领域模型，全是 Swift struct/enum，不带 persistence。内联到 `macos-app/InvestmentIntelligenceV2/`。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| DOM-1 | 基础 ID 类型：`InvestmentTargetID` / `DataProviderID` / `InstrumentID` / `ListingID` / `FundProductID` / `FundShareClassID` / `LegalEntityID` 等 | M0 | 2 | Sendable + Codable + Hashable |
| DOM-2 | Identity 层：`LegalEntity` / `Instrument` / `Listing` / `FundProduct` / `FundShareClass`（V3.1 §7-11）| DOM-1 | 3 | 字段齐全；A/C 类拆开 |
| DOM-3 | `ProviderIdentifier` + `IdentityResolutionMethod` + `InstrumentRelationship`（ETF→Index / ShareClass→Product / Stock→Entity / ADR→Stock）| DOM-2 | 2 | V3.1 §12-14 |
| DOM-4 | `TemporalEnvelope`（四时间：effectiveAt/publishedAt/availableAt/ingestedAt）+ `AvailabilityProvenance` | DOM-1 | 2 | DATA005 经济可知语义文档化；ingestedAt ≠ availableAt |
| DOM-5 | `CanonicalObservation` 协议 + 具体类型：`DailyBar` / `NAVObservation` / `FundHoldingSnapshot` / `MacroObservation` / `CorporateAction` / `Evidence` | DOM-2,4 | 5 | ADR-DATA003 raw + adjustment 分离 |
| DOM-6 | `KnowledgeContext` + `DataQueryMode`（economicKnowledge / exactSnapshot）| DOM-4 | 2 | 两种 query API 分离（V3.1 §46）|
| DOM-7 | `AvailabilityPolicy` 版本化结构 + V1 保守规则集（fund NAV / market close / fund disclosure 三类）| DOM-4 | 3 | 每条 policy 含 id/version/rule/provenance；可审计 |
| DOM-8 | `DataQuality` / `ProviderHealth` / `ProviderReliabilityClass`（officialStable/documentFreeAPI/communityAggregated/undocumentedPublicEndpoint）| DOM-1 | 2 | §103 + §21 |
| DOM-9 | Evidence/Signal 分层：`Evidence` + `EvidenceFact`（含 extractionMethod/verificationStatus）+ `InvestmentSignal` | DOM-1 | 3 | V3.1 §53-55；XBRL fact ≠ LLM extracted fact |
| DOM-10 | `Artifact` 协议 + `ValidityPolicy` enum（timeBound/untilDependencyChanges/tradingSession/immutableHistorical/composite）+ `ArtifactDependency` | DOM-1 | 2 | V2.2 §84 |

**里程碑 M1：Domain Model 编译通过 + 所有类型 Codable round-trip + Sendable 测试通过**（见 §4.0）。

---

### Epic 3 — Repository + InMemory + IdentityResolver + M2 验证（Phase 0.5 下半）

**目标**：跑通 V3.1 §38 的 M2 验收——两个真实 Provider 的 identity resolution 和 PIT 语义。这是整个项目的 go/no-go。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| REPO-1 | Repository 协议（七域）：Instrument / MarketTimeSeries / NAVTimeSeries / FundHolding / Macro / CorporateAction / Calendar，Observation 类 API 强制 `KnowledgeContext`（Identity/Calendar 例外见 ADR-DATA002 §3a）。**Fundamental 域拆到 REPO-1b**（FundamentalObservation 类型未定义前不强行空协议占位，审查 P2）| DOM-* | 3 | ADR-DATA002 强制 |
| REPO-1b | **FundamentalRepository**：FundamentalObservation 类型定义 + Repository 协议加入（从 REPO-1 拆出，Epic 7+ 引入 factor 时补）| REPO-1 | 2 | FundamentalObservation 定义；Fundamental 查询带 KnowledgeContext |
| REPO-2 | InMemoryRepository 实现（Dictionary-backed）| REPO-1 | 3 | economic/exact 两种 query 都支持；multi-vintage 每 (effectiveAt) 取最新 |
| REPO-2b | **preferredProvider 多源去重**：CanonicalObservation 加 sourceProviderID/provenance + 稳定 tie-breaker（从 REPO-2 拆出，审查 2026-08-12）| REPO-2 | 2 | preferredProvider 生效；同 effectiveAt+vintage 跨源确定性选一 |
| REPO-3 | JSON Fixture loader（`Tests/.../Fixtures/*.json`）| REPO-2 | 2 | 能加载真实样本 |
| REPO-4 | `IdentityResolver` **lookup 层**：按 (provider,scheme,value) 查已登记映射 + 校验 isAuthoritative + fuzzy 返回 candidate 经 Verification。**4 条建立路径是 IdentitySync（SYNC-8）建立时的匹配算法**，不是 resolver 运行时匹配（ADR-DATA001 §3 明确）| DOM-3, REPO-2 | 3 | V3.1 §13；fuzzy 不直接写 canonical；4 路径建立算法移到 SYNC-8 |
| REPO-4b | **初始 Identity 映射数据**：手工 verified 基础集（持仓内标的）+ 映射数据 fixture | REPO-4 | 2 | 持仓内基金/股票有 canonical 映射；非持仓标的留待 Identity Sync |
| REPO-5a | `ObservationFactory` **DailyBar + NAV 完整链**：拥有 `ProviderRecord` 定义 + ProviderRecord → CanonicalObservation（identity 解析 + policy 选 + PIT 标注 + payload 解析）| DOM-4,7, REPO-2 | 2 | 不会把 ingestedAt 当 availableAt；2 kind 端到端 |
| REPO-5b | `ObservationFactory` **FundHolding + Macro + CorporateAction 三类**：从 REPO-5 拆出（审查 2026-08-12），FundamentalObservation 与持仓 raw payload schema 就绪后实现 | REPO-5a | 2 | 5 kind 完整；持仓 schema 解析 |
| REPO-7 | 接 天天基金 Provider（调用现有抓取逻辑取持仓 + 历史 NAV → ProviderRecord，**不修改现有 client**）| REPO-5a,5b | 3 | 输出 staging |
| REPO-8 | M2 验收测试（§4.1 的 4 个场景，真实 Provider 链路）| REPO-4,4b,5a,5b,7 | 3 | 四个场景全过（真 gate，非形态预演） |

**里程碑 M2：真实数据上 identity + PIT 跑通**。M2 不过不进 Epic 5（GRDB）。

> **状态修正（2026-08-12，多次迭代）**：M2 当前为 **Blocked**。
>
> **REPO-6（且慢 Provider）已移除**（2026-08-12）：调研确认且慢在 V2 market data pipeline
> 无不可替代位置——净值转发天天基金（REPO-7 直连源头）、独有的主理人调仓动态不属于
> CanonicalObservation（5 个 ProviderRecordKind 都不匹配）、AI 分析也不需要。
> `QiemanProviderAdapter` stub、fixture 的 prodCode 映射、M2 场景 1（基金跨 Provider）均已
> 删除，场景从 5 个收敛为 4 个。`DataProviderID.qieman` 仅作 identity 层命名常量保留（非数据 Provider）。
>
> **已签收 Story（17 点 / 30，审查确认）**：REPO-1（3）、REPO-2（3）、REPO-3（2）、
> REPO-4（3，按新 lookup 定义）、REPO-5a（2）、REPO-5b（2）、REPO-2b（2）。
>
> **当前实现状态**（避免与下方 Story 表述冲突）：
> - REPO-1 Repository 协议（七域，Fundamental 拆到 REPO-1b）——完整
> - REPO-2 InMemoryRepository：economic/exact/operational 三 query mode、
>   multi-vintage 每 (effectiveAt) 取最新、Sendable、upsert 幂等——完整
> - REPO-2b preferredProvider 跨源去重：DataQuality 加 sourceProviderID（工厂从
>   ProviderRecord 注入），filterByContext 同 (effectiveAt, vintage) 多 Provider 时按
>   reliability → sourceProviderID → id 确定性 tie-break 择优；exactSnapshot 不去重——完整
> - REPO-3 JSON Fixture loader——完整
> - REPO-4 IdentityResolver lookup 层——完整（4 路径建立算法在 SYNC-8）
> - REPO-5a ObservationFactory（DailyBar + NAV 完整链，含 ProviderRecord 所有权 +
>   identity 解析 + policy 选 + PIT 标注 + payload 解析 + 非有限数防护）——完整
> - REPO-5b ObservationFactory（FundHolding + Macro + CorporateAction 三类）：
>   5 kind 全覆盖，FundHolding position 逐个 identity 解析（持仓代码携带 providerID，
>   支持跨 Provider——基金快照与持仓股票代码可来自不同 Provider），任意 position
>   未解析即拒收整条 snapshot（覆盖缺口由 Epic 8 PortfolioLookthrough 处理）——完整
> - REPO-7 天天基金 NAV 解析链：pingzhongdata + lsjz 真实 wire 格式（基于现有
>   QiemanPlatformFundQuoteFallbackTests inline mock 派生，**非 live network 录制**），
>   日期归一化、字段级合并、真实累计净值（Data_ACWorthTrend/LJJZ）、分红 Optional 不伪造、
>   schema 漂移抛错、NaN/Infinity 防护、诊断覆盖度（complete/unsupported）——NAV 这一条
>   链路真实；**持仓未接**（FundLookThroughClient 是独立 actor，留 Epic 4）
> - 字段缺口：天天基金 pingzhongdata 不直接披露分红（cumulativeDividendPerShare 留 nil）；
>   持仓只有 weightPct（无 shares/marketValue）
>
> **未达成项（M2 blocked 原因）**：
> - REPO-7 持仓链路未接（仅 NAV 链路真实）
> - REPO-8 M2 验收测试（§4.1 四场景真实链路）未跑通
> - live network 集成测试留 Epic 4（需网络）
> - REPO-1b FundamentalRepository 未实现（FundamentalObservation 类型未定义，Epic 7+）
> 待 Epic 4 补 live network 集成测试后，M2 可正式标记 Pass。

---

### Epic 4 — Provider Adapters（Acquisition Layer）

**目标**：完整 Provider 层，每个 adapter 只产 ProviderRecord，不写 Canonical。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| PROV-1 | `ProviderStaging`（JSONL spool dir）格式定义 + Schema Validator（`ProviderRecord` 所有权在 REPO-5a，PROV-1 只消费做 Staging/校验，审查 P2 消除所有权倒置）| REPO-5a | 2 | V3.1 §26 |
| PROV-2 | Stooq Adapter（美股历史日线 primary，CSV 下载 + 解析）| PROV-1 | 3 | personal-use 合规标注 |
| PROV-3a | AKShare **本地** Collector（macOS 进程外 Python，输出 staging；多 dataset 对接 + 异常处理）。DATA007 方案，**进阶可选**——默认 App 不含，想用 A 股全量的用户自装。分发困境见 DATA010 | PROV-1 | 8 | DATA007 隔离；不进 iOS；不直接写 Canonical；多 dataset 覆盖 |
| PROV-3b | AKShare **远程** Collector + App 端 `RemoteStagingProvider`（VPS 部署 Python collector 抓公开数据 → nginx 托管 JSONL → App HTTP 拉取 + 验签 + SchemaValidator）。DATA010 方案，**默认路径**——App 零 Python 依赖，A 股全量作远程增强，客户端三档降级。含跨语言 schema 契约测试 | PROV-1, PROV-8 | 5 | DATA010：公开数据 only / 鉴权反白嫖 / 三档降级 / 验签完整性；契约测试守护 Python↔Swift schema 对齐 |
| PROV-4 | SEC Adapter（封装现有 `SECOfficialSourceClient`）| PROV-1 | 2 | XBRL facts 带 extractionMethod |
| PROV-5 | FRED Adapter（宏观，利用 real-time periods/vintage）| PROV-1 | 3 | vintage 对齐 PIT |
| PROV-6 | Alpha Vantage Adapter（已有，降级 supplemental，加 25/天 quota 感知）| PROV-1 | 2 | quota 用完降级不阻塞 |
| PROV-7 | Tavily Adapter（保留作 Research 用，加月额度感知）| PROV-1 | 1 | |
| PROV-8 | ProviderHealth 监控基础（per-provider 成功/失败/quota 状态）| PROV-* | 2 | DATA006 行为 |

**里程碑 M3：Provider 层完整**。

> **状态（2026-08-12）**：M3 进行中（8/28 点，PROV-1/2/5 签收）。
> PROV-3 拆为 PROV-3a（本地 Python collector，DATA007，8pt，进阶可选）+
> PROV-3b（远程 VPS collector + RemoteStagingProvider，DATA010，5pt，默认路径）。
> DATA010 ADR 已 Proposed，定死凭证边界（公开数据 only）/ 反爬（聚合去重）/
> 三档降级 / 鉴权反白嫖 / 验签完整性。
>
> **已签收**：
> - PROV-1（2）—— `ProviderStaging`（JSONL spool 读写，append-only，
>   `Persistence/` 新目录）+ `ProviderRecordSchemaValidator`（结构前置闸门：字段非空、
>   时间序 effectiveAt≤publishedAt、rawPayload 按声明 kind 解码匹配；与 ObservationFactory
>   的语义转换互补不重叠）。ADR-DATA003 Pipeline 第 1+4 步可独立单测。**且为 PROV-3b
>   远程 collector 的接收侧基础**（RemoteStagingProvider 复用 Reader + Validator）。
> - PROV-2（3）—— Stooq 美股日线 Adapter：`StooqResponseParser`（CSV 表头列名分派、
>   非有限 OHLC 防护、Volume 缺失为 nil、dropped 计数）+ `StooqProviderAdapter`（产
>   DailyBar ProviderRecord，USD、unitedStates、adjustmentFactor=1.0 raw 不伪造复权）。
>   端到端验证 CSV→ProviderRecord→SchemaValidator→staging round-trip。ProviderEndpoint
>   加 stooqHistory，URLSession 按 endpoint 映射 providerID（不再硬编码 eastmoney）。
> - PROV-5（3）—— FRED 宏观 Adapter：`FREDResponseParser`（observations JSON，realtime_start
>   →publishedAt 做 PIT 锚点，"." 缺值丢弃+计数）+ `FREDProviderAdapter`（series config 驱动，
>   officialStable，产 MacroPayload ProviderRecord）。新增 `MacroRelease` availability policy
>   （base=publishedAt、US 法域）——修正 macro 不再误用 MarketClose（GDP Q1 值 dated 1-01 但
>   4-25 才发布，availableAt 应基于发布日）。端到端验证 FRED→MacroObservation→PIT。
>
> **未达成（M3 blocked 原因）**：PROV-3a/3b/4/6/7 各 Adapter 需接外部数据源
> （AKShare 本地/远程 Python / SEC XBRL / Alpha Vantage / Tavily），PROV-8
> ProviderHealth 依赖各 Adapter 落地后聚合。这些 Adapter 的解析逻辑可离线先行
> （参考 Stooq/FRED 的 StaticResponseFetcher 注入模式），但完整验收
> 需对应外部服务/VPS 的真实连通。PROV-3b 的跨语言契约测试可离线先行。

---

### Epic 5 — Canonical Store（GRDB，Phase 1）

**只在 M2 验收通过后开始**（ADR-DATA009）。**这会引入 GRDB 这个新依赖，AGENTS.md 第 6 条约定（无 SQLite）由此被打破——Epic 5 开始前需在 AGENTS.md 更新该约定。**

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| GRDB-1 | 引入 GRDB SPM dep + DB lifecycle（migration 框架，schemaVersion）| M2 | 3 | iOS/macOS/CLI/Tests 共用 |
| GRDB-2 | Identity schema（7 表：legal_entities / instruments / listings / fund_products / fund_share_classes / provider_identifiers / instrument_relationships）| GRDB-1 | 5 | V3.1 §14 |
| GRDB-3 | Market schema（daily_bars / corporate_actions / nav_observations，DATA008 行情单 vintage 简化）| GRDB-1 | 3 | 99.9% 走简单查询 |
| GRDB-4 | Fund schema（holding_snapshots / holding_positions / allocation_snapshots，multi-vintage）| GRDB-1 | 3 | DATA008 持仓多 vintage |
| GRDB-5 | Fundamental/Macro schema（对齐 FRED vintage）| GRDB-1 | 2 | |
| GRDB-6 | Intelligence/Decision/Agent schema（evidence / evidence_facts / signals / theses / artifacts / artifact_dependencies / decisions / agent_jobs / agent_job_events / agent_checkpoints）| GRDB-1 | 5 | |
| GRDB-7 | `GRDBRepository` 实现所有 Repository 协议（替代 InMemory）| GRDB-2..6 | 8 | Repository 契约不变；golden test 同样过 |
| GRDB-8 | Data Pipeline：Staging → IdentityResolver → TemporalNormalizer → SchemaValidator → DataValidator → Canonical Commit | GRDB-7, REPO-4,5a,5b | 5 | 四防火墙都在 commit 前 |
| GRDB-9 | 更新 AGENTS.md 第 6 条（数据持久化约定）承认 GRDB 引入 + iOS framework 链接 + Package.swift/Xcode 配置 + 数据目录规划 | GRDB-1 | 2 | 约定与代码一致；两端构建通过 |

**里程碑 M4：Canonical Store 上线**。

---

### Epic 6 — Data Sync / Backfill（Phase 3）

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| SYNC-1 | `TradingCalendar`（A 股交易日历 + 基金净值公布日历）| GRDB-7 | 3 | exchangeScheduleDerived 依赖此 |
| SYNC-2 | Market Daily Sync（收盘后增量：stocks/ETF/indexes）| SYNC-1, PROV-3b | 2 | |
| SYNC-3 | Fund NAV Sync | SYNC-1, REPO-7 | 2 | |
| SYNC-4 | Fund Holding Sync（披露检测，新 snapshot 自动入库）| REPO-7 | 2 | |
| SYNC-5 | Macro Sync（daily/weekly）| PROV-5 | 1 | |
| SYNC-6a | **持仓 universe Historical Backfill**（用户当前持仓涉及的标的，回填 ≥252 交易日）| SYNC-2,3 | 3 | 持仓内全部标的有历史 |
| SYNC-6b | **全市场 universe Historical Backfill**（Market Discovery 用的 300+ 行业/指数/资产标的，分批回填；受免费 Provider 额度限制，可分阶段）| SYNC-2,3 | 5 | WF-2 依赖的 universe 有基础覆盖；允许增量补全 |
| SYNC-7 | Provider 失败降级路径（local 兜底 + secondary + unavailable）| GRDB-8 | 3 | DATA006 + FREE001 |
| SYNC-8 | Identity Sync（发现新资产时 4 路径建立算法：provider authoritative / exchange+symbol exact / ISIN/CIK / manual verified → fuzzy 产 candidate → Verification → commit；非持仓标的的 identity 增量建立）| SYNC-2, REPO-4 | 5 | 新标的能进 Instrument Master；4 路径各有测试 |

**里程碑 M5：数据自给**。Factor Engine 才有可信输入。

---

### Epic 7 — Factor Engine

**铁律**：每个 factor 返回 metric（Decimal + unit），不返回分数；ordinal signal 由独立 SignalPolicy 产生。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| FAC-1 | `FactorDefinition` + `FactorSnapshot`（provenance: sourceObservationIDs / factorVersion / asOf）| M5 | 2 | 历史 Factor 可重算 |
| FAC-2 | `SignalPolicy`（metric → ordinal signal，versioned；分类阈值是 policy parameter，需 provenance 标注，类似 IndifferenceBand 的 heuristicPolicy）| FAC-1 | 3 | ordinal 不进 cardinal 运算（V3.1 §46）；阈值 provenance 可审计 |
| FAC-3 | Trend Factor（closeVsMA20 / closeVsMA60 / ma20Slope / ma60Slope）| FAC-1 | 2 | golden test |
| FAC-4 | Momentum Factor（20/60/120d return）| FAC-1 | 2 | golden test |
| FAC-5 | Volatility Factor（20/60d realized）| FAC-1 | 2 | golden test |
| FAC-6 | Drawdown Factor（current / max 252d）| FAC-1 | 2 | golden test |
| FAC-7 | Relative Strength（asset − benchmark，指定 benchmark）| FAC-1 | 2 | benchmark 显式 |
| FAC-8 | Factor PIT golden test 套件（固定序列 → 固定输出，跨 vintage 一致）| FAC-3..7 | 3 | |

---

### Epic 8 — Exposure / Risk

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| EXP-1 | `PortfolioLookthroughCalculator` v2（**全新实现**，不复用现有 `FundLookThrough.swift`；含 coverage/interval/unknownWeight/上下界，等价或超过现有 944 行的能力）| M5 | 8 | 不动现有 FundLookThrough（Epic 12 才下线）；现有测试场景在新实现上等价通过 |
| EXP-2 | Exposure Engine（asset class / sector / single security / fund overlap，输出 `ExposureEstimate` 含 lowerBound/upperBound）| EXP-1 | 5 | unknownWeight 进入上下界（V3.1 §33）|
| RISK-1 | Concentration（single position / underlying security / sector / HHI，含 lookthrough）| EXP-2 | 3 | 多基金重复持股正确识别 |
| RISK-2 | Correlation（历史序列不足 → unknown，不猜）| FAC-5 | 3 | |
| RISK-3 | `PortfolioRiskProfile`（多维度，不产单一分数）| RISK-1,2 | 2 | |

---

### Epic 9 — Daily Attribution Workflow（第一个完整 Workflow）

**第一个完整 Workflow**，90% deterministic，最适合验证整条 Data→Engine→Artifact→Renderer 链。这是首次让 macos-app `import` V2 代码进入双轨期。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| ATTR-1 | Attribution Engine（contribution / coverage / residual，数学正确）| EXP-1 | 5 | |
| ATTR-2 | `DailyAttribution` artifact + ValidityPolicy = immutableHistorical | ATTR-1 | 2 | |
| ATTR-3 | `AttributionRenderer`（coverage 分级措辞：≥80% / 50-80% / <50%，V2.2 §27）+ LLM Narrative 补充层（LLM 只补叙述，不改因果确定性）| ATTR-2 | 3 | LLM 不能改写因果确定性 |
| ATTR-4 | `DailyAttributionWorkflow` + Job lifecycle（queued/running/completed/failed/cancelled）| ATTR-3 | 3 | AgentJob/Event |
| ATTR-5 | macos-app 首次集成：新 Attribution 与现有 `MarketCloseReviewSnapshot` 双轨展示 | ATTR-4 | 3 | App 层引用 V2；旧代码保留 |

**里程碑 M6：第一个 Workflow 上线**。整条链路通了，后面 Decision/Research 才有信心。

---

### Epic 10 — Decision 子系统（V2.2 内容）

**依赖说明**：本 Epic 用 **mock Signal** 测试（Decision 不依赖真实 LLM Research）。真实 Signal 生产在 Epic 11（Research）。M7 验收用固定 mock Signal 验证「same inputs → same decision」。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| DEC-1 | `StrategicAllocationPolicy` + `AllocationTarget` + `TargetAllocationProvenance`（explicitUserAllocation / userSelectedTemplate）+ `StrategicAllocationValidator` | M4 | 5 | D000；Signal 不能改 Target；Agent 只能推荐目录已有模板 |
| DEC-2 | `StateConstraintEvaluator` + `RemediationRequirement`（祈使约束）+ Operational Obligation 分开 | EXP-2, RISK-3 | 5 | 现状违规 → remediation，不是 veto |
| DEC-3 | `PortfolioSnapshot` + `ProjectedPortfolio`（apply plan 后模拟）| EXP-2 | 3 | |
| DEC-4 | `ActionDomainBuilder`（per-asset 允许动作域，裁剪搜索空间）| DEC-3 | 3 | |
| DEC-5 | `TargetRebalancePlanner`（生成 PortfolioActionPlan，含 SizingProvenance）| DEC-1,2,4 | 8 | D001；Δw 只来自 target/remediation/user |
| DEC-6 | 双层 Constraint Gate（action-level pruning + portfolio-level on ProjectedPortfolio）| DEC-5 | 5 | 联合约束（相关性/总预算/再平衡零和）|
| DEC-7 | `CriterionEvaluator` + `CriterionDefinition` provenance（versioned deterministic evaluator + inputReferences）| DEC-6 | 5 | D002；黑箱 criterion 禁止 |
| DEC-8 | `CriterionComparator` + `IndifferenceBand`（heuristic 必须标注）+ Pareto Filter（Effective Dominance，incomparable/unknown 阻断 dominance）+ Partial DecisionPolicy（处理非传递性）| DEC-7 | 8 | D003；unresolvedTradeoff 真的可触发；非传递性有明确处理 |
| DEC-9 | `DecisionValidator` + `PortfolioDecisionArtifact` + Decision Replay（引用 Signal IDs 不重跑 Research）| DEC-8 | 3 | D004；same mock inputs → same decision |

**里程碑 M7：Decision 子系统可独立运行（mock signals）**。

---

### Epic 11 — LLM Research 子系统

**目标**：实现 V3.1 §100 的 Research 链：`Research Workspace → Notes → Signal Extraction → Validation → Signal Store`。这是现有代码最大的一块（三条 Agent 链路 2000+ 行），新系统要重写，但 harness 模式可参考现有 `TrendResearchAgent`（复制受控子集，不提前抽象——V2.2 §15 坑点）。

**铁律**：LLM 只做 Research / Event Interpretation / Thesis Formation / Narrative；不直接写 DB、不改 Target、不决定 Δw、不算 Risk/Attribution、不生成 Confidence 数字。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| RES-1 | `LLM Model Gateway`（`ModelProvider` 协议 + provider selection + timeout/retry/token budget + tracing + usage 记录）；Workflow 不直接操作 OpenAI/Anthropic SDK | DOM-9, M4 | 3 | V3.1 §46 |
| RES-2 | `Research Workspace` + Harness（多轮 Tool Calling 循环 / 预算 / 超时 / 取消 / 上下文裁剪；参考现有 `TrendResearchAgent` 模式重写，不抽象通用框架）| RES-1 | 8 | 单次 Research Job 完整跑通 |
| RES-3 | `Research Tool Registry`（封装 Provider 取数为 Research Tool；SEC/Tavily 开放研究工具；**不复用** Slice 0-7 的 `TrendResearchToolRegistry`，新建 V2 版）| RES-2, PROV-* | 5 | LLM 通过工具访问外部世界，不直接读 Repository |
| RES-4 | `Signal Extraction`（Research Notes → 结构化 `ResearchSignal`；versioned SignalPolicy 约束；ordinal signal 输出）| RES-2, DOM-9 | 5 | 自由 reasoning 不直接进系统状态 |
| RES-5 | `Research Validation`（SchemaValidator + EvidenceBindingValidator + FreshnessValidator；复用 Evidence 层）| RES-4 | 3 | LLM 输出后统一过 validation pipeline |
| RES-6 | `Signal Store` 持久化（Signal 进 GRDB signals 表 + derivedFrom evidence IDs；跨运行可查）| RES-5, GRDB-6 | 2 | Signal ≠ Evidence 分开存储（V3.1 §38）|
| RES-7 | `Structured Generation` 契约（所有 LLM 输出 Codable；禁止返回 Markdown 再 parse）| RES-1 | 2 | |
| RES-8 | `Evidence Matcher`（LLM 输出 Fact Claims → 匹配已有 Evidence；模型不主动生成 evidence ID）| RES-5 | 3 | V2.2 §51 |
| RES-9 | Research golden test 套件（固定 LLM mock 输出 → 固定 Signal；覆盖 Schema/EvidenceBinding/Freshness 校验）| RES-5,8 | 3 | |

**里程碑 M8：LLM Research 子系统可用（产真实 signals）**。

---

### Epic 12 — Workflows + Presentation + 现有 AI 链路 + Slice 0-7 下线

**这是清理与集成 Epic**：新 Workflow 全部上线（串联 Research + Decision），Presentation 层补全，旧代码全部删除。双轨期结束。

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| WF-1 | Portfolio Research Workflow（Research → AssetThesis → PortfolioThesis → Signals → Decision）| DEC-9, RES-9 | 8 | 替代 longTerm；真实 Research 产 Signal 喂 Decision |
| WF-2 | Market Discovery Workflow（Universe + Local Factor 候选 + 选择性 Research，非 LLM 盲搜）| FAC-8, SYNC-6b, RES-9 | 5 | 替代固定八组搜索；降 Tavily 消耗 |
| WF-3 | Intraday Workflow（Signal + Eligibility + Rebalance execution decision，非 LLM 猜仓位）| DEC-9, RES-9 | 5 | 替代 3+1 Agents；遵守 D001 |
| PRES-1 | `Presentation Layer`：`DecisionNarrator`（解释「为什么这个 plan 胜」，只解释不重决）+ `ResearchNarrator`（Thesis 叙述）+ 统一 `Artifact Query Service` | WF-1,2,3 | 5 | V2.2 §11 三分；UI 改读 Artifact |
| WF-4 | `TrendAnalysisReport` / `NextHourGuidanceReport` 完全下线（三条旧链路代码删除 + 测试删除）| PRES-1 | 5 | 三条旧链路代码不存在 |
| WF-5 | **Slice 0-7 下线**：删除 `Core/InvestmentIntelligence/` 全部代码（22 源文件）+ 关 Feature Flag + 删对应测试（~118 个）+ AppModel extension 清理 + 数据迁移（DecisionCase → PortfolioDecisionArtifact 若有迁移路径，否则清空重来并明确告知用户）| WF-4 | 8 | `InvestmentIntelligenceFeatureFlag` 删除；旧目录不存在；用户数据迁移有明确路径 |

**里程碑 M9：现有 AI 链路全替换 + Slice 0-7 下线**。双轨期结束，代码库只剩 V3.1 一套。

---

### Epic 13 — Agent Runtime 独立化 + 可选 package 抽取

| ID | Story | 依赖 | 点数 | 验收 |
|---|---|---|---|---|
| AGENT-1 | `AgentJob` / `AgentEvent` / `WorkflowRegistry` / `JobRecovery`（checkpoint + idempotency key）| WF-* | 8 | |
| AGENT-2 | `investment-agent` CLI（V3.1 §97 命令：data sync / health / identity inspect / market-research / portfolio-review / attribution / decision replay / jobs / resume）| AGENT-1 | 5 | 不启动 SwiftUI 能跑 research/sync/factor/attribution/decision |
| AGENT-3 | macOS XPC daemon（可选，App 关 UI 后台仍跑）| AGENT-2 | 5 | |
| PKG-1 | **评估并执行** SPM package 抽取（`InvestmentIntelligenceV2/` → 独立 `InvestmentIntelligenceKit` package）。M10 时真实依赖形状已清楚，按已知形状切，不是猜形状抽。| AGENT-2 | 5 | 若抽取：macos-app `import InvestmentIntelligenceKit`；CLI/daemon 独立 target |

**里程碑 M10：Agent 真正独立**。

---

## 4. 里程碑验收脚本

### 4.0 M1 — Domain Model 编译通过

- 所有 DOM-* 类型编译通过
- 每个类型的 Codable round-trip 测试通过（encode → decode → 相等）
- Sendable conformance 检查通过
- `swift test` 全绿

### 4.1 M2 — Identity + PIT 真实验证（★ go/no-go）

M2 是整个项目最关键的验收。四个场景必须全过：

| # | 场景 | 期望 |
|---|---|---|
| 1 | 同一股票在两个 Provider symbol 不同 | 解析到同一 `ListingID` |
| 2 | 基金 Q2 持仓 7-20 公告（2024 年周六）| `availableAt = nextTradingDay(7-20) = 7-22`；`economicKnowledge(asOf: 7-10)` 查不到 |
| 3 | Provider 故障延迟到 8-01 抓到 | `availableAt = 7-22`（客观，由 policy 推导），`ingestedAt = 8-01`；`economicKnowledge(asOf: 7-22)` 可见，`operationalKnowledge(asOf: 7-22)` 不可见 |
| 4 | 模拟一次 data revision（v1→v2）| 历史 vintage 查询仍看到 v1 |

> 原「同一基金在 Qieman 和天天基金代码不同」场景（基金跨 Provider identity）已随 REPO-6
> 且慢 Provider 移除而删除：基金 NAV 数据源唯一为天天基金，不存在跨 Provider 场景。
> 跨 Provider identity 机制改由场景 1（股票：天天基金 + Stooq）验证。

M2 不过不进 Epic 5（GRDB schema 冻结）。

### 4.2 M4 — Canonical Store 上线

- GRDBRepository 通过所有 InMemory 时代的 golden test
- 四防火墙都在 commit 路径上

### 4.3 M5 — 数据自给

- 持仓 universe 全部有 ≥252 交易日历史
- 全市场 universe 有基础覆盖（允许增量补全）
- Provider 故障 → local 兜底 → 降级而非崩
- TradingCalendar 正确处理节假日
- 非持仓新标的能进 Instrument Master

### 4.4 M6 — 第一个 Workflow

- DailyAttribution 在真实数据上产出
- coverage 分级措辞由 Renderer 程序化生成
- 现有 closeReview 双轨展示，新归因独立产出（旧代码仍在）

### 4.5 M7 — Decision 子系统（mock signals）

- Cardinal Firewall 闭环：任何 Δw 可追溯到合法 provenance
- 同 mock PortfolioSnapshot + mock Signals + Policy → 同 PortfolioActionPlan
- unresolvedTradeoff 在构造的真实场景中可触发（非装饰枚举）

### 4.6 M8 — LLM Research 子系统

- 真实 Research Job 完整跑通（多轮 Tool Calling → 结构化 Signal）
- Signal 进 Signal Store，derivedFrom 可追溯到 Evidence
- LLM 无法生成不存在的 evidence ID（Evidence Matcher 拦截）
- Structured Generation：无 Markdown parse 路径

### 4.7 M9 — 全替换 + 下线

- 三条旧 AI 链路代码删除后 `swift build` 通过
- `Core/InvestmentIntelligence/` 目录不存在
- `InvestmentIntelligenceFeatureFlag` 类型不存在
- Slice 0-7 用户数据有明确迁移/清理路径
- 所有测试绿

### 4.8 M10 — Agent 独立

- `investment-agent portfolio-review` 不启动 SwiftUI 能跑通
- Job 中途 kill → resume 能继续
- package 抽取（若执行）后 macos-app 仍正常构建

---

## 5. 推荐起点

**Epic 1 → Epic 2 → Epic 3 → 拿到 M2**。

理由：
- M2 是 go/no-go，跑不过后面全是空中楼阁
- 这几个 Epic 不动现有 macos-app 业务代码（只在 `InvestmentIntelligenceV2/` 新建 + 调现有 client 取数），零回归
- M2 跑通后 schema 设计才有真实数据支撑

---

## 附录 A — 架构 ADR 清单（Epic 1 产出，写入 `docs/adr/`）

| ADR | 标题 | Epic |
|---|---|---|
| FREE001 | Zero Paid Dependency | 1 |
| DATA001 | Canonical Identity | 1 |
| DATA002 | PIT Visibility | 1 |
| DATA003 | Raw Market Canonicalization | 1 |
| DATA004 | Local Accumulation | 1 |
| DATA005 | Economic Availability Semantics | 1 |
| DATA006 | Free Provider Fragility | 1 |
| DATA007 | External Collector Isolation | 1 |
| DATA008 | Observation Revision Policy | 1 |
| DATA009 | Model Validation Before Persistence Freeze | 1 |
| DATA010 | Remote Public-Data Collector（VPS 方案，PROV-3b 产出）| 4 |
| D000 | Strategic Target Provenance | 1 |
| D001 | Sizing Provenance | 1 |
| D002 | Criterion Provenance | 1 |
| D003 | Comparison Provenance | 1 |
| D004 | Decision Replay Boundary | 1 |

---

## 附录 B — 命名与目录约定

### B.1 目录结构（见 §2.3）

新代码统一在 `macos-app/InvestmentIntelligenceV2/`，子目录按职责分（Identity/Temporal/Observations/Repositories/Providers/Persistence/Sync/Factors/Exposure/Risk/Attribution/Decision/Research/Presentation/Workflows/Agent）。

### B.2 命名

- 类型名：UpperCamelCase（`InstrumentMaster`, `DailyBar`）
- 协议名：UpperCamelCase，无前缀（`Repository`, `CanonicalObservation`）
- 枚举 case：lowerCamelCase（`economicKnowledge`, `userSelectedTemplate`）
- ADR 文件：`docs/adr/NNNN-short-name.md`（FREE001 / DATA001-009 / D000-004）
- V2 目录前缀：`InvestmentIntelligenceV2/`（与现有 `Core/InvestmentIntelligence/` 区分，Epic 12 后者删除后可考虑改名去掉 V2）

### B.3 与 macos-app 集成时点

- Epic 1-8：macos-app 业务代码不引用 V2；V2 Provider 可调现有 client 取数但封装切断依赖
- Epic 9（Attribution）：App 层首次引用 V2，双轨展示
- Epic 12：旧 AI 链路 + Slice 0-7 全删除，V2 成唯一
- Epic 13：评估抽取独立 package

---

## 附录 C — v2 修订记录（相对 v1）

- **新增 Epic 11 LLM Research 子系统**（原计划隐形了现有代码最大的一块）
- **新增里程碑 M8**（Research 可用），里程碑重编号 M9/M10
- **新增 PRES-1 Presentation Layer**（DecisionNarrator + ResearchNarrator，V2.2 §11 三分补全）
- **点数上调**：PROV-3(5→8)、EXP-1(5→8)、DEC-8(5→8)、WF-5(5→8)、GRDB-9(1→2)
- **新增 REPO-4b**（Identity 映射初始数据，原藏在 REPO-4 里偏紧）
- **新增 SYNC-6a/6b**（持仓 vs 全市场 universe 拆分）+ **SYNC-8**（Identity Sync）
- **新增 §4.0 M1 验收脚本**
- **§2.2 明确测试归属**（Story 点数含单元测试，golden test 单列）
- **FAC-2 注明 SignalPolicy 阈值 provenance**
- **Epic 10 注明用 mock Signal**（依赖倒置说明）
- **规模估算更新**：~300 → ~340
