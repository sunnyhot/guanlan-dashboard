# DATA001. Canonical Identity

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-1..3；Epic 3 REPO-4；Epic 5 GRDB-2

## Context

同一只投资标的在不同 Provider 用完全不同的代码：

- 同一只基金在且慢（`prodCode`）、天天基金（6 位基金代码）、证监会基金号（`fundCode`）、ISIN 之间各自不同
- 同一只股票在上交所、深交所、港交所、SEC（CIK）、ISIN 之间各有标识
- ETF 与跟踪指数是两个不同的 instrument，但常被混为一谈
- 基金 A/C 类是同一产品的不同份额，费用结构不同，长期收益不同

如果让上层（Factor / Risk / Attribution）直接消费 Provider 的原始代码，会产生：

- **跨 Provider 重复计算**：同一基金在天天基金有 NAV、在且慢有持仓，原始代码不同会被当成两个标的
- **合并错误**：A/C 类不拆开会让收益归因失真
- **ETF/Index 混淆**：把 ETF 当指数算暴露，会把跟踪误差吃掉

备选方案：

1. **沿用现有「字符串代码当 ID」**：现有 `Core/InvestmentIntelligence/` 用字符串，导致多 Provider 合并困难，是本计划要替代的核心问题之一
2. **用一个全局 UUID 任意指代标的**：可以，但没有「身份」语义，无法做映射、去重、跨源对账
3. **分层 Canonical Identity Model**（本决策）：定义 LegalEntity / Instrument / Listing / FundProduct / FundShareClass 五层，每层有稳定 ID；Provider 原始代码通过 `ProviderIdentifier` + `IdentityResolver` 映射到 Canonical

## Decision

**系统内一切业务计算只引用 Canonical Identity，不允许直接使用 Provider 原始代码。** Canonical Identity 是分层模型（见 rollout Epic 2 DOM-1..3、Epic 5 GRDB-2）：

1. **五层实体**（自顶向下）：
   - `LegalEntity`：发行人（基金管理人 / 上市公司）
   - `Instrument`：抽象金融工具（一只基金、一只指数、一只股票的「合约」）
   - `Listing`：在某交易所/平台的挂牌（同一只股票可沪深港三地挂牌）
   - `FundProduct`：基金产品（含 A/C 类聚合）
   - `FundShareClass`：基金份额类别（A 类、C 类独立）

2. **ID 类型**：每种实体有专用 `struct ID: Sendable, Codable, Hashable, RawRepresentable`（DOM-1）。ID 一旦写入 Repository 永不更改、永不复用。

3. **Provider → Canonical 映射**（REPO-4）：4 条正式映射路径，按优先级：
   1. Provider authoritative（Provider 自带的官方 cross-ref）
   2. Exchange + symbol exact（交易所 + 代码精确匹配）
   3. ISIN / CIK（全球/监管唯一标识）
   4. Manual verified（人工审核登记）
   - **Fuzzy 匹配只产 candidate**，必须经 `Verification` 流程才能写入 Canonical。Fuzzy 不允许直接产生最终映射。
   - **路径是「建立时」算法，不是「查询时」算法**：4 条路径描述 IdentitySync
     （SYNC-8）在登记一条 `ProviderIdentifier` 时使用的匹配方法，匹配成功后
     记为 `resolutionMethod` 元数据。`IdentityResolver`（REPO-4）是 lookup 层，
     只按 `(provider, scheme, value)` 查已登记映射 + 校验 `resolutionMethod.isAuthoritative`，
     不在查询时重新执行匹配。这样职责清晰：建立时做重匹配（耗时可接受），
     查询时只查表（高频路径快）。Resolver 不实现 4 路径运行时匹配是有意设计，
     非缺陷。

4. **关系显式建模**（DOM-3）：ETF→Index（跟踪）、ShareClass→Product（归属）、Stock→Entity（发行）、ADR→Stock（存托），通过 `InstrumentRelationship` 表达，不靠命名约定推断。

5. **Repository API 强制 Canonical**（REPO-1）：所有 Repository 查询接口入参/出参只出现 Canonical ID，不允许出现 Provider 原始代码。Provider 代码只活在 Provider Adapter 和 IdentityResolver 内部。

## Consequences

- **Positive**：
  - 跨 Provider 合并、去重、对账有单一锚点，Factor / Risk / Attribution 可以放心跨源拼接
  - A/C 类、ETF/Index、多挂牌这些易错场景在 Identity 层一次性解决
  - Identity 是稳定锚点，使得「同一标的跨 vintage 重算」成为可能（配合 DATA002 / DATA008）

- **Negative**：
  - Identity 维护成本高：新增标的必须经过 Resolver + Verification，不能即抓即用
  - Identity 是单点：映射错误会污染下游所有计算，需要 M2 验收（5 场景）和持续校验
  - 五层模型对个人投资者场景可能偏重，但分层成本主要是写代码，不是运行时开销（都是轻量 struct）

- **Neutral**：
  - 非持仓标的的 identity 增量建立靠 SYNC-8（Identity Sync），不能阻塞主流程

## Compliance Check

- **DOM-1..3 测试**：每个 ID 类型的 `Sendable + Codable + Hashable` round-trip 测试（M1 验收）
- **REPO-4 测试（lookup 层）**：resolve 按 (provider,scheme,value) 查已登记映射 + 校验 isAuthoritative；fuzzy 路径断言「只产 candidate，不直接写 canonical」。**4 条建立路径的匹配算法测试在 SYNC-8**（建立时执行，非 resolver 运行时，见 §Decision 3）
- **REPO-1 协议审查**：Repository 协议中不得出现 Provider 原始代码类型（用 grep / 编译期约束）
- **M2 验收场景 1/2**（rollout §4.1）：跨 Provider 同一基金/股票必须解析到同一 Canonical ID
- **GRDB-2 schema**：Identity schema 7 表必须完整覆盖五层 + provider_identifiers + instrument_relationships
- **PR checklist**：任何业务层（Factors / Exposure / Risk / Attribution / Decision）出现 Provider 原始代码作为入参，直接拒绝

## References

- rollout §3 Epic 2 DOM-1..3、Epic 3 REPO-4/4b、Epic 5 GRDB-2
- rollout §4.1 M2 验收（5 场景）
- 关联 ADR：
  - DATA002（PIT Visibility）：Canonical ID 是 PIT 查询的稳定锚点
  - DATA008（Observation Revision）：Identity 不变，观测可修订
  - D000..D004：所有 Cardinal 都基于 Canonical Identity 锚定
