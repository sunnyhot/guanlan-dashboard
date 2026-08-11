import SwiftUI

struct NextHourGuidanceEvidencePopover: View {
    let report: NextHourGuidanceReport

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Label("完整判断依据", systemImage: "doc.text.magnifyingglass")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: AppPalette.spaceS)
                Text("\(report.completeEvidenceLedger.count) 条证据")
                    .font(AppPalette.appFont(.caption, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    if report.completeEvidenceLedger.isEmpty {
                        ContentUnavailableView(
                            "暂无可追溯证据",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("本轮只保留了本地风控结论，请按“仅供研究”理解。")
                        )
                    } else {
                        ForEach(report.completeEvidenceLedger) { item in
                            VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                                HStack(spacing: AppPalette.spaceS) {
                                    Text(item.sourceName)
                                        .font(AppPalette.appFont(.caption, weight: .bold))
                                        .foregroundStyle(AppPalette.info)
                                    Spacer(minLength: AppPalette.spaceS)
                                    if let urlText = item.url, let url = URL(string: urlText) {
                                        Link(destination: url) {
                                            Label("打开来源", systemImage: "arrow.up.right.square")
                                                .font(AppPalette.appFont(.caption))
                                        }
                                        .accessibilityLabel("打开 \(item.sourceName) 的证据来源")
                                    }
                                }

                                Text(item.title)
                                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(item.summary)
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(AppPalette.spaceM)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                        }
                    }

                    if !report.riskChecks.isEmpty {
                        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                            Text("执行前复核")
                                .font(AppPalette.appFont(.subheadline, weight: .bold))
                                .foregroundStyle(AppPalette.warning)
                            ForEach(report.riskChecks, id: \.self) { item in
                                Label(item, systemImage: "checkmark.shield")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                    }

                    if !report.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                            Text("数据边界")
                                .font(AppPalette.appFont(.subheadline, weight: .bold))
                                .foregroundStyle(AppPalette.warning)
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 520, height: 560)
    }
}
