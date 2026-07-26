# 趋势研究 Agent 可信度与资金安全改进方案

日期：2026-07-26  
项目：qieman-manager-dashboard（macOS SwiftUI）

## 一、范围与结论

本文主要评审和改进内嵌式趋势研究 Agent：

- 进程内 OpenAI-compatible `chat/completions`
- 只读工具循环
- `submit_trend_report` 结构化提交

同时覆盖 v3.9.5 已上线的“下一小时买卖建议”Agent。后者已经具备更严格的行动级门槛，包括行情刷新、基金穿透、两次最近一天搜索、标的行情证据、网页证据和缺证据时强制 `hold`。本方案不重复实现另一套规则，而是要求两个 Agent 复用同一套数据新鲜度、证据约束、审计和评测基础设施。

结论：

1. 当前实现已经具备较好的结构纪律、证据防伪和失败保护，但仍不能称为“高可信度投资判断”。
2. 首要风险不是模型措辞，而是数据状态不透明、方向性结论缺少完整证据契约，以及缺少可重复的安全验收。
3. LLM Verifier 可以作为语义复核，但不能被描述成“独立裁决证明”，也不应先于确定性安全门实施。
4. 改进目标不是保证预测正确，而是确保每条结论可追溯、数据边界可见、证据不足时自动降级，并且能够通过固定测试集复验。

---

## 二、现状定位

### 2.1 已有的硬约束

当前趋势研究 Agent 已经做到：

1. **运行时强制取数**：提交报告前必须调用 `get_portfolio_overview`、读取全部持仓；存在基金穿透快照时必须读取穿透；配置 Tavily 时必须发起搜索。
2. **证据账本防伪**：只有 App 工具能写入证据账本；模型提交的来源名称、URL、标题、摘要和时间会被规范证据覆盖；不存在的 evidence ID 无法进入最终报告。
3. **结构完整性校验**：短中长期齐全、持有基金覆盖、rationale/counterSignals 非空、板块与大类资产互斥、置信度范围、免责声明和部分绝对措辞均有校验。
4. **预算与失败纪律**：模型轮次、工具调用、网页搜索、无效提交、请求超时和上下文体积均有上限；失败、取消或超时不会覆盖上一份成功报告。
5. **基金穿透边界较完整**：披露日期、覆盖率、未知仓位、陈旧披露和“非实时完整持仓”均已结构化提供给 Agent。
6. **金额脱敏是结构级剔除**：不是依赖 prompt 要求模型自行保密。

因此，当前实现能较稳定地产出结构合规、引用来源真实、基金披露边界相对清晰的研究报告。

### 2.2 已确认的关键缺口

#### 缺口 A：方向性结论没有完整的证据契约

Validator 主要校验结构和 evidence ID 是否存在，不读取证据摘要，也不判断：

- direction 是否与证据方向一致；
- rationale 是否曲解证据；
- 是否忽略了同主题的反向证据；
- horizons、sectors、assetTrends 和 actions 是否互相矛盾；
- counterSignals 是否只是“注意风险”等无信息套话。

目前 `TrendAssetView`、`TrendHorizonView` 和 `TrendActionCandidate` 没有证据字段；sectors、marketOutlook 和 opportunities 虽有 `evidenceIDs`，但允许为空。纯观点报告仍可能通过。

#### 缺口 B：主趋势链路的数据时间和来源状态不可靠

当前主趋势快照仍存在：

- `platformPayload=nil`
- `alfaPayload=nil`
- `managerWatchEvents=[]`
- `dataAsOf` 使用快照创建时间
- 基金估值 `quotedAt=nil`
- 未在冻结主趋势快照前强制刷新相关行情

空数组没有区分“未接入”“未配置”“请求失败”和“请求成功但确实无信号”，模型可能把“没拿到数据”误解为“没有风险事件”。

#### 缺口 C：Harness 只证明调用过工具

主趋势 Agent 的 `readyForSubmission` 只要求网页搜索尝试次数大于零。搜索失败或返回零条有效结果，也可能满足“已经搜索”的覆盖条件。

Harness 能证明“工具被调用”，不能证明：

- 搜索产生了有效、近期、权威且不重复的证据；
- 主要观点得到足够证据支持；
- 反证被主动考虑；
- 行动建议满足资金安全门槛。

#### 缺口 D：置信度是模型自报

当前只校验 score 是否在 0～100：

- label 与 score 可以不一致；
- 新鲜度、来源权威性、穿透覆盖率和未知仓位不会确定性影响 score；
- “数据质量”“证据强度”和“预测不确定性”被混为一个数字；
- 尚无预测结果回测，因此不能称为经过统计校准的 confidence。

#### 缺口 E：缺少可信度验收与完整审计

当前报告文件保存最终报告和被引用的规范证据；运行日志主要记录阶段、工具名、耗时和错误，并覆盖上一次运行。尚不能完整复原：

- 本次使用的数据源及状态；
- 模型、prompt 和 schema 版本；
- 脱敏后的工具调用轨迹；
- Agent 看过但没有引用的证据；
- Validator、置信度归一化和未来 Verifier 的裁决过程。

也没有固定的对抗样例和验收指标证明改造确实降低了错误放行率。

---

## 三、可信度定义与设计原则

本项目中的“高可信度”定义为：

> 报告中的方向性结论和行动候选具有可追溯证据；数据来源、时间、完整性和缺口明确可见；证据不足或数据失效时系统确定性降级；每次运行可以复查并通过固定测试集验证。

它不表示：

- Agent 能保证市场预测正确；
- Verifier 能证明事实真实或未来走势正确；
- 引用了真实 URL 就代表解读正确；
- 一个 0～100 数字等于经过统计校准的上涨概率。

设计原则：

1. **确定性规则先于 LLM 判断**：能用代码验证的，不交给另一个模型决定。
2. **数据新鲜度按来源、品种、交易时段和用途判断**：不能使用单一 20 分钟规则覆盖所有资产。
3. **所有方向性结论都必须进入统一证据契约**：尤其是行动候选。
4. **资金动作 fail-closed**：缺证据、数据陈旧、来源失败或验证异常时，强制降级为 `hold/watch/uncertain`。
5. **Verifier 是第二意见，不是真相来源**：先 shadow 评测，再决定是否参与阻断。
6. **没有审计和验收，就不能宣称可信度提高**。

---

## 四、P0：先建立确定性资金安全底座

### P0-1　数据来源状态与分品种新鲜度

#### 目标

消除“空 = 无风险”“快照创建时间 = 数据截止时间”“所有报价统一按 20 分钟失效”等系统性误读。

#### 数据来源状态

为每个来源增加结构化状态，而不是只传空数组或自由文本 warning：

```text
source: marketIndex / portfolioQuote / fundNAV / fundDisclosure /
        qiemanAdjustment / alfaAdjustment / managerWatch / webSearch

status: notIntegrated / notConfigured / notRequested / fetching /
        successEmpty / success / failed

asOf: 来源数据时间
receivedAt: App 收到数据的时间
errorCode: 可选、脱敏
itemCount: 可选
```

语义要求：

- `successEmpty` 才能表达“已成功查询，本次确实无数据”。
- `notIntegrated/notConfigured/failed` 必须明确提示“不得把无数据解释为无风险”。
- 关键来源缺失时，短期方向和行动候选必须降级；不能只在 warning 中提醒后继续输出高置信判断。

#### 报价类型与新鲜度分离

`quoteType` 与 `freshnessStatus` 是两个维度，不应把 `stale` 放进报价类型枚举：

```text
quoteType:
  indexQuote / lastTrade / intradayEstimate / officialNAV / previousClose

freshnessStatus:
  fresh / previousSessionClose / stale / unknown

asOf
receivedAt
ageSeconds
marketSession
sourceLabel
```

建议策略：

| 数据类型 | 交易时段内 | 非交易时段 | 可支持的判断 |
|---|---|---|---|
| 股票、指数、场内基金 | 分钟级阈值 | 最近有效收盘，标记 previousSessionClose | 盘中动作必须 fresh；收盘数据可用于结构性判断 |
| 场外基金盘中估值 | 仅作为估算并标明时间 | 不作为最新成交/最终净值 | 盘中参考，不能描述为可成交价格 |
| 场外基金官方净值 | 日级 | 在下次官方净值前可作为最近已公布净值 | 日级收益和估值基线 |
| 基金定期披露 | 不适用分钟阈值 | 按披露日和陈旧阈值 | 结构、中长期解释；不证明当前真实持仓 |
| 平台/主理人事件 | 按事件时间 | 保留事件发生时间 | 事件信号，不等于行情 |

具体分钟和日级阈值应集中在 `TrendSourceFreshnessPolicy`，按品种和交易日历配置，不能散落在 Agent prompt 或多个 Validator 中。

#### 快照生成

主趋势分析在冻结快照前应：

1. 刷新个人持仓可用报价；
2. 刷新需要的指数；
3. 获取基金披露并记录成功、失败和缺失；
4. 明确获取或不获取 platform/alfa/manager 信号的原因；
5. 将每个来源的状态和时间一起冻结。

手动分析和已启用的定时分析本身就是一次明确的数据请求。分析所需的指数刷新应由 Agent 运行主动触发，不依赖菜单栏 ticker 是否开启；菜单栏设置只控制常驻展示和常驻刷新。若未来提供“禁止分析联网取行情”之类的独立隐私设置，则应尊重该设置并 fail-closed，而不是静默复用旧行情。

保留 `generatedAt` 表示报告生成时间。报告级 `dataAsOf` 只能用于 UI 摘要，不能代替各来源自己的 `asOf`；任何跨来源结论都应按实际引用证据判断新鲜度。

#### 主要修改位置

- `Core/AppModel/TrendAnalysis.swift`
- `Core/TrendResearch/TrendResearchSnapshot.swift`
- `Core/TrendResearch/TrendResearchToolRegistry.swift`
- 新增 `Core/TrendResearch/TrendSourceFreshnessPolicy.swift`

---

### P0-2　统一 Claim-Evidence 契约与确定性证据门槛

#### 目标

让所有带方向、风险或行动含义的结论都能回答：

- 哪些证据支持它？
- 哪些证据反对它？
- 哪些只是上下文，不能单独证明方向？
- 缺少什么证据，因此为什么降级？

#### 证据语义元数据

Claim-Evidence 关联依赖证据自身具有可校验的元数据。当前 evidence ID 只能证明来源记录存在，无法仅凭 `web:tavily:<hash>` 判断它与哪个标的、板块或 claim 相关。

建议为规范证据增加：

```text
TrendEvidenceMetadata {
  sourceKind
  sourceTier
  requestedTopicKeys
  entityCodes
  sectorKeys
  assetClassKeys
  quoteType
  freshnessStatus
  metadataConfidence
}
```

字段语义必须区分：

- `requestedTopicKeys`：工具调用原本要研究的主题，只证明查询意图。
- `entityCodes/sectorKeys/assetClassKeys`：证据内容实际关联的实体或主题。
- `sourceKind/sourceTier`：来源性质和权威等级。
- `metadataConfidence`：元数据来自确定性结构、规则提取还是语义提取。

生成规则：

1. 本地持仓、指数行情、基金净值、基金披露和平台事件使用结构化源字段打标签，属于确定性元数据。
2. `web_search` 增加经过快照校验的 `research_target` 参数，例如资产代码、指数 key、板块 key 或宏观主题；工具将其写入 `requestedTopicKeys`。
3. 网页结果标题和摘要中实际出现的实体、板块只能写入 `entityCodes/sectorKeys`，并标记提取方法和置信度。查询目标不能自动冒充“结果实际支持该主题”。
4. Validator 可以使用 `requestedTopicKeys` 判断搜索覆盖，但不能据此判定证据支持方向；实际支持关系仍由确定性结构数据或后续语义复核判断。
5. `sourceTier` 由 App 维护的来源注册表生成，未知来源默认 `unknown`，不得由模型自报。
6. 元数据与 evidence 正文一样只能由工具和 App 写入规范账本，模型提交值一律忽略。

#### 模型结构

建议引入统一结构：

```text
TrendClaimEvidence {
  supportingEvidenceIDs: [String]
  counterEvidenceIDs: [String]
  contextEvidenceIDs: [String]
  exemptionReason: String?
}
```

以下对象必须接入：

- `TrendHorizonView`
- `TrendSectorView`
- `TrendMarketOutlook`
- `TrendOpportunity`
- `TrendAssetView`
- `TrendActionCandidate`
- portfolio headline/riskLevel 如保留方向性判断，也必须有组合级证据

#### 行动策略分档

两个 Agent 复用同一策略框架，但不能对所有 action 套用相同的盘中门槛：

```text
informational:
  watch / waitForConfirmation / observeInBatches

allocationReview:
  pausePlan / rebalanceReview / considerIncrease / considerReduce

execution:
  下一小时 buy / sell
```

- `informational`：必须引用本地组合或标的事实，并提供观察条件；允许没有最新网页证据，但置信度和 actionability 受限。
- `allocationReview`：属于可能改变资产配置的建议，必须引用目标持仓/净值、与建议理由匹配的结构或外部证据，并提供触发、失效和仓位边界。基金建议如果依赖底层暴露，必须引用对应穿透证据及披露边界；不要求分钟级盘中行情，但数据必须对目标周期有效。
- `execution`：采用最严格的盘中行情、近期外部证据、基金穿透、仓位/分批、触发和失效门槛。

#### 硬校验

1. 每条方向性结论至少有一个 supporting evidence；没有时只能输出 `uncertain`，并填写结构化豁免原因。
2. evidence ID 必须来自本次运行账本，且与当前 claim 的标的、行业或数据类型具有关联。
3. `counterEvidenceIDs` 不得与 supporting evidence 完全相同；存在已识别反证时不得省略。
4. 基金短期判断不能只引用季度穿透；穿透只能解释暴露、集中度和中长期风险。
5. `informational` 和 `allocationReview` 按各自 policy level 校验，不能因为动作没有直接成交就免除证据和失效条件。
6. `execution` 行动采用最严格门槛：
   - 必须引用目标标的本地行情或净值证据；
   - 盘中买卖必须满足对应品种的新鲜度；
   - 必须引用近期且与标的/底层行业相关的外部证据；
   - 基金增减仓必须引用该基金穿透证据并披露日期和未知仓位；
   - 必须提供仓位/分批方式、触发条件和失效条件；
   - 任一项缺失时强制降级为 `hold/watch`。
7. 证据不足不能通过把 `externalSignalStatus` 改成 unavailable/partial 绕过。

#### 复用要求

“下一小时买卖建议”现有的标的行情、两条网页证据、基金穿透和 `hold` 降级规则，应抽取为共用的 `TrendClaimEvidencePolicy`，主趋势 Agent 和下一小时 Agent 使用同一套判定代码。

#### 主要修改位置

- `Core/TrendAnalysisModels.swift`
- `Core/TrendAnalysisValidator.swift`
- `Core/TrendResearch/SubmitTrendReportTool.swift`
- `Core/NextHourGuidance.swift`
- `Core/TrendResearch/TrendResearchPromptBuilder.swift`
- 新增 `Core/TrendResearch/TrendClaimEvidencePolicy.swift`
- 新增 `Core/TrendResearch/TrendEvidenceMetadata.swift`
- 新增 `Core/TrendResearch/TrendSourceAuthorityRegistry.swift`

---

### P0-3　对抗测试、验收指标与 fail-closed

#### 固定测试集

至少覆盖：

1. 证据明确利空，报告写成 bullish。
2. 账本包含明显反证，报告只引用支持证据。
3. horizons bearish，但 sectors、assetTrends 或 actions 给出无条件看多。
4. Tavily 请求失败。
5. Tavily 成功但返回零条有效结果。
6. 搜索结果重复、过期或只有低权威转载。
7. 盘中行情缺时间、超过阈值或来自上一交易日。
8. 闭市后使用最近收盘数据，确保不会误判为盘中实时行情。
9. 场外基金只有最后一次官方净值，没有盘中估值。
10. 基金穿透覆盖率低、未知仓位高或披露陈旧。
11. platform/alfa/manager 分别处于未接入、失败、成功为空和成功有数据。
12. evidence ID 伪造、错配标的或只挂无关证据。
13. confidence label 与 score 冲突。
14. counterSignals 只有“注意风险”等套话。

#### 报告级终止语义

任何数据源组合下，Agent 都必须存在可接受的终止路径，不能为了凑齐证据反复搜索或修复直到超时：

```text
disposition:
  actionable
  analysisOnly
  insufficientEvidence
```

- `actionable`：至少一个行动满足对应 policy level 的全部证据和时效门槛。
- `analysisOnly`：可以输出有证据的结构性研究，但所有行动降为 `hold/watch`。
- `insufficientEvidence`：基础快照可以生成，但外部证据、时效或覆盖率不足；短期方向降为 `uncertain`，行动全部禁用，并明确列出缺失来源。

搜索持续失败、返回零条有效结果或达到搜索预算时，应确定性进入 `analysisOnly/insufficientEvidence` 并正常提交报告，而不是继续消耗修复轮次。只有基础快照无法建立、报告无法解码或系统性故障时，整次运行才标记为失败。

#### P0 验收门槛

- 不存在的 evidence ID 通过率：0。
- 缺少目标行情或行情不满足时效要求的盘中买卖动作通过率：0。
- 基金缺少对应穿透证据时的短期增减仓动作通过率：0。
- 搜索失败或零有效结果被计为“有效搜索”的次数：0。
- 数据来源状态覆盖率：100%。
- 所有方向性结论均有证据契约，或被确定性降级为 uncertain/watch/hold。
- 搜索预算耗尽或关键外部来源不可用时，报告能以 analysisOnly/insufficientEvidence 正常结束。
- 旧版本报告能够安全解码；新增字段有迁移或默认值测试。
- 失败、取消、超时和验证异常继续保留上一份成功报告。

任何一项不满足，都不能以“可信度增强”名义发布。

---

### P0-4　可审计运行产物

新增本地 `TrendAgentRunArtifact`，与最终报告分开保存：

```text
runID
startedAt / completedAt / trigger
modelFingerprint
promptVersion / reportSchemaVersion / policyVersion
snapshotHash
sourceStatuses
redactedToolCalls
canonicalEvidenceLedger（包含 evidence metadata）
claimEvidenceLinks
validatorResults
confidenceNormalizationResults
verifierResults
reportDisposition
```

要求：

- 不持久化 API Key。
- 工具参数和搜索词先脱敏再记录。
- 完整金额快照不重复写入审计文件；保存摘要、哈希和必要的证据字段。
- 文件权限保持 `0600`。
- 支持有限保留策略，例如最近 20 次或最近 90 天，避免无限增长。
- UI 至少可以查看本次报告的数据来源状态、证据覆盖和降级原因。

现有 `TrendAgentRunLogStore` 可继续作为可读进度日志，但不能替代结构化审计产物。

---

## 五、P1：在确定性安全门之后增加语义复核

### P1-1　TrendReportClaimVerifier

#### 定位

Verifier 是“第二模型语义复核”，不是独立事实裁判，不证明未来走势正确。第一阶段只能 shadow 运行：记录裁决，不阻断正式报告。通过标注测试集评估后，才允许参与打回或降级。

#### 正确处理顺序

```text
报告解码
  → schema/结构校验
  → 规范化 evidence ledger
  → 确定性来源、时效、关联性和证据覆盖校验
  → Verifier 语义复核
  → 置信度归一化与最终 disposition
  → 保存报告和审计产物
```

Verifier 不应放在 Validator 前，也不应接收尚未规范化的模型自填证据。

#### 输入

每次只处理一个 claim，但必须包含：

- claim ID、类型、方向、周期、rationale；
- trigger、invalidating conditions、counterSignals；
- 已引用的支持/反向/上下文证据；
- 账本中由确定性主题匹配找出的、同标的或同主题但未被引用的候选证据；
- 证据来源等级、发布时间、新鲜度和披露边界。

只给“已引用证据”无法发现选择性忽略反证。也不能给整个完整组合上下文，以免无关信息造成锚定。

其中 `requestedTopicKeys` 只用于召回候选证据，不能作为“证据实际支持该 claim”的证明。Verifier 必须根据规范摘要和结构化事实判断实际支持、无关或冲突关系。

#### 输出

```text
claimID
verdict: supported / unsupported / unverifiable / conflicted
supportingEvidenceIDs
contradictingEvidenceIDs
reason
judgeConfidence
```

#### 处置

- 行动候选为 `unsupported/unverifiable/conflicted`：强制 `hold/watch`，不能继续保留买卖或增减仓动作。
- 普通研究结论为 `unsupported/conflicted`：回灌 Agent 修复；超过修复预算后降为 `uncertain` 并展示 warning。
- `unverifiable`：按数据用途和周期封顶置信度，写入明确降级原因。
- Verifier 失败、超时或返回非法 JSON：不能放宽任何确定性安全门；行动候选保持 fail-closed。

#### 评测门槛

阻断模式启用前，应使用不少于 100 条人工标注 claim 进行 shadow 评估：

- 关键反向证据的漏放必须在人工确认的高风险集合中为 0。
- 总体错误放行率目标不高于 5%。
- 错误打回率、额外延迟和额外成本必须在发布记录中给出。

同一模型、同一证据重复投票的错误高度相关，不能把“多数票”当作独立性。若要多模型裁决，应明确模型差异、成本和冲突处置，但首版不要求。

---

### P1-2　置信度约束，而非伪校准

将单一 confidence 拆成：

```text
dataQuality
evidenceStrength
forecastUncertainty
actionability
confidenceBasisCodes
```

其中：

- `dataQuality` 由 App 根据新鲜度、来源状态、披露覆盖率和未知仓位计算。
- `evidenceStrength` 由证据数量、来源等级、相关性、反证冲突和 Verifier 结果共同决定。
- `forecastUncertainty` 可以由模型提出，但受 App 封顶。
- `actionability` 由资金安全门确定；不满足门槛时固定为 hold/watch。
- `confidenceBasisCodes` 使用 App 生成的枚举原因码，不允许模型自由编造。

确定性规则：

1. label 始终由最终 score 派生，覆盖模型自填。
2. 置信度封顶按 claim 和周期执行，不做粗暴的整份报告统一乘数。
3. 陈旧季度披露可以支持中长期结构观点，但不能提高短期行动置信度。
4. `notIntegrated/failed/unknown` 与 `successEmpty` 采用不同原因码和封顶规则。
5. UI 优先显示低/中/高和降级原因，避免 73、74 这类没有统计基础的伪精度。

只有在保存预测、定义可判定结果并持续计算可靠性曲线或 Brier Score 后，才能把这一能力称为“置信度校准”。在此之前统一称为“置信度约束与解释”。

---

### P1-3　反证与网页搜索质量

#### 有效搜索定义

只有同时满足以下条件才算有效搜索：

- 请求成功；
- 返回至少一个本次运行中未重复的 evidence ID；
- 证据发布时间满足 claim 周期要求，或明确标记无发布时间；
- 搜索主题与主要暴露、目标标的、底层行业或预备行动相关。

`webSearchAttempts > 0` 不能再作为提交充分条件。

#### 搜索策略

- 优先对高仓位板块、主要风险和拟执行动作搜索，而不是机械地给每个小主题搜索一次。
- `web_search` 必须携带经过快照校验的 `research_target`，以便记录搜索覆盖和审计；该参数不替代对返回内容实际相关性的判断。
- execution 行动至少需要两个独立来源；同一发布者、同一原文的转载或仅 URL 不同的镜像不算来源多样性。
- 来源等级建议分为：
  1. 监管、央行、交易所、基金公司和上市公司原始披露；
  2. 权威财经媒体；
  3. 普通媒体和研究摘要；
  4. 聚合转载、论坛和无署名内容。
- Tavily 返回的摘要是检索证据，不等同于已经核验全文；高风险行动应优先引用原始来源。

来源等级由 `TrendSourceAuthorityRegistry` 维护：

- 规范化主域、子域、发布者和已知重定向后再分类；
- 未命中注册表的来源固定为 `unknown`，不能自动升为权威来源；
- “官方域名”只能证明发布者身份，不能单凭域名证明当前页面就是原始披露；
- 原始披露识别应结合发布者、页面类型、标题/路径规则和可用的文档标识；
- 注册表、重定向规范化、转载去重和原始来源识别必须有独立测试，并作为持续维护的数据资产。

#### PII scrub

在网络请求前程序化清洗：

- 本地组合名称、用户自定义名称和其他已知私有标识；
- 明确的金额表达；
- Cookie、token、API Key 等敏感模式；
- 日志只保存脱敏后的 query。

不能简单删除全部数字，因为基金代码、股票代码、政策编号和日期可能是合法查询内容。应使用本地敏感词集合、上下文规则和单元测试降低误伤。

---

## 六、P2：合规措辞与可解释 UI

### P2-1　措辞模式

将少量整词黑名单扩展为经过测试的模式：

- 保证、确定性获利、无风险；
- 强制用户执行；
- 把场外基金估值描述成实时可成交价；
- 把公开定期披露描述成当前完整持仓；
- 把 Verifier 结果描述成事实证明。

正则规则必须有白名单和误伤测试，不能阻止正常的风险说明，例如“无法保证收益”。

### P2-2　UI 展示

报告应直接展示：

- 每个数据源的状态和时间；
- 报价类型与新鲜度；
- 基金披露日期、覆盖率和未知仓位；
- 每条行动的支持证据和反向证据数量；
- 被降级为 uncertain/watch/hold 的具体原因；
- 报告 disposition：actionable / analysisOnly / insufficientEvidence；
- Verifier 是否仅为 shadow，避免用户误解为独立审计。

---

## 七、实施分期

| 阶段 | 内容 | 发布条件 |
|---|---|---|
| 0A | 来源状态、行情刷新、分品种新鲜度 | 数据状态测试全绿；旧报告兼容 |
| 0B | 证据语义元数据、全量 Claim-Evidence 契约、行动分档与 fail-closed、两个 Agent 共用策略 | P0 证据与资金安全门全部通过 |
| 0C | 报告终止语义、对抗测试集、验收指标、结构化审计产物 | 所有数据缺口场景均可安全结束，并可复现依据和降级过程 |
| 1A | Verifier shadow mode | 完成不少于 100 条人工标注 claim 评测 |
| 1B | Verifier 参与打回/降级、置信度约束 | 达到错误放行率和延迟/成本门槛 |
| 1C | 搜索来源等级、反证覆盖、PII scrub | 搜索失败不再满足提交条件 |
| 2 | 措辞模式、来源状态和证据解释 UI | 无关键误伤，用户能看到数据边界 |

实施时优先把 v3.9.5 下一小时 Agent 已有的严格动作规则抽成共用能力，不复制第二套 Validator。

---

## 八、仍然成立的能力边界

1. Agent 和 Verifier 都是 LLM，不能保证市场判断或收益结果正确。
2. Verifier 最多证明“在当前规范证据摘要下，结论没有明显曲解或遗漏已识别反证”，不能证明来源本身真实完整。
3. Tavily 摘要可能截断、遗漏上下文或依赖二手来源；关键结论应优先使用原始披露。
4. 基金穿透基于公开定期报告和有限重仓披露，不能代表基金当前完整持仓。
5. 场外基金盘中估值不是最终净值，也不是可即时成交的精确价格。
6. “可追溯、证据一致、数据边界明确、置信度有约束”是可信研究助手的必要条件，不等于预测准确。
7. 所有行动必须保持条件式表达，并提供触发、失效和仓位控制；证据不足时系统必须拒绝给出交易动作。

---

## 九、评审问题的结论

1. **LLM-as-judge 是否合理？**  
   合理，但只能作为确定性校验后的第二意见。先 shadow 评测，不能称为独立证明。

2. **强制每条结论挂证据是否会导致“为挂而挂”？**  
   会。因此要增加证据角色、标的/主题关联性、来源类型和确定性资金门槛，不能只检查数组非空。

3. **数据源缺失只写 warning 是否足够？**  
   不够。必须用结构化 source status 区分未接入、失败和成功为空，并对短期方向和行动候选确定性降级。

4. **置信度封顶是否合理？**  
   合理，但应按 claim、周期和数据用途执行，并拆分数据质量、证据强度与预测不确定性。没有结果回测前不要称为校准。

5. **“可审计 + grounding 一致”能否定义高可信度？**  
   可以作为工程可信度定义，但必须再加上来源权威性、fail-closed 和固定评测集；不能等同于预测准确。
