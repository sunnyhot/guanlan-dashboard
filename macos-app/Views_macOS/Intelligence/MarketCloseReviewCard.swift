import SwiftUI

// MARK: - 收盘复盘卡（审计 A1：V1 MarketCloseReview 的 V2 重建）
//
// 只读 InvestmentIntelligenceDashboardSnapshot.closeReview（Presentation
// DTO）；生成/补做动作走 model.runMarketCloseReview()；完整复盘（市场脉
// 搏/主题/逐持仓归因）在详情 sheet 经 ArtifactQueryService 读全量 artifact。
// 涨跌颜色走 AppPalette（红涨绿跌）。

struct MarketCloseReviewCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @ObservedObject var model: AppModel
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?

    private var summary: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary? {
        snapshot.closeReview
    }

    var body: some View {
        SectionCard(
            title: "收盘复盘",
            subtitle: "每日 21:00 冻结当日组合表现与市场叙述",
            icon: "moon.stars",
            trailing: {
                HStack(spacing: AppPalette.spaceS) {
                    Button(
                        model.closeReviewOperationState.isRunning
                            ? "生成中…" : buttonTitle
                    ) {
                        model.runMarketCloseReview()
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(
                        model.closeReviewOperationState.isRunning
                        || model.intelligenceRuntime == nil)
                    .help("生成/补做当日收盘复盘")
                    if let summary {
                        Button("查看完整复盘") { activeSheet = .closeReviewDetail }
                            .buttonStyle(.appText)
                            .controlSize(.small)
                    }
                }
            }
        ) {
            if case let .running(_, stage) = model.closeReviewOperationState {
                IntelligenceRunningRow(stage: stage)
            }
            if case let .failed(error) = model.closeReviewOperationState {
                IntelligenceInlineError(error: error)
            }
            if let summary {
                content(summary)
            } else {
                Text("尚未生成收盘复盘——收盘后点击「生成复盘」冻结当日表现、归因与市场叙述。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttonTitle: String {
        guard let summary else { return "生成复盘" }
        switch summary.state {
        case .todayDone: return "重新生成"
        case .awaitingTonight, .neverGenerated: return "生成复盘"
        case .overdue: return "补做今日复盘"
        }
    }

    @ViewBuilder
    private func content(
        _ summary: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                freshnessBadge(summary.state)
                Text(IntelligencePresentationFormatter.dateText(summary.reviewDate))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                Text(IntelligencePresentationFormatter.narrativeSourceLabel(summary.narrativeSource))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppPalette.surface, in: Capsule())
                Spacer(minLength: 0)
                if let amount = summary.dailyChangeAmount {
                    Text(Self.signedCurrencyText(amount))
                        .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                        .foregroundStyle(amount >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                    if let pct = summary.dailyChangePct {
                        Text(String(format: "%+.2f%%", pct))
                            .font(AppPalette.appFont(.footnote, design: .rounded))
                            .foregroundStyle(amount >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                    }
                } else {
                    Text("当日涨跌未公布")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if !summary.topImpacts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主要影响（\(summary.coveredHoldingCount)/\(summary.holdingCount) 覆盖）")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(
                        Array(summary.topImpacts.prefix(3).enumerated()), id: \.offset
                    ) { _, impact in
                        HStack(spacing: AppPalette.spaceS) {
                            Text(impact.name)
                                .font(AppPalette.appFont(.footnote, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let amount = impact.changeAmount {
                                Text(Self.signedCurrencyText(amount))
                                    .font(AppPalette.appFont(.footnote, design: .rounded))
                                    .foregroundStyle(amount >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                            }
                            if let pct = impact.changePct {
                                Text(String(format: "%+.2f%%", pct))
                                    .font(AppPalette.appFont(.caption, design: .rounded))
                                    .foregroundStyle(pct >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if !summary.tomorrowWatch.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("明日关注")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(summary.tomorrowWatch, id: \.self) { item in
                        Label(item, systemImage: "eye")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func freshnessBadge(
        _ state: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary.State
    ) -> some View {
        let color: Color
        switch IntelligencePresentationFormatter.closeReviewStateBadgeTone(state) {
        case .positive: color = AppPalette.positive
        case .warning: color = AppPalette.warning
        case .muted: color = AppPalette.muted
        }
        return Text(IntelligencePresentationFormatter.closeReviewStateLabel(state))
            .font(AppPalette.appFont(.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    static func signedCurrencyText(_ value: Double) -> String {
        let text = currencyText(abs(value))
        return value >= 0 ? "+\(text)" : "-\(text)"
    }
}

// MARK: - 完整复盘详情 Sheet（市场脉搏 / 强弱主题 / 逐持仓 / 数据边界）

struct MarketCloseReviewDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var review: MarketCloseReview?

    private var summary: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary? {
        model.intelligenceDashboardSnapshot?.closeReview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("收盘复盘详情")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                    if let summary {
                        Text("\(IntelligencePresentationFormatter.dateText(summary.reviewDate)) · \(IntelligencePresentationFormatter.narrativeSourceLabel(summary.narrativeSource))")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    if let review {
                        detailContent(review)
                    } else {
                        Text("正在读取复盘报告…")
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 640, height: 560)
        .onAppear(perform: loadReview)
    }

    private func loadReview() {
        guard let artifactID = summary?.artifactID,
              let runtime = model.intelligenceRuntime else { return }
        Task.detached(priority: .userInitiated) {
            let loaded = try? runtime.queryService.marketCloseReview(id: artifactID)
            await MainActor.run {
                review = loaded
            }
        }
    }

    @ViewBuilder
    private func detailContent(_ review: MarketCloseReview) -> some View {
        if let portfolio = review.portfolioReview {
            LabeledValue(
                title: "当日涨跌",
                value: {
                    if let amount = portfolio.dailyChangeAmount {
                        let pct = portfolio.dailyChangePct.map { String(format: "（%+.2f%%）", $0) } ?? ""
                        return "\(MarketCloseReviewCard.signedCurrencyText(amount))\(pct)"
                    }
                    return "未公布"
                }())
            LabeledValue(
                title: "总市值",
                value: currencyText(portfolio.totalMarketValue))
            LabeledValue(
                title: "涨跌覆盖",
                value: "\(portfolio.coveredHoldingCount)/\(portfolio.holdingCount) 持仓")
        }

        if !review.marketPulse.isEmpty {
            sectionTitle("市场脉搏")
            ForEach(Array(review.marketPulse.enumerated()), id: \.offset) { _, pulse in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppPalette.spaceS) {
                        Text(pulse.name)
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                        Text(IntelligencePresentationFormatter.pulseDirectionLabel(pulse.direction))
                            .font(AppPalette.appFont(.caption, weight: .medium))
                            .foregroundStyle(pulse.direction == .up ? AppPalette.marketGain : (pulse.direction == .down ? AppPalette.marketLoss : AppPalette.muted))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppPalette.surface, in: Capsule())
                        Text(pulse.confidenceText)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    Text(pulse.rationale)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if !review.strongThemes.isEmpty || !review.weakThemes.isEmpty {
            sectionTitle("强弱主题")
            ForEach(Array(review.strongThemes.enumerated()), id: \.offset) { _, theme in
                themeRow(theme, color: AppPalette.marketGain)
            }
            ForEach(Array(review.weakThemes.enumerated()), id: \.offset) { _, theme in
                themeRow(theme, color: AppPalette.marketLoss)
            }
        }

        if let portfolio = review.portfolioReview, !portfolio.topImpacts.isEmpty {
            sectionTitle("逐持仓影响")
            ForEach(Array(portfolio.topImpacts.enumerated()), id: \.offset) { _, impact in
                HStack(spacing: AppPalette.spaceS) {
                    Text(impact.name)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                    if let code = impact.code {
                        Text(code)
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                    }
                    Spacer(minLength: 0)
                    if let amount = impact.changeAmount {
                        Text(MarketCloseReviewCard.signedCurrencyText(amount))
                            .font(AppPalette.appFont(.footnote, design: .rounded))
                            .foregroundStyle(amount >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                    }
                    if let pct = impact.changePct {
                        Text(String(format: "%+.2f%%", pct))
                            .font(AppPalette.appFont(.footnote, design: .rounded))
                            .foregroundStyle(pct >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }

        if !review.tomorrowWatch.isEmpty {
            sectionTitle("明日关注")
            ForEach(review.tomorrowWatch, id: \.self) { item in
                Text("· \(item)")
                    .font(AppPalette.appFont(.footnote))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        DisclosureGroup("技术信息") {
            VStack(alignment: .leading, spacing: 4) {
                Text("报告 ID \(review.id.rawValue)")
                    .font(AppPalette.appFont(.caption, design: .monospaced))
                    .foregroundStyle(AppPalette.muted)
                    .textSelection(.enabled)
                if let attributionID = review.attributionArtifactID {
                    Text("归因 artifact \(attributionID)")
                        .font(AppPalette.appFont(.caption, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                        .textSelection(.enabled)
                }
                Text("数据边界 \(review.dataBoundary)")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .padding(.top, 2)
        }
        .font(AppPalette.appFont(.footnote))
    }

    private func themeRow(_ theme: MarketCloseReview.ThemeItem, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppPalette.spaceS) {
                Text(theme.name)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                Text(IntelligencePresentationFormatter.themeDirectionLabel(theme.direction))
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.1), in: Capsule())
            }
            Text(theme.rationale)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
    }
}
