#if os(iOS)
import SwiftUI

// MARK: - iOS 基金披露明细列表（从基金穿透面板 push 进来）
//
// 展示穿透快照里每只基金的披露摘要：占组合比、披露证券占比、前十大数量、行业数、
// 截止日期、数据源警告。ScrollView + 卡片列表，杂志型风格。

struct IOSFundDisclosureListView: View {
    let funds: [PortfolioFundLookThroughSummary]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: IOSDesign.spaceS) {
                ForEach(funds, id: \.fundCode) { fund in
                    fundCard(fund)
                }
            }
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.top, IOSDesign.spaceS)
            .padding(.bottom, 12)
        }
        .background(IOSDesign.paper)
        .navigationTitle("基金披露明细")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fundCard(_ fund: PortfolioFundLookThroughSummary) -> some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text(fund.fundName)
                    .font(IOSDesign.sansBody(15, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(formatted(fund.portfolioWeightPct))
                    .font(IOSDesign.monoNumber(14))
                    .foregroundStyle(IOSDesign.accent)
            }
            if let code = fund.fundCode as String?, !code.isEmpty {
                Text(code)
                    .font(IOSDesign.monoNumber(11, weight: .regular))
                    .foregroundStyle(IOSDesign.muted)
            }

            Divider().opacity(0.4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
                metricTile("披露证券", formatted(fund.disclosedSecurityWeightPct))
                metricTile("前十大", "\(fund.topHoldingCount) 只")
                metricTile("行业", "\(fund.industryCount) 个")
            }

            if let asOf = fund.asOf, !asOf.isEmpty {
                Text("截至 \(asOf)")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
            }
            if !fund.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(fund.warnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppPalette.warning)
                            Text(w)
                                .font(IOSDesign.sansBody(11))
                                .foregroundStyle(IOSDesign.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(IOSDesign.spaceS)
                .background(AppPalette.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
            }
        }
        .padding(IOSDesign.spaceM)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
        .overlay(RoundedRectangle(cornerRadius: IOSDesign.radiusM).stroke(IOSDesign.ink.opacity(0.1), lineWidth: 1))
    }

    private func metricTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(IOSDesign.sansBody(11))
                .foregroundStyle(IOSDesign.muted)
            Text(value)
                .font(IOSDesign.monoNumber(13))
                .foregroundStyle(IOSDesign.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ pct: Double) -> String {
        String(format: "%.1f%%", pct)
    }
}
#endif
