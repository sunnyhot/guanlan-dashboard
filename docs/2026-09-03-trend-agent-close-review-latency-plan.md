# 趋势 Agent 收盘复盘（closeReview）耗时根治计划

> 2026-09-03 起草，同日复核修订。证据基线：runID `552F6FE4`（2026-09-02 21:00 scheduled closeReview，29 只基金，1916s 撞总预算失败）。
> 配套已落地：总预算改按报告批次数扩容（`f6cb6ce`，29 只 → 3400s），本计划解决的是「跑得快」而非「跑得完」。
> 复核修订（第二轮）：逐条对照代码与诊断日志核验——缺陷 B 归因补全（轮 3 拒批实为三类错误），新增改动 ①.5 / ①.6 / ④ / ⑤ 与附 A（推理链控制），并修正 ①②③ 的若干设计细节。

## 1. 问题复盘（证据链）

### 1.1 时间线（来自 ai-analysis-logs 完整诊断日志）

| 阶段 | 耗时 | 结果 |
|---|---|---|
| fanout 并行生成 4 批 × 8 只 | 583s | **29 只全部生成成功并入库暂存**（tool 层 is_error=false，remaining 24→16→8→0） |
| 交互轮 1-2 重读数据 | 31s | fanout 已预取过同一批数据，交互对话不携带 |
| 交互轮 3 提交市场模块 | 617s | 全量终检被拒（**三类错误**，见 1.2） |
| 交互轮 4 重提市场模块 | 352s | 通过，但返回「剩余基金 29 只」——已暂存批次已被清空 |
| 交互轮 5 重做第 1 批 | 331s | 撞运行截止时间被杀，整 run 失败 |

轮 3 被拒的 11 条错误分三类：
1. **4 条**「已持有基金趋势周期缺少 counterSignals/反证条件」——周期级 counterSignals 缺陷（缺陷 B1）。
2. **6 条**「板块『X』方向为 uncertain，rationale 末尾必须写待观察信号」——模型原始提交方向是 看空/看淡 且 counterSignals 齐全，是 App 端关联降级改成 uncertain 后**未补出口**（缺陷 B2）。
3. **1 条**「大盘/大类资产『境内债券/固收』方向为 uncertain…」——同上，关联降级缺出口。

### 1.2 缺陷链（复核后共五环）

**缺陷 A：fanout 差一步收官，且注定差这一步。**
`TrendReportDraftStore.effectiveScope` 对 closeReview 要求重算 market 模块（2026-09-01 机会雷达下线收编后 market 加入 requiredModuleToolNames），init 时 `initialMarket = nil`、`initialAssets.removeAll()`（TrendReportModuleTools.swift:146-157）；overview/actions 从基线预填。`closeReviewFanOut`（TrendResearchAgent.swift:981 起）只并行生成基金批次，不生成 market 模块。而组装收官的 `assembledReport`（TrendReportModuleTools.swift:494）要求四模块齐全——market 永缺 → fanout 永远 `return nil` → 回退交互循环从头再走。**fanout 的全部价值只剩「把 29 只暂存进 store 等交互循环用」。**

**缺陷 B1：周期级 counterSignals 缺陷入库沉默，在最贵的时刻引爆。**
终检（TrendAnalysisValidator.swift:250-252）要求每只基金每个周期 `horizon.counterSignals` 非空。`storeAssetBatch` 入库归一化链现有 6 针保守兜底（归因前缀/降级/边界措辞/结构性豁免/合成三周期/**资产级** counterSignals 兜底），但**没有周期级** counterSignals 兜底。fanout 批次带着该缺陷入库（本次实证 4 只），潜伏到交互轮 3 市场模块提交、四模块恰好凑齐触发全量终检时才爆。

**缺陷 B2（复核新增）：关联降级缺「待观察信号」出口——与 B1 同轮引爆的另一半。**
`SubmitTrendReportTool.swift:108-131` 对支撑证据与主题无关联的 sectors/marketOutlook/opportunities 降级为 `direction = .uncertain` 并登记 warning，但**只改方向、不补 rationale 出口**；而 horizon 的强制降级路径（SubmitTrendReportTool.swift:345-352）有「待观察信号」补写逻辑。降级后的条目过 W4 明确性校验（TrendAnalysisValidator.swift:232-235）必拒。轮 3 的 7 条 sector/marketOutlook 错误即此类。**只落地改动 ① 不落地 ①.5，轮 3 型拒批依然会发生。**

**缺陷 C：`prepareRepairs` 关键词匹配一损俱损。**
轮 3 拒批错误含「已持有基金」字样 → `assetTrendsByCode.removeAll()`（TrendReportModuleTools.swift:638），错误实际只点名 4 只基金，29 只已暂存成果全部清空；「板块」字样同时清掉 market。此后模型从零重做，撞死线。**这是 fanout 成果被销毁的直接机制。**（复核确认：终检错误里的 name 来自已暂存条目——assembled report 读 store 数据——与 `assetTrendsByCode` 同源，改动 ② 的点名匹配可靠。）

**缺陷 D（复核新增）：提交阶段预算止损粒度是研究轮口径。**
`minimumStepBudgetSeconds = 60`（TrendResearchAgent.swift:257）对提交轮形同虚设：轮 5 在剩余 331s 时仍发起、注定中途被杀（白烧 331s 计费输出），且彼时 0 只暂存导致 W5 降级也失败。提交轮实测 352-617s，止损阈值应与提交轮预期成本对齐。

### 1.3 浪费核算

1916s 中：583s（fanout 成果被 C 销毁）+ 617s（轮 3 被 B1/B2 引爆的拒批）+ 352s（轮 4 market 重提，本可只修 sectors）+ 331s（轮 5 被 D 放行的注定失败请求）≈ **1883s（98%）由缺陷连锁造成**。理论串行完成需 ~2800s；fanout 若能收官 ~700s（当前模型口径）。

## 2. 目标与非目标

**目标**
1. closeReview（≥12 只基金走 fanout）整 run 耗时从 ~2800s 压到 **~700-900s**（4 倍提速，当前模型口径；推理链控制落地后见附 A）。
2. 已暂存的合格工作在任何拒批/回退/预算终局路径下不再被整块销毁或白烧。
3. 终检链、Evidence Ledger、Claim-Evidence Policy、报告 schema **零改动**——质量门不动。

**非目标**
- 不改 `TrendAnalysisValidator` / `TrendClaimEvidencePolicy` 的任何校验规则（本计划全部改动位于归一化/兜底/修复链，不改判定规则本身）。
- 不改 CLI 契约、报告 schema、双端 UI。
- 不动 NextHourGuidance / longTerm / marketRadar scope 的行为（marketRadar 调度已停）。
- 不做 prompt 大改与模型端点更换（推理链控制见附 A，另行评估）。

## 3. 改动明细

### 改动 ①（P0）：周期级 counterSignals 入库兜底 —— 归一化链第 7 针

- **文件**：`macos-app/Core/TrendResearch/TrendReportModuleTools.swift`
- **位置（复核修订）**：优先落在 `sanitizedHorizon` 的健康返回路径（TrendReportModuleTools.swift:1002-1004，`hasAssociated && removed.isEmpty` 的原样返回处）。理由：`sanitizedHorizon` 是 assetTrends（sanitizedAssetBatch，line 1075）与 keyAssets（sanitizedActions，line 1147）共用的唯一周期清洗链，一处实现同时覆盖两条路径——原计划的「storeAssetBatch 链上追加 map」只能覆盖 assetTrends，keyAssets 还要另写代码。
- **设计**：仅对 `counterSignals.isEmpty` 的周期填入保守占位 `["模型未提供该周期反证条件，关键假设或行情变化后重估。"]`；rationale / direction / claimEvidence / 资产级字段全部不动。**注意占位文案不得复用 `rebuild` 的「证据不足，当前方向判断不成立。」（line 1048）——健康路径的周期证据是合格的，只是缺反证表述，「证据不足」语义不符。**落地时须覆盖 `sanitizedHorizon` 的**全部返回分支**（健康原样返回、`rebuild(forceDowngrade: false)` 重建、降级 rebuild）——只在健康分支 patch 会让「有关联但被剔除过幻觉 ID」的 rebuild 分支继续透传空 counterSignals，原缺陷换个分支复发；实现上建议出口统一 wrap 或三处返回前各补一次。
- **测试**：
  - 新增（TrendReportModuleToolsTests）：构造一批基金，其中一个周期 counterSignals 为空且证据关联健康 → 入库后该周期为保守占位文案、其余字段与其它周期逐字段不变。
  - 新增 keyAssets 同型用例：keyAssets 健康周期 counterSignals 为空 → 经 sanitizedActions 后补占位。
  - 新增等价性用例：入库产物直接过 `TrendAnalysisValidator` 的资产周期 counterSignals 检查。
- **风险**：模型会「学会」不写反证条件、依赖兜底，稀释该字段质量。缓解：占位文案显式标注「模型未提供」留在报告里可被用户看见；上线后落诊断日志统计兜底触发率（事件名建议 `horizon_counter_signals_fallback`），若持续偏高再回 prompt 端加强（不在本计划内）。

### 改动 ①.5（P0，复核新增）：关联降级补「待观察信号」出口

- **文件**：`macos-app/Core/TrendResearch/SubmitTrendReportTool.swift`
- **位置**：association downgrade 三条循环（sectors line 108-115、marketOutlook line 116-123、opportunities line 124-131）。
- **设计**：降级时与 horizon 强制降级路径（line 345-352）同口径重建条目——`direction = .uncertain` 之外：① rationale 追加「待观察信号:与该主题关联的支撑证据恢复后重估方向。」；② confidence 压到 `TrendConfidence(score: min(35, score), label: "低").appNormalized`。三循环同修，opportunities 虽目前恒被清空（line 101），仍一并修以防未来复活。
- **测试**：
  - 新增：sector 的 supportingEvidenceIDs 全部与主题无关联 → 归一化后 direction=uncertain、rationale 含「待观察信号」、confidence ≤35，且整报告过 `TrendAnalysisValidator` 的 W4 明确性校验。
  - 新增：marketOutlook 同型用例。
- **风险**：无质量门放宽——降级语义不变，只补 App 侧本来就该写死的出口文案；用户可见报告多一句保守出口，可接受。

### 改动 ①.6（P1，复核新增）：market/sectors 的 counterSignals 入库兜底

- **文件**：`macos-app/Core/Trend/TrendBaselineContractPatch.swift`
- **位置**：`markets`（line 30-48）与 `sectors`（line 50-69）的 counterSignals 透传处（line 44/65）。
- **设计**：`counterSignals.isEmpty` 时补中性占位 `["出现与当前判断相反的关键信号时重估。"]`（不用「证据不足」措辞——market 证据可能健康，只缺反证表述）。`storeMarket`（TrendReportModuleTools.swift:214-219）已把该 patch 用于新提交数据，入库即生效，同时覆盖基线复用路径。
- **顺带核查**：`opportunities` 目前入库即被清空（SubmitTrendReportTool.swift:101），无需兜底；若未来恢复机会模块，记得同补。
- **测试**：
  - 新增：sector/marketOutlook counterSignals 为空 → 补占位、其余字段不变；产物过 `TrendAnalysisValidator` 的板块/大盘 counterSignals 检查（TrendAnalysisValidator.swift:97-99/106-108）。
- **风险**：与 ① 同型，文案中性、用户可见；触发率并入同一观测。

### 改动 ②（P0）：`prepareRepairs` 按点名精准清除

- **文件**：`macos-app/Core/TrendResearch/TrendReportModuleTools.swift`
- **位置**：`prepareRepairs(for:)`（line 614 起）的 assetBatch 分支。
- **设计**：
  - 触发条件不变（joined messages 含「已持有基金」/「assetTrends」/「资产「」）。
  - 触发后先做**点名匹配**：遍历 `assetTrendsByCode`，若 joined messages 包含该资产的 `name`（终检错误格式为 `…缺少 counterSignals/反证条件：\(asset.name) \(horizon)`，名字裸露无括号，直接子串匹配；同名 A/C 份额连带清除可接受，保守方向），仅移除被点名的。
  - **回退保险（复核补充实现细节）**：点名匹配一个都没命中 → 维持现状 `removeAll()`；「连续两轮拒批都命中 assetBatch 关键词且点名始终为空时同样 `removeAll()`」需要**新增跨轮状态**（store 目前是无状态 actor，需加一个 `consecutiveUnmatchedAssetClears` 计数属性），由 `maxInvalidSubmissions` 现有上限兜住循环。
  - market/overview/actions 分支不动（单模块粒度，无更细清除单位）。
- **测试**：
  - 新增：暂存 5 只，错误只点名 2 只名 → 仅 2 只被清、3 只保留。
  - 新增：错误含「已持有基金」但不含任何已暂存基金名 → 全清（向后兼容契约）。
  - 新增：连续两轮点名空 → 第二轮全清（跨轮状态契约）。
  - 新增：sector 类错误（含「板块」）不清任何基金。
- **风险**：点名匹配漏（名字被截断/改写）→ 缺陷基金多活一轮，下轮终检再次点名，受 `maxInvalidSubmissions`（随基金数扩容）约束收敛。无死循环新增面。

### 改动 ③（P1）：fanout 补 market 模块并行生成，直接收官

- **文件**：`macos-app/Core/TrendResearch/TrendResearchAgent.swift`
- **位置**：`closeReviewFanOut`（line 981 起）。
- **设计**：
  1. 把 `generateBatch(_:repairFeedback:)` 泛化为 `generateSingleTurn(toolName:instruction:repairFeedback:)`（保持原行为参数：deadline/perRequestTimeout/maxOutputTokens/temperature 均沿用 policy）。
  2. 并行任务组从「N 个批次」扩为「N 个批次 + 1 个 market 生成」：market 请求挂 `SubmitTrendMarketModuleTool` 的定义，user 指令复用 `TrendResearchPromptBuilder` 对 closeReview 的市场模块要求（指数放 marketOutlook、行业放 sectors、opportunities 留空、证据只引用已登记 evidence_id），数据载荷同一份 `dataPayload`（预取块已含 get_market_snapshot）。**指令需像 `generateBatch`（line 1077）一样显式写「不要调用任何只读工具，数据已在下方」**——fanout 只暴露提交工具，避免模型先输出研究请求。
  3. 各结果照旧经 `registry.execute` 入库（turn 0 诊断记录不变），失败者进修复列表；market 修复与批次修复同一循环、同样只修一次。
  4. 组装终检（`assembledReport` → `finalizeAssembledReport`）与成功收尾（artifact + completed events）完全复用现有第 4/5 步，零新路径。
  5. 预算：fanout 墙钟 ≈ max(批次轮, market 轮) ≈ ~620s（当前模型含推理链口径；推理链控制落地后 ~150s，见附 A），仍在 3400s 总预算内；deadline 硬约束已下传到每次请求（2026-09-01 注记），无需新增。
  6. **修复预算改用扩容口径（复核补充）**：修复循环的预算门（line 1172）现在用基础 `policy.maxInvalidSubmissions`=4，而交互循环用 `effectiveInvalidSubmissionBudget`（29 只 = 7）。market 加入第一波后 5 个并行提交可能全败，应改用 `Self.effectiveInvalidSubmissionBudget(fundCount:base:)`。
  7. **并发限流风险（复核补充）**：5 条并行流打同一 key；网关对 trend-research 是 `maxRetriesPerProvider=0`（line 262-265），一路 429 即该批次失败 → 单次修复 → 整体回退。**建议限并发为 3**（墙钟增量 < 一个批次轮时长，换取限流鲁棒性；实现为简单信号量或分批 TaskGroup），并在诊断日志记录并发档位。
  8. 回退契约不变：任一环节失败 → `return nil` → 交互循环；配合改动 ②，回退时已暂存的批次与 market 不再被后续拒批连带清空。
- **测试**：
  - 更新 `TrendResearchPerformanceOptimizationTests.testCloseReviewFanOutWiringContract`：源码契约断言补 market 工具定义、并行组包含 market 生成、修复循环覆盖 market、修复预算用扩容口径（fanout 无 E2E 测试的既有缺口沿用「契约源码断言 + 生产运行验证」策略，见基线文档 76 行注记）。
  - 新增：`effectiveScope` 为 closeReview 且基线存在时，market 必在 requiredModuleToolNameSet（防止未来 scope 改动悄悄复活缺陷 A）。
- **风险**：单轮生成 market 比交互轮更易踩格式缺陷。缓解：改动 ①.5/①.6 已把 market 终检的两大确定拒批类（关联降级缺出口、counterSignals 缺失）在归一化层消化；fanout 内一次修复机会 + 修复失败整体回退交互循环（= 现状路径）；最坏情况多花一轮 market 生成时间，受 deadline 钳制。

### 改动 ④（P1，复核新增）：提交阶段预算止损按预期轮成本

- **文件**：`macos-app/Core/TrendResearch/TrendResearchAgent.swift`
- **位置**：主循环的单步预算护栏（line 417-419）与 fanout 修复轮预算护栏（line 1160-1171）。
- **设计**：单步最小预算分阶段取值——研究轮维持 60s；`submissionMode` 或 fanout 修复轮改用 `policy.totalTimeoutPerReportBatchSeconds`（400s，与提交轮实测 352-617s 对齐）。剩余不足 → `budgetSkipBeforeRequest` → 走 W5 降级完成（配合 ②，已暂存批次不再被清空，降级能保住大部分成果）。实测依据：轮 5 剩 331s 仍发起、331s 输出全部白烧且降级因 0 暂存失败。
- **测试**：
  - 更新 `AgentRunPolicyCharacterizationTests`：submissionMode 下剩余 300s → budgetSkip；研究阶段剩余 100s → 放行（60s 阈值不变）。
- **风险**：400s 对「只剩 1-2 只基金的小批次」偏保守（小批 JSON 实测可 <200s），可能提前止损。缓解：止损后走降级完成而非失败，小组合损失可控；先上保守值，观测后可按剩余批数缩放。

### 改动 ⑤（P2，复核新增）：诊断日志补 usage 与推理链分片区分

- **文件**：`macos-app/Core/TrendResearch/AIAgentDiagnosticLog.swift`（`AIAgentModelResponseTrace`，line 35-53）+ `TrendResearchAgentModels.swift`（`AgentStreamProgress`）。
- **设计**：① `AIAgentModelResponseTrace` 增加 `usage` 字段（prompt/completion tokens，供应商有计量时含 reasoning 分量；include_usage 尾包已收取，只是没落盘）；② `AgentStreamProgress.active/finished` 增加 `reasoningChunkCount` 与 `contentChunkCount` 拆分（accumulator 已在分别累计 reasoning/content，只需分开计数）。
- **测试**：现有诊断日志单测扩展断言新字段序列化；accumulator 拆分计数单测（reasoning-only 流 / content-only 流 / 混合流）。
- **价值**：计划 §6 的耗时验收与附 A 的推理链占比都必须靠这两个数量化，否则优化只能靠 wall-clock 盲测。

### 附 A（另行评估，不随本批落地）：推理链控制

复核实测（runID 552F6FE4）：轮 3 流式 **617s / 约 22,963 分片**（分片数为量级佐证——当前诊断日志无分片计数字段，精确值待改动 ⑤ 落地后量化；正文长度已精确验证），最终 assistant 正文仅 **243 字符**（已验证：fanout 四批正文 0/24/0/0 字符、轮 3 为 243 字符，均为单 tool call）；推理链（reasoning_content）占单轮输出 **90%+**，生成速率约 37 分片/秒。候选杠杆：
1. 提交轮换非推理模型，或在 `OpenAICompatibleAgentClient` 请求体（line 795 起）透传 thinking 控制参数（需先验证智谱对 glm-5.x 的支持）；
2. 注意 `maxOutputTokens` 不约束 GLM 推理 token（49 分钟无界输出旧实证），若有 thinking 上限参数需单独设置。
预期：单轮 350-620s → 30-90s；改动 ③ 的 fanout 墙钟 ~620s → ~150s，整 run 可进 ~200-300s。落地后按改动 ⑤ 的计量验证。

## 4. 实施顺序与验收

| 步骤 | 内容 | 验收 | 提交 |
|---|---|---|---|
| 1 | 改动 ① + ①.5 + ①.6 + 单测（同属「入库/归一化即兜底」家族，测试模式相同） | `swift test` 全绿（当前基线约 970 个 test 方法 + 新增） | 单独 commit |
| 2 | 改动 ② + 单测（保值保险，依赖步骤 1 的拒批类已被消化） | 同上 | 单独 commit |
| 3 | 改动 ③ + 契约测试更新（成功率依赖 ①.5/①.6） | 同上 | 单独 commit |
| 4 | 改动 ④ + ⑤ + 单测 | 同上 | 单独 commit |
| 5 | 文档同步（见 §5） | — | 可并入步骤 3 |

每步跑全量 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（在 macos-app/ 下）。构建/发版按 AGENTS.md 流程，四改动合入后随下一个版本发布（发版前先查 tag，pull 用显式 ssh 443 URL）。

**整体验收（上线后观察，非 CI）**
- 下一次 scheduled closeReview：诊断日志出现 `fanout_completed`（而非 `fanout_fallback_to_interactive`）。
- 整 run 耗时 < 1200s，报告 disposition 非 insufficientEvidence。
- 若仍回退：交互循环从「剩余基金 29 只」变为「剩余基金 = 未完成批次」（改动 ② 生效的证据）。
- 若预算终局：日志出现 `budget_skip` 后 W5 降级完成，且降级报告中已覆盖基金数 > 0（改动 ②+④ 生效的证据）。
- 改动 ⑤ 落地后：每轮模型响应的 reasoning/content 分片比与 token 用量可在诊断日志直接读出。

## 5. 文档与基线同步

`docs/ai-pipeline-baseline.md`（AGENTS.md 指定的行为契约文档）需追加 dated 注记：
1. §2 运行流程 fanout 注记（76 行区域）：fanout 扩展为「批次 + market 并行生成、直收购官」，回退契约不变；并发上限与修复预算口径一并注明。
2. 181 行区域（修复链注记）：`storeAssetBatch`/`sanitizedHorizon` 归一化链第 7 针（周期级 counterSignals 兜底，覆盖 assetTrends 与 keyAssets）+ `TrendBaselineContractPatch` 第 8 针（market/sectors counterSignals 兜底）+ `SubmitTrendReportTool` 关联降级补出口 + `prepareRepairs` 点名精准清除与跨轮状态。
3. §2.3 预算注记（162 行区域）：补 2026-09-03 批次制预算注记（`f6cb6ce`，8 只/批 × 400s 实测轮耗时，替代每资产 4s）；补单步预算分阶段取值（研究 60s / 提交与 fanout 修复 400s）。

`AgentRunPolicyCharacterizationTests` 已随 `f6cb6ce` 更新，步骤 4 再补 budgetSkip 新契约。

## 6. 预期收益

| 场景 | 现状 | 改后 |
|---|---|---|
| 29 只 closeReview 正常路径 | ~2800s（串行 5-6 轮提交） | **~700-900s**（fanout 一波并行 + 终检；推理链控制落地后 ~200-300s，见附 A） |
| fanout 局部失败 | 整段回退 + 暂存成果后续可被清空 | 回退但暂存成果保值，交互循环只补缺口 |
| 周期级缺反证条件 | 潜伏到终审、引爆全清、最贵轮重做 | 入库即兜底（资产周期 + keyAssets），终审不再因此拒批 |
| 关联降级（证据与主题无关联） | 降级后缺出口，整报拒批、market 全清 | 降级即补出口与低置信，终检不再因此拒批 |
| market/sectors 缺反证条件 | 潜伏到终审、拒批后 market 全清 | 入库即兜底 |
| 剩余预算 < 一轮提交成本 | 发起注定中途被杀的计费请求 | 止损转降级完成，已暂存批次保留 |
| 半开网络/慢端点 | 3400s 内能跑完 | 同样跑得完，且大概率提前 ~2000s |

## 7. 决策记录

- 周期级兜底选「保守占位」而非「入库拒批 + 批内修复」：后者每坏一批多烧 400-600s，与提速目标相悖；且与归一化链既有 6 针同一先例（基线文档 437 行「W4 修补扩展」语义）。
- 占位文案两级区分：资产周期用「模型未提供…」（证据健康、只缺表述），market/sectors 用中性「出现相反关键信号时重估」（避免对健康证据宣称「证据不足」）；均不复用 `rebuild` 的「证据不足」文案。
- ① 实现位置选 `sanitizedHorizon` 健康返回路径而非 storeAssetBatch 链上追加 map：一处覆盖 assetTrends 与 keyAssets 两条共用链。
- ①.5 选「降级即补出口」而非「打回模型重写」：出口是 App 侧本来就写死的确定性文案（horizon mustDowngrade 路径已有同款先例），打回模型徒增一轮 350-620s 且不保证修好。
- market 模块生成放 fanout 并行波而非串行前置：两者墙钟相同，但并行波共享 dataPayload 与修复循环，代码增量最小。
- fanout 并发上限 3（4 批 + market 共 5 路打同一 key，网关零重试）：墙钟增量 < 一个批次轮时长，换取限流鲁棒性。
- 单步预算分阶段：研究轮 60s 不变；提交/fanout 修复轮取 400s（totalTimeoutPerReportBatchSeconds，实测 352-617s 对齐）。小批次偏保守可接受——止损走降级完成而非失败。
- 不动 `maxOutputTokensPerRequest`（32K）与 prompt 叙述性输出抑制，推理链控制单独列附 A：本计划范围不膨胀，但把实测证据（617s/22,963 分片 vs 正文 243 字符）固化在案，防止该最大杠杆失联。
