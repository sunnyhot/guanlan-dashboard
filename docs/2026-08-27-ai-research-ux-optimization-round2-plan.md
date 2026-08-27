# AI 研判普通用户体验优化 · 第二轮详细计划

> 日期:2026-08-27 · 基线:v4.2.2(cf8cc3a)
> 承接:[2026-08-19-ai-research-ux-optimization-master-plan.md](./2026-08-19-ai-research-ux-optimization-master-plan.md)(下称「主计划」)
> 范围:AI 研判子系统的上手、信息架构、触达、结果可读性、信任与成本透明度(macOS + iOS)
> 总原则:**呈现层与纯派生逻辑先行、工程契约零改动**;涉及 prompt/schema/validator 的行为契约变更(W4)单独走基线流程,不在呈现层批次内混做。

---

## 0. 与第一轮计划的关系

主计划(2026-08-19)已落地以下与本轮相关的部分,**不再重复规划,直接引用**:

| 主计划编号 | 内容 | 状态 |
|---|---|---|
| A | 收盘复盘时间契约显性化 + 失败外显(状态徽章/按钮语义化/TodayBrief 复盘错过条目) | 已完成 |
| B | 术语统一(`ConfidenceGrade` 四档)+ `TermHelpView` 人话解释机制 | 已完成 |
| P1 #1/#2/#11 | 今日研判摘要卡 + 「怎么读」指南 + 锚点滚动 | 已完成 |
| P2 #3 | 供应商预设(智谱/OpenAI/DeepSeek)+ 设置分层 + 隐私说明 | 已完成 |
| P3 #4/#5 | macOS 决策画像入口 / iOS 术语接入 | 已完成 |
| P4 #6 | `TrendErrorTriage` 错误分诊人话化 | 已完成 |
| P4 #7 | 菜单栏 AI 研判姿态 | 已完成 |
| P4 #10 | 实时日志空闲态收纳为单行状态条(**生成中仍自动展开整面日志**) | 已完成(部分) |
| P4 #12 | 旧趋势跟踪清单 sunset(行动候选 → `addDecisionCase`) | 已完成 |

主计划候选池中与本轮重叠的条目,**本轮计划内细化后升级为正式条目**:#14(通知,本轮 W3.1 扩展)、#16(生成进度摘要,本轮 W3.3)、#19(区段新鲜度,本轮 W3.4)、#22(示例演示报告,本轮 W1.3)、#8(成本观测,本轮 W6.1 重新评估)。

---

## 1. 设计原则(本轮新增)

1. **有条件的明确,而非打包票**:消灭「说了一堆没有结论、给了结论没有条件」;安全闸口(禁绝对化措辞、证据不足降 `uncertain`)一律保留。
2. **BYOK 约束下的向导化**:无法内置 Key,就用「一次一步」的向导替代裸表单,并在配置前让用户看到价值(示例研判)。
3. **结论先行 + 渐进披露**:每个结论卡四要素固定(方向词 → 一句话结论 → 为什么 → 什么情况作废/升级),证据账本永远在第二层。
4. **系统叫用户,不是用户记时间**:错峰时间模型(09:00/盘中/21:00/周日)由通知、角标、菜单栏主动触达,而不是靠用户记忆。
5. **「暂不明确」也是明确答案**:只要它带着「在等什么信号」。

---

## 2. 本轮问题清单(现状与代码依据)

| # | 问题 | 现状(代码依据) | 影响 |
|---|---|---|---|
| Q1 | 链路 A(市场雷达/收盘复盘/长期研判)完成无任何通知 | 只有链路 B 有 `nextHourGuidanceNotificationSender`(`Core/AppModel.swift:136`);`TrendAnalysis.swift` 成功分支无通知 | 用户点了「更新研判」或等 21:00 复盘,完成时毫无感知 |
| Q2 | 四个研判入口语义不统一、无新鲜度 | 「立即研判/扫描市场/更新研判/复盘」散在四个区段(`EnhancementTodayPanel.swift:31,114,158`;`MarketCloseReviewSection.swift:25`),仅复盘按钮经 A 批次语义化 | 用户不知道点哪个、上次何时生成 |
| Q3 | 研判基础(可信度)沉底 | `credibilitySection` 在页面最后一位(`InvestmentIntelligenceDashboardView.swift:36`) | 用户读结论时看不到「基于 68% 穿透数据、判断基础有限」 |
| Q4 | 页面顺序与紧迫度承诺不符 | 实际顺序:摘要 → 日志 → 收盘复盘 → 盘中 → 雷达 → 长期 → 判断与复盘 → 研判基础(`InvestmentIntelligenceDashboardView.swift:28-37`);注释宣称「盘中实时 → 全市场机会 → 长期研判」 | 收盘复盘插在盘中指引前,盘中(最紧迫)不在首位 |
| Q5 | 结论模棱两可:prompt 只管「不撒谎」不管「说人话的结论」 | 仅禁绝对化措辞(`TrendResearchPromptBuilder.swift:224`);`rationale` 非空即可过校验,无 hedge 词禁表、无结论句式约束 | 可产出「市场震荡、多空交织、需密切关注」这类零信息量结论 |
| Q6 | `uncertain` 是死胡同 | UI 显示「不确定」灰字无下文(`EnhancementTrendPanel.swift:740`) | 安全降级被体验成 AI 无能 |
| Q7 | 结论淹没在长文、无统一结论卡 | `rationale` 直接渲染为灰字段落(`EnhancementTrendPanel.swift:338`) | 方向徽章有,但「一句话结论/作废条件」无固定位置 |
| Q8 | 配置仍是表单而非旅程 | 预设/分层已做,但首启路径仍是「去设置」(`InvestmentTodaySummaryCard.swift:98`),功能↔Key 依赖不可见 | BYOK 下最大流失点 |
| Q9 | 行动候选无截断提示、关注后无反馈 | `prefix(3)` 静默截断(`EnhancementTodayPanel.swift:229`);「加入关注」点击后仅变「已关注」;复盘日期需事后自设(`InvestmentIntelligenceDashboardView.swift:180` 显示「关注后设置复查时间」) | 行动闭环断点 |
| Q10 | 错过的自动窗口无主动提示 | `TrendModuleAutoAnalysisSchedule.dueSlot` 只补当日内;跨日错过无任何提示(仅收盘复盘有 TodayBrief 条目,A 批次) | 「每天一份」承诺不可靠 |
| Q11 | 生成中日志整面展开、进度无叙事 | `TrendLiveLogPanel` 生成中自动展开并滚动内部术语(`TrendLiveLogPanel.swift:38-48`) | 普通用户盯着 agent 术语等 5-30 分钟 |
| Q12 | 成本不可见 | 主计划 #8 已关闭:流式 usage 尾包在 `OpenAICompatibleAgentClient` 被丢弃;用户自付 Key 全程无费用预期 | 信任与续用风险 |
| Q13 | 研判无历史回看 | `trend-analysis-report.json` 单文件覆盖(`ai-pipeline-baseline.md` 第 5 节) | 无法回看上周长期研判 |
| Q14 | iOS/macOS 割裂 | iOS 仍是「观点/组合/决策/记录」四段(`Views_iOS/EnhancementSectionView.swift:27-33`) | 双端心智不一致 |

---

## 3. 工作流详细方案

> 每条含:目标 / 方案 / 涉及文件 / 验收标准 / 风险级别(呈现层 / 行为契约)。
> 编号规则:`W<工作流>.<序号>`,主计划既有条目以「主#N」引用。

### W1 · 上手体验(BYOK 约束)

#### W1.1 六步配置向导(升级主 #3)
- **目标**:新用户从 AI 页内完成「选供应商 → 拿 Key → 贴 Key → 检测 → 选隐私 → 生成首份研判」,不再跳设置页面对裸字段。
- **方案**:新增 `TrendSetupWizardSheet`(macOS),步骤:
  1. 选供应商卡片(智谱/OpenAI/DeepSeek/自定义,每人话一句 + 「没有账号?去注册」外链;卡片标注「支持工具调用」);
  2. 拿 Key 并粘贴([在浏览器打开控制台] 走 `TrendProviderPreset.consoleURL`;剪贴板 `sk-`/`tvly-` 前缀自动预填,见 W1.4);
  3. 检测模型(复用 `checkTrendAIConnection`,成功打勾,失败走 W1.6 救援);
  4. 隐私模式大白话二选一(「AI 看不到金额·推荐」/「AI 看到金额·分析更准」);
  5. 可选增强:Tavily → 解锁全市场雷达 / Alpha Vantage → 增强美股财报 / SEC → 免费只需邮箱;每张卡标「可选」可跳过;
  6. 完成:「立即生成第一份研判」(full scope)+「顺便开启自动分析」(说明每日 09:00/21:00 消耗与计费)。
- **入口**:AI 页空态(替代「去设置」跳转)+ 设置页「配置向导」按钮;仅在 provider 未配置时自动出现,已配置用户只看到「重新配置」。
- **涉及文件**:新 `Views_macOS/InvestmentIntelligence/TrendSetupWizardSheet.swift`;改 `InvestmentTodaySummaryCard.swift`、`SettingsTrendPanel.swift`;iOS 简化版见 W1.8。
- **验收**:未配置用户 6 步内完成并可一键生成首份研判;每步只有单一任务;已配置用户不被打扰。
- **风险**:呈现层。

#### W1.2 空态改「能力清单 + 示例研判」入口
- **目标**:配置前让用户看懂「我会得到什么、缺什么 Key 会少什么」。
- **方案**:AI 页空态改为:①四行能力卡片(盘中指引/收盘复盘/长期研判/全市场机会),实时状态 ✅ 可用 / ⚠️ 缺 Tavily(点此补上)/ ❌ 未配置模型(点此开始),点击直达向导对应步骤;②「预览示例研判」按钮(W1.3)。
- **涉及文件**:`InvestmentTodaySummaryCard.swift`(空态)、`EnhancementTodayPanel.swift`(能力判定复用 `trendSettings.provider.isConfigured` / `webSearch.isConfigured`)。
- **验收**:任一缺失状态一行内说明「缺什么、怎么补」;不出现无解释的灰按钮。
- **风险**:呈现层。

#### W1.3 示例演示报告(升级主 #22)
- **目标**:BYOK 下抵消「先掏钱再验证」的心理门槛。
- **方案**:一份静态脱敏 `TrendAnalysisReport` 演示数据(标注「示例数据,非真实研判」),喂给现有渲染组件只读展示;向导第 1 步与空态均可预览。
- **涉及文件**:新 `Core/InvestmentIntelligence/DemoTrendReport.swift`(静态数据)、空态/向导接入。
- **防腐测试**:单测断言 Demo 数据通过 `TrendAnalysisValidator` 全部校验——W4.3 收紧校验后必须同步更新 demo,否则新用户看到的第一份「产品长什么样」恰是与 W4 目标相反的旧范式;改 validator 时该测试强制同步。
- **验收**:示例报告覆盖四链路的主要产物形态;显著标注非真实;单测锁住 validator 兼容。
- **风险**:呈现层(数据是静态假数据,不触碰任何契约)。

#### W1.4 剪贴板智能预填 + 供应商推断
- **方案**:向导打开时检测剪贴板 `sk-`/`tvly-`/`glm` 等前缀自动填入对应字段并高亮;贴 Key 后按 `TrendProviderPreset` 表推断供应商并提示确认。
- **涉及文件**:`TrendSetupWizardSheet.swift`(新)。
- **验收**:复制 Key → 打开向导即预填;推断正确时免去选供应商一步。
- **风险**:呈现层。

#### W1.5 预设应用反馈
- **方案**:设置页点预设 chip 静默填表现状(`SettingsTrendPanel.swift:253`)改为 Toast「已填好智谱地址与模型,只需贴 Key」。
- **涉及文件**:`SettingsTrendPanel.swift`。
- **风险**:呈现层。

#### W1.6 失败救援清单(扩展主 #6)
- **方案**:`TrendErrorTriage` 已有人话原因,补充「常见原因清单」:Key 无效/余额不足/模型不支持工具调用(预设卡标注哪些模型支持)/网络不通;检测失败时展示清单 + 逐条可执行的修复动作。
- **涉及文件**:`TrendSetupWizardSheet.swift`、`TrendErrorTriage.swift`(只加展示文案,不动分诊逻辑)。
- **风险**:呈现层。

#### W1.7 成本预期文案
- **方案**:向导第 1 步写明「Key 直接向模型服务商计费,本 App 不中转;一次市场雷达约 ¥0.5–2(视模型与搜索次数)」;自动分析开启前再次确认。
- **涉及文件**:`TrendSetupWizardSheet.swift`。
- **风险**:呈现层(金额为量级预估,文案注明「约」)。

#### W1.8 iOS 简化配置向导
- **目标**:iOS 端新用户同样在设置旅程内完成「选供应商 → 贴 Key → 检测 → 隐私模式」,不面对裸表单。现状 `IOSTrendSettingsView` 是 provider/webSearch/alphaVantage 三段 Form + 手动「保存」,与 macOS Q8 同病。
- **方案**:`IOSTrendSettingsView` 改造为分步向导:预设卡片选供应商(复用 `TrendProviderPreset` 与 `consoleURL` 外链,已有)→ 贴 Key(剪贴板预填同 W1.4)→ 检测(复用 `checkTrendAIConnection`,失败展示 W1.6 救援清单)→ 隐私模式大白话二选一(写入 `trendSettings.defaultPrivacyMode`,Core 已有)→ 完成。可选增强(Tavily/Alpha Vantage)收敛为完成页的开关列表,不做 macOS 六步全量;AI 页空态入口与 W1.2 对齐。
- **涉及文件**:`Views_iOS/IOSTrendSettingsView.swift`、`Views_iOS/EnhancementSectionView.swift`(空态入口)。
- **验收**:未配置用户在 iOS 上 4-5 步完成配置并可触发首次研判;已配置用户进入仍是可用的编辑表单,不被向导打扰;Views_iOS 不在 SPM 目标,须 Xcode 工程构建验证并记录执行者。
- **风险**:呈现层(Views_iOS,需 Xcode 验证)。

### W2 · 信息架构

#### W2.1 页面顺序对齐紧迫度承诺
- **方案**:调整 `InvestmentIntelligenceDashboardView` 区段顺序为:今日研判摘要 → **盘中实时指引 → 全市场机会雷达 → 收盘复盘 → 组合长期研判** → 判断与复盘 → 研判基础;非交易时段盘中区段空态已有引流(P1 已做),顺序调整后仍需验证。
- **涉及文件**:`InvestmentIntelligenceDashboardView.swift`、`EnhancementTodayPanel.swift`(注入顺序)。
- **验收**:盘中区段在交易时段位于复盘之前;锚点滚动仍正确(区段 id 不变)。
- **风险**:呈现层。

#### W2.2 研判基础上移
- **方案**:`credibilitySection` 移到摘要卡下方,做成全局横条(穿透覆盖率 + 数据时效 + 低覆盖警示);摘要卡在低覆盖(<70%)时加警示角标。
- **涉及文件**:`InvestmentIntelligenceDashboardView.swift`。
- **验收**:打开页面第一屏能看到「基于 68% 穿透数据 · 判断基础有限」。
- **风险**:呈现层。

#### W2.3 「今天一句话」hero 结论
- **方案**:从现有数据纯派生一句总判断(优先盘中 posture → 市场雷达最强信号 → 中期 horizon),展示在摘要卡顶部:「今天:防御为主,不追高,等量能信号」;派生逻辑放 Core(可测)。
- **涉及文件**:新 `Core/InvestmentIntelligence/TodayVerdictDerivation.swift` + `InvestmentTodaySummaryCard.swift`。
- **冲突语义**:盘中与中期信号方向冲突时,不得平均成无方向的中性句(那是 Q5 要消灭的形态);要么双短句(「短线防御 · 中线逢低布局」),要么不显示 hero。冲突路径与降级路径一并写入 `TodayVerdictDerivation` 测试。
- **验收**:hero 一句话 ≤ 20 字;四链路均无内容时不显示;信号冲突时输出双短句或隐藏,绝不输出无方向中性句;测试覆盖优先级、冲突与降级路径。
- **风险**:呈现层(纯派生)。

#### W2.4 简洁/详细双模式
- **评估前置**:与 W4.4 结论卡(结论先行、证据折叠)功能可能重叠——R2-P1 上线后先收集真实反馈,若结论卡已满足「普通用户不看长文」,本条可砍或缩窄为「证据账本显隐」单开关,不盲目动工。
- **方案**:每区段默认「简洁模式」(结论卡 + 2-3 条关键依据);「详细模式」展开完整证据账本、来源状态、warnings。模式切换全局记忆(`@AppStorage`)。
- **涉及文件**:各研判区段视图、`TrendComponents.swift`。
- **风险**:呈现层。

#### W2.5 时间线心智模型重构(远期)
- **方案**:把四链路按用户一天的时间轴呈现(开盘前 → 盘中 → 收盘 → 每周体检),替代平行板块;依赖 W2.1-W2.4 稳定后评估。
- **风险**:呈现层大改,单独评审。

### W3 · 触发、等待与触达

#### W3.1 链路 A 完成通知(扩展主 #14)
- **方案**:趋势研究成功/失败落盘后发本地通知,与链路 B 同款(`LocalNotificationManager` + 深链):
  - 收盘复盘成功:「今日复盘已生成,点击查看」;失败:「未完成,可手动补做」(主 #14,建议默认开);
  - 市场雷达成功:「今日市场机会已更新:N 个方向」;
  - 长期研判成功:「本周组合研判已更新」;
  - 手动触发的首份研判成功:「你的第一份研判已生成」(配合 W1.1 收尾)。
- **信号来源**:与 A 批次同源(attempt key + `moduleGeneratedAt`),零新状态。
- **通知偏好(防打扰)**:落地后通知路径达 4+ 条(盘中已有 + 复盘/雷达/长期/首份),必须配设置项:设置页新增「AI 研判通知」分组,按链路粒度可关;默认只开「收盘复盘完成 + 自动失败」两类,雷达/长期/首份研判默认关、用户可自行打开。不做偏好设置,「系统叫用户」会退化成「系统骚扰用户」。
- **深链接线**:通知点击路由(UNUserNotificationCenter delegate → `selectedSection` + 区段锚点滚动,复用 B 链路先例)需实际接线并实测,列入验收;不能只发通知不验证落地。
- **涉及文件**:`Core/AppModel/TrendAnalysis.swift`(成功/失败分支)、通知点击路由接线、设置页通知分组;`LocalNotificationManager` 已有。
- **验收**:三种链路完成均有通知且通知点击实测可达对应区段;失败通知只对自动运行发送(手动失败用户在场);通知可按链路在设置中关闭,默认开启项符合上述最小集。
- **风险**:呈现层(通知) + 新增系统权限请求时机需评估(建议在向导完成页请求)。

#### W3.2 触发时给预期
- **方案**:四个手动入口统一弹轻提示:「通常需要 5–15 分钟,期间可正常使用,完成后会通知你」;盘中研判为「约 1–3 分钟」。
- **成本同场提示**:全量 scope 手动运行同时显示「预计消耗 ¥X 量级(视模型与搜索次数)」——成本预期应出现在每次付费动作前,而不只在向导出现一次(W1.7 的日常化);盘中轻量链路可省。
- **涉及文件**:`EnhancementTodayPanel.swift`、`MarketCloseReviewSection.swift`(统一封装一个 start 入口)。
- **风险**:呈现层。

#### W3.3 生成进度叙事化(升级主 #16)
- **方案**:生成中首屏只显示五步进度条(复用 `NextHourGuidanceProgressView` 样式:持仓/行情/快照/三方分析/汇总校验)+ 一句当前步骤人话;完整日志默认收起,仅在用户点「查看运行详情」时展开。替代现在生成中自动展开整面日志的行为。
- **涉及文件**:`TrendLiveLogPanel.swift`、`TrendResearchProgressCard`(合并设计,避免连续两次改日志面板)。
- **非线性兼容**:Agent 存在校验拒批→修正重提的循环,进度条按阶段只进不退;重试时显示「校验修复中(第 2 次尝试)」而非重走进度。合并 `TrendResearchProgressCard`(`MarketCloseReviewSection.swift` 内)时保留其状态语义,不引入回跳。
- **验收**:生成中首屏无内部术语;进度可感知且不回跳,重试轮次可见;日志仍可达(高级用户)。
- **风险**:呈现层。

#### W3.4 四个按钮话术统一 + 上次生成时间(升级主 #19)
- **方案**:四个入口按钮统一为「更新 + 链路名」结构,副标题显示「上次 09:00 生成 · 每日自动」;盘中按钮显示「上次 10:15 研判 · 有效至 11:15」。
- **涉及文件**:`EnhancementTodayPanel.swift`、`MarketCloseReviewSection.swift`。
- **风险**:呈现层。

#### W3.5 错过的自动窗口主动问(扩展 Q10)
- **方案**:启动时检测「昨日市场雷达未生成」(跨日错过)与「昨日收盘复盘未生成」,TodayBrief 已有 `closeReviewMissed`,补 `marketRadarMissed` 条目 + AI 页顶部横幅「昨天的市场扫描没做,现在补吗?」(带成本提示);长期研判(周日 20:00)错过同理。
- **横幅时机(避免花冤枉钱)**:`TrendAutoAnalysisSchedule.dueSlot` 的语义是「上批 slot 过期 + 今日时刻已到即重新 due」——市场雷达(每日 09:00)错过后,App 在下一班在线时自动分析会自己补上。横幅仅在「距下一班自动运行 > 2 小时」时出现,避免怂恿用户手动做马上会自动发生的事;真正需要主动补的主要是收盘复盘(下一班次日 21:00)与每周长期研判。
- **连续失败升级**:TodayBrief 增加「自动研判已连续 N 天失败」条目(附 `TrendErrorTriage` 人话原因),与 `closeReviewMissed` 同机制——否则 Key 过期/余额不足时,用户只看到「昨天没做,补吗?」,手动补一次又失败,横幅反而掩盖根因。
- **涉及文件**:`Core/TodayBrief.swift`(新 kind)、`EnhancementCenterView.swift`(横幅)、AppModel 派生。
- **验收**:跨日错过任一链路,启动即见可执行的补做入口;距下一班自动运行 ≤ 2 小时不出现横幅;连续 ≥ 2 天自动失败时 TodayBrief 有升级条目;不自动补跑(成本由用户决定)。
- **风险**:呈现层 + 纯派生。

#### W3.6 边栏角标「AI 有新研判」
- **方案**:macOS 侧边栏「AI 研判」显示红点/计数,基于「最近一次链路成功生成时间 > 用户上次访问 AI 页时间」派生;访问即清零(`@AppStorage` 记录 lastSeenAt)。
- **涉及文件**:`ContentView.swift`(`sidebarBadge`)、AppModel 派生、`EnhancementCenterView` onAppear 记录。
- **验收**:自动研判完成后未读时角标可见,进入 AI 页后消失。
- **风险**:呈现层 + 一个新 AppStorage 键。

#### W3.7 手动请求排队(替代置灰)
- **方案**:自动任务运行中,手动点击「更新」进入队列,完成后自动执行,按钮显示「已排队」;替代现在的 `disabled`(`EnhancementTodayPanel.swift:40-44`)。
- **涉及文件**:`Core/AppModel/TrendAnalysis.swift`(任务协调)、四个入口。
- **验收**:互斥契约不变(A/B 仍不并发),用户请求不丢失。
- **风险**:行为层(不触碰落盘/校验契约,但动任务调度,单独提交 + 回归)。

### W4 · 结果可读性与明确性(行为契约变更,单独基线流程)

> **本工作流触碰链路 A 的 prompt/schema/validator,必须按 `docs/ai-pipeline-baseline.md` 要求:先更新基线文档与 characterization 测试,再动实现;单独 PR,不与其他批次合并。** 参照 2026-08-19 P5 followup 契约变更文档的流程。

#### W4.1 Prompt 明确性约束(`TrendResearchPromptBuilder.swift`)
- 结论句式规则:每个 `rationale` 第一句必须是带方向的判断句(「看多/看空/中性/暂不明确 + 因为……」)≤ 40 字;全文 ≤ 120 字。
- hedge 词禁用表(与绝对化禁令并列):禁「可能有机会/不排除/有待观察/建议关注/需持续跟踪/视情况而定」等零信息量措辞——要么给方向,要么给「在等什么」。
- `uncertain` 必填出口:`rationale` 末尾必须写「待观察信号:……」,说明什么信号、什么时间点出现后转为看多/看空。
- 注意:约束变严会增加 submit 拒批率,现有「拒批教训」correction 前移机制(主计划基线 74 行注记)可承接;实施后需真实生成验证拒批率。

#### W4.2 Schema:新增 `whatWouldChange` 字段(`TrendAnalysisModels.swift`)
- 给 `TrendHorizon` / `TrendSectorView` / `TrendOpportunityView` / `TrendActionCandidate` 增加 `whatWouldChange: String`(失效/升级条件,用户可读短句)。
- 旧报告解码 `decodeIfPresent ?? ""` 兜底,**不 bump schemaVersion**;UI 对空值降级用 `counterSignals` 首条。

#### W4.3 Validator 三条新校验(`TrendAnalysisValidator.swift`)
1. `rationale` 首句必须命中方向词表,否则拒批要求重写;
2. `direction == .uncertain` 必须带「待观察信号」,否则拒批;
3. 新字段 `whatWouldChange` 非空。
- 同步更新:`SubmitTrendReportTool` 校验链快照、`TrendAnalysisValidatorTests`、`AgentRunPolicyCharacterizationTests` 相关冻结用例。

#### W4.4 统一结论卡组件(UI,可与 W4.1-W4.3 解耦先行)
- 新组件 `VerdictCard`(方向徽章 + 把握 + 一句话结论 + 为什么 + 什么情况作废 + 依据折叠),替换周期卡/板块卡/机会卡的 `rationale` 裸渲染;盘中行动详情同步样式。
- 涉及文件:新 `Views_macOS/InvestmentIntelligence/VerdictCard.swift`;`EnhancementTrendPanel.swift`、`InvestmentDirectionCard.swift`、`NextHourGuidanceActionDetailSheet.swift`。
- 风险:呈现层(可先于 W4.1-W4.3 上线,旧数据降级展示)。

#### W4.5 「不确定」→「暂不明确 · 在等 XX」
- 徽章文案改「暂不明确」,下一行显示待观察信号(数据来自 W4.2 的 `whatWouldChange`/rationale 尾句);未升级数据时降级为「暂不明确 · 依据不足」。
- 涉及文件:`EnhancementTrendPanel.swift`(`TrendDirection.displayText`)、`InvestmentDirectionCard.swift`。

#### W4.6 置信度人话锚定
- 把握徽章旁挂解释:高(≥75)「可直接参考」、中(45-74)「需结合自己判断」、低(<45)「仅供参考,先别动」;复用 `TermHelpView` 机制。
- 涉及文件:`TrendComponents.swift`、`ResearchTermGlossary.swift`(词表补一条)。

#### W4.7 分歧显式化
- 结论卡依据区将 supports/counters 并排展示(「支持:2 条 ▸」「反对:1 条 ▸」),反对证据非空时结论卡加「有分歧」标记;数据层 `claimEvidence` 已具备,纯 UI。
- 涉及文件:`VerdictCard.swift`、`TrendEvidenceDetailModel` 复用。

### W5 · 信任与行动闭环

#### W5.1 行动候选「还有 N 条」+ 关注即时反馈
- 「行动候选」截断时显示「还有 N 条,查看完整报告」;「加入关注」点击后 Toast「已加入判断与复盘」+ 当场可选复盘日期(默认自动建议:X 天后),消除「关注后设置复查时间」断点。
- 涉及文件:`EnhancementTodayPanel.swift`、`DecisionCaseDetailSheet.swift`。

#### W5.2 行动一键落地
- 行动候选增加快捷操作:生成待办交易草稿(`PendingTradesStore` 已有)/ 加入自选清单(`PersonalWatchlistStore` 已有),按钮以菜单形式挂「加入关注」旁。
- 涉及文件:`EnhancementTodayPanel.swift`、AppModel 对应 action。

#### W5.3 每日回指展示强化
- P5 followup 契约已落地 `followupReviews`(链路 B);本轮把「昨日关注今天怎么样了」做成盘中区段第一条可见内容,数据已存在,纯 UI。
- 涉及文件:`NextHourGuidanceFollowupReviewsView.swift`(已有,位置/样式强化)。

#### W5.4 历史成绩单(远期)
- 「判断与复盘」增加聚合统计页:过去 90 天判断条数、兑现率、置信度-结果校准;依赖 `DecisionCase` 复盘数据积累,单独评审。
- 涉及文件:新统计视图 + `DecisionHistoryView.swift`。

#### W5.5 量化条件自动复查(远期)
- 触发/失效条件中可量化部分(价格/涨跌幅阈值)自动检测并在满足时通知「XX 的触发条件可能已满足」;自然语言条件仍人工。与 Investment Intelligence Slice 7「结构化触发条件求值」对齐。
- 涉及文件:新求值器 + `DecisionCase` 通知接线。
- 风险:行为层,单独评审。

### W6 · 成本与隐私透明

#### W6.1 成本可观测(重开主 #8)
- 前置调研已确认:流式 usage 尾包在 `OpenAICompatibleAgentClient` 被丢弃。方案:Agent 完成链路收集 usage(tokens/调用次数)写入运行 artifact,UI 在报告脚注展示「本次约 X tokens」,设置页聚合「本月用量」;金额估算按供应商公开单价表(量级)。
- **缺失语义**:部分供应商流式尾包不返回 usage,此时显示「本次用量未知(供应商未返回)」,不得显示 0(0 会被读成免费);金额一律带「约」并注明所依据的单价表。
- 涉及文件:`OpenAICompatibleAgentClient.swift`、`TrendAgentRunArtifactStore`、报告脚注、设置页。
- 风险:行为层(不动落盘契约,只加采集),单独提交。

#### W6.2 月度预算上限(远期)
- 用户设月度费用预算,自动分析超出即停并提醒;依赖 W6.1 数据。

#### W6.3 历史研判归档(远期)
- `trend-analysis-report.json` 改为保留最近 N 份(轮转文件)+「历史研判」只读视图;触碰磁盘契约(基线第 5 节),单独评审。

### W7 · 双端一致

#### W7.1 iOS 对齐 macOS 结构
- iOS 从「观点/组合/决策/记录」四段改为与 macOS 相同的信息架构(今日研判摘要 + 按紧迫度分区 + 研判基础);词表/档位 Core 已就绪(P3 已部分接入)。
- 涉及文件:`Views_iOS/EnhancementSectionView.swift`。
- 验证:Views_iOS 不在 SPM 目标,需 Xcode 构建验证并记录执行者。

#### W7.2 iOS 推送配套(升级主 #23)
- W3.1 通知的 iOS 端:UNUserNotification + 权限请求时机(iOS 天然期望推送);与 W7.1 同批评估。

---

## 4. 实施分期

### R2-P1 · 低风险高感知(呈现层,第一批)
| 条目 | 内容 | 状态 |
|---|---|---|
| W3.1 | 链路 A 完成通知(含首份研判送达) | ✅ 2026-08-27 |
| W2.1 + W2.2 | 页面顺序对齐 + 研判基础上移 | ✅ 2026-08-27 |
| W3.3 + W3.4 | 进度叙事化 + 四按钮话术统一 | ✅ 2026-08-27 |
| W4.4(先行) | 统一结论卡组件(旧数据降级) | ✅ 2026-08-27 |
| W5.1 | 行动候选截断提示 + 关注即时反馈 | ✅ 2026-08-27 |
| W1.4 + W1.5 | 剪贴板预填 + 预设应用 Toast | ✅ 2026-08-27 |

验收:全量 `swift test` 全绿(基线 680,2026-08-27 实测);不触碰任何行为契约。

> **R2-P1 落地记录(2026-08-27)**:700 个测试全绿(基线 680 + 新增 22)。实现要点:
> - W3.1:`TrendCompletionNotification` 载荷 + `TrendAnalysisSettings.notifications` 偏好(宽容解码,默认只开复盘完成+自动失败)+ 设置页「研判通知」分组;通知点击经新深链类型 `investmentIntelligenceSection` → `pendingInvestmentSectionAnchor` → 区段锚点滚动;`trendAnalysisNotificationSender` 为可注入闭包,测试注入 spy(失败仅自动运行发送、手动首份按偏好)。
> - W3.3:新增 `Core/Trend/TrendRunProgressNarrative.swift`(五步阶段只进不退 + 校验重试计轮次),`TrendResearchProgressCard` 升级为五步叙事条,`TrendLiveLogPanel` 生成中默认收起为首行人话、点「查看运行详情」展开。
> - W4.4:新增 `Views_macOS/InvestmentIntelligence/VerdictCard.swift` + `Core/Trend/TrendVerdictPresentation.swift`(首句拆分纯函数);作废条件在 W4.2 前降级用反证首条;`TrendDirection` 展示映射从 ETP 私有扩展迁出共用。
> - UIExperienceRegressionTests/TrendDashboardSummaryTests 三处源码断言随结构同步更新(等高 reservedSpace、雷达副标题回退文案、板块卡 VerdictCard 渲染),冻结意图不变。

### R2-P2 · 上手旅程(向导与空态)
| 条目 | 内容 | 状态 |
|---|---|---|
| W1.1 | 六步配置向导(macOS) | ✅ 2026-08-27 |
| W1.2 + W1.3 | 空态能力清单 + 示例演示报告 | ✅ 2026-08-27 |
| W1.6 + W1.7 | 失败救援清单 + 成本预期文案 | ✅ 2026-08-27 |
| W3.2 | 触发时给预期 | ✅ 2026-08-27 |
| W1.8 | iOS 简化向导(Views_iOS,Xcode 验证) | ✅ 2026-08-27 |

> **R2-P2 落地记录(2026-08-27,分支 pre-intelligence-v2)**:704 个测试全绿。
> - 向导直接写 `model.trendSettings` 并逐步保存(与设置面板同模式),崩溃不丢进度;检测步成功才放行。
> - `DemoTrendReport`(Core/InvestmentIntelligence)一次通过当前 Validator,防腐测试 `DemoTrendReportTests` 锁住;预览复用 VerdictCard 同套视觉。
> - W3.2 统一入口 `startTrendAnalysisFromUser(withExpectation:)` / `startNextHourGuidanceFromUser()`,时长+费用量级同场提示。
> - iOS 向导为 4+1 步简化版(可选增强收敛为完成页提示,不写占位 Key);已配置用户仍进完整表单。
> - **Views_iOS 验证**:xcodebuild `-sdk iphonesimulator26.5 CODE_SIGNING_ALLOWED=NO` 编译通过(执行者:ZCode agent,2026-08-27);Xcode 工程经 `xcodegen generate` 同步新增文件。
> - 本机模拟器运行时未安装(iOS 26.5 platform 缺 destination 运行时),真机/模拟器运行级验证待后续具备环境时补做。

### R2-P3 · 触达闭环(派生与调度层)
| 条目 | 内容 | 状态 |
|---|---|---|
| W3.5 | 错过的自动窗口主动问(TodayBrief 新 kind) | ✅ 2026-08-27 |
| W3.6 | 边栏角标「AI 有新研判」 | ✅ 2026-08-27 |
| W2.3 | 「今天一句话」hero | ✅ 2026-08-27 |
| W3.7 | 手动请求排队(单独提交 + 互斥回归) | ✅ 2026-08-27 |
| W5.3 | 每日回指展示强化 | ✅ 2026-08-27 |
| W7.1 + W7.2 | iOS 结构对齐 + 推送(单独批次,Xcode 验证) | ✅ 2026-08-27 |

> **R2-P3 落地记录(2026-08-27,分支 pre-intelligence-v2,三个提交)**:
> - **089119c(呈现+派生)**:横幅时机按合并后的规则实现(距下一班自动运行 ≤2h 不提示,自动分析关闭恒提示);连击计数存 `trendSettings.autoFailureStreaks`(宽容解码);TodayBrief 新增 marketRadarMissed/longTermMissed/autoAnalysisRepeatedFailure 三 kind;角标按链路生成时间晚于 `AppStorageKey.aiResearchLastSeen` 计数,进出 AI 页清零(替代已 sunset 的旧跟踪计数);hero 纯派生 `TodayVerdictDerivation`(冲突用固定对照措辞,测试覆盖);回指视图上移盘中区段第一条。
> - **9193ce8(W3.7,单独提交)**:排队状态 `queuedUserRequestedScope`,当前任务结束自动出队;取消连排队的请求一并清空;按钮三态「运行中/已排队/空闲」;可阻塞假 Agent 驱动的排队/取消/互斥回归 ×2。
> - **W7 批次**:iOS 从「观点/组合/决策/记录」四段改为与 macOS 同构的纵向单页(今日研判摘要+hero → 研判基础 → 收盘复盘 → AI 眼中的组合 → 判断与复盘);通知深链经共享 handler 落到 AI 页并消费锚点(W7.2)。iOS 验证:xcodebuild `-sdk iphonesimulator26.5` 全部源码编译通过,唯一失败为本机未安装模拟器运行时导致的资产目录编译(环境限制,执行者:ZCode agent 2026-08-27);CoreSimulator 目标解析不稳定,验证时用 `-target QiemanDashboard-iOS` 绕过 destination 解析。
> - 全量测试 726 全绿。

### R2-P4 · 明确性(行为契约,单独基线流程)
| 条目 | 内容 | 状态 |
|---|---|---|
| W4.1 | Prompt 明确性约束 | ✅ 2026-08-27 |
| W4.2 + W4.3 | `whatWouldChange` 字段 + Validator 三校验 | ✅ 2026-08-27 |
| W4.5 + W4.6 + W4.7 | 暂不明确出口 + 置信度锚定 + 分歧显式化(UI) | ✅ 2026-08-27 |
| W2.4 | 简洁/详细双模式 | ✅ 2026-08-27(缩窄版) |

流程:先更新 `ai-pipeline-baseline.md` 与 characterization 测试 → 实现 → 真实生成验证拒批率 → 独立 PR。

> **R2-P4 落地记录(2026-08-27,分支 pre-intelligence-v2,提交 cb84201 + R2-P4B)**:
> - **cb84201(行为契约)**:四个类型新增 `whatWouldChange`(宽容解码,未 bump schemaVersion);Validator 三校验(方向词首句/uncertain 待观察信号出口/whatWouldChange 非空);prompt `clarityContract` 注入 full 与增量 scope;**两个配套机制保证增量运行不被旧数据拖垮**——App 强制降级短期时自动补写待观察信号;`TrendBaselineContractPatch` 对复用基线打补丁(新提交数据照常校验不静默修补)。基线文档 §5/§7.3 已按流程先行更新。
> - **R2-P4B(UI)**:W4.5「不确定→暂不明确」,结论卡显示「在等:XX」(取 rationale 待观察信号尾句,缺省「依据不足」);W4.6 置信度锚定(词表新增 confidenceAnchor 条目,结论卡内把握胶囊旁挂「可直接参考/需结合自己判断/仅供参考先别动」);W4.7 分歧显式化(依据行「支持 N 条 · 反对 M 条」并排,反对非空标「有分歧」徽章);W2.4 按评估前置结论做**缩窄版**——摘要卡眼睛开关控制「证据与风险边界」整块显隐(AppStorage 全局记忆),未做完整双模式(结论卡已承担「结论先行」职责)。
> - 测试 733 全绿(新增 W4 拒批/词表/基线补丁/出口提取 9 个);iOS 源码经 xcodebuild iphonesimulator SDK 编译验证通过。
> - **待办**:真实模型生成验证拒批率(需配置 Key 的环境人工执行;约束变严由既有拒批修正机制承接,若拒批率异常需回调方向词表或首句长度约束)。

### 远期(单独评审)
W2.5 时间线重构 / W5.4 成绩单 / W5.5 量化条件自动复查 / W6.1 成本采集 / W6.2 预算上限 / W6.3 历史归档。

---

## 5. 全局约束(与主计划一致,补充本轮)

1. **测试基线**:每批次收尾全量测试全绿;本机须 `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`(主计划约束 2)。
2. **行为契约**:W4 与 W6.1、W3.7、W5.5、W6.3 触碰 prompt/schema/调度/磁盘契约,必须先走 `ai-pipeline-baseline.md` 基线更新流程,单独 PR;其余批次保持「工程契约零改动」。
3. **落盘兼容**:新字段一律 `decodeIfPresent ?? 默认` 宽容解码,不 bump schemaVersion;`TrendConfidence.label`、Snapshot schema、`x-sign` 等一律不动。
4. **红涨绿跌**:一切涨跌色走 `AppPalette`。
5. **构建**:新增 Core/Views_macOS 文件 SPM 与 `build_macos_app.sh` 自动包含;CLI 相关新文件同步 `scripts/build_qieman_cli.sh`;`Views_iOS` 改动合并前须经 Xcode 工程构建验证并记录执行者。
6. **文案**:改文案先查 `UIExperienceRegressionTests` 等源码断言并同步更新;新增术语必须登记 `ResearchTermGlossary`(测试强制)。
7. **提交规范**:每批次独立提交,标题面向用户可读(Release notes 由 commit 标题生成)。
8. **文档**:每批次收尾回写本文档状态列;全部完成后刷新 AGENTS.md 规模数字与本文件链接。
9. **复用优先**:派生与评分类逻辑(W2.3 hero / W3.4 新鲜度 / W3.6 角标 / W4.7 分歧)动笔前先核对 `Core/InvestmentIntelligence/` flag-gated 侧已有实现(`EvidenceFreshnessPolicy` 新鲜度、`ClaimAssessmentEngine` 证据评估等),同域不建两套逻辑。

---

## 6. 验收清单(全部批次完成后)

- [ ] 未配置模型的新用户可在 AI 页内 6 步完成配置并生成首份研判,全程不面对 Base URL/模型名等裸字段
- [ ] 用户配置前可通过示例研判预览产品价值;缺什么 Key、少什么功能一眼可见
- [ ] 四链路完成/失败均有系统通知,深链直达对应区段;边栏角标提示未读研判;通知可在设置中按链路关闭,默认只开最小集(复盘完成 + 自动失败)
- [ ] 页面按紧迫度排序,盘中指引在交易时段居首;研判基础(可信度)首屏可见
- [ ] 每条结论具备「方向词 + 一句话结论 + 为什么 + 什么情况作废/升级」四要素;「暂不明确」必带「在等什么信号」
- [ ] 生成中首屏无 agent 内部术语,只有进度与当前步骤人话
- [ ] 「加入关注」有即时反馈并可当场设定复盘日期;行动候选无静默截断
- [ ] 错过的自动窗口(市场雷达/收盘复盘/长期研判)启动即有可执行的补做入口;横幅不与临近的下一班自动运行重复;连续自动失败有 TodayBrief 升级提示
- [ ] 本页与「怎么读」指南、术语速查一致;iOS 与 macOS 同一信息架构与命名
- [ ] 全量 `swift test` 全绿;characterization 基线(链路 A/B/C)全部保持或已按流程更新
