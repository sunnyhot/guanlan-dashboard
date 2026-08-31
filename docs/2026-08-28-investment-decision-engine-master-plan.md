# 投资决策引擎落地总体计划（DSA 蓝图八层全量）

- **日期**: 2026-08-28
- **状态**: M1-M9 已实施（931 测试全绿，App 构建通过）；App 集成接线全部完成（L6 闭环 / L7 流水线 / L8 回测 / L1 广度预暖与注入 / iOS 面板，见 baseline 第 10.6 节，2026-08-31）；M10（token 型源）待凭据
- **来源**: 对 [ZhuLinsen/daily_stock_analysis](https://github.com/ZhuLinsen/daily_stock_analysis)（下称 DSA，MIT 许可，Python，约 32 万行）的深度调研结论 + 本仓库现状摸底
- **范围声明**: 本计划覆盖八层能力的全量落地（用户决策：「全干」）。实施按里程碑垂直切片推进，每个里程碑独立可验证、可中止。

---

## 0. 摘要

把 DSA 经过生产验证的「数据 → 规则证据 → 决策契约与护栏 → 信号闭环」整套设计，用**纯 Swift 原生**方式移植进本项目，与已有的三条 AI 链路（趋势研究 / 下一小时研判 / 趋势跟踪）和 InvestmentIntelligence（DecisionCase Slice 1-7）对接，形成完整的投资决策引擎。

八层总览：

| 层 | 名称 | 一句话 | 里程碑 |
|---|---|---|---|
| L1 | 市场数据引擎 | A股免费行情源全量接入 + 统一契约 + 熔断/限速/缓存 | M1-M2 |
| L2 | 规则技术分析引擎 | MA/乖离/MACD/RSI/量价/支撑压力预计算 + 100 分制评分 + 逐条理由 | M3 |
| L3 | 决策契约与护栏 | canonical 分数带 + 市场 7 阶段 + 数据质量封顶 + LLM 后确定性护栏 | M4 |
| L6 | 信号闭环 | 结构化信号抽取 → 生命周期 → 市价结算 → 胜率记忆校准 | M5 |
| L4 | 策略技能系统 | 15 个策略技能（数据化 prompt + 元数据）+ 注入框架 + regime 路由 | M6 |
| L5 | Agent 运行时升级 | non-retriable 缓存 + BUDGET_SKIP + scope guard | M7 |
| L7 | 多 Agent 流水线 | Technical/Intel/Risk/Decision 证据链 + 分歧摘要 + 确定性兜底 | M8 |
| L8 | 回测层 | 策略技能规则级历史回测，验证技能参数 | M9 |

**实施顺序原则**: L6 信号闭环是价值核心且依赖最少（M5 排在技能/流水线之前）；L1 是数据地基排最前；L7 按基线文档 9.3 节「复制受控子集」原则独立新建，不重构现有 Agent。

---

## 1. 背景与调研结论

### 1.1 DSA 是什么

A股/港股/美股 AI 分析系统：抓数据 → 规则技术分析 → 多维新闻搜索 → LLM 生成「决策仪表盘」→ 推送。Agent 子系统约 1.5 万行（17 工具、15 YAML 策略、可选多 Agent 流水线）。工程成熟度高（契约意识、护栏、审计字段）。

### 1.2 四类可借鉴资产

1. **A股免费行情接口的接口级知识**（纯 HTTP + JSON/文本，Swift 可直接复刻，含字段映射与坑清单）
2. **「决策护栏」prompt 工程范式**（数据质量一等公民、LLM 后确定性护栏、canonical 分数带、市场阶段感知）
3. **Agent 运行时机制**（non-retriable 缓存、最小步预算、scope guard、证据 valid/invalid 分区、风险否决单向状态机）
4. **信号生命周期闭环**（信号抽取 → 反向失效 → 到期结算 → 胜率校准记忆）——本项目 Evidence Intelligence「跨运行持久化」缺口的现成产品形态

### 1.3 不借鉴的部分（见第 9 节「明确不做」）

Python 生态依赖、无 JSON mode 的文本解析输出（我们的提交式工具 + Validator 更先进）、雪球（双方实证不可行）、TDX/baostock 私有二进制协议、8000 字符截断式上下文注入。

---

## 2. 现状盘点与差距地图

### 2.1 已有资产（2026-08-28 摸底核对）

| 资产 | 位置 | 状态 |
|---|---|---|
| 三条 AI 链路（趋势研究/下一小时/跟踪） | `Core/TrendResearch/` + `Core/Trend/` + `Core/NextHourGuidance.swift` | 成熟，行为冻结基线 `*CharacterizationTests` |
| DecisionCase 状态机 + 复盘 | `Core/InvestmentIntelligence/`（Slice 1-7 完成） | 骨架完整：lifecycle/decisionState 正交、追加式事件、caseKey 去重、reviewDueAt、DecisionReview 六态结论 |
| 单股/指数行情 | `QiemanPlatformNativeClient.swift:1707`（腾讯指数）、`:1724`（东财 push2 单股）、`:1765`（腾讯单股） | 只用价格三件套，无估值/量比/涨跌停价 |
| Evidence Ledger / Claim 策略 / Validator | `Core/TrendResearch/` 各文件 | 运行内登记溯源完整；跨运行持久化缺失 |
| 基金穿透 | `FundLookThrough.swift`（944 行） | 成熟 |
| II Feature Flag | `InvestmentIntelligenceFeatureFlag.swift` | 默认 true（已转正） |

### 2.2 差距地图

| 层 | 现状 | 缺口 |
|---|---|---|
| L1 数据引擎 | 仅指数 + 单股价格 | 全市场快照、K线、市场广度、板块、热榜、基础设施全缺 |
| L2 规则技术分析 | 无 | 全缺（LLM 目前裸看数据） |
| L3 决策契约 | DecisionCase 的 decisionState 是组合级语义 | 标的级分数带/动作枚举/确定性护栏/市场阶段检测全缺 |
| L6 信号闭环 | DecisionReview 复盘基于指标快照 + Claim 结果，**触发条件是自然语言不可自动求值**（baseline 9.2 明确列为缺口） | 市价结算（入场/止损/目标触价判定）、胜率→置信度校准全缺 |
| L4 技能系统 | 无 | 全缺 |
| L5 运行时 | 有预算/超时/取消 | 无 non-retriable 缓存、无 BUDGET_SKIP 止损、无工具参数 scope 校验 |
| L7 多 Agent | 三个独立 Agent（趋势/下一小时/Case 研究） | 无流水线式证据链传递与分歧汇总 |
| L8 回测 | 无 | 全缺 |

### 2.3 与 feature/investment-intelligence-v2 分支的关系

该分支领先 main 189 提交，合并方向待定。本计划**全部在 main 主线实施**：八层与 v2 分支内容基本正交（v2 是既有 II 系统的重构线，本计划是新增能力层）。若后续合流 v2，冲突面预计集中在 `Core/InvestmentIntelligence/` 目录内的新增文件（新文件为主，天然冲突低）。

---

## 3. 总体架构

### 3.1 新增模块布局

```
macos-app/Core/
├── MarketData/                          # L1+L2（通用基础设施，不挂 II flag）
│   ├── MarketDataTypes.swift            # 统一契约：MarketQuote/MarketDailyBar/MarketBreadthStats
│   ├── MarketBoardRule.swift            # 板块识别 + 涨跌停价规则
│   ├── MarketDataSession.swift          # URLSession 封装：限速/超时/重试/UA/Referer/GBK
│   ├── MarketDataCircuitBreaker.swift   # 熔断器（3 失败/300s 冷却/半开）
│   ├── MarketDataCache.swift            # actor TTL 缓存 + last-good
│   ├── TencentQuoteProvider.swift       # qt.gtimg.cn 全字段
│   ├── SinaSnapshotProvider.swift       # 全市场分页快照（含估值）
│   ├── EastmoneyKlineProvider.swift     # push2his 日 K
│   ├── EastmoneySnapshotProvider.swift  # dataapi/xuangu 全市场快照（周末可用，备选源）
│   ├── NewsNowFeedProvider.swift        # 财经热榜（财联社/雪球热门/见闻/金十）
│   ├── MarketBreadthCalculator.swift    # 广度统计（本地计算）
│   ├── MarketDataEngine.swift           # actor 门面：fallback 链 + 缓存 + 熔断组装
│   └── TechnicalAnalysisEngine.swift    # L2 规则技术分析（纯函数）
├── InvestmentIntelligence/
│   ├── DecisionContract/                # L3
│   │   ├── CanonicalDecisionScale.swift # 五带/三态/八态 单一事实源
│   │   ├── MarketPhase.swift            # 7 阶段检测（北京时间）
│   │   ├── DataQualityStatus.swift      # ok/stale/fallback/missing/partial/estimated/failed
│   │   ├── DecisionScoreCalibration.swift # raw/adjusted/reason 审计
│   │   └── DecisionStructureGuardrail.swift # 结构稳定器
│   ├── MarketSignals/                   # L6
│   │   ├── MarketDecisionSignal.swift   # 信号模型（schemaVersion=1 起）
│   │   ├── MarketSignalExtractor.swift  # 从 TrendAnalysisReport 行动候选抽取
│   │   ├── MarketSignalSettler.swift    # 市价结算（先止损后止盈优先级）
│   │   ├── MarketSignalStore.swift      # 一对象一文件 + index 摘要
│   │   ├── SignalAccuracyMemory.swift   # 胜率分桶 + ≥30 样本校准
│   │   └── MarketSignalService.swift    # 编排：去重/反向失效/结算/校准查询
│   ├── StrategySkills/                  # L4
│   │   ├── StrategySkill.swift          # 模型 + 元数据
│   │   ├── StrategySkillLibrary.swift   # 15 策略内置库（Swift 常量）
│   │   ├── StrategySkillInjector.swift  # prompt 渲染 + 默认纪律基线
│   │   └── StrategySkillRouter.swift    # regime 路由（输入=TechnicalAnalysis 结果）
│   └── MarketResearchPipeline/          # L7
│       ├── AgentOpinion.swift           # 子 Agent 统一观点契约
│       ├── MarketResearchContext.swift  # 共享上下文袋（深拷贝隔离）
│       ├── TechnicalResearchAgent.swift
│       ├── IntelResearchAgent.swift     # Tavily + NewsNow
│       ├── RiskResearchAgent.swift
│       ├── DecisionSynthesisAgent.swift # 零工具纯综合
│       ├── OpinionDisagreementSummary.swift
│       ├── RiskOverrideStateMachine.swift # 单向保守转移校验
│       └── MarketResearchPipeline.swift # quick/standard/full/specialist 编排 + 兜底
├── TrendResearch/                       # L5 改造点（现有文件小改）
│   ├── TrendResearchToolResultCache.swift  # 新增：non-retriable 缓存
│   └── (TrendResearchAgent.swift 等)       # 小改：BUDGET_SKIP + scope guard
└── Backtest/                            # L8
    └── StrategyRuleBacktester.swift     # 规则级回测
```

### 3.2 依赖关系

```
L1 MarketData ──→ L2 TechnicalAnalysis ──→ L3 DecisionContract ──→ L7 Pipeline
      │                    │                      │                    │
      │                    ├──→ L4 Router ──→ L4 Skills ──→ L7        │
      │                    └──→ L8 Backtest ←── L4                     │
      └──→ L6 Settler（市价结算）──→ L6 SignalService ←── L3 Scale ←──┘
                                  ↑
                     TrendAnalysisReport（行动候选抽取源）
```

关键解耦点：
- L2/L3/L6 核心逻辑全部是**纯函数/纯模型**，不依赖网络，测试零 mock；
- L6 的结算器只吃 `MarketQuote`/`MarketDailyBar`，不依赖具体 Provider；
- L7 是「复制受控子集」的独立循环（复用 `OpenAICompatibleAgentClient`），不改 TrendResearchAgent。

### 3.3 全局约定

1. **命名**: 新类型不带 `Qieman` 前缀（通用层），II 子域内保持现有风格
2. **持久化**: 纯 JSON + 一对象一文件 + index 摘要（跟随 `DecisionCaseJournalStore` 模式）；所有新模型 `schemaVersion` 从 1 开始 + `decodeIfPresent` 兼容解码
3. **并发**: 纯计算 struct + Sendable；有状态的用 actor（缓存/引擎/服务）
4. **颜色**: 任何 UI 接入时红涨绿跌走 AppPalette
5. **flag**: `Core/MarketData/` 与纯计算模型不挂 flag（通用基础设施）；II 自动化入口（信号自动抽取、流水线调度）尊重 `InvestmentIntelligence.enabled`
6. **构建接线**: `build_macos_app.sh` 用 find 自动发现源文件，新文件无需登记；**不动 CLI**（新增命令不在本计划范围，`build_qieman_cli.sh` 无需更新）
7. **测试**: 全部 XCTest，放 `macos-app/Tests/`；外部接口解析用内联字符串 fixture（不动 SPM resources）

### 3.4 验证命令

```bash
cd macos-app && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 全绿基线
APP_VERSION=4.8.0 bash scripts/build_macos_app.sh                                     # 构建验证
```

注意：CLT 工具链缺 SwiftUI 宏插件，build/test 必须带 `DEVELOPER_DIR` 前缀；WMO 相关 warning 为已知误报，不当回归。

---

## 4. 里程碑总览

| 里程碑 | 内容 | 预估规模 | 验收 |
|---|---|---|---|
| M0 | 摸底 + 本计划文档 | 已完成 | — |
| M1 | L1 核心：契约/腾讯全字段/新浪快照/广度计算/熔断限速缓存 | ~1.8k 行 + 测试 | 新测试全绿；广度计算对拍 DSA 规则 |
| M2 | L1 完整：东财K线/NewsNow/Engine 门面/get_market_snapshot 接线 | ~1.5k 行 | Agent 工具返回广度+K线；快照测试更新 |
| M3 | L2 规则技术分析引擎 | ~1.2k 行 | 指标对拍手算 fixture；评分理由非空 |
| M4 | L3 决策契约 + 护栏 | ~1.3k 行 | 分数带/阶段/护栏规则全覆盖测试 |
| M5 | L6 信号闭环（**价值核心**） | ~1.6k 行 | 结算优先级/反向失效/校准函数测试；接入 AppModel |
| M6 | L4 策略技能系统 | ~1.4k 行 | 15 策略加载校验；注入渲染快照测试 |
| M7 | L5 Agent 运行时升级 | ~0.6k 行 | Characterization 基线不破；缓存命中测试 |
| M8 | L7 多 Agent 流水线 | ~2.5k 行 | Fake LLM 走通四档模式；兜底仪表盘测试 |
| M9 | L8 回测 + 文档同步（baseline 第 10 节、AGENTS.md、PROJECT_MAP） | ~0.8k 行 | 回测对拍；文档核对 |
| M10 | 扩展：token 型源 + 东财 nid 补丁（可选，需用户凭据） | ~1.5k 行 | 按 provider 协议增量接入 |

每个里程碑完成后：`swift test` 全绿 + 该里程碑新测试；不追求一次合入，按里程碑提交（提交标题面向用户可读）。

---

## 5. 分层详细设计

### 5.1 M1/M2 — L1 市场数据引擎

#### 5.1.1 统一契约（`MarketDataTypes.swift`）

```swift
/// 全市场统一实时行情（聚合各源字段，缺失为 nil，不编造）
struct MarketQuote: Codable, Hashable, Sendable, Identifiable {
    let code: String            // 规范化：6 位数字（A股）；"HK00700"（港股）
    var name: String
    var price: Double?
    var previousClose: Double?
    var changePct: Double?      // %
    var open/high/low: Double?
    var volume: Double?         // 股（统一，不用「手」）
    var amount: Double?         // 元
    var turnoverRate: Double?   // 换手率 %
    var peRatio/pbRatio/volumeRatio: Double?
    var totalMarketCap/circMarketCap: Double?  // 元
    var limitUpPrice/limitDownPrice: Double?   // 涨停/跌停价
    var isST: Bool
    var board: MarketBoard      // 上证主板/深主板/创业板/科创板/北交所
    var quotedAt: String
    var source: String          // "tencent"/"sina"/"eastmoney"
}

/// 统一日线（前复权）
struct MarketDailyBar: Codable, Hashable, Sendable {
    let date: String            // yyyy-MM-dd
    let open/high/low/close/volume/amount: Double
    let pctChg: Double?         // %
}

/// 市场广度（本地计算产物）
struct MarketBreadthStats: Codable, Hashable, Sendable {
    var upCount/downCount/flatCount: Int
    var limitUpCount/limitDownCount: Int
    var totalAmountYi: Double?      // 两市成交额（亿）
    var sampleCount: Int
    var computedAt: String
    var dataBoundary: String        // 数据边界说明（样本/排除项）
}
```

#### 5.1.2 板块与涨跌停规则（`MarketBoardRule.swift`，对拍 DSA `efinance_fetcher.py:1013-1032`）

| 规则 | 值 |
|---|---|
| 北交所（代码 4/8 开头 + 92） | ±30% |
| 科创板（688）／创业板（300/301） | ±20% |
| ST（名称含 ST，按新规 ST 主板 ±5%） | ±5% |
| 其余主板 | ±10% |
| 涨跌停价 | `floor(preClose × (1±ratio) × 100 + 0.5) / 100` |
| 判定容差 | `round(abs(preClose × (1±ratio) − limitPrice), 10)` 与现价差的绝对值 < 0.005 判定触板 |

#### 5.1.3 Provider 规格（endpoint 级，均免 token）

**腾讯全字段**（`TencentQuoteProvider`，主源）：
```
GET http://qt.gtimg.cn/q=sh600519,sz000001
Headers: Referer: http://finance.qq.com
响应: GBK 编码 v_sh600519="1~名称~代码~最新~昨收~今开~成交量~...~31涨跌额~32涨跌%~33最高~34最低~35量额三元组~38换手%~39PE~43振幅%~44流通市值(亿)~45总市值(亿)~46PB~47涨停价~48跌停价~49量比"
```
- GBK 解码：`CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)`
- 字段映射对拍 DSA `akshare_fetcher.py:1455-1481`；量纲：市值亿×1e8、成交量口径不稳定→以「流通市值/价格×换手率」交叉校验后决定是否 ×100（DSA `_normalize_tencent_volume` 同款逻辑）
- 校验 `fields.count >= 45`

**新浪全市场快照**（`SinaSnapshotProvider`，广度主源）：
```
GET https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/Market_Center.getHQNodeData
    ?page={n}&num=100&sort=symbol&asc=1&node=hs_a&symbol=&_s_r_a=page
Headers: Referer: https://vip.stock.finance.sina.com.cn/mkt/
分页终止: len(items) < 100
```
- **坑**：`mktcap`/`nmc` 单位万元 → ×1e4；无 prevClose → `preClose = price / (1 + changePct/100)` 反推（广度计算用反推值可接受，注明 dataBoundary）

**东财全市场快照**（`EastmoneySnapshotProvider`，广度备选源，周末可用）：
```
GET https://data.eastmoney.com/dataapi/xuangu/list
    ?st=SECURITY_CODE&sr=1&ps=500&p={page}
    &sty=SECUCODE,SECURITY_CODE,SECURITY_NAME_ABBR,NEW_PRICE,CHANGE_RATE,VOLUME_RATIO,DEAL_AMOUNT,TURNOVERRATE,PE9,PBNEWMRQ,TOTAL_MARKET_CAP,CIRCULATION_MARKET_CAP
    &filter=(MARKET+in+("上交所主板","深交所主板","深交所创业板","上交所科创板","北交所"))
    &source=SELECT_SECURITIES&client=WEB
Headers: Referer: https://data.eastmoney.com/xuangu/
```
- **必须照抄 DSA 限速**：全局互斥 + 最小间隔 1.0s + 抖动 0.3s；Retry total=2, backoff=0.5, status_forcelist=[429,500,502,503,504]
- 分页终止：`page × ps >= data.result.count`

**东财日 K**（`EastmoneyKlineProvider`，主源）：
```
GET https://push2his.eastmoney.com/api/qt/stock/kline/get
    ?secid={1|0}.{code}&klt=101&fqt=1&beg=YYYYMMDD&end=YYYYMMDD
Headers: Referer: https://quote.eastmoney.com/  Accept: application/json
```
- secid 规则：沪（6/5/9 开头 + 688）= `1.`，深 = `0.`；返回中文列名 `日期/开盘/收盘/最高/最低/成交量/成交额/...` 按序映射
- 坑：成交量单位「手」→ ×100

**腾讯日 K**（备选，结构化 JSON 更稳）：
```
GET https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param={symbol},day,{start},{end},{count},qfq
```
- 单次上限 800 根；`count = max(30, min(800, 日历天数×1.8+20))`；响应 `data.{symbol}.qfqday`（或 `day`）；量纲手→×100

**NewsNow 热榜**（`NewsNowFeedProvider`）：
```
GET https://newsnow.busiyi.world/api/s?id=cls-hot|xueqiu-hotstock|wallstreetcn-quick|jin10
```
- 返回 JSON `{ code, data: [{ id, title, url, ... }] }`；UA 伪装浏览器、不跟随重定向；失败静默降级（热榜是增强项，不阻塞任何主流程）
- 定位：进 TrendResearch 的 web_search 证据面 + L7 Intel Agent 输入

#### 5.1.4 基础设施

- `MarketDataSession`：按 host 的串行限速（腾讯 0.3s / 新浪 0.3s / 东财 1.0s + 抖动）、8s 超时、随机 UA 池、Referer 注入、GBK 解码
- `MarketDataCircuitBreaker`：按 `(provider, capability)` 维度，3 失败 / 300s 冷却 / 半开 1 次探测
- `MarketDataCache`（actor）：TTL 分级（quote 60s / snapshot 600s / kline 1800s / newsnow 300s），last-good 磁盘快照（原子写 tmp+replace，目录 `ApplicationDataController` 管辖）
- `MarketDataEngine`（actor 门面）：quote 链 `tencent → eastmoney`（字段级补充合并）；kline 链 `eastmoney → tencent`；snapshot 链 `sina → eastmoney`；全部失败抛聚合错误（含每源失败原因）

#### 5.1.5 接线点

1. `MarketSnapshotTool`（`TrendResearchToolRegistry.swift:377`）升级：新增 `include_breadth` 参数，返回广度统计 + dataBoundary 警告（沿用现有 warnings 机制）
2. 新增 TrendResearch 工具 `get_daily_kline`（参数 code/days，返回 TA 引擎计算后的摘要而非原始 K 线——工具层 token 卫生，对齐 DSA「工具返回压缩产物」）
3. `NextHourGuidanceContext` 注入 `MarketBreadthStats`（盘中广度是下一小时研判的关键背景）
4. `AppModel/MarketData.swift` 新控制器：自动刷新调度 + 状态暴露

#### 5.1.6 测试（`Tests/MarketDataTests/`）

- 解析测试：内联真实响应样本（腾讯 GBK 字符串、新浪 JSON、东财 K 线 JSON）→ 字段映射断言（含万元/手换算、量纲交叉校验分支）
- 广度测试：构造含各板块/ST/触板样本的 quote 列表 → up/down/limit 计数对拍手算
- 熔断/缓存：行为测试（3 失败开熔断、半开恢复、TTL 过期）
- Engine fallback：注入 fake provider 链，断言降级顺序与字段合并

---

### 5.2 M3 — L2 规则技术分析引擎

`TechnicalAnalysisEngine.swift`，纯函数 `(code: String, bars: [MarketDailyBar], quote: MarketQuote?) -> TechnicalAnalysisResult`。参数对拍 DSA `stock_analyzer.py`：

| 模块 | 参数/规则 |
|---|---|
| 均线 | MA5/10/20/60；排列 7 态（强多/多/弱多/震荡/弱空/空/强空，MA5>MA10>MA20 且 MA20 上行=强多…） |
| 乖离率 | bias = (C−MA)/MA×100，MA5/10/20 三条 |
| 量能 | 量比 = 当日量 / 5 日均量；缩量 <0.7、放量 >1.5；量价 5 态：缩量回调(最佳)/放量上涨/平量/无量上涨/放量下跌 |
| 支撑压力 | MA5/10/20 支撑（容忍 ±2%）+ 近期低/高点；给出 support/resistance 价格 |
| MACD | 12/26/9；DIF/DEA/柱；7 态（零上金叉最强 → 零下死叉最弱） |
| RSI | 6/12/24 三周期；>70 超买、<30 超卖 |
| 评分 | 趋势 30 + 乖离 20（<0 回踩加分；>5% 严限追高；强趋势阈值×1.5 放宽）+ 量能 15（缩量回调 15 > 放量上涨 12 > 平量 10 > 无量上涨 6 > 放量下跌 0）+ 支撑 10（MA5 支撑 5 + MA10 支撑 5）+ MACD 15（零上金叉 15 > 金叉 12 > 上穿零轴 10 > … > 死叉 0）+ RSI 10（超卖 10 > 强势 8 > 中性 5 > 弱势 3 > 超买 0） |

```swift
struct TechnicalAnalysisResult: Codable, Hashable, Sendable {
    var score: Int                    // 0-100 加权
    var signal: CanonicalSignal       // 由 score 派生（走 L3 scale）
    var maAlignment: MAAlignment      // 供 L4 regime 路由
    var volumeStatus: VolumeStatus
    var support/resistance: Double?
    var biasMA5: Double?
    var macdState/rsiState: String
    var reasons: [TechnicalReason]    // ✅/❌ 逐条（"✅ 缩量回调，主力洗盘"）
    var riskFactors: [TechnicalReason]// （"❌ 乖离率过高，严禁追高"）
    var dataBoundary: String          // 样本数不足/实时价缺失等边界
}
```

**一致性消毒**（对拍 DSA `_sanitize_trend_analysis_for_prompt`）：注入 prompt 前剔除与主信号冲突的理由（如偏空时剔除看多结构理由），并把剔除记录写入 `promptConsistencyNotes`。

**与 Evidence Ledger 对接**：TA 结果注册为本地确定性证据（Evidence ID 规则：`ta:{code}:{date}`，sourceTier=local-computed），为 Claim 评估提供零 token 证据源——这是 L2 对本项目独有的增量价值。

测试：手算 fixture（构造 20-60 根已知 K 线，MA/MACD/RSI 数值对拍 Excel 级手算）；评分权重求和=100；理由非空；一致性消毒的正反用例。

---

### 5.3 M4 — L3 决策契约与护栏

#### 5.3.1 CanonicalDecisionScale（单一事实源，对拍 DSA `decision_scale.py`）

| 分数带 | action（八态） | decisionType（三态） |
|---|---|---|
| 80-100 | buy | buy |
| 60-79 | buy / add | buy |
| 40-59 | watch | hold |
| 20-39 | reduce | sell |
| 0-19 | sell / avoid | sell |

- 八态：buy/add/hold/reduce/sell/watch/avoid/alert；三态：buy/hold/sell（统计稳定用）
- **核心规则**：score ≥60 但 action∈{hold,watch} 或 score <40 但 action∈{hold,watch} → 必须携带 `guardrailReason`（把「模型自相矛盾」变成可审计字段）
- scale 同时被 prompt 注入（L4/L7）、TA 引擎（L2 派生 signal）、信号抽取（L6）三处消费，永不漂移

#### 5.3.2 MarketPhase（7 态，北京时间）

| 态 | 判定 |
|---|---|
| premarket | 交易日 <09:30（含 9:15-9:25 集合竞价） |
| intraday | 09:30-11:30 / 13:00-15:00 之间（含边界语义） |
| lunchBreak | 11:30-13:00 |
| closingAuction | 14:57-15:00 |
| postmarket | 交易日 ≥15:00 |
| nonTrading | 周末/节假日（节假日历从东财接口或内置表，v1 用「周一至五+已知节假日表」近似，dataBoundary 注明） |
| unknown | 无法判定 |

每态携带**行为禁令文案**（供 prompt 注入）：
- premarket：「不得描述今日走势已经发生；只能基于上一完整交易日生成开盘计划/观察价位/风险预案」
- intraday：「聚焦当前盘中状态与下一次检查点；不得使用盘后复盘口吻」
- 输出契约含 `nextCheckTime`（对接 NextHourGuidance 的调度窗口）

#### 5.3.3 DataQualityStatus → 置信度封顶

```
enum DataQualityStatus: ok/stale/fallback/missing/partial/estimated/failed
核心数据（quote/dailyBars/technical）任一 ∈ CORE_DEGRADED_STATUSES(stale/fallback/missing/partial/estimated/failed)
  → confidenceLevel 封顶 medium；两个以上 degraded → 封顶 low
```
与现有 `TrendSourceFreshnessPolicy` 对齐：freshness 状态映射到 DataQualityStatus，不另起炉灶。

#### 5.3.4 结构稳定器（`DecisionStructureGuardrail.swift`，对拍 DSA `analyzer.py:1000-1175`）

输入：LLM 决策（score/action/confidence）+ TA 结果（support/resistance）+ 资金流信号（可选，缺省 neutral）。位置判定容差带：

```
brokeSupport:  price < 0.985 × support
nearSupport:   price ≤ 1.03 × support
breakout:      price > 1.01 × resistance
nearResist:    price ≥ 0.97 × resistance
midRange:      其余
```

降级矩阵（全部单向保守，经 `RiskOverrideStateMachine` 校验转移合法性）：

| 原决策 | 位置 | 资金流 | 结果 |
|---|---|---|---|
| buy | nearResist | 非流入 | → hold |
| buy | midRange | neutral | → hold |
| buy | 任意 | 流出未突破 | → hold |
| buy | 任意 | unavailable | → hold（「买入缺资金面确认，先观察」） |
| sell | nearSupport | 非流出 + 无重大风险 | → hold（洗盘观察） |
| sell | 任意 | 流入未破位 | → hold |

降级时：score 钳制到 45-59 观望带；写入 `DecisionScoreCalibration{rawScore, adjustedScore, guardrailReason, structureSnapshot}`（审计字段，每次修正一条记录）；同步 coreConclusion 的空仓/持仓双轨文案与信号 emoji。

测试：六条降级规则全覆盖 + 容差带边界值 + score 钳制 + 审计字段完整性 + 转移合法性校验（非法转移抛错）。

---

### 5.4 M5 — L6 信号闭环（价值核心）

#### 5.4.1 信号模型（`MarketDecisionSignal.swift`）

```swift
struct MarketDecisionSignal: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    let id: UUID
    let schemaVersion: Int
    let dedupKey: String          // kind|subjectCode|direction|date（当日去重）
    let subjectCode: String       // A股代码 / 基金代码
    let subjectName: String
    let subjectMarket: StockMarket?

    let direction: CanonicalDecisionType   // buy/hold/sell（三态，统计稳定）
    let action: CanonicalAction            // 八态
    let score: Int
    let confidence: Double                 // 0-1（校准后）
    let rawConfidence: Double              // 校准前（审计）

    // 结构化价格条件（结算依据；不可解析的自然语言条件放 watchConditions）
    let entryLow/entryHigh: Double?
    let stopLoss/targetPrice: Double?
    let watchConditions: [String]
    let invalidatingConditions: [String]

    let reason: String
    let riskSummary: [String]
    let evidenceIDs: [String]              // 关联 Evidence Ledger ID
    let dataQualitySummary: String
    let sourceKind: SignalSourceKind       // trendReport / pipeline / manual

    let createdAt: String
    let reviewDueAt: String?               // 复查时间（direction 映射：buy/sell 3 天，watch 7 天）
    var status: SignalStatus               // active/settledWin/settledLoss/expired/invalidated
    var settlement: SignalSettlement?      // 结算详情
    var events: [SignalEvent]              // 追加式审计（对齐 DecisionCaseEvent 模式）
}

struct SignalSettlement: Codable, Hashable, Sendable {
    let settledAt: String
    let outcome: SignalOutcome   // hitTarget/hitStop/expiredUnresolved/superseded/insufficientData
    let settlePrice: Double?
    let settleDate: String?
    let maxFavorablePct: Double?  // 结算窗口内最大有利波动（质量维度，不只胜/负）
    let maxAdversePct: Double?
    let note: String
}
```

#### 5.4.2 抽取（`MarketSignalExtractor.swift`）

**源 1（本里程碑）**: `TrendAnalysisReport` 行动候选（现有模型，triggerConditions/invalidatingConditions 是自然语言）：
- 方向/分数/置信度直接映射；**价格条件用受控正则解析**（「回踩 X.XX 附近」「跌破 X.XX」「涨至 X.XX」→ entry/stop/target），解析失败的条目仍然建信号但价格条件为 nil（结算走 expiredUnresolved，dataBoundary 注明「价格条件不可自动求值」）
- 这正是 baseline 9.2「结构化触发条件求值」缺口的落地路径：**从现在起新建的行动候选要求 prompt 输出结构化价格字段**（`TrendResearchPromptBuilder` 行动候选 schema 增加 entryLow/entryHigh/stopLoss/targetPrice 可选字段 + Validator 校验数值合理性），旧报告自然语言兜底解析

**源 2（M8 后）**: L7 决策仪表盘直接产出结构化信号（天然带价格条件）

抽取纪律（对拍 DSA）：confidence 高→0.8 / 中→0.6 / 低→0.4；evidenceIDs 全量关联；score 与 action 不一致时抽取器按 canonical scale 强制对齐并记 `actionAdjustmentReason`。

#### 5.4.3 生命周期与结算（`MarketSignalSettler.swift`）

状态机：`active → settledWin/settledLoss（触价结算）| expired（到期未触发）| invalidated（反向信号出现 / 用户关闭）`

结算规则（优先级从高到低）：
1. **同日先止损后止盈**（保守口径：开盘价直接跳空穿越时按开盘价结算）
2. 结算数据源：日 K（`MarketDailyBar`）为主，reviewDueAt 检查时若无当日 K 线用 quote 兜底（dataBoundary 注明）
3. watch 类信号（无价格条件）到期 → expiredUnresolved，不计入胜率分子但计入样本（防「只统计敢报价的」幸存者偏差）
4. 反向失效：同标的出现反方向 active 信号 → 旧信号 invalidated(superseded)，事件链记录
5. 结算窗口 = createdAt → reviewDueAt + 缓冲 2 个交易日

#### 5.4.4 胜率记忆（`SignalAccuracyMemory.swift`，对拍 DSA `memory.py` + 校准扩展）

- 分桶维度：`(direction, subjectCode)`、`(direction, sourceKind)`、全局三层
- 每桶 ≥30 样本才启用校准（不足时返回 1.0 不干预）
- 校准函数：`calibrated = raw × clamp(bucketAccuracy, 0.3, 1.2)`——历史胜率 <30% 强制打 3 折以下，>80% 允许小幅上浮
- 防过拟合：校准系数落盘 + 变更事件审计；样本窗口默认近 180 天
- 消费方：L7 DecisionAgent prompt 注入「该类信号历史胜率」；信号展示层标注「历史同类胜率 62%（45 样本）」

#### 5.4.5 Store 与服务

- `MarketSignalStore`：`market-signals/{id}.json` 一对象一文件 + `index.json` 摘要（active 列表 + 桶统计缓存），原子写
- `MarketSignalService`（actor）：`ingest(report:)`（抽取+去重+反向失效）、`settleIfNeeded(asOf:)`（每日盘后跑一次，接 `PersonalAssetAutomation` 调度）、`calibration(for:)`
- 与 DecisionCase 关系：**正交互补**——Case 是组合级决策事项（用户处置中心），Signal 是标的级市场判定（自动结算中心）；UI 并列展示，数据不互写（信号不自动建 Case，反之亦然）

测试：抽取（结构化字段 + 自然语言正则正反例）、结算优先级（同日双触→止损胜、跳空→开盘价）、反向失效链、校准函数边界（<30 样本、上下限钳制）、Store 读写与 index 一致性、V1 兼容解码。

---

### 5.5 M6 — L4 策略技能系统

#### 5.5.1 形态决策：Swift 常量库（不引入 YAML）

理由：全仓库纯 JSON/Swift、无 YAML 解析器；技能文件主要消费方是 prompt 注入（编译期校验优于运行时解析）。模型保留 DSA 元数据语义：

```swift
struct StrategySkill: Codable, Hashable, Sendable, Identifiable {
    let id: String                // "dragon_head"
    let displayName: String       // "龙头策略"
    let category: SkillCategory   // trend/pattern/sentiment/fundamental
    let coreRules: [Int]          // 关联默认纪律基线条目编号
    let requiredTools: [String]   // ["get_realtime_quote","get_sector_rankings"] → 限制工具子集
    let aliases: [String]
    let defaultPriority: Int
    let marketRegimes: [MarketRegime]  // trendingUp/trendingDown/sideways/volatile/sectorHot
    let instructions: String      // 完整策略 prompt（从 DSA 15 个 YAML 全文移植+本地化）
    var isBuiltIn: Bool { true }
}
```

#### 5.5.2 15 策略清单（移植自 DSA `strategies/*.yaml`）

bull_trend 多头趋势 / ma_golden_cross 均线金叉 / shrink_pullback 缩量回踩（量化条件：回踩 MA5 误差 1% 内、回调量 <5 日均量 70%、止损 MA20）/ volume_breakout 放量突破 / hot_theme 热点题材 / event_driven 事件驱动 / growth_quality 成长质量 / expectation_repricing 预期重估 / bottom_volume 底部放量 / dragon_head 龙头策略 / one_yang_three_yin 一阳三阴 / box_oscillation 箱体震荡 / chan_theory 缠论 / wave_theory 波浪理论 / emotion_cycle 情绪周期

移植纪律：instructions 文本保留 DSA 的量化条件与评分调整（sentiment_score +10 等），适配本项目工具名（get_market_snapshot/get_daily_kline）；MIT 来源在文件头注释标注。

#### 5.5.3 注入框架（`StrategySkillInjector.swift`）

- 显式选择技能 → 只注入所选；**未显式选择 → 注入默认纪律基线**（`CORE_TRADING_SKILL_POLICY` 7 条：乖离 >5% 严禁追高 / 多头排列条件 / 筹码集中度标准 / 回踩买点偏好 / 风险排查五项 / 估值关注 / 强趋势放宽），不叠加默认技能集（避免「选了龙头还被塞趋势基线」）
- 渲染格式：`## 激活的交易技能` 分组编号块（技能名/适用场景/关联理念/全文）
- `StrategySkillRouter`：输入 TA 结果（maAlignment/trendScore/volumeStatus）→ regime 判定（对拍 DSA router.py：MA 多头+量能配合=trendingUp；空头排列=trendingDown；箱体=sideways；巨量分歧=volatile；板块领涨=sectorHot 需板块数据）→ 输出建议激活的技能集

#### 5.5.4 消费方

- L7 各子 Agent（skill Agent 按 requiredTools 限制工具集）
- TrendResearch 的 prompt 可选注入（v1 只给 L7 用，避免动趋势链路的行为冻结基线）

测试：15 技能加载完整性校验（id 唯一/instructions 非空/regime 合法）；注入渲染快照；regime 路由规则表；「显式选择不注入基线」语义。

---

### 5.6 M7 — L5 Agent 运行时升级（TrendResearch 小改，红线：不破行为冻结基线）

1. **`TrendResearchToolResultCache`**（actor，新增文件）：
   - key = `toolName + canonicalJSON(arguments)`；参数规范化：代码统一大写、去零填充变体（`0700.HK`/`hk700` → `HK00700`）、数字/布尔键排序稳定序列化
   - 缓存超时/取消结果并标记 `retriable=false`：LLM 重发同一调用直接命中缓存的失败信封，不再发起第二次执行（防重复副作用与预算浪费）
   - 正常结果短 TTL 缓存（60s，快照语义下幂等工具才缓存；isError 结果不落盘）
2. **BUDGET_SKIP**：`TrendResearchAgent` 步进前检查 `remainingBudget < 8s` → 直接终止并返回 `budgetSkip` 失败原因（区别于 `timeout`），不发注定超时的计费请求；失败原因枚举扩展进 HarnessState，**不改既有 timeout 语义**
3. **Scope guard**：`MarketSnapshotTool` 的 `asset_codes` 参数校验——请求的代码必须 ⊆ snapshot 冻结范围，越界返回 `scopeViolation`（retriable=false）+ 明确错误信封（复用现有 envelope.error 模式）

验证：`TrendResearchAgentCharacterizationTests` 等既有基线**必须全绿**（这是本里程碑的硬验收）；新增缓存命中/BUDGET_SKIP/scope 越界三组测试。

---

### 5.7 M8 — L7 多 Agent 流水线

#### 5.7.1 原则（baseline 9.3）

复制受控子集、独立循环（参考 `NextHourGuidanceAgent` 做法），**不重构 TrendResearchAgent、不提前抽通用 Harness**。复用 `OpenAICompatibleAgentClient` 与 `TrendEvidenceLedger`。

#### 5.7.2 契约

```swift
struct AgentOpinion: Codable, Hashable, Sendable {
    let agentName: String            // technical/intel/risk/[skillId]/decision
    let signal: CanonicalDecisionType
    let confidence: Double           // 构造时 clamp 0-1 + 记录输入合法性
    let confidenceWasValid: Bool
    let reasoning: String
    let keyLevels: KeyLevels?        // support/resistance/stopLoss
    let riskFlags: [RiskFlag]?       // RiskAgent 专属（severity + vetoBuy + adjustment）
    let raw: AgentJSONValue?         // 原始输出（审计）
}

struct MarketResearchContext {   // 共享上下文袋
    var query: String
    var subjectCode: String
    var prefetchedData: [String: AgentJSONValue]  // L1/L2 预取（行情/K线/TA 结果/广度）
    var opinions: [AgentOpinion]
    var riskFlags: [RiskFlag]
    var meta: [String: String]
}
```

#### 5.7.3 四档模式与阶段

```
quick:     Technical → Decision                                (~2 LLM 调用)
standard:  Technical → Intel → Decision
full:      Technical → Intel → Risk → Decision
specialist: Technical → Intel → Risk → [skill 并发批 1-4] → Decision
```

- 子 Agent 工具集：Technical{get_daily_kline, get_market_snapshot}；Intel{web_search, NewsNow}；Risk{web_search}；skill 按 `requiredTools`；Decision **零工具纯综合**
- 预取注入：L1/L2 数据由 AppModel 先算好放进 context，子 Agent 用 `[Pre-fetched: key]` 消息接收（**结构化 AgentJSONValue 传递，不学 DSA 的 8000 字符截断**）
- 阶段预算：pipeline 总超时内每阶段最小预算 15s（不足 → 跳过该阶段记 budgetSkip）；非关键阶段（intel/risk/skill）失败降级继续，关键阶段（technical/decision）失败终止
- skill 并发批：每个 skill 拿 context **深拷贝**（防并发写共享）；结果按原序重组；非法 signal 的 opinion 移入 diagnostics 桶（**不进证据链**），Decision prompt 注明「invalid 观点仅供 dataLimitations 标注，不得作为决策依据」

#### 5.7.4 Decision 综合与护栏

- 权重指南进 prompt：technical ~40% / intel ~30% / risk ~30%（任一 high 风险 → 信号封顶 hold）；skill 观点 20%
- 分歧摘要注入：bullish/bearish/neutral 分桶 + 风险覆盖计划（`OpinionDisagreementSummary`）
- **风险否决单向状态机**（`RiskOverrideStateMachine`）：只允许 buy→hold、sell→hold 方向的保守转移（buy→sell 直接跳跃非法）；转移经显式校验，非法抛错；否决后注入「风控接管：最终信号已下调为 X」
- **确定性兜底**：Decision JSON 解析失败 → 从 opinions 代码侧组装保守仪表盘（signal=多数决、confidence=平均×0.6、标注「降级生成」）——LLM 挂了产品不挂
- 输出：决策仪表盘结构（coreConclusion 双轨建议 / dataPerspective（直接嵌 L2 TA 结果）/ battlePlan（精确价格狙击点）/ phaseDecision 七字段含 nextCheckTime / signalAttribution 贡献度归一化 Σ=100）+ 自动喂给 L6 信号抽取（源 2）

#### 5.7.5 prompt 工程要点（移植 DSA 精华）

- 新闻时间硬约束：每条风险/催化必须带 YYYY-MM-DD，超窗或日期未知一律忽略
- 数据缺失行为级指令：「写『数据缺失，无法判断』，禁止编造」「筹码不可用只说明一次」
- 市场角色注入（A 股 T+1/涨跌停制度约束）
- 评分标准五档 ✅⚠️❌ 清单 + 可操作性稳定性约束（禁止单日涨跌导致建议剧烈翻转）

测试：Fake LLM（复用 `FakeTrendResearchAgent` 模式）走通四档；分歧摘要桶划分；风险否决状态机全转移矩阵；兜底仪表盘字段完整性；budgetSkip 降级路径。

---

### 5.8 M9 — L8 回测层 + 文档同步

`StrategyRuleBacktester.swift`：规则级回测——对带量化条件的技能（ma_golden_cross/shrink_pullback/volume_breakout/bottom_volume/box_oscillation），在其规则可计算的前提下于历史 K 线上逐日生成信号（复用 L2 TA 引擎 + 技能量化条件求值器），用固定 5%/8% 止损止盈或 MA20 破位平仓，输出：

```
struct BacktestReport {
    let skillID: String; let period: DateRange; let sampleCount: Int
    let winRate: Double; let profitFactor: Double     // 总盈利/总亏损
    let avgHoldingDays: Int; let maxDrawdownPct: Double
    let perSignal: [BacktestTrade]                     // 逐笔（可审计）
    let dataBoundary: String
}
```

定位：**验证技能参数**（技能 prompt 里的量化条件是否有统计优势），不做参数寻优（防过拟合；参数寻优留待未来，参考 DSA 生态的 AlphaEvo 思路）。样本 <30 输出「样本不足」不结论。

文档同步义务：`docs/ai-pipeline-baseline.md` 新增第 10 节（决策引擎链路契约）；AGENTS.md 目录表更新；PROJECT_MAP.md 更新。

---

### 5.9 M10 — 扩展（可选，按 provider 协议增量接入）

| 源 | 用途 | 接入方式 | 前置 |
|---|---|---|---|
| Tushare Pro | 稳定日线/实时/日历 | `POST http://api.tushare.pro` body `{api_name, token, params, fields}`，响应 `{code,msg,data:{fields,items}}`；80 次/分令牌桶；vol×100/amount×1000 | 用户 token |
| TickFlow | 全市场快照/申万板块 | SDK 资源型 API 的 HTTP 等价 | 用户 token |
| Longbridge | 港美股补齐 PE/量比/资金流 | `https://openapi.longbridge.cn` + 官方签名 | OAuth 凭据 |
| Futu OpenD | 港股基本面/派息/资金流 | 本地网关 `127.0.0.1:11111`（macOS App 天然适配） | 用户装 OpenD |
| 东财 nid 补丁 | push2 被反爬时的兜底 | `anonflow2.eastmoney.com/backend/api/webreport` 换 nid18 cookie（纯 HTTP 无 JS），TTL 20s | 仅被反爬时启用 |

---

## 6. 实施顺序与依赖

```
M1 ──→ M2 ──→ M3 ──→ M4 ──→ M5 ──→ M8 ──→ M9
       │             ↑              ↑
       └─────────────┘(M5 结算依赖 K线) └(M8 依赖 M3/M4/M6)
M6（可与 M4/M5 并行）──→ M8
M7（独立，随时可插入，红线是不破基线）
M10（最后，凭据就绪后）
```

推荐执行序：**M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9 → M10**。每个里程碑独立提交、独立可回滚；M5 完成后即具备独立价值（信号闭环转起来），即使后续中断也不留半成品。

---

## 7. 必须保持的既有契约（红线清单）

1. **时间尺度隔离**（baseline 第 8 节）：长期/盘中决策隔离不被新层打破；L6 信号与 L7 仪表盘标注自己的时间尺度；UI 并列展示
2. **互斥 guard**：`runNextHourGuidanceIfNeeded` / `runDailyTrendAnalysisIfNeeded` 的双向互斥语义不变；新增调度（信号结算/流水线）接入现有 60s 轮询 loop 时遵守同样的顺序 await 模式
3. **行为冻结基线**：`TrendResearchAgentCharacterizationTests` 等测试必须始终全绿；M7 只做加法
4. **Evidence ID 规则**（baseline 第 6 节）：新增证据类型（TA 结果 `ta:{code}:{date}`）遵循稳定 ID 原则
5. **Validator 校验链**（baseline 第 7 节）：行动候选新增结构化价格字段是**可选字段**，不破坏 W4 结论明确性契约与既有校验项
6. **提交式结构化输出**：不引入「文本解析 JSON」作为主路径（DSA 的短板）；L7 输出走校验器
7. **数据持久化**：纯 JSON Store、无 SQLite；一对象一文件 + index；schemaVersion + 兼容解码
8. **红涨绿跌**（AppPalette）；**纯 Swift 运行时**（不引入 Python/JS 依赖）
9. **CLI 契约不动**：本计划不改 CLI 命令；`build_qieman_cli.sh` 无需更新
10. **隐私**：新增工具/Agent 的数据面只有公开行情与新闻，不含用户持仓隐私（L7 预取数据经与 TrendResearchSnapshot 同样的隐私过滤原则）

---

## 8. 风险与坑

| 风险 | 缓解 |
|---|---|
| 东财/新浪接口反爬或改版 | 多源 fallback（腾讯↔东财↔新浪）、熔断、dataBoundary 注明；M10 nid 补丁兜底；接口契约测试用内联 fixture 锁行为，上游改版时测试红得快 |
| 腾讯 GBK / 单位混乱（手/股/万元/亿） | 统一契约层一次换算 + 量纲交叉校验；解析测试覆盖每个坑 |
| 假日历不准（nonTrading 误判） | v1 内置节假日表 + dataBoundary；结算对「误判交易日」容错（无 K 线顺延） |
| 信号结算的幸存者偏差 | watch 类信号计入样本不计入分子；校准窗口 180 天滚动 |
| L7 token 成本失控 | 四档模式分级；阶段最小预算；预算耗尽确定性兜底；用户可配 `AGENT_RESEARCH_MODE` |
| M7 动 TrendResearchAgent 伤基线 | 只加不改：新文件承载缓存；Agent 内仅插入预算检查点；Characterization 测试全绿为硬门禁 |
| 与 v2 分支合流冲突 | 全部新增文件为主；修改现有文件处（ToolRegistry/AppModel）改动最小化并列出清单 |

---

## 9. 明确不做的事

1. 不引入 Python/akshare/efinance 依赖——只取接口参数与字段映射知识
2. 不复刻 TDX/baostock 私有二进制协议、雪球（WAF 不可行，双方实证）
3. 不用「150 行 JSON 模板 + 文本解析」替代我们的提交式工具 + Validator（DSA 短板，不反向学习）
4. 不做 8000 字符截断式上下文注入（结构化传递）
5. 不做 token 级流式 SSE 与 bot 接入（产品形态不匹配，进度事件留待未来 UI 需要）
6. 不做回测参数寻优/策略自动进化（AlphaEvo 方向，留待 L8 验证有价值后评估）
7. 信号不自动建 DecisionCase、不自动触发交易（用户处置权红线，对齐「AI 行动跟踪单一路径」既有约定）

---

## 10. 验收标准（总）

1. `swift test` 全绿（含全部新增测试与既有 Characterization 基线）
2. `APP_VERSION=x.y.z bash scripts/build_macos_app.sh` 构建通过
3. 端到端冒烟：真实行情源下广度/K线/TA/信号结算各跑通一次（网络测试单独跑，不进 CI 基线）
4. 每个里程碑有独立提交，提交标题面向用户可读（Release notes 从 commit 标题生成的既有约定）
5. 文档同步完成：baseline 第 10 节 + AGENTS.md + PROJECT_MAP.md

---

## 附：DSA 参考文件索引（实施时查）

- 行情接口与字段映射：`data_provider/akshare_fetcher.py:1355-1506`（腾讯）、`src/services/screening/snapshot.py:425-523`（新浪/东财快照）、`efinance_fetcher.py:974-1061`（广度+涨跌停规则）、`tencent_fetcher.py`（K线兜底）
- 决策契约与护栏：`src/schemas/decision_scale.py`、`src/analyzer.py:1000-1613`（护栏）、`phase_decision_guardrail.py`
- 信号闭环：`src/services/decision_signal_extractor.py:43-168`、`decision_signal_service.py:120-168`
- 技能系统：`strategies/*.yaml`（15 个）、`src/agent/skills/defaults.py:26-59`、`router.py`
- Agent 运行时：`src/agent/runner.py:326-889`（循环/预算/并行/缓存）、`execution.py`（non-retriable 缓存）
- 多 Agent：`src/agent/orchestrator.py`、`agents/*.py`、`risk_override.py`
- 本仓库克隆位于 `/tmp/daily_stock_analysis`（重新克隆：`git clone ssh://git@ssh.github.com:443/ZhuLinsen/daily_stock_analysis.git`）
