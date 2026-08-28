import Foundation

/// W1.3:示例演示报告——BYOK 下配置前先看到产品价值。
///
/// 一份静态、脱敏的 `TrendAnalysisReport`,覆盖四条链路的主要产物形态
/// (周期判断 / 板块 / 大市场观点 / 机会 / 行动候选),喂给现有渲染组件只读展示。
/// **防腐约束**:Demo 数据必须始终通过当前 `TrendAnalysisValidator` 全部校验
/// (`DemoTrendReportTests` 锁住)——Validator 收紧(W4.3)时必须同步更新这里,
/// 否则新用户看到的第一份「产品长什么样」恰是与 W4 目标相反的旧范式。
enum DemoTrendReport {
    static let generatedAtText = "2026-08-27 21:10:00"
    static let dataAsOfText = "2026-08-27 15:00:00"

    static let shared: TrendAnalysisReport = make()

    static func make() -> TrendAnalysisReport {
        let evidence = Self.evidence
        let claim = { (supporting: [String]) -> TrendClaimEvidence in
            TrendClaimEvidence(
                supportingEvidenceIDs: supporting,
                counterEvidenceIDs: [],
                contextEvidenceIDs: [],
                exemptionReason: nil
            )
        }

        return TrendAnalysisReport(
            id: UUID(uuidString: "DEMO0000-0000-4000-8000-000000000001") ?? UUID(),
            generatedAt: generatedAtText,
            dataAsOf: dataAsOfText,
            privacyMode: .sanitized,
            externalSignalStatus: .partial,
            portfolio: TrendPortfolioSummary(
                headline: "示例组合:结构均衡,短期以防御为主",
                riskLevel: .medium,
                summary: "示例数据。组合覆盖股债与行业基金,穿透覆盖率约 78%;短期波动可控,中期等待量能信号再做加减仓。",
                claimEvidence: claim(["demo:portfolio:snapshot"])
            ),
            horizons: [
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutralNegative,
                    confidence: Self.confidence(58),
                    rationale: "短期偏谨慎,量能不足且外部信号仅部分可用。缩量震荡阶段追高性价比低,以持有和观察为主。",
                    whatWouldChange: "成交额连续两日站上万亿并放量突破趋势线时,短期转中性。",
                    counterSignals: ["成交额连续两日回升至万亿以上"],
                    claimEvidence: claim(["demo:portfolio:snapshot", "demo:market:csi300"])
                ),
                TrendHorizonView(
                    horizon: .medium,
                    direction: .neutral,
                    confidence: Self.confidence(62),
                    rationale: "中期中性,估值处于近五年中位附近。盈利修复斜率待确认,维持既有配置不动。",
                    whatWouldChange: "季报盈利一致预期上修时,中期判断转偏强。",
                    counterSignals: ["季报披露后企业盈利一致预期下修"],
                    claimEvidence: claim(["demo:portfolio:snapshot"])
                ),
                TrendHorizonView(
                    horizon: .long,
                    direction: .neutralPositive,
                    confidence: Self.confidence(71),
                    rationale: "长期偏乐观,股债性价比仍偏向权益。适合按计划分批投入,不因短期波动停投。",
                    whatWouldChange: "股债性价比回到中性以下时,长期判断转中性。",
                    counterSignals: ["长期利率中枢显著上行"],
                    claimEvidence: claim(["demo:portfolio:snapshot"])
                )
            ],
            marketOutlook: [
                TrendMarketOutlook(
                    id: "demo-market-csi300",
                    name: "沪深300",
                    category: "index",
                    direction: .neutral,
                    confidence: Self.confidence(60),
                    rationale: "中性,宽基震荡格局未变,指数处于区间中段。突破需要量能与政策信号配合,当前更适合定投而非单笔加仓。",
                    evidenceIDs: ["demo:market:csi300"],
                    counterSignals: ["单日成交额突破 1.2 万亿并持续三日"],
                    claimEvidence: claim(["demo:market:csi300"])
                )
            ],
            sectors: [
                TrendSectorView(
                    id: "demo-sector-semiconductor",
                    name: "半导体",
                    exposureText: "示例:占组合约 8%,行业景气与国产替代逻辑并行",
                    direction: .bullish,
                    confidence: Self.confidence(66),
                    rationale: "偏强,板块景气上行,设备与材料环节订单能见度改善。估值不低,适合持有而非追高,回调时分批关注。",
                    whatWouldChange: "设备订单环比连续两季下滑时,板块判断转中性。",
                    evidenceIDs: ["demo:sector:semiconductor"],
                    counterSignals: ["下游消费电子需求二次走弱"],
                    claimEvidence: claim(["demo:sector:semiconductor"])
                )
            ],
            opportunities: [
                TrendOpportunity(
                    id: "demo-opportunity-dividend",
                    name: "中证红利",
                    category: "指数",
                    scope: .marketWide,
                    direction: .neutralPositive,
                    confidence: Self.confidence(64),
                    rationale: "防御,红利资产在震荡市里防御属性突出。股息率相对无风险利率的利差仍在高位,适合作为组合稳定器。",
                    whatWouldChange: "股息率利差收窄至近五年 30% 分位以下时,机会评级下调。",
                    triggerConditions: ["利差收窄至近五年 30% 分位以下时停止加仓"],
                    invalidatingConditions: ["分红政策集中下调"],
                    evidenceIDs: ["demo:market:dividend"],
                    counterSignals: ["市场风格切换至高弹性成长"],
                    claimEvidence: claim(["demo:market:dividend"])
                )
            ],
            keyAssets: [],
            assetTrends: [],
            actions: [
                TrendActionCandidate(
                    id: "demo-action-dividend-watch",
                    kind: .watch,
                    title: "关注红利资产配置价值",
                    detail: "示例行动:把「中证红利」加入观察,若回调 3% 以上再评估是否分批增持,单次不超过组合 2%。",
                    targetName: "中证红利",
                    confidence: Self.confidence(68),
                    whatWouldChange: "分红政策集中下调或利差快速收窄时,撤销该关注。",
                    triggerConditions: ["指数回调 3% 以上且利差仍在高位"],
                    invalidatingConditions: ["分红政策集中下调或利差快速收窄"],
                    claimEvidence: claim(["demo:market:dividend", "demo:portfolio:snapshot"])
                )
            ],
            evidence: evidence,
            warnings: [],
            disclaimer: "示例数据,非真实研判;数字均为演示用途。AI 输出仅供参考,非投资建议。",
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: .analysisOnly,
            sourceStatuses: Self.sourceStatuses
        )
    }

    private static func confidence(_ score: Int) -> TrendConfidence {
        TrendConfidence(score: score, label: TrendConfidence.label(for: score))
    }

    private static var evidence: [TrendEvidence] {
        [
            TrendEvidence(
                id: "demo:portfolio:snapshot",
                sourceName: "组合快照(示例)",
                title: "示例组合穿透快照",
                url: nil,
                publishedAt: nil,
                retrievedAt: dataAsOfText,
                summary: "示例组合:8 只基金,股 6 债 2;穿透覆盖率 78%,披露截至 2026-06-30。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .portfolioSnapshot,
                    sourceTier: .primary,
                    metadataConfidence: .deterministic
                )
            ),
            TrendEvidence(
                id: "demo:market:csi300",
                sourceName: "行情快照(示例)",
                title: "沪深300 指数行情",
                url: nil,
                publishedAt: nil,
                retrievedAt: dataAsOfText,
                summary: "示例行情:沪深300 近一月区间震荡,换手率处于中位以下。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .marketQuote,
                    sourceTier: .primary,
                    entityCodes: ["000300"],
                    entityNames: ["沪深300"],
                    metadataConfidence: .deterministic
                )
            ),
            TrendEvidence(
                id: "demo:sector:semiconductor",
                sourceName: "行情快照(示例)",
                title: "半导体行业指数行情",
                url: nil,
                publishedAt: nil,
                retrievedAt: dataAsOfText,
                summary: "示例行情:半导体行业指数近一月跑赢宽基,量价配合。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .marketQuote,
                    sourceTier: .primary,
                    entityCodes: ["半导体"],
                    entityNames: ["半导体"],
                    sectorKeys: ["半导体"],
                    metadataConfidence: .deterministic
                )
            ),
            TrendEvidence(
                id: "demo:market:dividend",
                sourceName: "行情快照(示例)",
                title: "中证红利指数行情",
                url: nil,
                publishedAt: nil,
                retrievedAt: dataAsOfText,
                summary: "示例行情:红利指数回撤小于宽基,股息率利差维持高位。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .marketQuote,
                    sourceTier: .primary,
                    entityCodes: ["000922"],
                    entityNames: ["中证红利"],
                    metadataConfidence: .deterministic
                )
            )
        ]
    }

    private static var sourceStatuses: [TrendSourceStatus] {
        let states: [(TrendDataSource, TrendDataSourceState, String)] = [
            (.marketIndex, .success, "宽基与行业指数行情"),
            (.portfolioQuote, .success, "组合持仓估值"),
            (.fundNAV, .success, "基金净值"),
            (.fundDisclosure, .successEmpty, "最新季报已计入穿透"),
            (.qiemanAdjustment, .notRequested, "示例报告不读取主理人调仓"),
            (.alfaAdjustment, .notRequested, "示例报告不读取投顾组合"),
            (.managerWatch, .notConfigured, "未配置主理人关注"),
            (.officialSource, .notConfigured, "未配置 SEC 官方源"),
            (.alphaVantage, .notConfigured, "未配置 Alpha Vantage"),
            (.webSearch, .notConfigured, "联网搜索已下线")
        ]
        return states.map {
            TrendSourceStatus(
                source: $0.0,
                status: $0.1,
                asOf: dataAsOfText,
                receivedAt: dataAsOfText,
                errorCode: nil,
                itemCount: nil,
                detail: $0.2
            )
        }
    }
}
