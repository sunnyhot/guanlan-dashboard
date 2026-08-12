# DATA003. Raw Market Canonicalization

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 2 DOM-5；Epic 4 PROV-1/2/3；Epic 5 GRDB-3/8

## Context

Provider 给出的原始行情字段千差万别：

- 股票 OHLCV 字段名、单位（元 / 分 / 美分）、复权方式（前复权 / 后复权 / 不复权）、时区（北京时间 / 美东时间 / UTC）、日期粒度（交易日 / 自然日）
- 基金净值单位净值 / 累计净值 / 复权净值各家口径不一
- 宏观数据的频率（日 / 月 / 季）、季节调整、基期、单位（% / 指数 / 美元）
- 公司行动（分红送股）的 ex-date / record-date / pay-date 字段名混乱

如果直接把 Provider 原始字段透传到 Factor / Attribution，会产生：

- **单位错误**：用元当分、用百分比当小数，因子值差几个数量级
- **复权错误**：跨 vintage 用不同复权基准计算 return，得到虚假的跳跃
- **时区错误**：跨市场事件时间对齐错位
- **可重算性破坏**：原始字段变了，历史重算结果就变，违反 DATA008

现有代码（`Core/TrendResearch/`）的 SEC / AlphaVantage 工具直接消费原始字段，导致因子重算不可重现，是本计划要替代的核心问题。

备选方案：

1. **每个 Provider 各存一份原始字段**：查询时现场拼装，复权/单位转换散在各处，错误难定位
2. **Provider 自己负责转换成标准格式**：Provider 不可信，且同一 Provider 历史数据可能用旧格式，破坏 PIT
3. **Raw + Adjustment 分离的 Canonical Schema**（本决策）：Provider 写入 raw + adjustment 两个通道，业务层只读 Canonical，转换在 commit pipeline 上一次性完成

## Decision

**Provider Adapter 只产 ProviderRecord（raw + adjustment），不写 Canonical。Canonical 化在 Data Pipeline commit 路径上完成，业务层只消费 Canonical。**

1. **CanonicalObservation 类型**（DOM-5）：每个观测类型有明确的 canonical 字段、单位、时区：
   - `DailyBar`：OHLCV 统一为「小数 return / 调整后价格 / 原始价格」三组；货币字段带 `currency`；时区统一 UTC 日界
   - `NAVObservation`：单位净值 / 累计净值 / 累计分红三字段，货币明确
   - `FundHoldingSnapshot`：每条 position 带 weight（0-1 小数）/ shares / marketValue（本币）/ listing（CanonicalID）
   - `MacroObservation`：value + 单位枚举 + 频率 + 季节调整标记 + 基期
   - `CorporateAction`：ex-date / record-date / pay-date / 行动类型 / 比例

2. **Raw + Adjustment 分离**（DOM-5 ADR-DATA003）：
   - `raw` 通道：原始 Provider 字段（OHLC、单位、复权系数）逐字保存，作为审计与重算源
   - `adjustment` 通道：复权因子、汇率、单位换算因子，独立时间序列
   - Canonical 在查询时按 vintage 拼装 raw + adjustment，不预先合成不可拆

3. **Pipeline 顺序**（GRDB-8）：`Staging → IdentityResolver → TemporalNormalizer → SchemaValidator → DataValidator → Canonical Commit`。每一步都是 commit 前的 firewall，不让脏数据进 Canonical Store。

4. **单位 / 货币 / 时区是强类型字段**：禁止用 `Double` 隐式约定单位。Factor / Attribution / Risk 只接受已声明单位的值（Decimal + unit）。

5. **Provider Adapter 不做业务转换**：Adapter 只负责「把 Provider 协议解析成 ProviderRecord」。任何复权、单位换算、归一化都进 Canonical Pipeline，不在 Adapter 里。这样 Adapter 可以独立测试、独立替换。

## Consequences

- **Positive**：
  - 业务层只读标准格式，Factor / Attribution 重算可信、可重现
  - Raw + Adjustment 分离让历史 vintage 可重算（DATA008），即使 Provider 改了复权基准
  - 单位强类型避免「差几个数量级」类隐性 bug
  - Pipeline 顺序清晰，每步可单测、可审计

- **Negative**：
  - Pipeline 步骤多，写入路径慢（但只占 0.1% 调用，可接受）
  - Canonical Schema 设计要覆盖所有观测类型，DOM-5 是 Epic 2 最大 Story（5 点）
  - Provider 字段变更时 SchemaValidator 可能拒收，需要有人维护映射

- **Neutral**：
  - 99.9% 的查询走简单 canonical 字段，无需关心 raw，性能与直接读 Provider 无差

## Compliance Check

- **DOM-5 测试**：每个 CanonicalObservation 类型字段齐全、单位/货币/时区强类型
- **PROV-1 测试**：`ProviderRecord` + `ProviderStaging` JSONL 格式 + SchemaValidator 拒收非法字段
- **GRDB-8 测试**：Pipeline 5 步顺序固定，任何一步失败不进 Canonical Commit
- **GRDB-3/4 schema**：Market / Fund schema 区分 raw + adjustment 列
- **PR checklist**：
  - Provider Adapter 出现业务转换（复权 / 单位换算 / 归一化）→ 拒绝
  - 业务层（Factor / Attribution / Risk）出现 Provider 原始字段类型 → 拒绝
  - Canonical 类型出现 `Double` 隐式约定单位 → 拒绝

## References

- rollout §3 Epic 2 DOM-5、Epic 4 PROV-1..3、Epic 5 GRDB-3/8
- 关联 ADR：
  - DATA001（Canonical Identity）：Canonical 价格/持仓的 Identity 锚点
  - DATA002（PIT Visibility）：Canonical 化时必须保留 vintage
  - DATA008（Observation Revision）：raw + adjustment 分离支撑 vintage 重算
  - DATA007（External Collector Isolation）：AKShare 进程外产 staging，再过 Pipeline
  - DATA010（Remote Collector）：远程 collector 产的 staging 同样过 Pipeline（不绕过任何防火墙）
