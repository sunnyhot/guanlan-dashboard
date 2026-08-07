import SwiftUI

struct InvestmentDirectionEvidenceRow: View {
    let evidence: TrendEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text(evidence.sourceName)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                if let publishedAt = evidence.publishedAt, !publishedAt.isEmpty {
                    Text(String(publishedAt.prefix(10)))
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: AppPalette.spaceS)
                if let url = evidence.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("查看来源", systemImage: "arrow.up.right.square")
                    }
                    .font(AppPalette.appFont(.caption))
                }
            }

            Text(evidence.title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(evidence.summary)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.card,
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
    }
}
