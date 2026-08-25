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

> **状态修正（2026-08-12，多次迭代）**：M2 曾长期 **Blocked**（行情端连通性）。
> **2026-08-21 起 M2 = Pass**（四场景 + evidence manifest 全绿，放行记录与二次样本
> 修订见下方「M2 达成」；Epic 5 GRDB 解锁）。
>
> **REPO-6（且慢 Provider）已移除**（2026-08-12）：调研确认且慢在 V2 market data pipeline
> 无不可替代位置——净值转发天天基金（REPO-7 直连源头）、独有的主理人调仓动态不属于
> CanonicalObservation（5 个 ProviderRecordKind 都不匹配）、AI 分析也不需要。
> `QiemanProviderAdapter` stub、fixture 的 prodCode 映射、M2 场景 1（基金跨 Provider）均已
> 删除，场景从 5 个收敛为 4 个。`DataProviderID.qieman` 仅作 identity 层命名常量保留（非数据 Provider）。
>
> **已签收 Story（19 点 / 30，审查确认）**：REPO-1（3）、REPO-2（3）、REPO-3（2）、
> REPO-4（3，按新 lookup 定义）、REPO-5a（2）、REPO-5b（2）、REPO-2b（2）、
> REPO-1b（2，2026-08-21）。
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
> - REPO-4b 初始 Identity 映射数据——完整：seed `repo-4b-portfolio-v1` 覆盖当前 App
>   「我的持仓」`user-portfolio.json` 中的 13 条未归档持仓（3 条 A 股、4 条场内基金、
>   6 条场外基金），仅登记 `eastmoney` 的 `stock_symbol` / `fund_code` 精确键，全部
>   `MANUAL_VERIFIED`；canonical 引用和实体类型由 `PortfolioIdentityCoverageTests` 校验，
>   非持仓标的留待 SYNC-8。遵守 ADR-DATA001、ADR-DATA002、ADR-DATA009；原始 App
>   数据文件不进入仓库。
> - REPO-5a ObservationFactory（DailyBar + NAV 完整链，含 ProviderRecord 所有权 +
>   identity 解析 + policy 选 + PIT 标注 + payload 解析 + 非有限数防护）——完整
> - REPO-5b ObservationFactory（FundHolding + Macro + CorporateAction 三类）：
>   5 kind 全覆盖，FundHolding position 逐个 identity 解析（持仓代码携带 providerID，
>   支持跨 Provider——基金快照与持仓股票代码可来自不同 Provider），任意 position
>   未解析即拒收整条 snapshot（覆盖缺口由 Epic 8 PortfolioLookthrough 处理）——完整
> - REPO-7 天天基金 NAV + 持仓链路：NAV 使用 pingzhongdata + lsjz 真实 wire 格式（基于现有
>   QiemanPlatformFundQuoteFallbackTests inline mock 派生，**非 live network 录制**），
>   日期归一化、字段级合并、真实累计净值（Data_ACWorthTrend/LJJZ）、分红 Optional 不伪造、
>   schema 漂移抛错、NaN/Infinity 防护、诊断覆盖度（complete/unsupported）；持仓通过注入
>   的 FundLookThroughClient typed disclosure 转成 FundHoldingPayload，shares / marketValue
>   缺口保留 nil。两条链路均产 ProviderRecord，可经 ProviderStaging JSONL 落地。
> - REPO-1b FundamentalRepository——完整（2026-08-21）：`FundamentalObservation`
>   （**LegalEntity 维度**，SEC CIK 的 Canonical 目标；periodStart nil = 时点项；
>   封闭 `FilingForm` enum 10-Q/10-K/20-F/40-F，范围外表单拒收）+ `FundamentalRepository`
>   第八域加入 Repository 聚合（KnowledgeContext 强制）+ InMemoryRepository 实现。
>   **期间分组语义**：economic 查询按 (metricKey, unit, periodStart, periodEnd) 分组取
>   最新 vintage——revenue/assets 同 periodEnd、Q2/H1 同 periodEnd 不互相塌缩（此前
>   filterByContext 按 effectiveAt 分组会吞掉同日多事实）。ObservationFactory 解除
>   `.fundamentalFact` 拒收（`canonicalConversionDeferred` case 删除），SEC 记录
>   → FundamentalObservation 端到端打通；identity 要求 `sec_cik → LegalEntity`，
>   其他维度拒收（真实映射由 SYNC-8 建立）。新增版本化
>   `AvailabilityPolicyV1.FilingRelease`（filing_release v1：base=publishedAt、
>   US 法域、+1 交易日，与 MacroRelease 审计分离）。10 个测试
>   （FundamentalRepositoryTests）+ RepositoryContractTests/AvailabilityPolicyTests 同步。
> - 字段缺口：天天基金 pingzhongdata 不直接披露分红（cumulativeDividendPerShare 留 nil）；
>   持仓只有 weightPct（无 shares/marketValue）
>
> **未达成项（M2 blocked 原因）**：
> - REPO-8 已补 `M2LiveAcceptanceTests` 四个真实链路 gate；2026-08-14 按 Architect
>   方案完成事实修订：断言全部由真实公告日推导（Q2=07-18、Q1=04-20 周六），identity
>   样本换真实 QDII（513100 AAPL），整套测试经 `M2MarketEvidenceSource` actor 串行
>   共享抓取（每上游一次）+ Stooq → Alpha Vantage 候选链（DATA006），并输出 evidence
>   manifest（Provider/endpoint/抓取时间/raw SHA-256/published-available-ingested/
>   两端 symbol 与 ListingID）。
>
> **✅ M2 达成（2026-08-21 Pass，四场景 + evidence manifest 全绿）**：
> - 配置真实 Alpha Vantage key（用户提供，存 Keychain `trend.alphaVantage.apiKey`，
>   不进仓库）后，**免费层能力边界实测推翻原修复假设**：`outputsize=full` 与
>   `TIME_SERIES_DAILY_ADJUSTED` 均为 premium；date-range 参数被**静默忽略**
>   （仍返回最新 100 条）；即免费 key 永远无法服务 2024-07 历史窗口。Stooq
>   复测仍 anti-bot challenge（.unavailable 降级语义不变）。
> - **二次样本修订**（ADR-DATA009 事实修订路径，同 2026-08-14 先例）：场景 1 行情
>   窗口由固定 2024-07 改为随 now 滑动的近 20 天（`M2MarketEvidenceSource.marketWindow`），
>   稳落 AV compact 覆盖（最近 100 个交易日）；持仓样本仍锚定真实 2024 Q2 归档。
>   场景 1 验证跨 Provider identity（与行情期无关），PIT 断言（场景 2-4）不变。
> - AV Adapter 补窗口感知 `outputsize` 选择（PROV-6 完善）：窗口起点早于 120 日历日
>   → `full`（免费 key 收 premium 提示 → DATA006 quotaExhausted 降级不阻塞；
>   premium key 解锁历史窗口）；近窗口保持 `compact`。+5 单测。
> - **M2 放行证据**：四场景真实验证——场景 1 Stooq 反爬降级 → AV secondary 真实
>   AAPL 日线与天天基金 513100 持仓 AAPL 解析到同一 ListingID；场景 2/3/4 天天基金
>   真实公告日 PIT 语义全过；evidence manifest 输出（Provider/端点/抓取时间/SHA-256）。
> - **遗留（不阻塞 M2，影响 SYNC-6）**：美股**历史**回填（≥252 交易日）在免费层
>   无可用源（Stooq 反爬 + AV 免费仅近 100 交易日）。实测 Yahoo v8 chart API 本机
>   可达（2024-07 全量日线、无 key、无挑战）——建议 Epic 6 前评估引入第三候选
>   （`undocumentedPublicEndpoint` 可靠性类已预定义，需按 DATA006/FREE001 评审）。

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

> **状态（2026-08-20）**：M3 进行中（23/28 点，PROV-1/2/3a/4/5/6/7/8 签收；
> PROV-3b 客户端侧离线完成 + **App 生产接线已落地（2026-08-21，见下）**，
> 剩服务端 VPS 部署 + 端到端）。
> PROV-3 拆为 PROV-3a（本地 Python collector，DATA007，8pt，进阶可选）+
> PROV-3b（远程 VPS collector + RemoteStagingProvider，DATA010，5pt，默认路径）。
> DATA010 ADR 已 Proposed，定死凭证边界（公开数据 only）/ 反爬（聚合去重）/
> 三档降级 / 鉴权反白嫖 / 验签完整性。
>
> **2026-08-20 增量签收**（全部离线先行，StaticResponseFetcher / FakeClient 注入模式；
> 含同日五轮审查修复，见下方「审查修复记录」）：
> - **PROV-8（2）**—— `ProviderHealthMonitor`（actor，`Providers/ProviderHealthMonitor.swift`）：
>   版本化 `HealthDegradationPolicy`（DOM-7 同款 id/version 可审计形态，七条规则
>   按优先级：quota 耗尽→unavailable / 连续失败≥5→unavailable / rateLimited 冷却期→
>   degraded（过期自动恢复）/ quota 剩余<20%→degraded / 连续失败≥2→degraded /
>   窗口成功率<0.5（样本≥5）→degraded / 其余 healthy）。
>   上报 API：recordSuccess / recordFailure(error:)（quotaExhausted→rateLimited+quota 推满
>   （先滚动周期再推满）、rateLimited→独立冷却不累计连续失败、schemaMismatch→记 drift、
>   notFound→不计入统计）/ recordQuota / incrementQuota（先滚动周期再写入）；查询 API：
>   health(for:) / isCallable / snapshot（SYNC-7 降级入口）。quota 周期自动滚动
>   （hourly/daily/monthly UTC 确定性重置点）。未注册 Provider 上报一律忽略并返回
>   nil（DATA006「未声明 reliabilityClass → 拒绝」）。成功率只按非限流调用计算
>   （限流冷却/额度重置后不残留 degraded）。30 个测试。
> - **PROV-4（2）**—— SEC Adapter（`Providers/SECResponseParser.swift`）：复用现有
>   `SECOfficialSourceClient` + `SECOfficialSourceCache`（公平访问限流 / User-Agent /
>   缓存不重复实现），新写 V2 独立解析器。**新增 `ProviderRecordKind.fundamentalFact` +
>   `FundamentalFactPayload`**（Validator/Factory 同步接 case；ObservationFactory 对该
>   kind 显式拒收 `canonicalConversionDeferred`——FundamentalObservation 在 REPO-1b
>   定义前不产 Canonical，staging + schema 校验可用）。PIT 语义：一条记录 = 一个
>   (concept, unit, start/end, filed) 事实行，同 concept 同 period 多次申报（10-Q 初报 /
>   10-K 修订）保留为不同 publishedAt 的多条记录（ADR-DATA008 multi-vintage）；
>   effectiveAt=期间结束、publishedAt=filed、providerCode=`sec_cik`（统一 10 位补零）。
>   **验收项：payload 携带 `extractionMethod = .xbrlFact`**（与 LLM extracted fact
>   类型层区分，DOM-9）。concept 候选按 (unit, start/end, filed) **逐事实**选优先概念
>   ——同期间多标签披露只留最高优先级不重复，公司换标签年份的两段历史都保留。
>   错误映射：403→unavailable、429→rateLimited（公平访问限流，独立冷却自动恢复）、
>   invalidResponse/缺 us-gaap→schemaMismatch、目录外 ticker→notFound。17 个测试。
> - **PROV-7（1）**—— Tavily 月额度感知（`Providers/TavilyQuotaPolicy.swift`）：
>   `TavilyQuotaPolicy`（免费层 1000 credits/月，版本化可持久化）三档决策
>   available / lowQuota(剩<100 保守) / exhausted（→Research 降级「无 web 搜索」模式，
>   DATA006 §5）；`TavilyProviderErrorMapper` 把 `TavilySearchClientError` 映射
>   ProviderError（**432/433→quotaExhausted（月额度耗尽）、429→rateLimited（瞬时频控
>   独立冷却，不污染月额度）、401→unavailable、invalidResponse→schemaMismatch**）；
>   `quotaConfig` 直通 ProviderHealthMonitor 的 monthly QuotaConfig。Tavily 不产
>   ProviderRecord（搜索结果是 Evidence，RES-3 封装为 Research Tool 时消费本层）。
>   14 个测试。
> - **PROV-3b 客户端侧（离线部分）**—— `RemoteStagingProvider`（actor，
>   `Persistence/RemoteStagingProvider.swift`，ADR-DATA010 接收面）：manifest 拉取 →
>   （可选）Ed25519 验签（CryptoKit，非法公钥**初始化即抛**、伪造签名拒收整批）→
>   本地 state 增量比对（同 sha256 跳过）→ 逐文件 sha256 完整性校验（不符拒收该
>   文件、其余继续）→ 复用 PROV-1 Reader + SchemaValidator 分桶 → 合法记录 append
>   本地 spool → state 持久化。**journal/offset 两阶段提交**：append 前先原子写
>   journal（记录 spool 偏移），append → checkpoint 成功才清 journal；下次 sync 启动
>   先恢复未提交 journal（截断 spool 回偏移），checkpoint 失败/崩溃后重试 spool 仍
>   只有一份。**恢复先于断路器**（checkpoint 失败立即打开断路器，退避期内的
>   sync 虽 .skipped 不触网络，本地 journal 恢复仍必须执行）。**断路器**：
>   连续失败指数退避（60s 起、15min 封顶），退避期 sync 直接 .skipped 不触网络。
>   spool 大小读不出**抛错**（不静默 0），恢复偏移大于当前 spool 大小**拒绝截断**
>   （spool 被外部改动的不一致现场上报而非破坏）。`URLSessionRemoteStagingFetcher`
>   带 X-Collector-Key + 路径穿越防护；403/429 映射 rejectedByServer（明确降级
>   语义）。manifest wire 契约（camelCase + ISO8601 + 小写 hex sha256）已测。
>   **读取容错（fail-closed）**：state/journal/spoolSize 不用 fileExists 前置
>   （它无法区分「不存在」与「权限/IO 查不了」），直接读取、只把明确的
>   no-such-file 错误当「无」；其它读取/解码失败终止本轮并保留现场（不把坏
>   state 当空 state 误截断已提交 spool、不静默跳过未恢复的 journal）。
>   journal 偏移**负数拒绝**（合法 JSON 可解出负值，静默 clamp 0 会清空 spool）、
>   越界拒绝（大于当前 spool 大小）、缺失 spool 只允许 offset==0。25 个测试。
>   **App 生产接线已落地（2026-08-21）**：`InvestmentIntelligenceV2/Sync/RemoteStagingSync.swift`
>   （配置面 `RemoteStagingSyncConfig` + Store + 路径布局 `RemoteStagingSyncPaths` +
>   装配 `RemoteStagingSyncSetup`）+ `Core/AppModel/RemoteStagingSyncLoop.swift`
>   （App 侧唯一调用点：启动读 `remote-staging-sync.json`——不存在 = 默认关闭
>   零后台任务；配置齐备启动 sync 循环：立即一轮 + 每 6h；失败只记诊断
>   `remoteStagingSyncStatus`，不弹错不重试不阻塞原生路径）。**配错显式上报
>   不静默降级**：enabled 但公钥/baseURL 非法 → misconfigured 状态，绝不带错
>   偷跑或静默转未验签。xcodegen 重生成 + macOS/iOS 双端构建通过；12 个
>   wiring 测试（配置 round-trip/前向兼容、路径布局、装配分档、端到端
>   config→provider→生产路径 sync + 增量轮不重复追加）。客户端配置文档见
>   remote-collector/README「客户端配置」。**这是 App 层首次引用 V2 代码**
>   （B.3 例外，PROV-3b 剩余项明示的接线工作；无 UI，纯配置文件 gate）。
>
>   **App 接线审查修复（2026-08-24，1×P1 + 1×P2）**：
>   - P1——`RemoteStagingSyncStatus` 的 synced 分档**补齐拒收计数**
>     （filesRejectedTampered / recordsRejectedInvalidSchema 此前被丢弃，
>     部分文件 sha256 不符或 schema 非法时诊断面显示成干净成功；非零
>     tampered 是 DATA010 防注入完整性事件）。映射抽成纯函数
>     `RemoteStagingSyncStatus.make(from:)`，+3 状态映射测试。
>   - P2——Setup 分档修正：**enabled=true 但 baseURL 缺失/非法 →
>     misconfigured**（原经 isRunnable 合并判断落进 notConfigured，与
>     「配错显式上报」契约相反）；enabled=false 才是 notConfigured。
>     测试反向断言同步修正（notConfigured → misconfigured + 空 URL 用例）。
>
>   **剩余（PROV-3b 未整点签收）**：真实 VPS 部署与 HTTP 端到端连通验收。
>   服务端产出物已完成（2026-08-21，仓库根 `remote-collector/remote_publish.py`，
>   **服务端组件与 macos-app 包分离**，不进 App/SPM/Xcode 工程；定位
>   akshare_collector.py 单一实现的搜索顺序：--collector-script → 同目录（VPS
>   部署）→ 仓库源码树；`--generate-key` 单文件部署即可运行）：消费
>   PROV-3a staging（dataset 白名单 + 文件名严格匹配 + 路径越界拒收 + staging
>   sha256 复验）→ 快照发布（snapshots/<ts>/ 完整一轮 + `snapshot.txt` 单文件
>   原子指针；manifest 显式登记**本轮通过校验的文件**，generatedAt 取 staging
>   声明的数据产出时间（缺失/非法 fail-closed 拒发 exit 2——新鲜度锚点不可
>   伪造）；manifest.json 对齐 RemoteStagingManifest wire 契约 + 可选
>   manifest.sig Ed25519 签名——签名失败废弃快照不切指针，manifest 与
>   签名永不错配；空 staging / 全部条目非法同理不切；保留最近 5 个快照）。
>   **客户端快照固定读取**：一次 sync 只读一次 snapshot.txt 固定快照 ID，
>   manifest / 签名 / 文件整批从 snapshots/<id>/ 不可变路径读取——中途发布
>   不破坏批次内部一致性（防「旧 manifest + 新签名」误判篡改）。
>   **离线跨语言契约测试已落地**（`RemotePublishContractTests`，12 项）：Python
>   `--selftest` / staging 真实产物 → Swift RemoteStagingProvider 端到端
>   （manifest wire 契约 + 指针 / sha256 完整性 / 增量轮 / 篡改拒收 / Ed25519——
>   Python cryptography 签 → CryptoKit 验，篡改 manifest 拒收整批 / 部分
>   dataset 重发不登记旧文件且 generatedAt 与 staging 逐字节相等 / 签名失败
>   指针不动且线上仍可验签消费 / generatedAt 缺失 fail-closed / staging 路径
>   穿越拒收 / keygen 无 collector 依赖 / 非法日历 generatedAt（2026-02-30、
>   25:61:61）fail-closed）。nginx/Cloudflare 部署
>   指引（托管整个发布根）见 remote-collector/README。
>
> **审查修复记录（2026-08-21，七轮，PROV-3b）**：
> - 第七轮（2×P2 + 2×P3）：独立 signer 方案修正——仅从被监护主机自取
>   staging 重算 manifest **不充分**（hash 一致 ≠ 数据真实性，伪造 JSONL
>   会被照单签名），须从独立可信数据源重采集/核验或基于可信证据人工审批
>   （DATA010 + README）；测试钩子改锁保护计数器（onFetchFile @Sendable
>   闭包改捕获变量在 Swift 6 严格并发下报错，FakeRemoteFetcher 内建
>   fileFetchCount）；DATA010 §5 摘要「可选」改「生产必须启用」；rollout
>   第五/六轮悬空空条目清理（插入时遗留）。
> - 第六轮（1×P1 + 2×P2）：DATA010 §5 **顶部旧摘要条目**同步改为收窄后的
>   保证范围（此前仅改了分档小节，摘要仍写「即使 VPS 被攻陷无私钥」，与
>   整机失陷说明自相矛盾）；**客户端独立时钟未来上界**——服务端校验对
>   「collector 与 publisher 共用 VPS 时钟一起漂移」失效（同机差值≈0），
>   RemoteStagingProvider 在下载任何文件前用本机 now() 复核
>   generatedAt（+10min 容忍度，超限 malformedManifest fail-closed；单测
>   断言 0 文件下载 + spool 无字节，近未来容忍放行）；独立 signer 反
>   **签名 Oracle** 条件写入未来方案（独立授权或验证待签内容，不能对
>   被攻陷数据链主机提交的任意字节签名）。
> - 第五轮（1×P1 + 1×P2）：**signed 保证范围收窄**——私钥（未加密 PEM）
>   与 collector/publisher 同机，完整主机失陷时「攻击者无私钥」不成立
>   （可读私钥或在签名前替换 staging，产出合法签名的伪造数据）；DATA010 §5
>   + README 显式改为「静态目录/nginx/传输链被攻陷且 signer 与私钥可信」，
>   整机失陷不在保证内，覆盖它需签名移独立信任域（当前范围外）。
>   **generatedAt 未来上界**——远未来时间戳会让新鲜度监控永不触发
>   degraded（时钟错误/损坏 staging）；超过 now + 10min 容忍度即 exit 2
>   指针不动（近未来容忍放行），契约测试补远未来用例（11→12 项）。
> - 第四轮（1×P1 + 2×P2）：**威胁模型分档**——「最坏 rollback」结论只适用
>   signed 模式；unsigned（不传 --signing-key / 客户端不配公钥）下攻陷方可
>   同时改数据与 manifest sha256，客户端接受伪造数据。DATA010 §5 + README
>   显式分档（signed = 生产强制；unsigned = 仅测试/受信网络，发布器对
>   unsigned 发布打 stderr 告警）。**generatedAt 严格日历校验**——正则后
>   加 strptime 真实日历 + round-trip 逐字节（2026-02-30 / 25:61:61 拒收
>   exit 2，防 Swift JSONDecoder 滚算致锚点失真）；契约测试改原始字符串
>   比较（不经 Date 归一化）+ 非法日历用例。**快照清理时间宽限期**——
>   纯数量保留会在慢客户端 sync 期间删掉正读的快照（fetchFile 404 +
>   半批追加）；prune 改「最新 5 + 指针 + 宽限期内（默认 24h，mtime，
>   --grace-seconds 可调）」，README 半批语义如实修正（已完成文件不回滚，
>   幂等下轮补缺）。
> - 第一轮（2×P1 + 2×P2）：manifest 改显式登记本轮通过校验的文件（不再扫
>   目录，旧 dataset 不带新 generatedAt 重新上架），generatedAt 取 staging
>   声明的数据产出时间；发布改 snapshots/<ts>/ 快照 + current symlink 原子
>   切换（签名失败废弃快照不切 current，manifest 与签名永不错配）；staging
>   条目三层校验（dataset 白名单 / 文件名严格匹配 / resolve 后不越界）；
>   akshare_collector 延迟导入（--generate-key 单文件部署可用）。契约测试
>   5→9 项。
> - 第二轮（3×P1 + 7×P2）：URLSessionRemoteStagingFetcher 显式
>   reloadIgnoringLocalCacheData（URLCache 启发式缓存会让 manifest 陈旧）；
>   客户端 manifest.version==1 闸门（服务端 bump v2 fail-closed 拒收，
>   不静默按 v1 解读）；Xcode 工程收录 InvestmentIntelligenceV2（project.yml
>   双端 sources + excludes Collector/**，xcodegen 重生成，macOS/iOS scheme
>   构建通过）；remote_publish main 外层异常兜底统一 exit 2（裸 traceback
>   的退出码 1 撞「无 dataset 可发布」语义）+ current 非 symlink 显式报错；
>   keygen O_CREAT|O_EXCL 一步 0600（消除先写后 chmod 的 umask 暴露窗口）；
>   requirements <2.0.0 封顶 + Python>=3.9/flock/日志轮转/硬链接不可原地改
>   staging 的运维说明 + FREE001 受控让步声明进 README；DATA010 → Accepted；
>   ProviderStagingReader.read 复用 decodeLines（逐行容错单一实现）；剩余项
>   显式补 App 生产接线（RemoteStagingProvider 当前零生产调用点，SYNC-2 入口）。
> - 第三轮（2×P1）：**快照固定读取**——current symlink 原子切换只保证单次
>   路径解析，不保证一次 sync 的多次 HTTP 请求同源（旧 manifest + 新签名 →
>   误判篡改 + 断路器）；改为 snapshot.txt 单文件原子指针（tmp+rename）+
>   客户端 fetchCurrentSnapshotID 只读一次、manifest/签名/文件整批从
>   snapshots/<id>/ 不可变路径读取（fetcher 协议改形，FakeRemoteFetcher
>   多快照重构，中途发布回归测试用双密钥判定）；**generatedAt fail-closed**——
>   staging 缺失/非 ISO8601 UTC（含小数秒）时拒发 exit 2（原先 `or now()`
>   会把 schema 漂移的陈旧数据标成刚产出），契约测试补「published ==
>   staging 声明值逐字节相等」断言 + 缺失 fail-closed 用例（9→10 项）。
>   nginx 改托管整个发布根（snapshot.txt + snapshots/），回滚 = 原子改指针。
>
> **审查修复记录（2026-08-20，五轮）**：
> - 第一轮（3×P1 + 4×P2）：非法 Ed25519 公钥 init 抛错不静默降级；state 写失败
>   上抛不虚报 .synced + quota 记账先滚动周期再写入；SEC concept 去重、notFound
>   不计健康统计、Tavily 429 语义分离、sec_cik 统一 10 位补零。
> - 第二轮（2×P1 + 1×P2）：remote staging 改 journal/offset 两阶段提交（checkpoint
>   失败后重试 spool 不重复，不再依赖 Pipeline upsert 兜底）；SEC concept 去重改
>   逐事实粒度（换标签年份的历史不消失）；`ProviderError` 新增 `rateLimited(
>   retryAfter:)`（429 类瞬时限流独立冷却自动恢复，不累计连续失败、不推满 quota），
>   Tavily/SEC 429 映射同步更新。
> - 第三轮（2×P1 + 1×P2）：journal 恢复移到断路器判断之前（退避期内 .skipped
>   仍完成本地恢复）；spool 大小读不出抛错 + 恢复偏移越界拒绝截断（保护已提交
>   数据）；限流调用不进成功率分母（连续 429 冷却过期后自动恢复 healthy，
>   不被 0% 窗口锁死）。
> - 第四轮（2×P1）：state 读取/解码失败不再视为空 state（避免「checkpoint 已
>   成功 + journal 未清 + state 瞬时读不出」时误判未提交而截断已提交 spool 的
>   静默数据丢失）；journal 存在但读取失败时终止本轮（不再静默跳过恢复导致
>   未提交追加被后续轮次重复下载）。两者均「只有明确的 no-such-file 才算不存在」。
> - 第五轮（2×P1）：去掉三处 fileExists 前置（它无法区分「不存在」与「权限/
>   IO 查不了」，会绕开 fail-closed），改为直接读取、仅 no-such-file 错误码当
>   「无」；journal 负偏移拒绝（可解码的负值经 max(0,·) clamp 会清空整个
>   spool，缺失 spool 时也不得当 offset==0 恢复成功）。
>
> **未达成（M3 blocked 原因；2026-08-21 更新）**：仅剩 PROV-3b 真实 VPS 部署 +
> 端到端。PROV-3a 真实联调已完成（akshare 1.18.92 本机 venv，fund_nav 3869 条 /
> fund_holdings 4 条真实数据；stock/index 行情端点上游拒连、macro 上游接口漂移，
> 分类与隔离行为符合设计——详见 PROV-3a 签收段）。
>
> **状态（2026-08-14，历史）**：M3 进行中（18/28 点，PROV-1/2/3a/5/6 签收）。
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
> - PROV-6（2）—— Alpha Vantage 美股日线 supplemental Adapter：`AlphaVantageResponseParser`
>   （TIME_SERIES_DAILY JSON，OHLCV 全字段——现有 AlphaVantageResearchTool 只用 close+volume
>   丢了 OHLC、本 parser 补全；非有限数防护、缺 volume→nil、dropped 计数）+
>   `AlphaVantageProviderAdapter`（**复用 `Core/Clients/AlphaVantageClient`** 取 raw Data，
>   URL/鉴权/上游信号检测不重复，只新写 OHLC 解析 + ProviderRecord 转换。documentFreeAPI、
>   USD、unitedStates、adjustmentFactor=1.0 raw 不复权）。quota 感知：`AlphaVantageClientError`
>   映射 `ProviderError`——dailyBudgetExceeded / serviceMessage（Information/Note rate limit）→
>   `quotaExhausted`（**降级不阻塞**，核心验收）；Error Message → schemaMismatch。
>   端到端验证 JSON→ProviderRecord→SchemaValidator→staging round-trip。
> - PROV-3a（8）—— AKShare 本地 Collector（DATA007 进程外隔离，进阶可选）：
>   `InvestmentIntelligenceV2/Collector/akshare_collector.py`（独立 Python 进程，
>   SPM exclude 不进 App/iOS target；5 个 dataset——个股/指数日线、基金净值、
>   基金季度持仓、中国宏观，每 dataset 独立 JSONL + manifest.json（status/recordCount/
>   droppedMalformed/errorCategory/errorMessage/sha256），异常分类 environment/network/
>   not_found/schema/internal，单 dataset 失败隔离 exit 1，环境错误 exit 2，行数上限
>   防失控回填）+ Swift 侧 `AKShareLocalCollector.swift`（manifest 模型 + 失败隔离的
>   staging 摄取（sha256 校验 + SchemaValidator 分桶 + append 到 App spool，不写
>   Canonical）+ 仅 macOS `#if os(macOS)` launcher（python 候选链、watchdog 超时杀进程））。
>   **跨语言 schema 字节对齐**：camelCase / ISO8601 UTC（无小数秒）/ enum rawValue /
>   rawPayload base64 / Decimal 定点输出；A 股日期归一化上海日界 UTC 瞬时（与
>   EastmoneyResponseParser.normalizeToTradingDay 一致）。契约测试
>   （`--selftest` 离线输出 → Reader → SchemaValidator → ObservationFactory 全链路）
>   9 项 + 摄取/launcher 错误路径单测 15 项全绿。
>
>   **✅ 真实联调完成（2026-08-21，ASH-12 解除）**：本机 venv 安装 akshare
>   1.18.92（Python 3.11；PyPI 直连超时需走国内镜像，`pip install -i
>   pypi.tuna.tsinghua.edu.cn/simple`），`--selftest` 6 dataset 全绿 + 真实抓取
>   一轮（默认标的、2026-01-01..08-21 窗口）：
>   - **fund_nav ok 3869 条**（110022 全史净值，wire 格式与契约逐字段吻合：
>     camelCase/ISO8601 UTC/base64 payload/enum rawValue/沪日界归一化）；
>   - **fund_holdings ok 4 条**（2024 四季度快照；72 个权重空/0 的 position 被
>     数据质量闸门丢弃并计数——既有签名语义）；
>   - **stock_daily / index_daily 持续 `network` ConnectionError**：东财行情
>     端点（push2 quote 系）对本机选择性拒连（同站 fund 端点正常），直接调
>     `ak.stock_zh_a_hist` 复现——上游反爬非 collector 缺陷；分类/隔离/manifest
>     行为全部符合设计（单 dataset 失败不影响他者，exit 1，manifest 仍落盘）；
>   - **macro_china `schema` KeyError 'data'**：金十数据中心 datacenter.jin10.com
>     已改吐 HTML 壳，akshare 1.18.92 的 `macro_china_gdp_yearly` 解析失效（上游
>     接口漂移；直接 probe 复现）。中国宏观该 dataset 需换源（东财宏观系 akshare
>     函数或后续 ADR），另行立 story 处理。
>   联调结论：collector 机制（分类/隔离/manifest/跨语言格式）经真实数据验证；
>   两个 dataset 的上游限制如实记录，不阻塞 PROV-3a 签收语义（失败分类正是
>   DATA006/DATA007 要求的行为）。
>
> **未达成（M3 blocked 原因，2026-08-21 更新）**：仅剩 **PROV-3b 真实 VPS 部署 +
> HTTP 端到端连通**（App 生产接线与跨语言契约测试已就绪，见 PROV-3b 段）。
> PROV-3a 真实联调已完成（见上）；其余 Adapter（PROV-2/4/5/6/7/8）已签收。

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

> **状态（2026-08-21）**：M2 已 Pass（见 Epic 3 状态块），Epic 5 解锁。
> **GRDB-1 已签收（3 点）**——`macos-app/Package.swift` 引入 GRDB ≥ 6.29
>（`Package.resolved` 锁 6.29.3）+ `InvestmentIntelligenceV2/Persistence/CanonicalDatabase.swift`
>（DB lifecycle：打开/创建/迁移幂等/内存库；`schemaVersion` 常量与迁移清单
> 数量一致性有测试守护；迁移**只追加不改写**——已发布 id 改名 = 老库全量
> 重跑，测试冻结 v1_baseline 首位）。7 个测试（CanonicalDatabaseTests）。
>
> **GRDB-1 审查修复（2026-08-24，2×P2）**：
> - 迁移失败语义**删除虚假擦库承诺**：原注释声称「失败库下次打开从零重建」
>   但实现只是把 `eraseDatabaseOnSchemaChange` 显式置 false（默认值，且与
>   迁移失败无关）。改为如实记录 GRDB 事务语义——每 migration 独立事务原子
>   回滚、下次打开按名重试失败项；spool 重放重建是运维路径不自动执行
>   （瞬时 IO 故障不应升级为整库擦除）。
> - 构建脚本**产物名与版本参数契约**：SPM 产物名固定为 target 名
>   QiemanDashboard，拷贝从固定名取再重命名为可覆盖的 APP_NAME（原按
>   `$APP_NAME` 找源文件，设置即 cp 失败——APP_NAME 覆盖端到端验证通过）；
>   MIN_MACOS_VERSION 从可覆盖环境变量改为固定常量 14.0（主程序实际按
>   Package.swift 编译，可覆盖的声明门槛是谎言），注释指向单一事实源。
>
> **GRDB-1 二轮审查修复（2026-08-24，2×P2）**：
> - **迁移状态语义重写**：原手写 `allSatisfy`/count 比较有双重错误——init 已
>   自动迁移所以升级后调用恒 false；降级库（含当前代码不认识的 migration）
>   反被误报「待执行」。改用 GRDB 原生 `hasCompletedMigrations` /
>   `hasBeenSuperseded` 区分三态（`CanonicalMigrationState`：current /
>   pending(count) / superseded(unknown)），`migrationState(of:)` 可对裸库
>   调用（自动迁移前窗口的真实状态）。
> - **降级保护落地**（迁移前预检）：文件库打开时发现 superseded 直接抛
>   `CanonicalDatabaseError.supersededByNewerSchema` 拒绝打开——老代码继续
>   迁移/读写会把新库置于未知状态；恢复路径 = 升级 App 或删库走 spool 重放。
> - **内存库 init 去掉 Bool 参数**：`init(inMemory:)` 的参数被静默忽略
>   （true/false 都建内存库），误传 false 会静默得到易失库；改为无参
>   `init()`（文件库走 `init(path:)`，意图不可混）。+3 测试
>   （裸库 pending / superseded 拒开 / 未知项清单），共 10 个。
>
> **GRDB-2 已签收（5 点，2026-08-24）**——migration `v2_identity` +
> `Persistence/IdentitySchema.swift`（7 表 DDL + row codec）+
> `Persistence/CanonicalColumnCodec.swift`（跨表列编解码约定）：
> - **7 表**：legal_entities / instruments / listings / fund_products /
>   fund_share_classes / provider_identifiers / instrument_relationships，
>   主键全为 Canonical ID（TEXT）。schemaVersion → 2；迁移只追加
>   （v1_baseline 首位不变，升级路径测试守护 v1-only 旧库自动补 v2）。
> - **schema 层防火墙**：外键（instruments.issuer → legal_entities、
>   listings/fund_products/fund_share_classes → instruments 等，GRDB 默认启用
>   FK，悬空引用拒收）；provider_identifiers 复合主键
>   (provider_id, scheme, value) = 「一个 Provider 代码至多一条映射」的
>   库级保证（IdentityResolver lookup 语义）；active 挂牌 (exchange, symbol)
>   **部分唯一索引**（退市 Listing 保留、同码重挂是新行不冲突）；
>   fund_share_classes UNIQUE (product_id, share_class_code)。
> - **列编解码约定（CanonicalColumnCodec，GRDB-3..6 复用）**：时间戳
>   ISO8601 UTC 毫秒（字典序 = 时间序，PIT 比较可直接在 SQL 做）；Decimal
>   走 TEXT（NSDecimalNumber description，不走 Double）；JSON 子文档
>   （regulatoryIDs / feeStructure）TEXT + sortedKeys 确定性编码。
> - **fail-closed 解码**：枚举列未知 rawValue 拒收（不 `?? 默认值` 静默
>   换壳——Identity 是一切计算的锚点）；关系行端点类型按
>   relationship_type 契约校验（TRACKS_INDEX 两端必须 instrument、
>   SHARE_CLASS_OF 是 fundShareClass→fundProduct 等），错配行拒收；
>   时间戳非法格式拒收。
> - 15 个测试（IdentitySchemaTests）：迁移追加语义 / 升级路径 / 全表列
>   清单 / 完整 identity 图 domain↔row 往返 / 毫秒精度 / FK·复合主键·
>   部分唯一·产品+份额唯一约束 / 未知枚举·端点错配·非法时间戳 fail-closed /
>   三元组查询命中与 miss。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **GRDB-3 已签收（3 点，2026-08-24）**——migration `v3_market` +
> `Persistence/MarketSchema.swift`（3 表 DDL + row codec）+
> `Persistence/ObservationColumns.swift`（观测表共享列组，GRDB-4/5 复用）：
> - **3 表**：daily_bars / nav_observations / corporate_actions，维度键外键到
>   Identity（listing_id → listings、share_class_id → fund_share_classes）——
>   观测只能挂在已解析的 Canonical Identity 上（防火墙 1 库级兜底）。
> - **DATA008 合规**：三表统一 (维度键, effective_at, vintage) 唯一索引
>   （vintage = announcement_date + publisher_version 两列）；行情单 vintage
>   简化体现在查询形态，schema 仍完整支持 multi-vintage（同 effectiveAt
>   不同 vintage 共存测试守护）。
> - **PIT 字符串比较约定落地**：四时间为 ISO8601 UTC 毫秒 TEXT，字典序 =
>   时间序（跨 ±400 天抽样测试），`available_at <= ?` 直接 SQL 比较——
>   GRDB-7 Repository 的 economic/operational 查询依赖此路径（测试用
>   两根不同 availableAt 的 bar 验证 asOf 过滤语义）。
> - **共享列组**（ObservationEnvelopeColumns）：四时间 + policy 溯源 3 列 +
>   质量 4 列 + vintage 2 列，列名/编解码单一权威；enum 列 fail-closed
>   解码（decodeEnum 移至 CanonicalColumnCodec 共享，IdentitySchemaError
>   收窄回 identity 专属错误）。
> - **价格列**：同观测多 Price 币种必须一致（单 currency 列 + codec 校验，
>   混币拒收）；NAV 的累计净值/累计分红缺失保持 nil 不伪造。
> - 14 个 MarketSchemaTests（迁移追加 / 共享列 / 三表往返含 nil 边界 /
>   唯一索引拒重 / multi-vintage 共存 / FK / PIT 字符串比较 / 字典序=时间序 /
>   混币拒收 / 未知枚举 fail-closed）。
>
> **GRDB-4 已签收（3 点，2026-08-24）**——migration `v4_fund` +
> `Persistence/FundSchema.swift`（3 表 DDL + row codec）+ **新领域类型
> `AllocationSnapshot`**（`Observations/CanonicalObservation.swift`，基金
> 报告期资产大类占比快照——此前 DOM-5 未定义，GRDB-4 随 schema 一并落地；
> Exposure 的 asset class 通道消费它）：
> - **3 表**：holding_snapshots（快照骨架）/ holding_positions（一行一持仓，
>   (snapshot_id, position_index) 主键保序）/ allocation_snapshots（大类占比
>   JSON 列——条目小且整读，与持仓子表形态刻意不同：后者需要跨基金按
>   listing 聚合，前者无此查询路径）。
> - **持仓多 vintage**（DATA008）：(product_id, effective_at, vintage) 唯一
>   索引，修订 = 追加行不覆盖（测试守护）。
> - **外键链**：snapshot → fund_products、position → snapshot + listings
>   （REPO-5b「未解析 position 拒收整条快照」的库级兜底）；listing_id 索引
>   服务 RISK-1 多基金重复持股聚合。
> - **往返保序**：positions 乱序插入读回仍按 position_index = 披露顺序；
>   可选 Price 双列（market_value + currency）同空同非空，不配套 fail-closed。
> - 11 个 FundSchemaTests。
>
> **GRDB-5 已签收（2 点，2026-08-24）**——migration `v5_fundamental_macro` +
> `Persistence/FundamentalMacroSchema.swift`（2 表 DDL + row codec）：
> - **2 表**：fundamental_observations（entity_id → legal_entities，SEC CIK
>   的 Canonical 目标）/ macro_observations（indicator_id → instruments）。
> - **事实身份唯一键**（REPO-1b 分组语义）：(entity, metricKey, unit,
>   periodStart, periodEnd, vintage)。**concept 不进键**——公司换 XBRL 标签
>   年份的同事实两段历史靠 metricKey 归并（PROV-4 逐事实概念选择）。
> - **NULL 陷阱封口**：period_start 可空（时点项），SQLite 唯一索引视 NULL
>   互不相等——两条同键 NULL 行不撞约束；用 `COALESCE(period_start,'')`
>   表达式索引封死（专项测试守护）。
> - **FRED vintage 对齐**：macro (indicator, effectiveAt, vintage) 唯一，
>   advance/second 修订行共存；base_period JSON 列（非指数指标 nil）。
> - 11 个 FundamentalMacroSchemaTests（流量/时点事实往返、宏观 basePeriod
>   两态、唯一键含 NULL 封口、修订+换标签共存、Q2/H1 同 periodEnd 不互斥、
>   FK、未知 form/unit fail-closed）。
>
> **GRDB-9 已签收（2 点，2026-08-24，Epic 5 收尾之一）**——约定与代码一致：
> - **数据目录规划落地**：`Persistence/CanonicalStorePaths.swift`——库文件
>   `<AppData>/investment-intelligence-v2/canonical.sqlite3`，与 remote-staging
>   spool 同住 V2 工作目录（spool 是事实源、库是派生物，删库重放走 spool，
>   ADR-DATA004）；`openDatabase(in:)` 幂等建目录 + 迁移的单一入口（补上
>   CanonicalDatabase.init 刻意不代建目录的「App 侧统一负责」层）。
> - **iOS framework 链接验证**：xcodegen 重生成（收录 GRDB-2..6 新文件），
>   macOS + iOS 双端 xcodebuild Debug 构建通过；iOS 产物 GRDB 静态链入
>   （debug dylib 链系统 libsqlite3）+ GRDB_GRDB.bundle 资源在 bundle 内。
> - **AGENTS.md 第 6 条最终化**：原「无 SQLite」约定废止改写为完整现状
>   （六版 schema 清单 / 各域 schema 文件位置 / 列编解码约定 / 迁移只追加 /
>   CanonicalStorePaths / GRDB 限 V2 范围）。
> - 3 个 CanonicalStorePathsTests（落点约定 + 与 spool 共存 / openDatabase
>   建目录幂等 + 重开迁移不重跑）。
>
> **GRDB-7 已签收（8 点，2026-08-24）**——`Repositories/GRDBRepository.swift`
> （八域 Repository 协议的 GRDB 实现）+ **前置 migration `v7_provider_unique`**
>（`Persistence/ProviderUniqueMigration.swift`）+ **查询语义单一权威抽取**
>（`Repositories/ObservationQuerySemantics.swift`）：
> - **v7 修正唯一索引漏 provider 维度**：GRDB-3/4/5 的
>   (维度, effectiveAt, vintage) 唯一索引与 REPO-2b「跨 Provider 各存一行、
>   查询择优」冲突（第二家 Provider 的行会被拒收，跨源去重退化为丢弃）。
>   v7 把唯一键改为 (维度, effectiveAt, vintage, **source_provider_id**)：
>   同 Provider 幂等拒重、跨 Provider 共存。v3/v4 的内联 UNIQUE 走标准表重建
>   （`PRAGMA defer_foreign_keys` + rename 改写 holding_positions 的 FK），
>   v5 显式索引直接换。**v6 存量库升级数据存活有专项测试**（行情 + 持仓 +
>   positions 子表）。
> - **行为等价的结构保证（M4「golden test 同样过」的落地）**：
>   `ObservationQuerySemantics`——filterByContext / isPreferred /
>   reliabilityPreferenceRank / providerSortKey / contextIncludes 从
>   InMemoryRepository 抽出为两套实现共用的纯函数单一权威（InMemory 保留
>   同名 static 薄转发）。GRDBRepository 的 SQL 只做维度键取行，PIT 语义
>   全部走共享函数。`GRDBRepositoryParityTests`：同一 fixture 灌两套实现，
>   全部查询 API（含单点 dailyBar/navObservation/latestHolding）在 10 种
>   context（economic×4 时点 / operational×2 / exact×2 / vintageFilter×2）
>   下输出逐一相等；fuzzy resolve 双双拒收。
> - **exactSnapshot 确定性补强**（共享语义层，两套实现同时受益）：等值
>   vintage 的排序 tie-break 补 effectiveAt→id（GRDB 侧 SQL 索引扫描顺序与
>   内存侧插入顺序不同，排序键必须与输入顺序无关；InMemory 时代测试只断言
>   count / vintage 序，无顺序断言被破坏——全量绿佐证）。
> - **单点查询逐字对齐**：dailyBar/navObservation 不走 filterByContext
>   （黄金行为 = 同日 + 可见性过滤取 vintage 最大，不经分组/vintageFilter——
>   parity 测试抓出的真实分歧点，以 InMemory 为准修复）。
> - **写入语义**（一轮审查后改写，见下方审查修复记录）：按
>   (维度, effectiveAt, vintage, provider) 身份键显式冲突处理——同身份同
>   业务内容幂等（保留最早 ingestedAt）、同身份不同内容拒收
>   `observationContentConflict`（逐条不阻塞批次）、持仓快照骨架 + positions
>   全组参与内容比对；写入方法保留 throws（FK 违例 = identity 未登记，
>   管道要暴露）。
> - **读取错误策略**（协议非 throwing）：失败 → 该查询返回空（缺口语义，
>   DATA006）+ `lastQueryError` 线程安全诊断面（NSLock，与 InMemory 同款
>   约定），不静默不伪造。
> - GRDBRepositoryParityTests（身份 / 全 context 矩阵 / resolve 与关系 /
>   多 Provider 共存 / v6→v7 升级数据存活 / 冲突与幂等写入 / 单点语义与
>   preferredProvider 契约；项数随审查修复追加，以套件通过为准）。
>
> **GRDB-8 已签收（5 点，2026-08-24）**——`Persistence/CanonicalPipeline.swift`
> （Staging → Canonical Commit 四防火墙管道）+
> `Persistence/CanonicalDataValidator.swift`（语义闸门）+ GRDBRepository 的
> 单事务 `commit(_:)` 批量入口：
> - **管道**：ProviderRecord[] → ① ProviderRecordSchemaValidator（结构）→
>   ② ObservationFactory（identity 解析防火墙 + TemporalNormalizer PIT 标注）
>   → ③ CanonicalDataValidator（四时间不变量 / OHLC 拓扑 low≤body≤high /
>   价格·复权因子·NAV 正性 / 持仓权重 [0,1] 与披露总权界 / 公司行动比例 /
>   基本面期间序）→ ④ GRDBRepository.commit 单事务提交（FK 违例整批回滚，
>   库级兜底）。**拒收粒度 = 单条**：坏记录逐条报告（stage + 原因）不阻塞
>   批内合法子集（DATA006 拒收不阻塞的管道侧语义）；提交事务失败则整批
>   回滚（commitError 上报，不留半批）。
> - **确定性派生（ADR-DATA004 重放幂等）**：ObservationID =
>   SHA256(provider|scheme|value|kind|effective|published) 截断 16 字节——
>   同一条 ProviderRecord 任何时刻重放生成同 ID，Repository 的显式冲突
>   语义按业务身份幂等归并（重放测试守护行数不翻倍）；Vintage =
>   (publishedAt, 1)——Provider 更正重公布 = 新 publishedAt = 新 vintage 行，
>   旧 vintage 保留（DATA008）；publisherVersion > 1 保留给同公告日多次修订
>  （ProviderRecord 无法表达）。
> - **晚发布语义（一轮审查后闭环）**：初版记录过「MarketClose 晚于可知窗口
>   的重公布被 temporalNormalizeFailed 拒收」的边界；审查确认这是 DATA008
>   行情修订能力的缺口而非 policy 设计意图，已在审查修复中闭环——
>   TemporalNormalizer 现按 availableAt = max(policy 保守下界, publishedAt)
>   （DATA005「客观可知」：早于下界公布仍按下界不乐观，晚于下界公布上抬到
>   publishedAt；对满足下界的既有数据零影响）。
> - **spool 直连**：`commitRecords(fromSpool:)`（PROV-1 Reader → pipeline，
>   SYNC-2..5 循环的每轮入口；文件级读取失败上抛，非记录级拒收）。
> - CanonicalPipelineTests（端到端提交可查 / 幂等重放 / 更正产生新 vintage
>   且 economic 取修订 / 四防火墙各有专项拒收测试含 FK 整批回滚 / alias
>   幂等归并 / 冲突拒收溯源 / spool 直连；项数随审查修复追加，以套件通过为准）。
>
> **✅ M4 达成（2026-08-24）**：GRDBRepository 经 `GRDBRepositoryParityTests`
> 与 InMemoryRepository 在全部查询 API × 10 种 context 下输出逐一相等
>（「InMemory 时代的 golden test 同样过」的结构化落地）；四防火墙全部在
> CanonicalPipeline 的 commit 路径上（含 FK 库级兜底）。**Epic 5 全部
> story（GRDB-1..9，30 点）签收完毕**，Epic 6（Sync / Backfill）解锁。
>
> **Epic 5 一轮审查修复（2026-08-24，3×P1 + 2×P2 + 1 遗留闭环）**：
> - **P1 重摄入篡改历史 ingestedAt**：INSERT OR REPLACE 整行覆盖会使
>   operationalKnowledge 的历史可见边界漂移。观测写入改为显式冲突语义
>   （按 v7 身份键查既有行）：同身份同内容 → 保留**最早** ingestedAt
>  （更早补录前移、更晚重摄入不动）；同身份不同内容 → 拒收
>   `observationContentConflict`（Pipeline 逐条 contentConflict 拒收不阻塞
>   批次，更正走新 publishedAt = 新 vintage）。内容指纹排除摄入元数据
>  （ingested_at / policy_derived_at——后者每次重放必变，纳入会让幂等
>   重放永远判冲突，修复中实测发现）。
> - **P1 preferredProvider 未生效**：isPreferred 择优链补第二层
>   「同 vintage 时 context.preferredProvider 命中者优先」（位于 vintage
>   之后、reliability 之前——修订仍优先于来源偏好）；filterByContext 传入
>   context.preferredProvider。契约测试：无偏好 reliability 胜 / 有偏好覆盖
>   reliability / 单点查询同语义 / InMemory 与 GRDB 双实现一致。
> - **P1 单点查询绕过 context 语义**：dailyBar / navObservation 此前只按
>   mode 过滤 + 最大 vintage（vintageFilter / preferredProvider / 跨源
>   tie-break 全部旁路；parity 测试未发现因 InMemory 共享同一缺陷实现）。
>   新增共享 `selectPointObservation`（vintageFilter 精确 / exact 取最新
>   vintage / economic 走完整分组择优），**双实现同步修复**（InMemory 的
>   缺陷一并纠正）；全部维度查询补 ORDER BY（确定性卫生）。
> - **P2 Provider 映射悬空目标**：upsert(ProviderIdentifier) 在同一事务内
>   验证 polymorphic canonical 目标实体存在（悬空 → 拒收，不再等到观测
>   commit 时 FK 回滚整批合法子集）；commit 级 FK 仍是兜底（原生 SQL 注入
>   悬空映射的模拟测试保留）。
> - **P2 持仓权重合计缺口**：CanonicalDataValidator 补两条合计约束——全部
>   position 权重合计 ≤ 1（千分位容差；0.6+0.6 此前可穿过防火墙）、已披露
>   明细合计与 disclosedWeightTotal 一致（互相印证）。
> - **遗留闭环（MarketClose 晚发布修订）**：见上方「晚发布语义」修订段。
> - 审查结论「暂不标记 Epic 5 完全收口」据此撤销：上述全部修复落地，
>   swift test 全量绿（排除环境性 AppLaunchPresentationPolicyTests）。
>
> **Epic 5 二轮审查修复（2026-08-24，1×P1 + 2×P2 + 注释同步）**：
> - **P1 内容指纹误含代理键**：指纹原含 `id`（持仓子行还含 `snapshot_id`）
>   ——同一事实经同 Provider 的另一个精确 identifier alias 摄入会派生不同
>   ObservationID，业务身份与内容相同却被误判内容冲突。指纹改为只含业务
>   内容列（排除摄入元数据 + 代理键 id / snapshot_id）；补**不同
>   ObservationID 的幂等归并测试**（repository 级 + Pipeline 级 alias 场景，
>   行数不翻倍、首行保留）。
> - **P2 单点 vintageFilter / exactSnapshot 分支漏 preferredProvider**：
>   `selectPointObservation` 的这两个分支原按确定性排序取末位，同 vintage
>   多来源时显式偏好失效。改为先确定目标 vintage，再在同 vintage 候选内走
>   `isPreferred` 全序（含来源偏好）；序列型 exactSnapshot 保留全部来源
>   不变。补 vintageFilter / exact 两分支 × 有无偏好的契约测试（双实现）。
> - **P2 内容冲突拒收丢失原始记录身份**：Pipeline 现保留
>   ObservationID → ProviderRecord 映射，contentConflict 拒收携带真实的
>   provider/scheme/value/kind（可诊断、可按记录重试），ObservationID 移入
>   reason；测试断言四字段。
> - **注释与文档同步**：GRDBRepository 文件头、CanonicalPipeline 文件头、
>   rollout GRDB-7/GRDB-8 签收段的「INSERT OR REPLACE」表述全部改写为
>   显式冲突语义。
>
> **✅ Epic 5 三轮复审通过（2026-08-24，`93c2c69`）**：三个代码边界收口
> 确认、无新 P0–P2 问题，**Epic 5 标记为完全完成**（含两轮审查修复 +
> 一轮复审通过；全量回归与目标套件通过，跳过环境性
> AppLaunchPresentationPolicyTests）。P3 文档数字偏差同步清理：测试项数
> 表述改为「以套件通过为准」防漂移。
>
> **GRDB-6 已签收（5 点，2026-08-24）**——migration `v6_intelligence` +
> `Persistence/IntelligenceSchema.swift`（10 表 DDL + row codec）：
> - **10 表**：evidence / evidence_facts / signals / theses / artifacts /
>   artifact_dependencies / decisions / agent_jobs / agent_job_events /
>   agent_checkpoints。
> - **两类表**：有领域类型的（evidence=EvidenceObservation、evidence_facts=
>   EvidenceFact、signals=InvestmentSignal、artifacts+artifact_dependencies=
>   Artifact 协议，当前以 PlaceholderArtifact 为 codec 载体，Epic 7-10 各
>   具体 Artifact 补 codec）；通用形状的（theses / decisions / agent_jobs /
>   events / checkpoints——领域类型在 WF-1/DEC-9/AGENT-1 落地时补 toDomain，
>   schema 列不改只追加 migration）。
> - **EvidenceID 是 UNIQUE 逻辑身份**：evidence 同时存 ObservationID（行
>   主键）与 EvidenceID；下游引用（evidence_facts FK / signals 的
>   derivedFrom JSON）一律 EvidenceID——DailyBar 的 ObservationID 无法冒充。
>   signals.derivedFrom 不建跨表 FK（JSON 数组做不到行级 FK），完整性由
>   RES-5 Validation + RES-8 Evidence Matcher 保证（M8 验收项）。
> - **artifact_dependencies 规范化**（不进 JSON）：(kind, reference_id)
>   索引服务失效传播查询「dependency 变化 → 受影响 artifacts」
>   （untilDependencyChanges 策略的存储基础），(artifact_id, dep_index)
>   主键保序。
> - **AgentJobStatus** 定义（ATTR-4 生命周期五态，schema 层 fail-closed 解码）；
>   agent_jobs.idempotency_key UNIQUE 可空（AGENT-1 幂等语义库级兜底，NULL
>   手工运行共存）；events/checkpoints (job_id, seq) 主键（事件流保序 + 断点
>   续跑）。
> - 15 个 IntelligenceSchemaTests（10 表存在 / evidence 双 ID 唯一 / facts
>   数值两态 + FK / signal 溯源往返 + 未知方向 fail-closed / artifact 依赖
>   规范化往返 + 失效传播查询 + 约束 / job 幂等键唯一与 NULL 共存 / 事件流
>   保序 + 同 seq 拒收 / status fail-closed / theses·decisions 原始读写）。
>
> **构建链同步迁移（GRDB-1 的隐藏工作量）**：`scripts/build_macos_app.sh` 从
> 裸 swiftc 改为 `swift build -c release --arch` + 拷贝产物（源排除/最低系统
> 版本以 Package.swift 为单一事实源；debug 档保留加速路径；debug 端到端跑通
> 出 .app + ad-hoc 签名 + zip 验证；release 档本机编译通过）；`project.yml`
> 声明 GRDB.swift package（product 名 GRDB）三 target 依赖，xcodegen 重生成，
> macOS/iOS 双端 xcodebuild 通过。**GRDB `SQL` 类型污染**：同模块内无标注
> 字符串闭包链会被 SQL 的 ExpressibleByStringInterpolation + Sequence 扩展
> 劫持推断（TrendLiveLogPanel.copyLogs 显式 `: String` 修复，AGENTS.md 坑点 17）。
> **AGENTS.md 第 6 条已随 Epic 5 开始更新**（原「无 SQLite」约定废止，
> GRDB 限 V2 Canonical Store 范围内使用；GRDB-9 剩余：iOS framework 链接细节
> 与数据目录规划的最终验收）。swift test 全量绿（排除环境性崩溃的
> AppLaunchPresentationPolicyTests，见下）。
> **已知环境问题（与 Epic 5 无关）**：`AppLaunchPresentationPolicyTests` 在
> 本机确定性 signal 11（干净 HEAD 复现），全量跑需 `--skip`；待单独排查。

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

> **状态（2026-08-24，Epic 6 全部收口）**：**SYNC-1..8（含 6a/6b，26 点）全部签收**，
> M5 验收能力全部落地（引擎层离线验证；生产数据积累随 App 接线[Epic 9/B.3]
> 与真实 Provider 持续运行达成——见 §4.3 逐项对应：SYNC-6a 覆盖率验收 /
> SYNC-6b 分批增量补全 / SYNC-7 local 兜底降级 / SYNC-1 节假日日历 /
> SYNC-8 新标的进 Instrument Master）。universe 内容策展归 WF-2。
> **SYNC-1 已签收（3 点）**——
> `Sync/TradingCalendars.swift`（真实交易日历 + 基金净值公布日历）：
> - **交易日 = 当地日历周一~周五 减 交易所休市表**。两个结构性事实由算法保证
>   不进数据表：周末从不开市（含国务院「调休上班」的周末——交易所不跟随
>   调休开市，2025-01-26/2026-02-14 等有测试）；表只登记周内休市日，周末
>   条目 init 即拒收（fail-closed，数据源给出周末休市日 = 抓取/转录有错）。
> - **版本化 `MarketHolidayTable`**（jurisdiction/year/version/closedDates/
>   provenance 可审计；同法域同年双表构造失败不静默择一；日期串严格校验
>   ——格式 round-trip、年份匹配、真实日历日，非法抛
>   `MarketHolidayTableError`）。新一年安排由交易所年末公告后**追加**新表，
>   已发布表不改写。种子数据 2024–2026 三年 SSE + NYSE 全量休市日
>   （上交所三份官方通知 + NYSE 节假日惯例，2026-07-04 周六→07-03 周五补休），
>   测试用**全集相等**冻结（任何转录漂移即红）。
> - **`HolidayTableTradingCalendar`**：同时实现 `TradingCalendar`（DOM-7 协议，
>   AvailabilityPolicy/TemporalNormalizer/InMemoryRepository/GRDBRepository
>   既有依赖面直接换真日历）与 `CalendarRepository`（八域 Calendar 域）。
>   时区按法域（CN=Asia/Shanghai、US=America/New_York、HK 无种子表退化
>   仅周末且覆盖 API 如实报告空）。`tradingDay(after:)` 返回归一化当地日界
>   （与 policy 二次 tradingDayStart 幂等）。
> - **覆盖缺口显式化**：表外年份退化为仅周末判断（sync 不崩），
>   `verifiedCoverageYears` / `hasVerifiedHolidayCoverage` 把「无权威休市表
>   背书」暴露给调用方。
> - **导航辅助**（SYNC-2..6 窗口计算用）：latestTradingDayOnOrBefore /
>   previousTradingDay / nextTradingDay / tradingDays(endingAt:count:)，
>   跨春节缺口（2026-02-13→02-24）语义有测试。
> - **`FundNAVPublicationCalendar`**（基金净值公布日历）：语义锚点 =
>   `AvailabilityPolicyV1.FundNAV`（T 日净值 availableAt=startOfDay(next(T))），
>   `latestGuaranteedPublishedNAVDate(asOf:)` = asOf 所在（或之前最近）交易日的
>   前一个交易日——交易日晚间/休市日/周末三态有测试；
>   `navEffectiveDates(from:through:)` 跳过休市与周末（backfill 窗口）。
>   QDII T+2 不建模：保守 +1 只影响「这轮抓不到下轮补」，不伪造数据。
> - **与 policy 的集成验证**：FundNAV policy + 真日历 → 2026-02-13（节前最后
>   交易日）的 availableAt = 02-24（无休市表会错算成 02-16）；MarketClose
>   policy 美股跨耶稣受难日 04-17→04-21。测试（TradingCalendarTests，
>   以套件通过为准）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **SYNC-3 已签收（2 点，2026-08-24）**——`Sync/FundNAVSync.swift` +
> `Sync/SyncKit.swift`（SYNC-2..5 共享的直接抓取基础设施）：
> - **SyncKit**：`DirectSyncPaths`（spool/state 目录布局，与 canonical.sqlite3
>   同住 V2 工作目录——spool 事实源、库派生物，ADR-DATA004）+
>   `SyncStateStore<State>`（游标状态 JSON 原子持久化：ISO8601 毫秒、
>   tmp + replaceItemAt 安全替换、读取 fail-closed——只有明确的文件不存在
>   才算首轮，坏状态抛 `SyncStateError` 不静默当空重抓）。
> - **FundNAVSync 引擎**（fund 粒度隔离，单只失败不影响他者）：
>   锚点 = `FundNAVPublicationCalendar.latestGuaranteedPublishedNAVDate`
>   （T+1 保守语义）→ 游标 ≥ 锚点直接跳过；增量窗口 [游标+1 天, 锚点]
>   （首轮回看 400 日历天，深度回填走 SYNC-6a）；fetch → SchemaValidator
>   分桶（非法不落 spool）→ **先 append spool 再 commit**（库可删重放）→
>   CanonicalPipeline 四防火墙。
> - **游标保守推进规则**：干净轮（无拒收、commit 成功）→ 推进到本轮最大
>   effectiveAt；无新数据（QDII T+2 滞后）/ 有拒收 / commit 失败 → 一律
>   不推进。重试靠确定性 ObservationID 幂等去重（不翻倍，有测试），不跳过
>   被拒收的日期（静默数据洞比重复抓取更贵）。
> - **ProviderHealth 集成**（PROV-8）：isCallable == false 跳过抓取（零网络）；
>   成功/失败按 ProviderError 语义上报；结构分桶拒收记 schema 漂移。
> - App 接线遵守 B.3 时点（Epic 9 集成时参照 RemoteStagingSyncLoop 模式）。
>   12 个测试（FundNAVSyncTests）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **SYNC-4 已签收（2 点，2026-08-24）**——`Sync/FundHoldingSync.swift`
> （持仓披露检测 + 新 snapshot 自动入库，报告期驱动）：
> - **`FundReportPeriod`**（year+quarter，Comparable + "2026Q2" wire 形态，
>   非法解码 fail-closed）+ **`FundDisclosureSchedule`**（披露时限保守下界：
>   季报 quarter-end +15 **交易日**（节假日使之下界不早于监管的 15 工作日）、
>   年报 +3 日历月；`latestGuaranteedPublishedPeriod(asOf:)` 为披露检测锚点）。
>   时限是**下界不是承诺**——真实公告以公告 API 为准，指数/ETF 类基金
>   Q1/Q3 可能不披露季报。
> - **`FundHoldingSync` 引擎**（fund 粒度隔离）：候选期 = (游标, 锚点] 升序
>   逐期抓取（`EastmoneyHistoricalHoldingProviderAdapter` 按报告期构造，
>   公告 API 提供真实 publishedAt）；**公告未出 ≠ 失败**——
>   `announcementNotFound` 记 .notYetPublished、游标停在最后成功期、
>   停止本基金后续期（升序下更晚的期更不可能已公布），不计 ProviderHealth
>   失败（对齐 PROV-8 notFound 语义）。结构分桶 → spool append → 四防火墙
>   commit；有拒收 / commit 失败游标不推进（重试幂等，不跳期）。
> - **适配器 scheme 扩展**：`EastmoneyHistoricalHoldingProviderAdapter`
>   接受/透传 `fund_product_code`（持仓快照的 canonical 维度是 FundProduct，
>   ObservationFactory 要求 fundProduct 目标；fund_code 兼容保留）。
> - 测试（FundHoldingSyncTests，以套件通过为准）：报告期导航/编解码、时限数学
>   （含清明/年报 3 个月）、首轮 7 期回补、upToDate、新季度检测只补缺失期、
>   公告未出游标保持、拒收游标保持、失败隔离、健康降级。swift test
>   全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> **SYNC-5 已签收（1 点，2026-08-24）**——`Sync/MacroSync.swift`
> （FRED 宏观同步，daily/weekly 节奏）：
> - **修订优先的窗口语义**：宏观序列会再发布（FRED real-time vintage，
>   ADR-DATA008）——抓取不做 effectiveAt 截断（修订可能落在任何历史期），
>   幂等与修订分工由确定性派生保证：同 ID 同内容幂等归并、新 realtime_start
>   = 新 vintage 行（economic 取最新修订、exactSnapshot 保留历史版本，
>   测试覆盖 2.5→3.1 修订场景）。
> - **节奏 gate**：per-series `refreshInterval`（日频序列配日检、季频配周检，
>   调用方声明），未到期 .skippedCadence 零网络。
> - **游标只用于报告**（lastIngestedEffectiveAt 驱动新观测计数与 upToDate
>   判断），不约束抓取窗口——与 SYNC-3 的本质差异。
> - 失败语义同 SYNC-3/4：series 粒度隔离、ProviderHealth 上报、
>   isCallable 跳过、坏状态 fail-closed。7 个测试（MacroSyncTests）。
>   swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> **SYNC-7 已签收（3 点，2026-08-24）**——`Sync/ProviderFallbackChain.swift`
> （DATA006 §Decision 3 三档降级在抓取面的落地）：
> - **编排**：primary → secondary → … 有序候选；每候选前置 `isCallable`
>   闸门（unavailable / 额度尽 / 限流冷却中 → 零网络跳过）；抓取失败换下家
>   （quotaExhausted / rateLimited 的冷却与恢复语义在 ProviderHealthMonitor，
>   链只消费判定 + 上报成功/失败/quota +1）。
> - **local 兜底非致命化**：全部候选失败返回 `.allFailed`（不抛错不阻塞），
>   读取面继续由本地 Canonical Store 服务——结构性测试验证「先入库一根 bar、
>   再全失败、查询照常返回」。`localFallbackSummary` 是降级语义的可观测出口。
> - **空链合法**（无远程候选 → 直接 allFailed → local-only，不 trap——
>   配置错误用降级语义表达比崩溃更符合 DATA006）。
> - 与 PROV-8 的分工：monitor 管状态（谁健康/冷却/额度），链管一次抓取的
>   编排；未注册 Provider 的 isCallable=false（未声明即拒绝）语义保持。
> - SYNC-2 Market Daily Sync（Stooq primary → Alpha Vantage secondary，
>   M2 已验证的候选链）消费本链（已落地，见下）。8 个测试
>   （ProviderFallbackChainTests）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **SYNC-2 已签收（2 点，2026-08-24）**——`Sync/MarketDailySync.swift`
> （收盘后增量：stocks/ETF/indexes，两通道合一轮）：
> - **直接抓取通道**（美股日线 Stooq→AV 候选链，经 SYNC-7 降级链）：
>   锚点 = 法域感知的「保证已公布」最新 bar 日期（MarketClose T+1 语义 ×
>   NYSE/SSE 日历——感恩节跨休市锚点有测试）；窗口 [游标+1, 锚点] →
>   降级链抓取 → 结构分桶 → 直接抓取 spool → 四防火墙 commit。
>   全 Provider 失败 = .allProvidersFailed（local 兜底，游标不动）；
>   usedRole 记录本轮实际使用的候选（primary/secondary 可观测）。
> - **远程 staging 提交通道**（A 股行情经 AKShare collector）：
>   `commitRecords(fromSpool:)` 把 RemoteStagingSyncLoop 维护的 remote
>   spool 提交进 canonical（幂等重放不翻倍有测试；spool 不存在 = 通道
>   未启用，正常跳过；文件级读取失败上抛不静默）。本引擎不直接抓 A 股。
> - 游标保守推进同 SYNC-3；7 个测试（MarketDailySyncTests）。swift test
>   全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> **SYNC-6a 已签收（3 点，2026-08-24）**——`Sync/HistoricalBackfill.swift`
> （持仓 universe 历史回填 ≥252 交易日 + 覆盖率验证）：
> - **窗口 = 交易日数而非日历天**：锚点往回 `requiredTradingDays`（默认
>   252）个交易日（NAV 锚点用 T+1 公布语义、bar 锚点法域感知），直接对应
>   M5 验收语义；测试断言窗口跨 2026 春节/美股节假日正确跳休市。
> - **抓取+提交与增量引擎同款**（结构分桶 → spool append → 四防火墙），
>   **幂等**（重跑 252 行不翻倍有测试）；**不动增量游标**——回填补历史，
>   重叠部分下轮增量幂等归并。
> - **覆盖率验证是验收本体**：`TargetCoverage` 对比期望交易日集合与库内
>   实际 effectiveAt 集合（**以查询为准不以 fetch 返回为准**——Provider
>   可能少给），报告 covered/required、缺口样本、allSufficient。
>   Provider 只给 100 天 → insufficient + 头部缺口如实报告（有测试）；
>   降级链全失败 → local 兜底 + 覆盖率 0/252 如实呈现。
> - universe（用户当前持仓）是 App 侧装配（B.3 时点），本类型收显式清单。
>   5 个测试（HistoricalBackfillTests）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **SYNC-8 已签收（5 点，2026-08-24）**——`Sync/IdentitySync.swift`
> （非持仓标的的 identity 增量建立，ADR-DATA001 §Decision 3 的建立时算法）：
> - **4 条正式路径按优先级**（命中即停，各有测试）：
>   1. providerAuthoritative——hint 携带的官方 cross-ref 指向已登记代码时
>      继承其 canonical；
>   2. exchangeSymbolExact——(exchange, symbol) 与已有 Listing 精确匹配
>      （无 exchange 证据不猜；深市同码不误映射到沪市 listing，各自权威）；
>   3. isinOrCik——ISIN 匹配 Instrument（唯一挂牌升到 Listing 层）、CIK
>      补零归一后匹配 LegalEntity.regulatoryIDs（SEC 事实的 canonical 目标）；
>   4. manualVerified——`registerManualVerified` 增量入口（REPO-4b 形态）。
> - **创建模式**（新标的进 Instrument Master）：exchange+symbol 或 ISIN
>      权威证据齐备时创建 LegalEntity→Instrument→Listing 实体链并登记；
>      **基金类不自动创建**（份额/Product 语义不能猜，走 manualVerified）。
>      ID 从稳定输入 SHA256 派生——重复建立幂等（同 ID upsert 不翻倍）。
> - **fuzzy 只产 candidate**：无权威证据时按字符 bigram Dice 相似度对已有
>      Instruments 产候选（防火墙 1：fuzzy 登记行 lookup 不可解析），
>      `verify(accept:)` 升级 manualVerified 后才可解析、reject 保持拒绝。
> - **冲突不覆盖**：已有权威映射 + 新提案指向不同 canonical → 报 conflict
>      保留既有（identity 单点，改映射污染下游）。
> - Repository 增补 `allInstruments/allListings/allLegalEntities` 枚举 API
>      （协议 + InMemory + GRDB 同步实现，扫描匹配用）。
> - 测试（IdentitySyncTests，以套件通过为准）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **SYNC-6b 已签收（5 点，2026-08-24）**——`Sync/MarketUniverseBackfill.swift`
> （全市场 universe 分批历史回填，Epic 6 收口）：
> - **分批预算**：每轮 `maxTargetsPerRound` 个目标（优先级序、稳定 tie-break），
>   partial completion 一等公民——「受免费 Provider 额度限制，可分阶段」的
>   引擎语义；额度感知复用降级链 isCallable 闸门（AV 25/天耗尽 → 当轮
>   allFailed → 留队列下轮再试，测试覆盖）。
> - **进度状态持久化**：sufficient 条目记入 completedEntries 后续轮次跳过
>   （省额度、幂等）；覆盖不足自动留队列。universe 版本化数据文件**增量
>   补全**：新增条目自动进批次、旧完成项按 key 跳过、universe 收缩时陈旧
>   完成项不计入进度（都有测试）。
> - **双通道**：直接抓取条目（美股）走 HistoricalBackfill 全流程；remote
>   通道条目（A 股，数据由 RemoteStagingSync + MarketDailySync 提交）只
>   验证覆盖率（`coverageReport` 新增免抓取入口）——零网络零误报。
> - universe 内容策展（哪些指数/行业进 300+ 清单）是 WF-2（Market
>   Discovery）的工作，本引擎只收版本化清单。6 个测试
>   （MarketUniverseBackfillTests）。swift test 全量绿（跳过环境性
>   AppLaunchPresentationPolicyTests）。
>
> **✅ Epic 6 完全收口（2026-08-24）**：SYNC-1（3）/ SYNC-2（2）/ SYNC-3（2）/
> SYNC-4（2）/ SYNC-5（1）/ SYNC-6a（3）/ SYNC-6b（5）/ SYNC-7（3）/
> SYNC-8（5）= 26 点全部签收，M5 能力落地（引擎层离线验证，新增 9 个测试
> 套件、以套件通过为准）。Epic 7（Factor Engine）解锁。
>
> **Epic 6 一轮审查修复（2026-08-24，6×P1 + 1×P2）**：
> - **P1 FRED 未真正抓取 vintage**：endpoint 缺 realtime_start/end 时 FRED
>   默认当天——响应是当前快照而非历史 vintage，且会把抓取当天标成所有
>   历史值的 publishedAt（后续运行伪造 vintage）。修复：`fredObservations`
>   endpoint 显式携带 realtime 窗口（adapter 默认 realtime_start=1900-01-01
>   早于一切 FRED 序列）+ output_type=1；**api key fail-closed**（缺失直接
>   unavailable 报「缺少 FRED API key」，废止 PLACEHOLDER 静默坏请求）。
>   realtime 参数从 adapter 到 fetcher 的端到端传递与缺 key 拒收有测试。
> - **P1 universe 固定前缀批次饿死后续目标**：每轮对相同排序取前 N，持续
>   失败的高优先级条目会永久占据批次。修复：持久化**轮转游标**
>   （rotationCursor，沿 universe 优先级序单圈扫描、跳过已完成、取满预算），
>   保证每个未完成条目在有限轮内必被尝试；永久失败不饿死后续目标的
>   轮转行为有测试（5 标的预算 3，S0-S2 永久失败时 S3/S4 第二轮完成）。
> - **P1 displayName 派生 Canonical ID 合并不同证券**：同名不同码的标的会
>   派生相同 LegalEntity/Instrument ID 被错误合并。修复：创建模式的 ID 锚点
>   **只从权威键派生**——listing 路径 exchange|symbol、ISIN 路径校验后 ISIN；
>   displayName 降为可变属性；占位发行人按标的独立派生（宁可多建不误并，
>   真实归属由披露数据走权威路径合并）。同名不同码三层实体独立有测试。
> - **P1 过期 Verification 覆盖权威映射**：verify() 无冲突检查地 upsert，
>   fuzzy 生成后另一轮建立的权威映射会被旧 accept 覆盖。修复：只升级
>   「当前仍是 fuzzy candidate 且候选一致」的行；已有权威映射时一致=幂等
>   成功、不同=过期提案拒收（映射不动）。过期/幂等两态有测试。
> - **P1 保守游标跨过被丢弃的日期（SYNC-3/2）**：droppedMalformed 计数被
>   读取但未参与推进判定，valid/invalid 混合时也推进——T/T+2 合法而 T+1
>   被丢时游标直接到 T+2，T+1 永不重试。修复：推进条件收紧为三重干净
>   （管道零拒收 + 无结构非法 + 上游零丢行），任一不满足游标不动（已提交
>   合法行保留，幂等重抓不翻倍）；MarketDailySync 同步消费降级链透传的
>   diagnostics。混合 invalid / 上游丢行两形态（NAV + 行情）都有回归测试。
> - **P1 coverage key 跨标的碰撞**：`bar|code.value` 无法区分不同 scheme/
>   交易所/法域的同码标的，覆盖结果互相覆盖并错误标记完成。修复：
>   HistoricalBackfill / coverageReport / MarketUniverseBackfill 全链路
>   改用 canonical 维度——`bar|<listingID>` / `nav|<shareClassID>`。
> - **P2 空报告期后 continue 跨期推进（SYNC-4）**：某期零记录时 continue，
>   更晚的期成功后游标越过空洞。修复：空期立即返回 held（停在空洞前，
>   不再尝试更晚的期）；「确认不适用」的显式持久化跳过状态留作后续
>   story（不能用跳过去代替）。空期立即 hold 有测试。
> - 修复后 swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> **Epic 6 二轮审查修复（2026-08-24，4×P1 + 1×P2）**：
> - **P1 FRED 全量 vintage 被单页上限截断**：parser 只解码 observations、
>   忽略响应顶层 count/offset/limit，且 endpoint 无分页参数——全量 vintage
>   超过单页上限（100,000）后每轮重复抓第一页，后续 vintage 永久缺失。
>   修复：endpoint 增加 `offset`（+sort_order=asc），`parsePageMetadata`
>   解码分页元数据（缺省字段按单页处理，兼容旧 fixture），adapter 循环
>   抓取至 `offset + received >= count`（offset 不推进/超 200 页 fail-closed
>   schemaMismatch）。两页拼接（4 条全回）与无分页字段单页停止都有测试。
> - **P1 FRED API key 泄露进错误文本**：非 2xx 错误携带完整 absoluteString
>   （query 含 api_key），会流进 ProviderError → sync 失败原因 → 降级诊断。
>   修复：`redactedDescription(of:)` 剥离 query/fragment 只留 scheme/host/path，
>   错误构造统一走脱敏；纯函数测试锁定「不含 api_key、不含任何查询参数」。
> - **P1 游标闸门漏 merge 丢行与 unsupported**：只统计
>   droppedMalformedBySource 会漏 droppedOnMerge，并把
>   completeness == .unsupported 的零丢行当真（「没报」≠「没有」）。
>   修复：FundNAVSync / MarketDailySync 的上游干净条件统一收紧为
>   `completeness == .complete && totalDropped == 0`；merge 丢行 +
>   unsupported 两形态（NAV 与行情各一组）都有回归测试。
> - **P1 verify() 绕过 fuzzy candidate**：登记行不存在时 `if let` 落空仍会
>   upsert manualVerified——调用方可借 verify 直提任意 canonical 映射。
>   修复：`guard let registered else { return false }`；无登记行的 verify
>   拒收且零写入（有测试）；直接人工登记走独立入口 registerManualVerified。
> - **P2 完整 realtime 起点用官方下界**：默认 realtimeStart 从 1900-01-01
>   改为 **1776-07-04**（FRED 官方定义的完整实时区间下界），默认参数
>   endpoint 精确匹配锁定有测试。
> - 修复后 swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> **Epic 6 三轮审查修复（2026-08-24，2×P1 边界缺口）**：
> - **P1 传输层错误仍泄露 api_key**：非 2xx 分支已脱敏，但 catch-all 分支
>   `\(error)` 整体插值底层错误——URLError/NSError 的 userInfo 携带
>   NSErrorFailingURLStringKey（带 api_key 的完整 URL），同样会流进
>   ProviderError → sync 结果 → 降级诊断。修复：只记录 domain/code +
>   脱敏 URL（不插值错误对象）；URLProtocol 注入含凭据 userInfo 的
>   URLError 传输失败，断言错误文本无 api_key / 无任何查询参数。
> - **P1 分页响应 offset 可前跳漏页**：只查 `nextOffset > requested` 且
>   `hasMorePages == false` 直接退出——请求 offset=0、响应自称 offset=2
>   且「已到末页」时会静默漏掉前两页。修复：累计本页前先
>   `guard metadata.offset == offset`（前跳/后退都拒收 schemaMismatch），
>   另加 `count >= offset + received` 一致性校验。前跳 / 后退 /
>   count 不一致三个形态都有测试。
> - 修复后 swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。

---

### Epic 7 — Factor Engine

**铁律**：每个 factor 返回 metric（Decimal + unit），不返回分数；ordinal signal 由独立 SignalPolicy 产生。

> **状态（2026-08-24，Epic 7 全部收口）**：**FAC-1..8（18 点）全部签收**，
> 代码在 `InvestmentIntelligenceV2/Factors/`（FactorModel / SignalPolicy /
> TrendFactor / MomentumFactor / VolatilityFactor / DrawdownFactor /
> RelativeStrengthFactor，共 7 源文件），测试以套件通过为准：
> FactorModelTests / SignalPolicyTests / TrendFactorTests /
> MomentumFactorTests / VolatilityFactorTests / DrawdownFactorTests /
> RelativeStrengthFactorTests / FactorPITGoldenTests（8 套件）。
> swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests）。
>
> 实现要点（与 Story 表述的对齐）：
> - **铁律落实**：全部 factor 产出 `FactorMetric`（Decimal + 强类型
>   FactorUnit，scale=12 舍入）；`OrdinalFactorSignal` 刻意不携带任何数值
>   字段——ordinal 无法回流 cardinal 运算是类型层保证，不靠约定。
> - **FAC-1**：FactorSnapshot 实现 Artifact 协议（`id: ArtifactID`，
>   FactorSnapshotID 收敛为 typealias）；provenance 三件套
>   sourceObservationIDs / factorVersion / asOf；id 确定性派生（重算幂等），
>   factorVersion = 全部 definition key@version 的双 FNV-1a 摘要。
>   FactorEngine 以 economicKnowledge(asOf:) 读数（PIT 语义由 Repository
>   既有语义保证，引擎不重复实现）。
> - **FAC-2**：SignalPolicy 阈值带 provenance（policyID/version/basis/
>   rationale，heuristic 必附 rationale）；规则缝隙 / 未配置 metricKey /
>   数据不足一律 fail-open 到 .uncertain（「没规则」≠「中性」）。
> - **FAC-3..7**：窗口全部 versioned 参数进 FactorDefinition.parameters
>   （windowBars / slopeHorizon / denominator=n-1 / windowPolicy=cap /
>   benchmarkListingID / alignment=independent-tail）。两个刻意的语义
>   决策：① drawdown 窗口是 cap 上限（不足 252 用可得，政策差异在
>   parameters 显式声明）；② 相对强度两侧独立取尾部区间收益，不逐日
>   对齐（跨市场日历不同，强制对齐是猜测）。Decimal 全程，sqrt 用
>   Double 初值 + 牛顿精化（确定性）。
> - **FAC-8**：golden 套件锁定「固定序列 → 固定输出」（等差序列闭式解
>   字面量）+ 跨 vintage 一致（不可见 vintage 重算 byte-identical、可见后
>   旧 vintage 择优淘汰不双计、benchmark 修订同样受 PIT 约束）+ 未来数据
>   不泄漏（完整库 vs 截断库同一 asOf 的 snapshot 相等）。
>
> Epic 8（Exposure / Risk）解锁。

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

> **状态（2026-08-24，Epic 8 全部收口）**：**EXP-1（8）/ EXP-2（5）/
> RISK-1（3）/ RISK-2（3）/ RISK-3（2）= 21 点全部签收**，代码在
> `InvestmentIntelligenceV2/Exposure/`（PortfolioLookthroughCalculator /
> ExposureEngine）与 `InvestmentIntelligenceV2/Risk/`（ConcentrationCalculator /
> CorrelationCalculator / PortfolioRiskProfiler），测试以套件通过为准：
> PortfolioLookthroughCalculatorTests / ExposureEngineTests /
> ConcentrationCalculatorTests / CorrelationCalculatorTests /
> PortfolioRiskProfilerTests（5 套件）。swift test 全量绿（跳过环境性
> AppLaunchPresentationPolicyTests）。
>
> 实现要点（与 Story 表述的对齐）：
> - **EXP-1 分层**：V2 抓取已由 Epic 4/6 Provider 链进 Canonical
>   Observation，计算器只做旧实现的「make 层」等价物（纯计算、不做 IO）。
>   能力等价旧 944 行计算面（跨基金合并 / coverage 三级 / 资产大类 /
>   missing+stale 警告 / 每基金摘要），旧实现的抓取 / 缓存 / 重试场景
>   属 Provider 层、不在计算器范围。**超越**：全部 Decimal Ratio +
>   上下界（最坏情况归因：upper = point + 维度 unknown；证券维与资产
>   大类维缺口分开记录）+ 行业聚合走显式分类输入（不内置行业字典）+
>   Artifact conformance。类型名 LookthroughSnapshot 避开同 target 的
>   旧 Core PortfolioLookThroughSnapshot。
> - **EXP-2**：三维规范化为统一 ExposureEstimate（bounds 从 EXP-1 原样
>   保持，unknownWeight 进入上下界）+ fund overlap 新维度
>   （Σ min(wA,wB) + unknown 上界）。
> - **RISK-1**：三层集中度 + HHI 上下界（凸性最坏：Σw² + 2·wmax·u + u²）；
>   重复持股经穿透层识别（基金层的分散假象被穿透合并暴露）。
> - **RISK-2**：Pearson（Decimal）按 effectiveAt 严格同日配对；不足三态
>   （insufficientSamples / noOverlappingDates / zeroVariance）一律
>   unknown 不猜，绝不用 0 或均值填充。
> - **RISK-3**：多维聚合 Artifact，**类型层无单一分数字段**（Mirror 白名单
>   测试锁定）；数据基础维度透明呈现覆盖情况。
>
> Epic 9（Daily Attribution Workflow，M6）解锁——这是 macos-app 首次
> import V2 代码进入双轨期的 Epic。

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

> **状态（2026-08-24，Epic 9 全部收口，M6 达成）**：**ATTR-1（5）/
> ATTR-2（2）/ ATTR-3（3）/ ATTR-4（3）/ ATTR-5（3）= 16 点全部签收**。
> 引擎层代码在 `InvestmentIntelligenceV2/Attribution/`
> （AttributionEngine / DailyAttribution / AttributionRenderer /
> DailyAttributionWorkflow），App 桥在
> `Core/AppModel/AttributionV2Bridge.swift`（唯一 App→V2 桥），
> UI 在 `Views_macOS/InvestmentIntelligence/AttributionV2Section.swift` +
> `Views_iOS/EnhancementSectionView.swift` 双轨段。测试以套件通过为准：
> AttributionEngineTests / DailyAttributionTests / AttributionRendererTests /
> DailyAttributionWorkflowTests / AttributionV2BridgeTests（5 套件）。
> swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests 崩溃与
> M2Live 场景 1 当日外网阻塞）；双端构建验证通过（SPM macOS +
> xcodebuild iOS Simulator，xcodegen 重新生成工程编入新文件）。
>
> 实现要点（与 Story 表述的对齐）：
> - **ATTR-1**：contribution = w×r；coverage = 已知权重和；residual =
>   portfolioReturn − attributed（仅当提供组合实际收益）。收益率未知进
>   coverage 缺口不猜；全 Decimal、确定性排序。
> - **ATTR-2**：immutableHistorical（历史归因永不失效，上游修订走新
>   artifact）；producedAt 不参与 id（重算幂等）。
> - **ATTR-3**：三档分级措辞随覆盖度递减（<50% 必须「不宜据此下结论」）；
>   LLM Narrative 契约 = AttributionNarrativeProvider 协议 + 冻结摘要
>   输入 + 独立 narrative 字符串（withNarrative 整体附加），类型层不存在
>   「LLM 改写归因值」通道；deterministicNarrative 提供无 LLM 兜底。
> - **ATTR-4**：AgentJob/AgentEvent 基础形态（五态状态机 + 非法迁移守护 +
>   幂等指纹 id）；Epic 13 AGENT-1 在此之上扩展 Registry/Recovery。
>   provider 抛错 = failed；成分收益率未知 ≠ 失败。
> - **ATTR-5（B.3 兑现：App 层首次引用 V2）**：双轨展示与旧
>   marketCloseReview 并存（旧代码零改动）；无市值行不进归因（需权重
>   基础），Double→Decimal 经字符串舍入避免浮点尾噪；归因日取
>   latestChangeDate；macOS/iOS 双端同步接入。
>
> Epic 10（Decision 子系统，mock signals）解锁。

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

> **状态（2026-08-24，Epic 10 全部收口，M7 达成）**：**DEC-1（5）/
> DEC-2（5）/ DEC-3（3）/ DEC-4（3）/ DEC-5（8）/ DEC-6（5）/
> DEC-7（5）/ DEC-8（8）/ DEC-9（3）= 45 点全部签收**，代码在
> `InvestmentIntelligenceV2/Decision/`（9 源文件：StrategicAllocationPolicy /
> StateConstraintEvaluator / PortfolioProjection / ActionDomainBuilder /
> TargetRebalancePlanner / ConstraintGate / CriterionEvaluator /
> CriterionComparator / PortfolioDecisionArtifact）。测试以套件通过为准：
> 同名 9 个测试套件（StrategicAllocationPolicyTests…PortfolioDecisionArtifactTests）。
> swift test 全量绿（跳过环境性 AppLaunchPresentationPolicyTests 崩溃与
> M2Live 场景 1 当日外网阻塞）。mock signals 验证：DEC-9 的 replay 测试
> 用 signalCardinal 通道的固定分数闭环（same inputs → same decision）。
>
> 实现要点（与 Story 表述的对齐）：
> - **DEC-1（D000）**：Target 唯一写入路径 = StrategicAllocationPolicy 两
>   apply 方法，签名不含任何 Signal 类型（「Signal 不能改 Target」类型层
>   保证）；provenance 只两类；Validator 拒权重和≠1（禁止「剩余配 cash」）。
> - **DEC-2**：三态判定（violated/satisfied/unknown）用 EXP-2 上下界；
>   unknown = 跨阈值（可能违规不猜）；违规产 remediation 不是 veto；
>   OperationalObligation 独立类型。
> - **DEC-3**：忠实投影（不归一不 clamp 负值，非法留给 Gate）；新标的
>   两不（不猜资产类 / 不静默丢弃 → unresolvedNewSubjects）。
> - **DEC-4**：动作域 = per-subject Δw 区间 + 新标的白名单（默认裁剪），
>   搜索空间结构性缩小。
> - **DEC-5（D001）**：Δw 唯一生产者；SizingProvenance 三来源
>   （target/remediation/user），输入无 Signal 类型（LLM 不能产 Δw）；
>   pro-rata 类内分配 + toleranceBand + 目标 0 清仓 + 无持仓类 note
>   不引入新标的；域外动作剔除留证。
> - **DEC-6（D001 §4）**：Layer1 动作硬约束裁剪；Layer2 投影联合约束
>   （负权重/无杠杆/零和/换手预算/加权平均相关——unknown 对跳过不猜）；
>   rescale 按比例缩放不引入新 Δw。
> - **DEC-7（D002）**：weightedSum/absoluteDevination 确定性求值 +
>   inputReferences（signal 影响唯一通道 = signalCardinal 显式标注）+
>   computation 审计轨迹；缺失输入 → unknown。
> - **DEC-8（D003）**：Effective Dominance（禁止加权聚合）；IndifferenceBand
>   heuristic 显式 provenance（rationale 空 precondition 拒）；unknown 阻断
>   + blockingUnknowns 透明；非传递循环不打破（全部成员 admissible）；
>   unresolvedTradeoff 真实可触发。类型改名 PlanComparisonResult 避开
>   Foundation 同名。
> - **DEC-9（D004）**：引用层 IDs（signal/criterion/factorSnapshot/target/
>   band）+ immutableHistorical + 确定性 id；Validator provenance 闭环
>   四查；Replay 不重跑 Research，what-if 产新决策不动原 artifact。
>
> **Epic 7–10 跨 Epic 审查修复（2026-08-24，8×P1 + 1×P2）**：
> - **P1 约束判定**：单标的暴露改集合三级判定（任一 lower 超阈 →
>   violated，不再被更宽区间掩盖）；资产类偏差改区间数学（Target 落在
>   暴露区间内时偏差下界为 0，不再误报 violated）。
> - **P1 相关性键域**：投影主体键剥 listing| 前缀 + 无序对匹配裸
>   ListingID（修复前生产 pair 全部 skipped、约束形同虚设）；基金主体
>   显式跳过。
> - **P1 ID 碰撞**：统一 StableDigest（sortedKeys JSON 语义 payload，
>   只排除 producedAt）——Lookthrough/Attribution/Decision/Target 四处
>   ID 补全语义输入（纯直接持股组合同日曾全部同 ID）。
> - **P1 Target 构造封闭**：AllocationTarget memberwise init 被
>   fileprivate 抑制（同文件 Policy 唯一入口）；Codable 校验式解码
>   （脏权重在解码点拒绝）。
> - **P1 D004 闭环**：DecisionValidator 四类引用（signal/factor/
>   criterion/band）fail-closed resolvers；DecisionReplayer 完整重放
>   Planner→Compare→Decide（重放产出含行动计划与 provenance）。
> - **P1 Artifact 持久化**：IntelligenceSchema+ArtifactCodecs 落地五类
>   Artifact + AgentJob 的 GRDB 往返 codec（payload 自包含 + 依赖表行
>   同步写；不触碰已发布迁移）。
> - **P1 App 归因口径**：portfolioReturn 仅估值与涨跌双全覆盖时提供
>   （子集收益不再当全组合 residual 基准）；覆盖状态透出 + high 档
>   措辞不再声称「全部持仓」。
> - **P2 归因日界**：回退用上海时区当日零点（同日内 ID 稳定）；
>   macOS section 单次读取 outcome。
> - 修复后 swift test 全量绿（跳过环境性同前）；iOS Simulator 构建验证
>   通过；新增回归测试覆盖每个修复点。
>
> **二轮审查修复（2026-08-24，7×P1 + 2×P2，全部落地）**：
> - **P1 跨进程 ID 稳定**：sortedKeys 不排序 Hashable 键字典的交替数组
>   编码（[ListingID: SectorClassification] 顺序随进程漂移）——Lookthrough
>   IdentityPayload 全部规范化（positions 规范串排序数组 + 行业
>   sortedKeyEntries）；jsonPayload 编码失败显式抛错。
> - **P1 Exposure/Risk ID 补全**：Exposure 纳入参与计算的 observation
>   IDs + overlapTopN；RiskProfile 纳入 correlationTopN/窗口/最小样本。
> - **P1 Target 解码 ID 自洽**：解码后重算派生 ID 与 JSON id 核对，
>   换内容保旧 ID 的伪造 Target 在解码点拒绝。
> - **P1 Validator 默认 fail-closed**：ReferenceResolvers 默认全 false
>   （缺 resolver = 无法证明可解析 = 拒绝），.everythingResolvable 为
>   显式声明形态。
> - **P1 Replayer 绑定 artifact**：artifact 补存 comparison（D004 §1
>   结果层）；replay(artifact:) 三重键域校验；verify 做 decision/
>   comparison/plans 三层全等验证。
> - **P1 幂等持久化**：write 同 ID 同内容 no-op / 异内容 conflict
>   （重放不主键冲突）；补齐第 6 类 LookthroughSnapshot codec。
> - **P1 AgentJob 双向 codec**：toAgentJob 事件时间线重放 + 终态一致
>   校验；idempotency_key 含 workflow 前缀；event payload JSON 编码
>   （nil/空串语义保留，特殊字符安全）。
> - **P2 pair 确定性合并**：反序重复对不再 trap（一致幂等 / 矛盾取
>   规范序列化小者）；**P2 badge 估值覆盖**：估值不全时「已知估值内
>   完整」（warning），不再单凭引擎 grade 声称覆盖完整。
> - 修复后 swift test 全量绿（1767 passed，环境性排除同前）；iOS
>   Simulator 构建通过；每个修复点有回归测试。
>
> **三轮审查修复（2026-08-24，5×P1 + 2×P2 + 1×P1 提交缺口，全部闭环）**：
> - **P1 HEAD 编译缺口**：二轮的 DailyAttribution try! 适配漏提交（干净
>   HEAD 编译失败）——已补提交；本轮以干净 HEAD 克隆复验构建通过。
> - **P1 重算伪冲突**：幂等比较剥离 producedAt（语义指纹），首次产出
>   时间保留——同语义稍后重算幂等通过。
> - **P1 Replayer 引用绑定**：ReplayInputs.resolvedReferences 与 artifact
>   引用层逐项核对（referenceMismatch fail-closed）。
> - **P1 Lookthrough 输入封闭**：基金/直接持股 XOR precondition +
>   校验式 Codable（双设双计暴露 / 双空权重消失均拒）。
> - **P1 冲突相关性保守合并**：取 |ρ| 较大者（fail-closed），不再字典序
>   取小降风险。
> - **P1 Validator 结果层闭环**：comparison plan 域 + decision 可推导
>   校验；PartialDecision 语义相等只看 (status, admissible)。
> - **P2 badge 三重口径**：仅 coverage==100% 且估值完整才「覆盖完整」；
>   80–99.9% 用「覆盖较高」。
> - **P2 Job 身份闭环**：派生 ID / 幂等键 / 事件归属 / 首事件时间 /
>   started-completed 列五重一致性校验。
> - 修复后 swift test 全量绿（1771 passed，环境性排除同前）；干净 HEAD
>   克隆 macOS + iOS Simulator 构建均通过；每个修复点有回归测试。
>
> **四轮审查修复（2026-08-25，4×P1 + 2×P2，全部闭环）**：
> - **P1 引用绑定 resolver 化**：裸 replay(inputs:) 私有化；InputResolving
>   协议是 inputs 唯一来源；criterion/band/target 从 inputs 实际内容
>   结构性派生（无法自报），resolver 只声明无法派生的 signal/factor。
> - **P1 comparison 完整性**：pairwise 必须是完整无序对域 C(n,2)；
>   paretoFront 必须由 pairwise dominance 重新推导相等。
> - **P1 provenance 实校验**：plan/动作的 Target 引用 == artifact.target；
>   dependencies 集合与引用层一致（原空操作枚举删除）。
> - **P1 badge 分支收窄**：V2 纯 formatter，partial/low 不再被通配分支
>   吞掉（低于 50% 曾显示「较高」）。
> - **P2 解码 directAssetClass 归属** / **P2 Job 冗余列完整比较**
>   （删列不再静默、errorMessage 与 FAILED detail 核对）。
> - 修复后 swift test 全量绿（1774 passed，环境性排除同前）；干净 HEAD
>   克隆 macOS + iOS Simulator 构建均通过；每个修复点有回归测试。
>
> **五轮审查修复（2026-08-25，4×P1 + 2×P2，全部闭环）**：
> - **P1 resolver 材料化**：InputResolving 返回 ReplayMaterials（定义 +
>   per-plan 输入 + 强类型实例），**分数由 Replayer 内部重算**——signal/
>   factor 引用域从定义实例结构性派生，resolver 无法自报或注入分数。
> - **P1 多 Target 折叠**：逐 plannerRun 无条件严格相等（含双 nil）；
>   Validator 同步无条件。
> - **P1 dependencies 完整比较**：(kind|refID|version) 多重集比较；
>   assemble 补 criterion/band 的 policy 依赖。
> - **P1 读回 split-brain**：fetchDomain 严格读回（id/validity/时间/
>   依赖表逐字段校验，分歧抛错）。
> - **P2 pair 键分隔符**：入口拒绝含 | 的 plan key。**P2 iOS 同口径**：
>   badge/贡献行/residual/覆盖/失败态同步。
> - 修复后 swift test 全量绿（1777 passed，环境性排除同前）；干净 HEAD
>   克隆 macOS + iOS Simulator 构建均通过；每个修复点有回归测试。
>
> **六轮审查修复（2026-08-25，5×P1 + 1×P2，全部闭环）**：
> - **P1 resolver 注入数值**：criterion 输入值只能经 `CriterionInputExtractor`
>   从强类型实例提取——signal 经 versioned `SignalCardinalPolicy` 转 cardinal
>   （artifact 新增 `signalCardinalPolicyVersion` 引用 + policy 依赖）、factor 按
>   「`<snapshotID>#<metricKey>`」从 snapshot 提取、observation 取实例值
>   （`CardinalObservation`）；`ReplayMaterials` 删除 `criterionInputs`，
>   同一引用 ID 锁定唯一数值（提取源决策级共享，per-plan 数值分叉通道不存在）。
> - **P1 实例身份绑定**：材料字典 key 必须就是实例自身 ID
>   （`definition.fingerprint` / snapshot/signal/observation id），factor/signal/
>   observation 引用域与实例域**精确相等**（superset 也拒），
>   `materialIdentityMismatch` fail-closed。
> - **P1 重放自包含**：Planner 全部输入按确定性指纹锚定
>   （`PlannerRun.fingerprint()` → `artifact.plannerInputFingerprints`，参与
>   确定性 ID 派生，绑定校验逐 plan 比对）；`higherIsBetter` 移入 versioned
>   `CriterionDefinition`（比较方向不再由调用方注入）；完整重放删除外部
>   `now`——各 plan 时间从 `artifact.plans[key].asOf` 冻结（plan id 含时间，
>   漂移在 verify 的 plans 全等中暴露）。
> - **P1 依赖比较碰撞**：DecisionValidator 改 `ArtifactDependency` 多重集合
>   结构化计数比较（不再拼接 kind|refID|version 字符串，`|` 碰撞不再可能）；
>   codec strict reader 同步字段级比较 + `dep_index` 从 0 连续校验 +
>   producedAt 重编码逐字比较（取消 2ms 容差，1ms 漂移拒收）。
> - **P1 strict reader 绕过**：payload-only `toDomain`/六类 `toX()` 隐藏删除，
>   唯一公开读回入口为 DB-backed `fetchDomain` + 六类 typed fetch
>   （`fetchFactorSnapshot` 等），round-trip 测试全部改走 strict 入口。
> - **P2 comparator 崩溃**：`precondition` 改 `throws(CompareError)`，非法
>   plan key 在重放路径上转为 `ReplayError.malformedPlanKey`（不再崩进程）。
> - 修复后 swift test 全量绿（1606 passed，环境性排除同前——AppLaunch
>   PresentationPolicyTests 在无窗口服务器环境 signal 11 为既有问题，干净
>   HEAD 同样复现）；干净 HEAD macOS release + iOS Simulator 构建均通过；
>   每个修复点有回归测试（实例身份/指纹漂移/冻结时间/依赖碰撞样例/
>   dep_index 断号/1ms 时间漂移/非法 plan key）。
>
> **七轮审查修复（2026-08-25，4×P1 + 2×P2，全部闭环——六轮修复方案的
> 重放比较语义收敛）**：
> - **P1 方案分数共享退化**：criterion 输入恢复**逐 plan 求值**——新增
>   plan-scoped `PLAN_METRIC` 输入通道（`PlanMetrics`：`plan.turnover`
>   Σ|Δw| + `plan.projectedWeight#<AssetClass>` 投影资产类权重，从各自的
>   plan+portfolio 强类型推导，封闭命名空间 fail-closed）；factorMetric /
>   observation 保持决策级共享 cardinal。singlePreferred 可重现，测试锁定
>   「同 IDs + 不同规划输入 → 不同决策」（D003 dominance 语义恢复）。
> - **P1 what-if 同 ID 换内容**：`replayWhatIf` 重设计——以 base 冻结规划
>   输入重算，**产出新 PortfolioDecisionArtifact 记录新引用**（新
>   factorSnapshotIDs / criterionVersions / band 版本；引用变更按版本纪律
>   bump）。替换实例携带自己的新 ID，「同 ID → 同实例」不再有 API 例外
>   （D004 §5「替换引用 ID，产出新 artifact」）。
> - **P1 新引用不可定位**：PlannerRun **冻结内嵌**进 artifact
>   （`plannerInputs`，参与确定性 ID 派生；域完整性与逐 run Target 一致性
>   fail-closed 校验）——完整重放从 artifact 本体取 Planner 输入，自包含，
>   不依赖尚不存在的 PlannerRun Store；`ReplayMaterials` 收敛为 criterion
>   定义 + factor/observation 实例 + band。
> - **P1 ordinal 伪 cardinal**：删除 `SignalCardinalPolicy` 与
>   `SIGNAL_CARDINAL` 输入通道（direction×strength→±1/±0.6/±0.2 只是序数
>   编码，重新打开 D002 黑箱评分）；criterion 数值只来自可测量 cardinal
>   （FactorMetric / CardinalObservation / PlanMetrics），无可测量来源的
>   LLM Signal 保持 narrative，artifact.signalIDs 仅为 research provenance。
> - **P2 Comparator 顺序相关**：比较前校验各 plan criterion schema——同
>   plan 内 criterion ID 重复抛 `duplicateCriterion`（不再静默取首个），
>   跨 plan 同 ID 定义不一致（version/unit/方向）抛
>   `criterionDefinitionMismatch`，方向取 canonical 定义。
> - **P2 幂等写忽略 depIndex**：`ensureIdentical` 补比对 `dep_index`——
>   索引整体偏移/断号但字段相同时报 conflict，不再误判幂等 no-op 后又被
>   strict reader 拒收。
> - 修复后 swift test 全量绿（1608 passed，环境性排除同前）；干净 HEAD
>   macOS release + iOS Simulator 构建均通过；每个修复点有回归测试
>   （per-plan 分歧 / what-if 新引用与身份违规 / 内嵌域与 Target 冲突 /
>   命名空间外 planMetric / 重复与冲突 criterion schema / dep_index 偏移
>   幂等冲突）。
>
> **八轮审查修复（2026-08-25，4×P1 + 2×P2，全部闭环——重放语义终态收敛）**：
> - **P1 投影完整性**：`projectedWeight#<class>` 改复用
>   `ProjectedPortfolio.project`——白名单新标的（`eligibleNewSubjects`
>   声明资产类）进入投影资产类权重；合法但缺席的类别返回**已知 0**
>   （不是 unknown）；白名外新标的 fail-closed 抛
>   `unresolvedProjectedSubject`（不猜分类、不静默丢弃）。
> - **P1 冻结规划一致性**：`frozenPlannerIssue` 共享校验
>   （Validator / replay / what-if 同一门禁）——plans 非空、
>   plannerInputs 域 == plans 域、逐 run Target 严格相等、逐 plan 以冻结
>   asOf 重跑 TargetRebalancePlanner 与已存 plan 全等。「Validator 放行
>   而 Replayer 拒绝」的分裂关闭（新错误 case emptyPlans /
>   plannerTargetConflict / frozenPlanMismatch）。
> - **P1 payload 兼容**：决策 artifact 切换新 kind
>   `PORTFOLIO_DECISION_V2`（plannerInputs / 摘要入 payload 后结构不兼容
>   旧 PORTFOLIO_DECISION）；旧 kind 行对 decision typed fetch 是
>   **fail-closed legacy**（kindMismatch 拒绝——不伪造缺失的 PlannerRun、
>   不按新结构解码崩溃）。
> - **P1 内容绑定**：`CriterionDefinition` / `IndifferenceBand` 增加
>   `contentDigest()`；artifact 引用层新增 `criterionContentDigests` /
>   `bandContentDigest`（参与确定性 ID 派生，policy 依赖携带摘要为
>   version——失效传播按内容粒度）；绑定校验比对摘要，同版本不同
>   权重/引用/方向/阈值的材料被拒；`assemble` 改以定义与 band 实例为
>   唯一来源派生版本与摘要（版本字符串与内容不允许分叉）。
> - **P2 Comparator canonical union**：canonical 定义取**全部 plan 的
>   union**，后续 plan 首次出现的 criterion 不再漏登记（A 缺 cost 时
>   B/C 的 cost 不再回退默认方向）；比较阶段移除 higherIsBetter 默认值。
> - **P2 what-if 洗白**：what-if 计算前先过冻结规划一致性校验——损坏的
>   base（域缺失 / Target 冲突 / 不可重放）不会被「洗成」结构自洽的
>   新 artifact。
> - 修复后 swift test 全量绿（1616 passed，环境性排除同前）；干净 HEAD
>   macOS release + iOS Simulator 构建均通过；每个修复点有回归测试
>   （白名单新标的投影 + 缺席类别已知 0 / 同版本不同内容与 band 阈值 /
>   不可重放 plan 与空 plans / 旧 kind fail-closed / union 方向 /
>   what-if 拒损坏 base）。

> Epic 11（LLM Research 子系统）解锁——WF-1/2/3 的真实 Signal 生产前置。

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
| 1 | 同一股票在两个 Provider symbol 不同（真实 QDII 样本：天天基金 513100 Q2 持仓 `AAPL` + 行情 Provider `aapl.us`/`AAPL`）| 解析到同一 Nasdaq `ListingID`；行情 Provider 走 Stooq primary → Alpha Vantage secondary 候选链（DATA006） |
| 2 | 基金 Q2 持仓 2024-07-18 公告（真实公告日，周四）+ 同基金 Q1 2024-04-20 公告（真实周六样本）| `availableAt = nextTradingDay(publishedAt)`（Q2 → 07-19；Q1 → 04-22 跨周末）；`economicKnowledge(asOf: 7-10)` 查不到 |
| 3 | Provider 故障延迟到 8-01 抓到 | `availableAt = 07-19`（客观，由 policy 从真实公告日 07-18 推导），`ingestedAt = 8-01`；`economicKnowledge(asOf: 07-19)` 可见，`operationalKnowledge(asOf: 07-19)` 不可见，`operationalKnowledge(asOf: 8-01)` 可见 |
| 4 | 模拟一次 data revision（v1→v2），v1 `announcementDate` 取 Provider 真实 `publishedAt` | 历史 vintage 查询仍看到 v1 |

> 原「同一基金在 Qieman 和天天基金代码不同」场景（基金跨 Provider identity）已随 REPO-6
> 且慢 Provider 移除而删除：基金 NAV 数据源唯一为天天基金，不存在跨 Provider 场景。
> 跨 Provider identity 机制改由场景 1（股票：天天基金 + 行情 Provider）验证。
>
> **2026-08-14 事实修订**（ADR-DATA009「真实数据推翻假设后修订设计」路径）：
> 原表述「Q2 持仓 7-20 公告（周六）→ availableAt 7-22」基于错误样本假设。天天基金
> 公告 API 实跑确认 110022 的 Q2 公告日是 **2024-07-18（周四）**，不是 07-20；周末
> 跨交易日语义改由同一基金真实 Q1 样本（公告日 **2024-04-20，周六** → availableAt
> 04-22）验证，不伪造日期。跨 Provider identity 样本从 A 股 600519.cn 换成真实 QDII
> 持仓（513100 的 AAPL），与 Stooq 美股源定位一致；Stooq 反爬 challenge 按 DATA006
> 记 `.unavailable` 并降级 Alpha Vantage secondary，不在客户端实现绕过。断言全部由
> 事实推导（`expectedAvailableAt = tradingDay(after: record.publishedAt)`），不硬编码。
>
> **2026-08-21 二次修订（行情窗口）+ M2 Pass**：配置真实 AV key 后实测免费层
> `outputsize=full` / date-range / `TIME_SERIES_DAILY_ADJUSTED` 均 premium
> （date-range 参数被静默忽略），Stooq 仍反爬——场景 1 行情窗口改为随 now 滑动的
> 近 20 天（AV compact 覆盖内），持仓样本仍锚定真实 2024 Q2 归档；identity 语义
> 与行情期无关，场景 2-4 PIT 断言不变。四场景 + evidence manifest 全绿，M2 放行
>（放行证据与遗留事项见 Epic 3 状态块）。

M2 不过不进 Epic 5（GRDB schema 冻结）——**M2 已于 2026-08-21 Pass，Epic 5 解锁**。

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
