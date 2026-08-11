# DATA004. Local Accumulation

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 5 GRDB-3/4；Epic 6 SYNC-6a/6b

## Context

免费 Provider 配额受限（FREE001）：

- Alpha Vantage free tier 25 次/天，1 只股票 1 年日线就要 1 次调用，252 交易日历史要分多天
- AKShare / 天天基金偶尔风控，单次抓不全
- Stooq 历史长度不固定，最近一年数据有时缺

如果每次需要数据都现抓，会产生：

- **回测无法跑**：历史数据要 252+ 交易日 × N 标的，现抓几天都跑不完
- **重复抓取**：同一只标的同一历史段每次重算都重抓，浪费配额
- **Provider 故障即瘫痪**：免费 Provider 一旦挂掉，系统完全无法运行

现有代码每次启动都重抓最新数据，没有「积累」概念，无法做长期回测。

备选方案：

1. **每次都现抓**：直接放弃回测和归因重算能力
2. **临时缓存**：只缓存最近一段，过期就重抓，仍是「现抓」思路
3. **本地积累 + 增量同步**（本决策）：所有抓到的数据永久入库，按 (canonicalID, vintage) 唯一索引；增量同步只补缺口

## Decision

**所有抓到的 Provider 数据一旦入库永不丢弃，按 (canonicalID, vintage) 唯一组织；查询优先本地，缺口才同步。**

1. **本地积累优先**（GRDB-3/4 schema）：
   - `daily_bars` 按 (listingID, tradingDay, vintage) 唯一索引；同一交易日可有多个 vintage（DATA008）
   - `nav_observations` / `holding_snapshots` / `corporate_actions` 同理
   - 一旦写入，原始 raw + adjustment 通道永不修改；修订走新 vintage

2. **增量同步**（SYNC-2/3/4）：
   - Market Daily Sync：只补「上次同步后到最新交易日」的缺口，不重抓历史段
   - Fund NAV Sync：同上
   - Fund Holding Sync：监听新披露，新 snapshot 入库，不覆盖旧 snapshot
   - Macro Sync：daily / weekly 增量
   - 同步失败时标 unavailable，下次重试只补失败段

3. **历史 Backfill 是显式一次性动作**（SYNC-6a/6b）：
   - **持仓 universe**：用户当前持仓涉及的标的，一次性回填 ≥252 交易日（SYNC-6a）
   - **全市场 universe**：Market Discovery 用的 300+ 行业/指数/资产标的，分批回填，受免费额度限制可分阶段（SYNC-6b）
   - Backfill 写入即永久，后续只增量补

4. **Provider 配额是稀缺资源**：每次同步必须先算「本地缺什么」，按缺口优先级排序后调用 Provider，不允许「全量刷新」式调用。Adapter 层暴露 quota 接口（DATA006 / FREE001）。

5. **Provider 失败有兜底**（SYNC-7）：local 已有数据 → 继续可用；缺口段标记 unavailable，决策层看到 unknown 而不是 0（配合 RISK-2「correlation 不足 → unknown，不猜」）。

## Consequences

- **Positive**：
  - 历史数据积累越久，回测 / 归因重算 / 决策重放越可信
  - Provider 故障期间系统仍能基于本地数据继续运行
  - 配额消耗最小化，免费额度可持续支撑日常运行
  - vintage 多版本为 DATA008 revision 提供基础

- **Negative**：
  - 磁盘占用随时间增长，需要定期审计（但单标的 252 交易日 × 数年只占 KB 级，可接受）
  - 早期数据缺口无法补全（用户从某天才开始用），决策时需要明确标注 coverage
  - 全市场 backfill 受额度限制，可能数周才覆盖完整 universe

- **Neutral**：
  - 现有「每次现抓」的代码路径在 Epic 12 一次性切换到 local accumulation，期间双轨
  - 离线模式下系统降级但仍可读，符合 FREE001 离线回放承诺

## Compliance Check

- **GRDB-3/4 schema 测试**：每个观测表都有 (canonicalID, vintage) 唯一索引；同 vintage 写入是 upsert（仅修 raw+adjustment，不改 effectiveAt）
- **SYNC-2/3 测试**：增量同步只补缺口，不重抓已存在段；测试用「模拟已有 7-20 数据，再 sync 应只抓 7-21 之后」
- **SYNC-6a/6b 验收**：持仓 universe 全部有 ≥252 交易日历史（M5 验收）
- **SYNC-7 测试**：Provider 失败时本地数据继续可用，缺口标 unavailable
- **PR checklist**：
  - Provider Adapter 出现「全量刷新」式调用 → 拒绝
  - 同步代码删除已有 vintage 数据 → 拒绝
  - 业务层用 0 / 默认值兜底缺口 → 拒绝（应该用 unknown）

## References

- rollout §3 Epic 5 GRDB-3/4、Epic 6 SYNC-2..7
- rollout §4.3 M5 验收（数据自给）
- 关联 ADR：
  - FREE001（Zero Paid Dependency）：免费配额稀缺是本 ADR 的根本动因
  - DATA002（PIT Visibility）：local accumulation 是 PIT 重放的物质基础
  - DATA006（Free Provider Fragility）：Provider 失败的兜底链
  - DATA008（Observation Revision）：修订走新 vintage 而非覆盖
