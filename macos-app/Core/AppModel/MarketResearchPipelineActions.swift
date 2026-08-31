import Foundation

// MARK: - L7 市场研究流水线 + L8 策略回测 App 集成（2026-08-31）
//
// L7：四档（quick/standard/full/specialist）多 Agent 流水线，护栏链
// 「风险否决 → 结构稳定器 → 阶段 → 数据质量」产出 MarketDecisionDashboard；
// candidateSignal 直接入 L6 信号闭环（胜率校准后入库）。
// L8：策略技能规则级回测（纯本地计算，无 LLM），给「这个技能历史上靠不靠谱」
// 的量化答案；样本 <35 根 K 线 / <30 笔可结算交易时结果降级展示。
//
// 互斥：与趋势分析/下一小时研判/专项研究共用「生成中」互斥 guard（baseline 第 8 节）。

extension AppModel {

    // MARK: - L7 流水线

    /// 手动触发多 Agent 市场研究（UI 入口）。
    func runMarketResearch(
        subjectCode: String,
        subjectName: String,
        mode: MarketResearchPipelineMode
    ) async {
        guard InvestmentIntelligence.enabled else { return }
        guard trendGenerationState != .generating,
              nextHourGuidanceGenerationState != .generating,
              decisionCaseResearchState != .generating,
              marketResearchState != .generating
        else {
            lastMarketResearchError = "其他 AI 任务正在运行，请稍后再试。"
            return
        }
        guard trendSettings.provider.isConfigured else {
            lastMarketResearchError = "未配置 AI 模型，无法启动研究。"
            return
        }

        let trimmedCode = subjectCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            lastMarketResearchError = "请输入标的代码（如 600519 / 00700）。"
            return
        }

        marketResearchState = .generating
        lastMarketResearchError = ""
        defer {
            if marketResearchState == .generating { marketResearchState = .idle }
        }

        let context = MarketResearchContext(
            subjectCode: trimmedCode,
            subjectName: trimmedName.isEmpty ? trimmedCode : trimmedName
        )
        let pipeline = MarketResearchPipeline(
            client: OpenAICompatibleAgentClient(),
            engine: MarketDataEngine(),
            settings: trendSettings.provider
        )

        // run 内部已做 LLM 失败的确定性兜底（不 throws），降级情况经 degradedStages 透出
        let result = await pipeline.run(context: context, mode: mode)
        latestMarketResearchResult = result
        marketResearchState = .succeeded
        // candidateSignal 进入 L6 闭环（与趋势报告信号同一套去重/校准/结算）
        ingestMarketSignals(signals: [result.candidateSignal])
    }

    /// 流水线 candidateSignal / 其他直填信号入库（校准 → 去重 → 反向失效）。
    func ingestMarketSignals(signals: [MarketDecisionSignal]) {
        guard InvestmentIntelligence.enabled, !signals.isEmpty else { return }
        guard let service = makeMarketSignalService() else { return }
        Task { @MainActor in
            let calibrated = await withTaskGroup(of: MarketDecisionSignal.self) { group in
                for signal in signals {
                    group.addTask { await service.calibratedSignal(signal) }
                }
                var results: [MarketDecisionSignal] = []
                for await signal in group { results.append(signal) }
                return results
            }
            _ = try? await service.ingest(signals: calibrated)
            let all = await service.allSignals()
            marketSignals = all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - L8 策略回测

    /// 规则级回测（纯本地，无 LLM、无互斥 guard；约拉 260 根日 K）。
    func runStrategyBacktest(skillID: String, subjectCode: String) async {
        guard InvestmentIntelligence.enabled else { return }
        let trimmed = subjectCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard StrategySkillLibrary.skill(id: skillID) != nil else { return }

        isRunningBacktest = true
        defer { isRunningBacktest = false }
        do {
            let engine = MarketDataEngine()
            let bars = try await engine.dailyBars(code: trimmed, days: 260)
            latestBacktestReport = StrategyRuleBacktester.backtest(
                skillID: skillID,
                bars: bars
            )
        } catch {
            latestBacktestReport = nil
            lastMarketResearchError = "回测拉取日 K 失败：\(error.localizedDescription)"
        }
    }
}
