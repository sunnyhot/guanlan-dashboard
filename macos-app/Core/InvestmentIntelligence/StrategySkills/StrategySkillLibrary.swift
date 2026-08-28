import Foundation

/// 内置策略技能库（15 个）。移植自 daily_stock_analysis strategies/*.yaml（MIT），
/// 量化条件与评分调整保留原文口径；工具名适配本仓库 Agent 工具集：
/// get_daily_history/analyze_trend/get_realtime_quote → `get_daily_kline`（内含技术面摘要），
/// search_stock_news → `web_search`，get_sector_rankings → `get_market_breadth` + `web_search`。
enum StrategySkillLibrary {
    static let all: [StrategySkill] = [
        bullTrend, maGoldenCross, volumeBreakout, hotTheme, eventDriven,
        shrinkPullback, growthQuality, expectationRepricing, bottomVolume,
        boxOscillation, oneYangThreeYin, chanTheory, waveTheory, emotionCycle, dragonHead,
    ]

    static func skill(id: String) -> StrategySkill? {
        all.first { $0.id == id }
    }

    static func search(_ query: String) -> [StrategySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return all.filter { skill in
            skill.id.lowercased().contains(trimmed)
                || skill.displayName.lowercased().contains(trimmed)
                || skill.aliases.contains { $0.lowercased().contains(trimmed) }
        }
    }

    // MARK: - 趋势类

    static let bullTrend = StrategySkill(
        id: "bull_trend",
        displayName: "默认多头趋势",
        description: "常规个股分析的默认策略：多头排列、趋势延续与回踩低吸。",
        category: .trend,
        coreRules: [1, 2, 3],
        requiredTools: ["get_daily_kline"],
        aliases: ["趋势", "趋势分析", "多头趋势"],
        defaultPriority: 10,
        marketRegimes: [.trendingUp],
        instructions: """
        **默认多头趋势**

        1. 趋势确认（优先级最高）：用 `get_daily_kline` 的 ma_alignment 判断 MA5/MA10/MA20 排列；MA5≥MA10≥MA20 且 MA20 上行为多头结构；价格显著跌破 MA20 时降低看多权重。
        2. 位置与节奏：优先「回踩不破」而非「高位追涨」；价格距 MA5/MA10 过远时提示等待回踩；放量突破有效阻力时可提高胜率评级。
        3. 量价验证：`get_daily_kline` 的 volume_price_state 确认突破日/反弹日是否放量；缩量上涨需谨慎，放量滞涨需警惕分歧。
        4. 输出要求：给出明确倾向与触发条件；必须给止损参考（MA20 下方或结构低点）；无清晰优势时明确写「暂不出手」。

        评分调整：多头排列+趋势强度良好 +12；回踩关键均线后企稳 +8；放量突破关键阻力 +10。
        """
    )

    static let maGoldenCross = StrategySkill(
        id: "ma_golden_cross",
        displayName: "均线金叉",
        description: "均线金叉配合量能确认，经典趋势反转/延续信号。",
        category: .trend,
        coreRules: [1, 2, 3],
        requiredTools: ["get_daily_kline"],
        aliases: ["均线金叉", "金叉"],
        defaultPriority: 20,
        marketRegimes: [.trendingUp],
        instructions: """
        **均线金叉**

        1. 金叉检测：主信号 = MA5 在最近 3 个交易日内上穿 MA10；强信号 = MA10 上穿 MA20；用 `get_daily_kline` 的 macd_state 检查是否金叉/零上金叉。
        2. 量能确认：金叉日成交量高于 5 日均量（volume_ratio > 1.2 为积极信号）。
        3. 趋势背景：盘整后金叉最强；上升趋势中金叉为延续；深度下跌中金叉是弱信号需更多确认。
        4. 价格位置：价格应在交叉均线附近或上方，乖离率 <5% 避免追高延迟入场。

        评分调整：MA5×MA10 金叉配合量能 +10；MA10×MA20 金叉 +8；MACD 零上金叉再 +5。理想买点设在交叉均线水平附近。
        """
    )

    static let volumeBreakout = StrategySkill(
        id: "volume_breakout",
        displayName: "放量突破",
        description: "放量突破阻力位信号，适用于股价接近已知阻力位时。",
        category: .trend,
        coreRules: [1, 2, 3],
        requiredTools: ["get_daily_kline", "web_search"],
        aliases: ["放量突破", "突破"],
        defaultPriority: 30,
        marketRegimes: [.trendingUp],
        instructions: """
        **放量突破**

        1. 阻力位识别：`get_daily_kline` 的 resistance 字段（通常为 20 日高点或平台顶部）。
        2. 量能确认：当日成交量 > 5 日均量 2 倍（volume_ratio > 2.0）。
        3. 价格确认：收盘必须站上阻力位；收盘位于当日振幅上方 30%（强势收盘）；突破后乖离率仍需 <5%。
        4. 后续验证：次日开盘应在突破位之上，区分真假突破。
        5. 风险过滤：`web_search` 检查无重大利空；PE 不应过高（避免泡沫型突破）。

        评分调整：放量突破确认 +12；板块共振再 +5。理想买点在突破位附近，止损设在突破位下方 3%。
        """
    )

    static let shrinkPullback = StrategySkill(
        id: "shrink_pullback",
        displayName: "缩量回踩",
        description: "缩量回踩均线支撑信号，趋势延续的理想入场点。",
        category: .trend,
        coreRules: [1, 2, 4],
        requiredTools: ["get_daily_kline"],
        aliases: ["缩量回踩", "回踩"],
        defaultPriority: 40,
        marketRegimes: [.trendingDown, .sideways],
        instructions: """
        **缩量回踩**

        1. 前提条件（理念2）：必须处于上升趋势（MA5>MA10>MA20），用 `get_daily_kline` 的 ma_alignment 确认多头排列。
        2. 回踩检测（理念4）：价格回踩至 MA5 附近（误差 1% 以内）或 MA10 附近（误差 2% 以内）；回调期成交量 < 5 日均量的 70%（volume_ratio < 0.7，volume_price_state 应为缩量回调）。
        3. 反弹信号（理念1）：当前价格守住均线支撑；MA5 乖离率 <2% 为最佳买入区间（bias_ma5 字段）。
        4. 确认条件（理念5）：`web_search` 无利空；筹码健康（获利比例 50-80%）。

        评分调整：缩量回踩 MA5 +10；缩量回踩 MA10 且量能 <0.6 倍均量 +8。理想买点在 MA5，次优在 MA10，止损设在 MA20。
        """
    )

    // MARK: - 反转/形态类

    static let bottomVolume = StrategySkill(
        id: "bottom_volume",
        displayName: "底部放量",
        description: "长期下跌后底部放量，潜在趋势反转信号。",
        category: .reversal,
        coreRules: [2, 5],
        requiredTools: ["get_daily_kline", "web_search"],
        aliases: ["地量见底", "底部放量"],
        defaultPriority: 60,
        marketRegimes: [.trendingDown],
        instructions: """
        **底部放量**

        1. 持续下跌确认：股价从 20 日高点到近期低点跌幅 >15%；`get_daily_kline` 的 ma_alignment 应为空头排列。
        2. 量能异动：当日成交量 > 5 日均量 3 倍（volume_ratio > 3.0），且出现在前期极度缩量之后。
        3. 价格企稳：当日 K 线收阳（recent_bars 可查）；守住近期低点；长下影线更佳。
        4. 确认因素：`web_search` 是否有基本面催化；筹码平均成本接近现价（成本收敛）。
        5. 风险提示（理念2）：这是反转信号，风险高于趋势跟踪，仓位建议最多 2-3 成。

        评分调整：底部放量确认 +8；配合阳线+新闻催化再 +5。止损设在近期低点。
        """
    )

    static let oneYangThreeYin = StrategySkill(
        id: "one_yang_three_yin",
        displayName: "一阳夹三阴",
        description: "一阳夹三阴 K 线整理形态，趋势延续入场信号。",
        category: .pattern,
        coreRules: [2, 4],
        requiredTools: ["get_daily_kline"],
        aliases: ["一阳穿三阴", "一阳夹三阴"],
        defaultPriority: 110,
        marketRegimes: [.sideways, .trendingUp],
        instructions: """
        **一阳夹三阴**（最近 5 个交易日）

        1. 第1日：大阳线（收盘>开盘，实体 > 股价 2%）。
        2. 第2-4日：连续三根阴线或小 K 线——每根最低价不跌破第1日开盘价；成交量逐步萎缩（量比 <0.8）；三根 K 线收在第1日实体范围内。
        3. 第5日：再收阳线，收盘价突破第1日收盘价。
        4. 用 `get_daily_kline` 的 recent_bars 检查最后 5 根 K 线；ma_alignment 确认多头排列（理念2）。

        评分调整：形态成立+趋势看多 +15；形态成立但趋势不明 +5。理想买点在第5日收盘价附近，止损设在第1日开盘价下方。
        """
    )

    // MARK: - 框架类

    static let boxOscillation = StrategySkill(
        id: "box_oscillation",
        displayName: "箱体震荡",
        description: "识别箱体区间，箱底买入、箱顶减仓，适用于横盘震荡。",
        category: .framework,
        coreRules: [1, 2, 3],
        requiredTools: ["get_daily_kline"],
        aliases: ["箱体", "箱体震荡"],
        defaultPriority: 50,
        marketRegimes: [.sideways],
        instructions: """
        **箱体震荡**

        1. 箱体识别（近 60~120 日）：箱顶 = 多次触碰未破的高点聚集区（3 次以上）；箱底 = 多次下探未破的低点连线；两端各触碰 2-3 次方可确认；用 `get_daily_kline` 的 support/resistance 辅助定位。
        2. 位置判断：箱底区域（距支撑 ≤5%）→ 买入/加仓，止损箱底下方 3%；箱中 1/3 → 观望；箱顶区域（距阻力 ≤5%）→ 减仓/止盈，不追高。
        3. 量能辅助：箱底放量企稳 = 支撑有效可较重仓；箱顶缩量滞涨 = 卖出信号；放量超均量 2 倍向上突破 → 转多头趋势策略，新目标 = 箱体高度延伸；向下有效跌破 → 离场，原支撑转阻力。
        4. 箱体宽度：(顶-底)/底×100%；<5% 不参与；5%-15% 标准箱体可波段。

        评分调整：箱底企稳 +10；箱顶滞涨减仓信号确认 +8（对减仓方向）。
        """
    )

    static let chanTheory = StrategySkill(
        id: "chan_theory",
        displayName: "缠论",
        description: "基于笔、线段、中枢结构判断趋势级别、买卖点与背驰。",
        category: .framework,
        coreRules: [1, 2, 3, 4],
        requiredTools: ["get_daily_kline"],
        aliases: ["缠论", "缠论分析"],
        defaultPriority: 70,
        marketRegimes: [.volatile],
        instructions: """
        **缠论**（分型 → 笔 → 线段 → 中枢 → 趋势）

        1. 中枢识别（近 60 日）：连续 3 段走势重叠区间为中枢；连续 3 个同级别中枢同向移动为趋势。
        2. 背驰判断（最高优先级）：顶背驰 = 价格新高但 MACD 红柱面积缩小 → 卖出/减仓；底背驰 = 价格新低但绿柱面积缩小 → 买入/加仓。用 `get_daily_kline` 的 macd_state 与 recent_bars 对比。
        3. 买卖点：一买（最强）= 下跌趋势中最后一个中枢出现底背驰；二买 = 离开下跌中枢后首次回调不破中枢高点；三买 = 中枢震荡后向上突破不回中枢内。一卖/二卖/三卖对称反向。
        4. 级别与仓位：日线级别买卖点 30-50% 仓位；周线级别 50-80%；多级别共振信号最强。
        5. 输出要求：明确当前处于上涨趋势/下跌趋势/中枢震荡；指出是否存在背驰及级别。

        评分调整：一买/三买确认 +12；顶背驰确认减仓 +10（对减仓方向）。
        """
    )

    static let waveTheory = StrategySkill(
        id: "wave_theory",
        displayName: "波浪理论",
        description: "艾略特 5 推 3 调浪型结构，判断当前浪型与潜在目标。",
        category: .framework,
        coreRules: [1, 2, 3, 4],
        requiredTools: ["get_daily_kline"],
        aliases: ["波浪", "波浪理论", "艾略特"],
        defaultPriority: 80,
        marketRegimes: [.volatile],
        instructions: """
        **波浪理论**（5 浪推进 + 3 浪调整）

        1. 浪型识别（近 120 日）：第1浪 = 反转首波量能温和放大；第3浪 = 最强推动浪放量且 MACD 强势，绝不是最短浪；第5浪 = 量能弱于第3浪，顶背离则临近结束。A 浪首次下跌多数人误以为回调；B 浪反弹力度弱、量能萎缩，陷阱风险高；C 浪下跌力度常超 A 浪。
        2. 黄金位置：第2浪回调在第1浪的 38.2%~61.8%；第3浪目标 = 第1浪的 1.618~2.618 倍延伸；第4浪不得进入第1浪价格区域（规则违反即计数作废）；C 浪目标 ≥ A 浪长度。
        3. 最优买点：第2浪回调企稳（黄金坑，止损第1浪起点）；第4浪回调企稳（次优，止损第1浪顶部）；第3浪初期放量突破第1浪高点。避免第5浪末端追高。
        4. 风险提示：B 浪反弹不宜重仓；波浪计数有主观性，需其他指标验证。

        评分调整：第2/第4浪回调企稳 +10；第3浪初期突破 +12；第5浪末顶背离减仓 +10（对减仓方向）。
        """
    )

    static let emotionCycle = StrategySkill(
        id: "emotion_cycle",
        displayName: "情绪周期",
        description: "基于情绪/换手/量价识别恐慌底与狂热顶，逆情绪布局。",
        category: .framework,
        coreRules: [1, 2, 3, 5],
        requiredTools: ["get_daily_kline", "get_market_breadth", "web_search"],
        aliases: ["情绪", "情绪周期"],
        defaultPriority: 100,
        marketRegimes: [.sectorHot],
        instructions: """
        **情绪周期**（恐慌→悲观→怀疑→希望→乐观→兴奋→贪婪→狂热循环）

        1. 换手率热度（核心指标）：<0.5%/日 = 冷淡潜在底部；0.5-2% 正常；2-5% 活跃不追高；>5% 高热度警惕情绪顶；>10% 极度过热通常短期顶部。用 `get_daily_kline` 的 turnover_rate。
        2. 连续换手走势（近 20 日）：高→低持续降温+缩量 = 情绪退潮等待；低→高加速升温+陡增 = 情绪启动可介入；单日暴量（换手超前 5 倍）= 警惕主力出货。
        3. 新闻情绪：`web_search` 中集中出现「利好兑现/涨停/机构推荐」→ 过热；集中「业绩下滑/跌破支撑」→ 悲观或造底部；散户舆论极端负面 = 反向指标。市场级情绪用 `get_market_breadth` 的涨停家数与涨跌比校准。
        4. 均线收缩与波动率：MA5/10/20 三线粘合 = 蓄势；波动率（ATR）萎缩至低位 = 爆发前兆。
        5. 情绪底部特征（买入区）：换手 <0.5% + 缩量 + 新闻悲观 + 均线粘合；顶部特征（卖出区）：换手 >5-10% + 暴量 + 利好刷屏 + 加速赶顶。

        评分调整：情绪底部特征齐备 +12；情绪顶部特征齐备减仓 +10（对减仓方向）。
        """
    )

    static let eventDriven = StrategySkill(
        id: "event_driven",
        displayName: "事件驱动",
        description: "围绕业绩/政策/并购/订单等事件评估催化强度与风险边界。",
        category: .framework,
        coreRules: [3, 5],
        requiredTools: ["web_search", "get_daily_kline"],
        aliases: ["事件驱动", "催化", "催化事件"],
        defaultPriority: 45,
        marketRegimes: [.sectorHot, .volatile],
        instructions: """
        **事件驱动**

        1. 事件分类：`web_search` 梳理近期关键事件（业绩/政策/订单产品/资本运作/监管风险），明确发生时间——**过期或时间未知的信息不能作为主要依据**。
        2. 影响路径：判断事件影响收入、利润率、估值、融资能力、市场份额还是仅情绪；重大订单/政策利好要说明兑现周期与不确定性；监管/减持/处罚/诉讼风险优先。
        3. 市场反应：`get_daily_kline` 判断事件是否已被价格充分反映——放量上涨未过关键阻力可等待确认；高位放量滞涨或利好后冲高回落警惕兑现压力。
        4. 交易计划：事件未兑现前强调仓位控制与时间窗口；兑现后重新评估「预期交易」→「业绩验证」切换；负面事件先看风险释放是否充分。

        输出要求：明确事件性质（利好/利空/中性/不确定）+ 可信度 + 兑现周期 + 已反映程度；操作建议必须包含失效条件（公告不及预期/跌破关键支撑/热度消退）。
        评分调整：强催化未充分反映 +12；利好已充分兑现提示风险 −10。
        """
    )

    static let growthQuality = StrategySkill(
        id: "growth_quality",
        displayName: "成长质量",
        description: "收入利润增长、ROE、现金流与行业空间，识别高质量成长与失速。",
        category: .framework,
        coreRules: [2, 3, 5],
        requiredTools: ["web_search", "get_daily_kline"],
        aliases: ["成长", "成长股", "成长质量"],
        defaultPriority: 55,
        marketRegimes: [.trendingUp],
        instructions: """
        **成长质量**

        1. 成长性：`web_search` 检索财报数据（营收/归母净利/经营现金流/ROE）；收入与利润增长须同向，警惕「增收不增利」；只有概念热度财报未验证 → 降低成长确定性。
        2. 质量：ROE 高且稳定为优；经营现金流与净利润同向盈利质量更可靠；现金流显著弱于利润 → 提示回款/存货/应收风险。
        3. 估值承受力：PE/PB 与市值判断是否提前透支；高成长可承受更高估值但必须说明增长能否覆盖估值；估值高+成长放缓 → 明显下调评分。
        4. 趋势确认：`get_daily_kline` 判断长期逻辑是否被资金确认；基本面向好但技术未确认 → 给观察条件而非直接追买。

        评分调整：收入、利润、现金流和 ROE 同向改善 +15；成长放缓+估值高 −10。买点：业绩验证后突破 / 回踩长期均线 / 估值回落。
        """
    )

    static let expectationRepricing = StrategySkill(
        id: "expectation_repricing",
        displayName: "预期重估",
        description: "业绩/政策/估值预期变化，寻找预期差修复或过热回落风险。",
        category: .framework,
        coreRules: [3, 5, 6],
        requiredTools: ["web_search", "get_daily_kline"],
        aliases: ["预期", "预期差", "预期重估"],
        defaultPriority: 65,
        marketRegimes: [.volatile, .sectorHot],
        instructions: """
        **预期重估**

        1. 预期来源：`web_search` 识别改变预期的信息（业绩预告/机构观点/订单/政策/产品进展/行业数据），区分硬信息（公告财报订单）与软信息（传闻观点情绪）。
        2. 预期差方向：正向 = 原悲观+新信息好于预期；负向 = 原乐观+新信息低于预期或验证失败；信息已被连续大涨充分反映 → 提示兑现风险。
        3. 估值重估：PE/PB、市值、ROE、现金流判断重估有无基本面支撑；估值回落区分一次性扰动 vs 长期逻辑变化。
        4. 价格确认：`get_daily_kline` 判断预期变化是否转化为趋势——放量突破 = 资金确认；缩量反弹 = 修复观察；高位放量滞涨/利好不涨/跌破关键支撑 = 预期转弱。

        评分调整：正向预期差且价格未充分反映 +15；负向预期差确认 −12。观察点：下一份财报/订单兑现/政策落地/技术确认。
        """
    )

    static let hotTheme = StrategySkill(
        id: "hot_theme",
        displayName: "热点题材",
        description: "跟踪政策产业热点，判断题材强度、板块扩散与个股成色。",
        category: .framework,
        coreRules: [2, 3, 5, 7],
        requiredTools: ["web_search", "get_market_breadth", "get_daily_kline"],
        aliases: ["热点", "题材", "热点题材"],
        defaultPriority: 35,
        marketRegimes: [.sectorHot],
        instructions: """
        **热点题材**

        1. 热点强度：`get_market_breadth` 的涨停家数/涨跌比 + `web_search` 判断相关板块是否处于涨幅/人气前列；热点从核心股扩散到板块多股 = 扩散期；单股异动板块未共振 → 降低权重。
        2. 个股相关性：检查业务/订单/产能/客户/公告是否与热点直接相关，区分「实质受益/间接受益/概念关联弱」；概念弱但涨幅过大 → 提示题材兑现风险。
        3. 相对强弱：个股涨幅、量比、换手是否强于板块平均；强势热点股 = 放量、换手活跃、回调不破关键均线。
        4. 节奏与风险：不追连续加速+高乖离位置；新闻集中「已大涨/资金追捧/游资博弈」→ 警惕情绪顶；监管问询/澄清公告一票降级。

        评分调整：热点启动或扩散期+个股实质受益 +12；退潮期 −8。输出热点阶段（启动/扩散/分化/退潮）+ 触发条件（回踩承接/放量突破/板块共振/退潮止损）。
        """
    )

    static let dragonHead = StrategySkill(
        id: "dragon_head",
        displayName: "龙头策略",
        description: "板块轮动中识别龙头股，适用于板块启动或催化剂出现时。",
        category: .trend,
        coreRules: [2, 7],
        requiredTools: ["get_daily_kline", "get_market_breadth", "web_search"],
        aliases: ["龙头", "龙头战法"],
        defaultPriority: 90,
        marketRegimes: [.sectorHot],
        instructions: """
        **龙头策略**

        1. 板块领涨地位：`get_market_breadth` + `web_search` 检查所在板块是否近期涨幅前列；确认个股是否在板块启动中率先上涨或涨停。
        2. 换手率与动能（理念7 强势放宽）：龙头股换手率通常 >5%；量比 >1.5 说明交易兴趣活跃。用 `get_daily_kline` 的 turnover_rate / volume_ratio。
        3. 相对强度：对比个股涨跌幅与板块平均——真正龙头上涨日应跑赢板块 2% 以上。
        4. 新闻催化：`web_search` 搜索板块级催化（政策/事件/业绩），龙头行情常伴随板块整体催化。
        5. 乖离率检查（理念1 严进）：龙头可放宽乖离率至 7%，但超过 10% 仍需谨慎。

        评分调整：确认为龙头股 +10；板块处于主动轮动期再 +5。
        """
    )
}
