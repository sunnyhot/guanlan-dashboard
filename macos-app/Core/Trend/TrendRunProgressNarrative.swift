import Foundation

/// W3.3:生成进度的「人话叙事」纯派生。
///
/// `trendProgressLogs` 只含 Agent 内部术语(工具名、模块名),普通用户不可读;
/// 本类型把运行日志映射为「五步进度 + 当前步骤人话」,供实时日志面板与
/// 各区段的进度卡共用。校验拒批→修正重试的循环按「阶段只进不退 +
/// 显示重试轮次」处理,进度条不回跳。
struct TrendRunProgressNarrative: Equatable {
    enum Stage: Int, CaseIterable, Comparable {
        case dataPrep = 0
        case marketSnapshot = 1
        case thirdPartyResearch = 2
        case synthesis = 3
        case done = 4

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var stepText: String {
            switch self {
            case .dataPrep: return "准备持仓与行情"
            case .marketSnapshot: return "读取市场快照"
            case .thirdPartyResearch: return "查阅外部研究"
            case .synthesis: return "汇总与校验结论"
            case .done: return "完成"
            }
        }

        /// 进度条分段下的极短标签。
        var shortText: String {
            switch self {
            case .dataPrep: return "持仓"
            case .marketSnapshot: return "行情"
            case .thirdPartyResearch: return "研究"
            case .synthesis: return "汇总"
            case .done: return "完成"
            }
        }
    }

    /// 当前阶段(运行内只进不退)。
    let stage: Stage
    /// 校验拒批后的修正重试轮次(无拒批时为 1)。
    let attemptCount: Int

    /// 当前步骤的人话描述;重试中显示「校验修复中(第 N 次尝试)」。
    var statusText: String {
        if stage == .done { return "已完成" }
        if attemptCount > 1 && stage >= .synthesis {
            return "校验修复中(第 \(attemptCount) 次尝试)"
        }
        return "正在\(stage.stepText)…"
    }

    /// 从运行日志派生:阶段取所有日志命中的最高阶段;重试轮次按
    /// 「报告校验失败,正在自动修正」类日志条数 + 1 计算。
    /// 日志匹配的字符串与 `handleTrendAgentEvent`/`trendToolDisplayName`
    /// 写入的文案保持同源,改动日志文案时需同步这里(有单测兜底)。
    static func derive(from logs: [TrendProgressLog]) -> TrendRunProgressNarrative {
        var stage = Stage.dataPrep
        var rejections = 0
        for log in logs {
            let text = log.message
            if text.contains("报告校验失败") {
                rejections += 1
            }
            if let hinted = stageHint(in: text), hinted.rawValue > stage.rawValue {
                stage = hinted
            }
        }
        return TrendRunProgressNarrative(stage: stage, attemptCount: rejections + 1)
    }

    private static func stageHint(in text: String) -> Stage? {
        // 组合/持仓/穿透类工具 → 数据准备。
        if text.contains("读取组合概览")
            || text.contains("读取持仓明细")
            || text.contains("读取基金底层资产")
            || text.contains("冻结持仓") {
            return .dataPrep
        }
        if text.contains("读取市场快照") || text.contains("市场快照") {
            return .marketSnapshot
        }
        // 三方研究:Tavily 搜索、SEC 披露、AlphaVantage。
        if text.contains("Tavily")
            || text.contains("web_search")
            || text.contains("SEC")
            || text.contains("official_sec_research")
            || text.contains("alpha_vantage_research")
            || text.contains("搜索行业与政策") {
            return .thirdPartyResearch
        }
        // 报告已通过校验,进入保存收尾。
        if text.contains("已生成有效报告") || text.contains("保存趋势报告") {
            return .done
        }
        // 分模块提交与最终校验。
        if text.contains("提交")
            || text.contains("校验")
            || text.contains("汇总") {
            return .synthesis
        }
        return nil
    }
}
