import SwiftUI

enum InvestmentIntelligenceStyle {
    static func tint(for state: PortfolioDecisionState) -> Color {
        switch state {
        case .stable: return AppPalette.positive
        case .watch: return AppPalette.info
        case .prepare: return AppPalette.warning
        case .adjustReview, .exitReview: return AppPalette.warning
        case .insufficientEvidence: return AppPalette.muted
        }
    }

}

struct InvestmentStateBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(AppPalette.appFont(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 1))
    }
}

struct InvestmentMetricLabel: View {
    let title: String
    let value: String
    var tint: Color = AppPalette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.body, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InvestmentEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: AppPalette.spaceM) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppPalette.positive)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
