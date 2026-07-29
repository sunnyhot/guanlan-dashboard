import Foundation

enum TrendDashboardTone: Hashable {
    case brand
    case positive
    case info
    case warning
    case danger
    case muted
}

struct EnhancementTrendStatus: Hashable {
    let isProviderConfigured: Bool
    let generationState: TrendGenerationState
    let lastGeneratedAt: String?
    let headline: String
    let externalSignalStatus: TrendExternalSignalStatus?
    let isStale: Bool

    var valueText: String {
        if !isProviderConfigured {
            return "未配置"
        }
        switch generationState {
        case .generating:
            return "生成中"
        case .failed:
            return "失败"
        case .rejected:
            return "已拦截"
        case .idle, .succeeded:
            if lastGeneratedAt == nil {
                return "未生成"
            }
            return isStale ? "待更新" : "已生成"
        }
    }

    var detailText: String {
        var parts = [headline]
        if let externalSignalStatus {
            parts.append("外部信号 \(externalSignalStatus.rawValue)")
        }
        if let lastGeneratedAt {
            parts.append(lastGeneratedAt)
        }
        return parts.joined(separator: " · ")
    }

    var severity: TrendDashboardTone {
        if !isProviderConfigured {
            return .warning
        }
        switch generationState {
        case .generating:
            return .info
        case .failed:
            return .danger
        case .rejected:
            return .warning
        case .idle:
            return lastGeneratedAt == nil ? .info : (isStale ? .warning : .positive)
        case .succeeded:
            if isStale {
                return .warning
            }
            return externalSignalStatus == .unavailable ? .info : .positive
        }
    }
}

enum TrendDashboardStatus: Hashable {
    case unconfigured
    case empty
    case generating
    case ready
    case stale
    case failed
    case rejected
}

enum TrendDashboardActionKind: Hashable {
    case configure
    case generate
    case refresh
    case openReport
    case wait
}

struct TrendDashboardAction: Hashable {
    let kind: TrendDashboardActionKind
    let title: String
    let systemImage: String
    let tone: TrendDashboardTone
    let isPrimary: Bool
    let isDisabled: Bool
}

struct TrendDashboardHorizonItem: Identifiable, Hashable {
    let id: TrendHorizon
    let title: String
    let directionText: String
    let confidenceText: String
    let confidence: TrendConfidence
    let rationale: String
    let tone: TrendDashboardTone
}

struct TrendDashboardSectorItem: Identifiable, Hashable {
    let id: String
    let name: String
    let exposureText: String
    let directionText: String
    let confidenceText: String
    let confidence: TrendConfidence
    let rationale: String
    let tone: TrendDashboardTone
}

struct TrendDashboardSummary: Hashable {
    let status: TrendDashboardStatus
    let stateText: String
    let headline: String
    let detail: String
    let riskLevel: TrendRiskLevel?
    let riskText: String
    let riskTone: TrendDashboardTone
    let generatedAt: String?
    let dataAsOf: String?
    let externalSignalText: String?
    let externalSignalTone: TrendDashboardTone
    let horizons: [TrendDashboardHorizonItem]
    let sectors: [TrendDashboardSectorItem]
    let primaryAction: TrendDashboardAction
    let secondaryAction: TrendDashboardAction?

    static func make(
        report: TrendAnalysisReport?,
        trendStatus: EnhancementTrendStatus,
        generationState: TrendGenerationState,
        lastError: String,
        progressLogs: [TrendProgressLog]
    ) -> TrendDashboardSummary {
        if !trendStatus.isProviderConfigured {
            return empty(
                status: .unconfigured,
                stateText: "未配置",
                headline: "尚未配置趋势分析模型",
                detail: "先在设置中填写模型地址、模型名称和 API Key。",
                primaryAction: action(.configure, title: "配置模型", systemImage: "gearshape", tone: .warning)
            )
        }

        if generationState == .generating {
            return from(
                report: report,
                status: .generating,
                stateText: "生成中",
                fallbackHeadline: "正在生成 AI 趋势分析",
                detail: progressLogs.last?.message ?? "正在等待模型返回",
                primaryAction: action(.wait, title: "生成中", systemImage: "hourglass", tone: .info, isDisabled: true),
                secondaryAction: report == nil ? nil : action(.openReport, title: "查看旧报告", systemImage: "doc.text.magnifyingglass", tone: .info, isPrimary: false)
            )
        }

        if generationState == .failed {
            return from(
                report: report,
                status: .failed,
                stateText: "失败",
                fallbackHeadline: "AI 趋势分析生成失败",
                detail: clipped(lastError, fallback: "查看增强页了解失败原因"),
                primaryAction: action(.refresh, title: "重新分析", systemImage: "arrow.clockwise", tone: .warning),
                secondaryAction: report == nil ? nil : action(.openReport, title: "查看旧报告", systemImage: "doc.text.magnifyingglass", tone: .info, isPrimary: false)
            )
        }

        if generationState == .rejected {
            return from(
                report: report,
                status: .rejected,
                stateText: "已拦截",
                fallbackHeadline: "AI 趋势报告未通过安全校验",
                detail: clipped(lastError, fallback: "报告结构或措辞不符合展示规则"),
                primaryAction: action(.refresh, title: "重新分析", systemImage: "arrow.clockwise", tone: .warning),
                secondaryAction: report == nil ? nil : action(.openReport, title: "查看旧报告", systemImage: "doc.text.magnifyingglass", tone: .info, isPrimary: false)
            )
        }

        guard let report else {
            return empty(
                status: .empty,
                stateText: "未生成",
                headline: "等待生成 AI 趋势分析",
                detail: "将结合本地持仓、平台动态和模型可用的外部信号生成组合判断。",
                primaryAction: action(.generate, title: "立即分析", systemImage: "wand.and.stars", tone: .brand)
            )
        }

        if trendStatus.isStale {
            return from(
                report: report,
                status: .stale,
                stateText: "待更新",
                fallbackHeadline: report.portfolio.headline,
                detail: "这份报告不是今天生成，建议刷新后再用于复核。",
                primaryAction: action(.refresh, title: "重新分析", systemImage: "arrow.clockwise", tone: .warning),
                secondaryAction: action(.openReport, title: "查看完整报告", systemImage: "doc.text.magnifyingglass", tone: .info, isPrimary: false)
            )
        }

        return from(
            report: report,
            status: .ready,
            stateText: "已生成",
            fallbackHeadline: report.portfolio.headline,
            detail: report.portfolio.summary,
            detailMaxLength: nil,
            primaryAction: action(.openReport, title: "查看完整报告", systemImage: "doc.text.magnifyingglass", tone: .brand),
            secondaryAction: action(.refresh, title: "重新分析", systemImage: "arrow.clockwise", tone: .info, isPrimary: false)
        )
    }

    private static func empty(
        status: TrendDashboardStatus,
        stateText: String,
        headline: String,
        detail: String,
        primaryAction: TrendDashboardAction
    ) -> TrendDashboardSummary {
        TrendDashboardSummary(
            status: status,
            stateText: stateText,
            headline: headline,
            detail: detail,
            riskLevel: nil,
            riskText: "风险未知",
            riskTone: .muted,
            generatedAt: nil,
            dataAsOf: nil,
            externalSignalText: nil,
            externalSignalTone: .muted,
            horizons: [],
            sectors: [],
            primaryAction: primaryAction,
            secondaryAction: nil
        )
    }

    private static func from(
        report: TrendAnalysisReport?,
        status: TrendDashboardStatus,
        stateText: String,
        fallbackHeadline: String,
        detail: String,
        detailMaxLength: Int? = 48,
        primaryAction: TrendDashboardAction,
        secondaryAction: TrendDashboardAction?
    ) -> TrendDashboardSummary {
        let riskLevel = report?.portfolio.riskLevel
        let externalSignal = report?.externalSignalStatus
        let fallbackDetail = report?.portfolio.summary ?? fallbackHeadline
        let normalizedDetail = normalized(detail, fallback: fallbackDetail)
        return TrendDashboardSummary(
            status: status,
            stateText: stateText,
            headline: report?.portfolio.headline ?? fallbackHeadline,
            detail: detailMaxLength.map { clipped(normalizedDetail, fallback: fallbackDetail, maxLength: $0) } ?? normalizedDetail,
            riskLevel: riskLevel,
            riskText: riskLevel?.dashboardText ?? "风险未知",
            riskTone: riskLevel?.dashboardTone ?? .muted,
            generatedAt: report?.generatedAt,
            dataAsOf: report?.dataAsOf,
            externalSignalText: externalSignal.map { "外部信号\($0.dashboardText)" },
            externalSignalTone: externalSignal?.dashboardTone ?? .muted,
            horizons: makeHorizons(report?.horizons ?? []),
            sectors: makeSectors(report?.sectors ?? []),
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        )
    }

    private static func makeHorizons(_ horizons: [TrendHorizonView]) -> [TrendDashboardHorizonItem] {
        TrendHorizon.allCases.map { horizon in
            if let item = horizons.first(where: { $0.horizon == horizon }) {
                return TrendDashboardHorizonItem(
                    id: horizon,
                    title: horizon.dashboardText,
                    directionText: item.direction.dashboardText,
                    confidenceText: "\(item.confidence.label)信心",
                    confidence: item.confidence,
                    rationale: normalized(item.rationale, fallback: "暂无判断依据"),
                    tone: item.direction.dashboardTone
                )
            }
            return TrendDashboardHorizonItem(
                id: horizon,
                title: horizon.dashboardText,
                directionText: "暂无判断",
                confidenceText: "低信心",
                confidence: TrendConfidence(score: 0, label: "低"),
                rationale: "本次报告没有返回\(horizon.dashboardText)观点。",
                tone: .muted
            )
        }
    }

    private static func makeSectors(_ sectors: [TrendSectorView]) -> [TrendDashboardSectorItem] {
        sectors.prefix(4).map { sector in
            TrendDashboardSectorItem(
                id: sector.id,
                name: sector.name,
                exposureText: sector.exposureText,
                directionText: sector.direction.dashboardText,
                confidenceText: "\(sector.confidence.label)信心",
                confidence: sector.confidence,
                rationale: normalized(sector.rationale, fallback: "暂无板块依据"),
                tone: sector.direction.dashboardTone
            )
        }
    }

    private static func action(
        _ kind: TrendDashboardActionKind,
        title: String,
        systemImage: String,
        tone: TrendDashboardTone,
        isPrimary: Bool = true,
        isDisabled: Bool = false
    ) -> TrendDashboardAction {
        TrendDashboardAction(
            kind: kind,
            title: title,
            systemImage: systemImage,
            tone: tone,
            isPrimary: isPrimary,
            isDisabled: isDisabled
        )
    }

    private static func clipped(_ value: String, fallback: String, maxLength: Int = 48) -> String {
        let source = normalized(value, fallback: fallback)
        guard source.count > maxLength else { return source }
        return "\(source.prefix(maxLength - 1))..."
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

extension TrendRiskLevel {
    var dashboardText: String {
        switch self {
        case .low:
            return "低风险"
        case .medium:
            return "中风险"
        case .high:
            return "高风险"
        case .unknown:
            return "风险未知"
        }
    }

    var dashboardTone: TrendDashboardTone {
        switch self {
        case .low:
            return .positive
        case .medium:
            return .warning
        case .high:
            return .danger
        case .unknown:
            return .muted
        }
    }
}

extension TrendExternalSignalStatus {
    var dashboardText: String {
        switch self {
        case .available:
            return "可用"
        case .unavailable:
            return "不可用"
        case .partial:
            return "部分可用"
        case .stale:
            return "可能过期"
        }
    }

    var dashboardTone: TrendDashboardTone {
        switch self {
        case .available:
            return .positive
        case .unavailable:
            return .warning
        case .partial:
            return .info
        case .stale:
            return .warning
        }
    }
}

extension TrendHorizon {
    var dashboardText: String {
        switch self {
        case .short:
            return "短期"
        case .medium:
            return "中期"
        case .long:
            return "长期"
        }
    }
}

extension TrendDirection {
    var dashboardText: String {
        switch self {
        case .bullish:
            return "偏强"
        case .neutralPositive:
            return "中性偏强"
        case .neutral:
            return "中性"
        case .neutralNegative:
            return "中性偏弱"
        case .bearish:
            return "偏弱"
        case .uncertain:
            return "不确定"
        }
    }

    var dashboardTone: TrendDashboardTone {
        switch self {
        case .bullish, .neutralPositive:
            return .positive
        case .neutral:
            return .info
        case .neutralNegative, .bearish:
            return .warning
        case .uncertain:
            return .muted
        }
    }
}
