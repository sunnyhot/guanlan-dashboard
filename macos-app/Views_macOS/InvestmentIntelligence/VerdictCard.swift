import SwiftUI

// W4.4:TrendHorizon 展示映射同样从 EnhancementTrendPanel 迁出共用。
extension TrendHorizon {
    var displayText: String {
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

// W4.4:TrendDirection 展示映射从 EnhancementTrendPanel 的私有扩展迁出,
// 供结论卡与各研判卡共用。W4.5:「不确定」统一为「暂不明确」。
extension TrendDirection {
    var displayText: String {
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
            return "暂不明确"
        }
    }

    var tint: Color {
        switch self {
        case .bullish, .neutralPositive:
            return AppPalette.positive
        case .neutral:
            return AppPalette.info
        case .neutralNegative, .bearish:
            return AppPalette.warning
        case .uncertain:
            return AppPalette.muted
        }
    }
}

/// W4.4/W4.5/W4.7 统一结论卡内容块:
/// 方向徽章 + 把握(带档位锚定) + 一句话结论 + 为什么 + 「暂不明确·在等 XX」出口 +
/// 什么情况作废 + 依据行(支持/反对并排,反对非空标「有分歧」)。
///
/// 作为内容块嵌入周期/板块/大盘/机会卡片,替代 `rationale` 裸渲染;
/// 不自带容器背景,由外层卡片保持统一视觉。旧数据降级:
/// `whatWouldChange` 为空时作废条件取反证首条,再缺则不渲染该行;
/// 「在等什么」缺省时显示「依据不足」。
struct VerdictCard: View {
    let direction: TrendDirection?
    var confidence: TrendConfidence? = nil
    let rationale: String
    var whatWouldChange: String = ""
    let counterSignals: [String]
    /// 支持证据条数(来自 claimEvidence.supportingEvidenceIDs)。
    var supportingCount: Int? = nil
    /// 反对证据条数(非 0 时结论卡标「有分歧」,W4.7)。
    var counterCount: Int? = nil

    private var content: TrendVerdictPresentation.Content {
        TrendVerdictPresentation.split(rationale: rationale)
    }

    private var invalidationText: String? {
        TrendVerdictPresentation.invalidationText(
            whatWouldChange: whatWouldChange,
            counterSignals: counterSignals
        )
    }

    /// W4.5:uncertain 的「在等什么」;缺省降级「依据不足」。
    private var waitText: String? {
        TrendVerdictPresentation.watchSignal(rationale: rationale)
    }

    private var hasDivergence: Bool {
        (counterCount ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let direction {
                HStack(spacing: 6) {
                    TintedCapsuleBadge(
                        text: direction.displayText,
                        tint: direction.tint,
                        font: AppPalette.appFont(.caption, weight: .bold),
                        horizontalPadding: 7,
                        verticalPadding: 2
                    )
                    if hasDivergence {
                        // W4.7:反对证据非空时显式标记分歧,不让结论显得全员一致。
                        TintedCapsuleBadge(
                            text: "有分歧",
                            tint: AppPalette.warning,
                            font: AppPalette.appFont(.caption2, weight: .semibold),
                            horizontalPadding: 5,
                            verticalPadding: 1
                        )
                    }
                    if let confidence {
                        TrendConfidenceMeter(confidence: confidence, showsAnchorCaption: true)
                    }
                    Spacer(minLength: 4)
                }
            }

            if !content.headline.isEmpty {
                Text(content.headline)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.reasoning.isEmpty {
                Text(content.reasoning)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if direction == .uncertain {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.top, 1)
                    Text(
                        waitText.map { "在等:\($0)" }
                            ?? "暂不明确 · 依据不足"
                    )
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let invalidationText {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.warning)
                        .padding(.top, 1)
                    Text("什么情况作废：\(invalidationText)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.warning)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let supportingCount {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                    Text("查看 Agent 判断依据")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                    Spacer(minLength: 4)
                    // W4.7:支持/反对并排,分歧一眼可见。
                    Text("支持 \(supportingCount) 条")
                        .font(AppPalette.appFont(.caption2))
                    if let counterCount, counterCount > 0 {
                        Text("· 反对 \(counterCount) 条")
                            .font(AppPalette.appFont(.caption2, weight: .semibold))
                            .foregroundStyle(AppPalette.warning)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppPalette.appFont(.caption2, weight: .bold))
                }
                .foregroundStyle(AppPalette.info)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
