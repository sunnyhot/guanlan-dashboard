import SwiftUI

// W4.4:TrendDirection 展示映射从 EnhancementTrendPanel 的私有扩展迁出,
// 供结论卡与各研判卡共用。W4.5 统一「不确定→暂不明确」文案时在此收敛。
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
            return "不确定"
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

/// W4.4 统一结论卡内容块:方向徽章 + 把握 + 一句话结论 + 为什么 + 什么情况作废 + 依据行。
///
/// 作为内容块嵌入周期/板块/大盘/机会卡片,替代 `rationale` 裸渲染;
/// 不自带容器背景,由外层卡片保持统一视觉。旧数据降级:
/// `whatWouldChange`(W4.2)落地前,「什么情况作废」取反证信号首条,
/// 反证也缺则不渲染该行。
struct VerdictCard: View {
    let direction: TrendDirection?
    var confidence: TrendConfidence? = nil
    let rationale: String
    let counterSignals: [String]
    /// 非 nil 时渲染「查看依据」行;点击动作由外层卡片承接(整卡可点)。
    var evidenceCount: Int? = nil

    private var content: TrendVerdictPresentation.Content {
        TrendVerdictPresentation.split(rationale: rationale)
    }

    private var invalidationText: String? {
        TrendVerdictPresentation.invalidationText(counterSignals: counterSignals)
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
                    if let confidence {
                        TrendConfidenceMeter(confidence: confidence)
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

            if let evidenceCount {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                    Text("查看 Agent 判断依据")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(evidenceCount > 0 ? "\(evidenceCount) 条" : "暂无直接证据")
                        .font(AppPalette.appFont(.caption2))
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
