import Foundation
import XCTest
@testable import QiemanDashboard

// SubmitTrendReportTool 行为冻结测试。
//
// SubmitTool 是趋势研究链路的安全闸口(见 docs/ai-pipeline-baseline.md 第 7 节)。
// 投资智能改造最可能触动的契约面都在这里:
//   - 数据不足 → 清空行动 + 降级 short uncertain + disposition=insufficientEvidence
//   - 伪造证据静默过滤(ledger canonical)
//   - sourceStatuses/externalSignalStatus 被 App 重写(覆盖模型自报)
//   - schemaVersion 门控
//   - 时间/隐私字段被快照覆盖
//
// 这些测试冻结"当前行为"本身——改造时若有意改变行为(如收紧权限、加 schemaVersion),
// 需主动更新对应测试,而非无声破坏。
final class SubmitTrendReportCharacterizationTests: XCTestCase {

    // MARK: - 测试基础设施(参考 TrendResearchToolTests.swift 的 private helpers)

    private let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let createdAt = "2026-07-24 10:00:00"
    private let dataAsOf = "2026-07-24 09:58:00"

    /// 最小 snapshot:sourceStatuses 留空 → normalized 后 portfolioQuote/marketIndex/fundDisclosure
    /// 全为 .notRequested → insufficientReasons 必然非空 → actions 清空 + disposition=insufficientEvidence。
    /// 这是 SubmitTool 在"数据不完整"场景下的基线行为。
    private func makeMinimalSnapshot(
        assets: [TrendContextAsset] = [],
        sourceStatuses: [TrendSourceStatus] = [],
        marketQuotes: [TrendResearchQuote] = []
    ) -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: runID,
            createdAt: createdAt,
            dataAsOf: dataAsOf,
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: assets.count, holdingCount: assets.count,
                activePlanCount: 0, pendingAssetCount: 0,
                totalMarketValue: nil, totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil, totalEffectiveHoldingAmount: nil
            ),
            assets: assets,
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: marketQuotes,
            lookThrough: nil,
            insightHeadline: "测试组合",
            sourceWarnings: [],
            sourceStatuses: sourceStatuses
        )
    }

    /// 基金资产(assetType="基金"),会被 expectedFundCodes 收录,触发 fundDisclosure 检查。
    private func makeFundAsset(code: String) -> TrendContextAsset {
        TrendContextAsset(
            id: "asset-\(code)", name: "基金\(code)", code: code,
            assetType: PersonalAssetType.fund.displayName, sector: "—",
            statusText: "持有", weightText: "10%", profitPct: 1.2, estimateChangePct: 0.3,
            pendingTradeCount: 0, activePlanCount: 0, pausedPlanCount: 0, endedPlanCount: 0,
            marketValue: 1000, costValue: 900, profitAmount: 100,
            pendingCashAmount: nil, estimatedNextPlanAmount: nil, totalCumulativePlanAmount: nil
        )
    }

    /// 构造一个"数据完整"的 snapshot:portfolioQuote/marketIndex/fundDisclosure 全 success,
    /// 且 marketQuotes 含可用中国指数 → insufficientReasons 为空 → 可测 analysisOnly/actionable。
    private func makeCompleteSnapshot(fundCodes: [String] = ["001000"]) -> TrendResearchSnapshot {
        let assets = fundCodes.map { makeFundAsset(code: $0) }
        let usableChinaIndex = TrendResearchQuote(
            kind: "index", evidenceID: "market:index:sseComposite:2026-07-24 09:30:00",
            code: MarketIndexKind.sseComposite.rawValue, name: "上证综指",
            price: 3200, changePct: 0.5, changeAmount: 16,
            quotedAt: "2026-07-24 09:30:00", sourceLabel: "实时",
            assessment: TrendQuoteAssessment(
                quoteType: .indexQuote, freshnessStatus: .fresh,
                asOf: "2026-07-24 09:30:00", receivedAt: createdAt,
                ageSeconds: 0, marketSession: .trading
            )
        )
        let statuses = [
            TrendSourceStatus(source: .portfolioQuote, status: .success, receivedAt: createdAt),
            TrendSourceStatus(source: .marketIndex, status: .success, receivedAt: createdAt),
            TrendSourceStatus(source: .fundNAV, status: .success, receivedAt: createdAt),
            TrendSourceStatus(source: .fundDisclosure, status: .success, receivedAt: createdAt, itemCount: fundCodes.count)
        ]
        return makeMinimalSnapshot(assets: assets, sourceStatuses: statuses, marketQuotes: [usableChinaIndex])
    }

    /// 把 overview 证据写入 ledger(SubmitTool 成功路径必备,否则 portfolio.claimEvidence 引用落空)。
    private func recordOverviewEvidence(into ledger: TrendEvidenceLedger, snapshot: TrendResearchSnapshot) async {
        let evidence = TrendEvidence(
            id: "portfolio:overview:\(snapshot.runID.uuidString)",
            sourceName: "组合概览", title: "组合快照",
            url: nil, publishedAt: nil, retrievedAt: createdAt,
            summary: "测试用组合概览",
            metadata: TrendEvidenceMetadata(
                sourceKind: .portfolioSnapshot, sourceTier: .primary,
                entityNames: ["组合"], metadataConfidence: .deterministic
            )
        )
        await ledger.record([evidence])
    }

    /// Submit 一个 report 对象,返回 tool result。
    private func submitReport(
        _ report: TrendAnalysisReport,
        snapshot: TrendResearchSnapshot,
        ledger: TrendEvidenceLedger,
        officialSourceSettings: OfficialSourceSettings = .empty,
        alphaVantageSettings: AlphaVantageSettings = .empty
    ) async throws -> TrendResearchToolResult {
        let context = TrendResearchToolContext(
            snapshot: snapshot,
            evidenceLedger: ledger,
            officialSourceSettings: officialSourceSettings,
            alphaVantageSettings: alphaVantageSettings
        )
        let reportData = try JSONEncoder().encode(report)
        let reportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        let arguments = try JSONSerialization.data(withJSONObject: ["report": reportObject])
        return await SubmitTrendReportTool().execute(
            argumentsJSON: String(data: arguments, encoding: .utf8) ?? "{}",
            context: context
        )
    }

    /// 从 result 提取 normalized report(成功路径用)。
    private func extractReport(from result: TrendResearchToolResult) throws -> TrendAnalysisReport {
        guard case .report(let report) = result.completion else {
            XCTFail("预期 submit 成功返回 .report,实际 completion=nil(isError=\(result.isError))。contentJSON=\(result.contentJSON)")
            throw NSError(domain: "test", code: 1)
        }
        return report
    }

    // MARK: - 测试 1:数据不足(持仓报价非 success)清空行动 + 降级

    func testInsufficientPortfolioQuoteClearsActionsAndDowngradesShortHorizon() async throws {
        // snapshot 不设 sourceStatuses → portfolioQuote 经 normalize 后为 .notRequested → 触发降级
        let snapshot = makeMinimalSnapshot(assets: [])
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshot)

        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        // 给一个 allocationReview 级 action,验证它会被清空
        let reportWithAction = try injectAction(into: report)

        let result = try await submitReport(reportWithAction, snapshot: snapshot, ledger: ledger)
        let normalized = try extractReport(from: result)

        XCTAssertEqual(normalized.disposition, .insufficientEvidence, "持仓报价不足时 disposition 必须降级")
        XCTAssertTrue(normalized.actions.isEmpty, "数据不足时所有行动必须被清空")
        // short horizon 应被降为 uncertain
        let shortHorizon = normalized.horizons.first { $0.horizon == .short }
        XCTAssertEqual(shortHorizon?.direction, .uncertain, "短期方向必须降为 uncertain")
    }

    // MARK: - 测试 3:基金披露 itemCount < 期望触发降级

    func testInsufficientFundDisclosureClearsActions() async throws {
        // 有 2 只基金但 disclosure itemCount 只有 1
        let snapshot = makeCompleteSnapshot(fundCodes: ["001000", "001001"])
        // 覆盖 fundDisclosure 的 itemCount 为 1(小于期望的 2)
        let adjustedStatuses = snapshot.sourceStatuses.map { status -> TrendSourceStatus in
            if status.source == .fundDisclosure {
                return TrendSourceStatus(
                    source: .fundDisclosure, status: .success, receivedAt: createdAt, itemCount: 1
                )
            }
            return status
        }
        let snapshotWithLowDisclosure = makeMinimalSnapshot(
            assets: ["001000", "001001"].map { makeFundAsset(code: $0) },
            sourceStatuses: adjustedStatuses,
            marketQuotes: snapshot.marketQuotes
        )
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshotWithLowDisclosure)

        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshotWithLowDisclosure)
        let reportWithAction = injectAction(into: await ensureAssetTrends(in: report, for: snapshotWithLowDisclosure, ledger: ledger))

        let result = try await submitReport(reportWithAction, snapshot: snapshotWithLowDisclosure, ledger: ledger)
        let normalized = try extractReport(from: result)

        XCTAssertEqual(normalized.disposition, .insufficientEvidence, "披露数不足期望时必须降级")
        XCTAssertTrue(normalized.actions.isEmpty)
    }

    // MARK: - 测试 4:伪造证据 ID 被静默丢弃(不报错)
    //
    // SubmitTool 的证据归一化:report.evidence 里 ledger 不存在的条目被丢弃。
    // 这道防线防止模型在 evidence 数组里塞虚构证据。
    // (claim 引用伪造 ID 的拦截由 Validator 负责,见 TrendAnalysisValidatorTests。)

    func testFabricatedEvidenceIDsAreSilentlyDropped() async throws {
        let snapshot = makeCompleteSnapshot()
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshot)

        let fabricated = TrendEvidence(
            id: "fabricated:eid", sourceName: "虚构来源", title: "虚构证据",
            url: "https://fake.example.com", publishedAt: "2026-01-01",
            retrievedAt: createdAt, summary: "模型自造的证据",
            metadata: .unknown
        )
        let baseReport = downgradingShortHorizonToUncertain(
            TrendAnalysisReport
                .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .unavailable)
                .groundedForSubmission(snapshot: snapshot)
        )
        let reportWithAssetTrends = await ensureAssetTrends(in: baseReport, for: snapshot, ledger: ledger)
        // 重置 sectors/actions 避免 claimEvidence 引用问题,只保留 assetTrends + evidence 数组
        let reportWithFabricated = rebuildReport(
            reportWithAssetTrends,
            sectors: [],
            actions: []
        )
        // 手动扩展 evidence:rebuildReport 不直接支持扩展 evidence,用 JSON 中转
        var reportWithExtraEvidence = reportWithFabricated
        let combinedEvidence = reportWithExtraEvidence.evidence + [fabricated]
        reportWithExtraEvidence = TrendAnalysisReport(
            id: reportWithExtraEvidence.id,
            generatedAt: reportWithExtraEvidence.generatedAt,
            dataAsOf: reportWithExtraEvidence.dataAsOf,
            privacyMode: reportWithExtraEvidence.privacyMode,
            externalSignalStatus: reportWithExtraEvidence.externalSignalStatus,
            portfolio: reportWithExtraEvidence.portfolio,
            horizons: reportWithExtraEvidence.horizons,
            marketOutlook: reportWithExtraEvidence.marketOutlook,
            sectors: reportWithExtraEvidence.sectors,
            opportunities: reportWithExtraEvidence.opportunities,
            keyAssets: reportWithExtraEvidence.keyAssets,
            assetTrends: reportWithExtraEvidence.assetTrends,
            actions: reportWithExtraEvidence.actions,
            evidence: combinedEvidence,
            warnings: reportWithExtraEvidence.warnings,
            disclaimer: reportWithExtraEvidence.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: reportWithExtraEvidence.disposition,
            sourceStatuses: reportWithExtraEvidence.sourceStatuses
        )

        let result = try await submitReport(reportWithExtraEvidence, snapshot: snapshot, ledger: ledger)
        let normalized = try extractReport(from: result)

        XCTAssertFalse(normalized.evidence.contains { $0.id == "fabricated:eid" },
                       "ledger 中不存在的证据必须被静默丢弃")
        XCTAssertTrue(normalized.evidence.contains { $0.id.hasPrefix("portfolio:overview:") },
                      "ledger 真实产出应保留")
    }

    // MARK: - 测试 5:模型虚报 sourceStatuses=success 被 App 重置

    func testModelSelfReportedSourceStatusesOverwrittenByApp() async throws {
        let snapshot = makeCompleteSnapshot()
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshot)

        // 模型在 report 里虚报各来源 success,但 ledger 无对应证据且未配置官方源
        let baseReport = downgradingShortHorizonToUncertain(
            TrendAnalysisReport
                .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .unavailable)
                .groundedForSubmission(snapshot: snapshot)
        )
        var report = await ensureAssetTrends(in: baseReport, for: snapshot, ledger: ledger)
        let fakeSuccessStatuses = TrendDataSource.allCases.map {
            TrendSourceStatus(source: $0, status: .success, receivedAt: createdAt)
        }
        report = rebuildReport(report, sourceStatuses: fakeSuccessStatuses)

        let result = try await submitReport(report, snapshot: snapshot, ledger: ledger)
        let normalized = try extractReport(from: result)

        // officialSource:模型虚报 success,但未配 SEC → 必须被重写
        let officialStatus = normalized.sourceStatuses.first { $0.source == .officialSource }
        XCTAssertNotEqual(officialStatus?.status, .success,
                          "模型虚报的 officialSource=success 必须被 App 重写")
    }

    // MARK: - 测试 6:externalSignalStatus 只在 ledger 有外部证据时才提升

    func testExternalSignalStatusOnlyPromotedWhenLedgerHasExternalEvidence() async throws {
        let snapshot = makeCompleteSnapshot()
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshot)

        // 模型自报 externalSignalStatus=.available,但 ledger 只有 portfolio 证据(无外部研究)
        let report = downgradingShortHorizonToUncertain(
            TrendAnalysisReport
                .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .available) // 模型虚报
                .groundedForSubmission(snapshot: snapshot)
        )
        let reportWithTrends = await ensureAssetTrends(in: report, for: snapshot, ledger: ledger)

        let result = try await submitReport(reportWithTrends, snapshot: snapshot, ledger: ledger)
        let normalized = try extractReport(from: result)

        // ledger 无外部研究证据 → 即使模型自报 available 也应降级
        XCTAssertNotEqual(normalized.externalSignalStatus, .available,
                          "ledger 无外部证据时 externalSignalStatus 不得为 available")
    }

    // MARK: - 测试 7:schemaVersion=1 被 submit 拒绝

    func testSchemaVersionOneRejectedAtSubmit() async throws {
        let snapshot = makeMinimalSnapshot()
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)

        // fixture 默认 schemaVersion=1
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .unavailable
        )
        XCTAssertEqual(report.schemaVersion, 1, "前置:fixture 默认 schemaVersion 应为 1")

        let reportData = try JSONEncoder().encode(report)
        let reportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        let arguments = try JSONSerialization.data(withJSONObject: ["report": reportObject])

        let result = await SubmitTrendReportTool().execute(
            argumentsJSON: String(data: arguments, encoding: .utf8) ?? "{}",
            context: context
        )

        XCTAssertTrue(result.isError, "schemaVersion=1 必须被拒")
        XCTAssertNil(result.completion, "被拒时不得返回 report")
        XCTAssertTrue(result.contentJSON.contains("schemaVersion") || result.contentJSON.contains("report_validation_failed"),
                      "拒绝信封应提及 schemaVersion 或校验失败")
    }

    // MARK: - 测试 8:generatedAt/dataAsOf/privacyMode 被快照覆盖

    func testGeneratedAtDataAsOfPrivacyModeOverwrittenBySnapshot() async throws {
        let snapshot = makeMinimalSnapshot(privacyModeOverride: .fullDetail)
        let ledger = TrendEvidenceLedger()
        await recordOverviewEvidence(into: ledger, snapshot: snapshot)

        // report 里塞一个明显错误的旧时间,验证被覆盖
        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .unavailable)
            .groundedForSubmission(snapshot: snapshot)

        let result = try await submitReport(report, snapshot: snapshot, ledger: ledger)
        let normalized = try extractReport(from: result)

        XCTAssertNotEqual(normalized.generatedAt, "1999-01-01 00:00:00", "generatedAt 必须被当前时间覆盖")
        XCTAssertEqual(normalized.dataAsOf, snapshot.dataAsOf, "dataAsOf 必须被快照覆盖")
        XCTAssertEqual(normalized.privacyMode, snapshot.privacyMode, "privacyMode 必须被快照覆盖")
    }

    // MARK: - 报告构造辅助

    /// 完整快照(本地数据源全 success)下 insufficientReasons 为空,App 不再强制降级
    /// short 周期;但 ledger 无外部研究证据时 disposition 仍为 insufficientEvidence,
    /// Validator 要求模型自报的 short 周期必须是 uncertain(联网搜索移除后的新契约)。
    private func downgradingShortHorizonToUncertain(
        _ report: TrendAnalysisReport
    ) -> TrendAnalysisReport {
        let horizons = report.horizons.map { item in
            guard item.horizon == .short, item.direction != .uncertain else { return item }
            var rationale = item.rationale
            if !rationale.contains("待观察信号") {
                rationale += " 待观察信号:本地数据源齐全但缺少外部研究证据;数据恢复后重估短期方向。"
            }
            return TrendHorizonView(
                horizon: item.horizon,
                direction: .uncertain,
                confidence: item.confidence,
                rationale: rationale,
                whatWouldChange: item.whatWouldChange,
                counterSignals: item.counterSignals,
                claimEvidence: item.claimEvidence
            )
        }
        return rebuildReport(report, horizons: horizons)
    }

    /// 给 report 补上与 snapshot 基金资产对应的 assetTrends,并把每只基金的持仓证据写入 ledger。
    /// Validator 要求:① 所有持有基金出现在 assetTrends;② asset.claimEvidence 的 supporting 必须关联该基金。
    private func ensureAssetTrends(
        in report: TrendAnalysisReport,
        for snapshot: TrendResearchSnapshot,
        ledger: TrendEvidenceLedger
    ) async -> TrendAnalysisReport {
        let exemptClaim = TrendClaimEvidence(exemptionReason: "测试用,暂无关联证据")
        var assetEvidences: [TrendEvidence] = []
        let trends = snapshot.assets.map { asset -> TrendAssetView in
            let evidenceID = "portfolio:asset:\(asset.id)"
            assetEvidences.append(TrendEvidence(
                id: evidenceID, sourceName: "持仓标的", title: asset.name,
                url: nil, publishedAt: nil, retrievedAt: createdAt,
                summary: "\(asset.name) 持仓快照",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .portfolioSnapshot, sourceTier: .primary,
                    entityCodes: [asset.code].compactMap { $0 },
                    entityNames: [asset.name],
                    metadataConfidence: .deterministic
                )
            ))
            let assetClaim = TrendClaimEvidence(supportingEvidenceIDs: [evidenceID])
            return TrendAssetView(
                id: asset.id, name: asset.name, code: asset.code,
                sector: asset.sector, impactText: "影响测试",
                horizons: TrendHorizon.allCases.map { horizon in
                    TrendHorizonView(
                        horizon: horizon, direction: .uncertain,
                        confidence: TrendConfidence(score: 50, label: "中"),
                        rationale: "测试", counterSignals: ["反证"],
                        claimEvidence: exemptClaim
                    )
                },
                rationale: "测试标的", counterSignals: ["反证"],
                claimEvidence: assetClaim
            )
        }
        await ledger.record(assetEvidences)
        return rebuildReport(report, assetTrends: trends)
    }

    /// 给 report 注入一个 allocationReview 级 action(用于测试它被清空)。
    private func injectAction(into report: TrendAnalysisReport) -> TrendAnalysisReport {
        let action = TrendActionCandidate(
            id: "test-action-1", kind: .rebalanceReview,
            title: "测试行动", detail: "用于验证清空",
            targetName: "测试标的",
            confidence: TrendConfidence(score: 60, label: "中"),
            triggerConditions: ["触发条件1"],
            invalidatingConditions: ["失效条件1"]
        )
        return rebuildReport(report, actions: [action])
    }

    /// 重建 report,只替换指定字段(保留 schemaVersion=2 等其余字段)。
    private func rebuildReport(
        _ report: TrendAnalysisReport,
        horizons: [TrendHorizonView]? = nil,
        sectors: [TrendSectorView]? = nil,
        assetTrends: [TrendAssetView]? = nil,
        actions: [TrendActionCandidate]? = nil,
        sourceStatuses: [TrendSourceStatus]? = nil
    ) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: report.id,
            generatedAt: report.generatedAt,
            dataAsOf: report.dataAsOf,
            privacyMode: report.privacyMode,
            externalSignalStatus: report.externalSignalStatus,
            portfolio: report.portfolio,
            horizons: horizons ?? report.horizons,
            marketOutlook: report.marketOutlook,
            sectors: sectors ?? report.sectors,
            opportunities: report.opportunities,
            keyAssets: report.keyAssets,
            assetTrends: assetTrends ?? report.assetTrends,
            actions: actions ?? report.actions,
            evidence: report.evidence,
            warnings: report.warnings,
            disclaimer: report.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: report.disposition,
            sourceStatuses: sourceStatuses ?? report.sourceStatuses
        )
    }
}

// MARK: - makeMinimalSnapshot 的 privacyMode 覆盖辅助
private extension SubmitTrendReportCharacterizationTests {
    func makeMinimalSnapshot(privacyModeOverride: TrendPrivacyMode) -> TrendResearchSnapshot {
        let base = makeMinimalSnapshot()
        return TrendResearchSnapshot(
            runID: base.runID, createdAt: base.createdAt, dataAsOf: base.dataAsOf,
            privacyMode: privacyModeOverride, portfolio: base.portfolio,
            assets: base.assets, sectors: base.sectors,
            platformSignals: base.platformSignals, managerSignals: base.managerSignals,
            marketQuotes: base.marketQuotes, lookThrough: base.lookThrough,
            insightHeadline: base.insightHeadline, sourceWarnings: base.sourceWarnings,
            sourceStatuses: base.sourceStatuses
        )
    }
}
