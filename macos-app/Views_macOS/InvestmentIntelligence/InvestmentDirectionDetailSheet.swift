import SwiftUI

struct InvestmentDirectionDetailSheet: View {
    let signal: InvestmentDirectionSignal

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AppPalette.spaceM) {
                Image(systemName: signal.recommendation.systemImage)
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(signal.recommendation.tint)
                    .frame(width: 38, height: 38)
                    .background(
                        signal.recommendation.tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                    Text(signal.name)
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    HStack(spacing: AppPalette.spaceS) {
                        InvestmentStateBadge(
                            text: signal.recommendation.displayName,
                            tint: signal.recommendation.tint
                        )
                        Text(signal.dimension.displayName)
                        Text("置信度 \(signal.confidence.normalizedScore)%")
                    }
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                }

                Spacer(minLength: AppPalette.spaceM)
                Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                    .buttonStyle(.appSecondary)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("关闭投资方向详情")
            }
            .padding(AppPalette.spaceL)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        Label("判断依据", systemImage: "doc.text.magnifyingglass")
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(signal.rationale)
                            .font(AppPalette.appFont(.body))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: AppPalette.spaceM) {
                            Label("\(signal.evidenceCount) 条依据", systemImage: "doc.on.doc")
                            Label(
                                "\(signal.independentExternalSourceCount) 个独立外部来源",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                            if signal.hasAuthoritativeEvidence {
                                Label("含权威来源", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(AppPalette.positive)
                            }
                        }
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                    }
                    .padding(AppPalette.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        signal.recommendation.tint.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    )

                    if let exposureText = signal.portfolioExposureText {
                        InvestmentDirectionDetailBlock(
                            title: "组合暴露依据",
                            systemImage: "briefcase.fill",
                            items: [exposureText],
                            emptyText: ""
                        )
                    }

                    InvestmentDirectionDetailBlock(
                        title: "触发条件",
                        systemImage: "bolt.fill",
                        items: signal.triggerConditions,
                        emptyText: "本轮未形成结构化触发条件，暂不应直接执行交易。"
                    )

                    InvestmentDirectionDetailBlock(
                        title: "失效与反向信号",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                        items: signal.invalidatingConditions + signal.counterSignals,
                        emptyText: "暂无明确失效条件，应降低结论等级并持续复核。"
                    )

                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        Label("完整证据", systemImage: "books.vertical.fill")
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)

                        if signal.evidence.isEmpty {
                            Text("没有可追溯证据，因此该结论只能作为观察项。")
                                .font(AppPalette.appFont(.subheadline))
                                .foregroundStyle(AppPalette.warning)
                        } else {
                            ForEach(signal.evidence) { evidence in
                                InvestmentDirectionEvidenceRow(evidence: evidence)
                            }
                        }
                    }
                    .padding(AppPalette.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AppPalette.cardStrong,
                        in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    )

                    Label(
                        "以上为条件式研究结论，不构成自动交易指令或收益承诺。",
                        systemImage: "info.circle"
                    )
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                }
                .padding(AppPalette.spaceL)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 680)
        .background(AppPalette.surface)
    }
}
