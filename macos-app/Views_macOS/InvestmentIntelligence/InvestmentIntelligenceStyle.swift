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

    static func tint(for grade: ConfidenceGrade) -> Color {
        switch grade {
        case .veryHigh, .high: return AppPalette.positive
        case .medium: return AppPalette.warning
        case .low: return AppPalette.danger
        }
    }

}

/// 术语解释入口：小问号，点击弹 popover，hover 有短提示兜底。
/// 只用于不在 Button 内部的场景（嵌套在卡片按钮内时改用 `.help()`）。
struct TermHelpView: View {
    let term: ResearchTerm
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .buttonStyle(.plain)
        .help(term.plainExplanation)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TermHelpPopoverContent(term: term)
        }
        .accessibilityLabel("解释「\(term.title)」是什么意思")
    }
}

private struct TermHelpPopoverContent: View {
    let term: ResearchTerm

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label(term.title, systemImage: "text.book.closed")
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            Text(term.plainExplanation)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(term.example)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(AppPalette.spaceS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AppPalette.info.opacity(AppPalette.accentSubtle),
                    in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                )
        }
        .padding(AppPalette.spaceM)
        .frame(width: 300, alignment: .leading)
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
