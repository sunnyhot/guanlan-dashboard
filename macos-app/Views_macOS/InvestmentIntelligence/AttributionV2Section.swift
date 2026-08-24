import SwiftUI

/// V2 双轨归因面板（ATTR-5）：确定性归因（DailyAttributionWorkflow）与上方
/// 旧收盘复盘（MarketCloseReviewSection，LLM 链路）并存展示，供对照。
/// 旧 section 与旧代码不动，Epic 12 才下线。
struct AttributionV2Section: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 审查 P2-9：单次读取（避免同一次 body 内重复跑 workflow）
        let outcome = model.dailyAttributionV2
        SectionCard(
            title: "当日归因（V2 引擎）",
            subtitle: "纯计算归因：持仓收益拆解到成分，与上方复盘双轨对照",
            icon: "chart.bar.doc.horizontal",
            trailing: {
                Spacer()
                if let rendered = outcome?.rendered {
                    InvestmentStateBadge(
                        text: badgeText(rendered.grade),
                        tint: badgeTint(rendered.grade)
                    )
                }
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                switch outcome {
                case .none:
                    Label(
                        "暂无持仓快照：刷新个人持仓后这里展示当日收益归因。",
                        systemImage: "clock"
                    )
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)

                case .some(let outcome) where outcome.job.state == .failed:
                    Label(
                        outcome.errorDetail ?? "归因计算失败",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.warning)

                case .some(let outcome):
                    if let rendered = outcome.rendered {
                        contentView(rendered: rendered, outcome: outcome)
                    } else {
                        Label(
                            "归因渲染缺失",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.warning)
                    }
                }
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func contentView(rendered: RenderedAttribution, outcome: DailyAttributionWorkflow.RunOutcome) -> some View {
        Text(rendered.headline)
            .font(AppPalette.appFont(.headline, weight: .semibold))
            .foregroundStyle(AppPalette.ink)

        if !rendered.contributionLines.isEmpty {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                ForEach(Array(rendered.contributionLines.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(lineTint(line))
                }
                if rendered.contributionLines.count > 5 {
                    Text("其余 \(rendered.contributionLines.count - 5) 项…")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            .padding(AppPalette.spaceM)
            .background(
                AppPalette.cardStrong,
                in: RoundedRectangle(cornerRadius: AppPalette.panelRadius)
            )
        }

        if let note = rendered.residualNote {
            Label(note, systemImage: "arrow.left.and.right")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }

        Label(rendered.caveat, systemImage: "info.circle")
            .font(AppPalette.appFont(.caption))
            .foregroundStyle(AppPalette.muted)

        // 审查 P1-8：估值/涨跌覆盖显式展示;未全覆盖时 residual 不产
        Text(dataBasisText(outcome: outcome) + " · V2 确定性引擎（无 LLM）")
            .font(AppPalette.appFont(.caption2))
            .foregroundStyle(AppPalette.muted)
    }

    // MARK: - 样式 helper

    /// 行着色：贡献正负（红涨绿跌，AppPalette 统一）。
    private func lineTint(_ line: String) -> Color {
        if line.contains("贡献 +") || line.contains("收益 +") { return AppPalette.marketGain }
        if line.contains("贡献 -") || line.contains("收益 -") { return AppPalette.marketLoss }
        return AppPalette.ink
    }

    private func badgeText(_ grade: AttributionCoverageGrade) -> String {
        switch grade {
        case .high: return "覆盖完整"
        case .partial: return "部分覆盖"
        case .low: return "覆盖不足"
        }
    }

    private func badgeTint(_ grade: AttributionCoverageGrade) -> Color {
        switch grade {
        case .high: return AppPalette.positive
        case .partial: return AppPalette.warning
        case .low: return AppPalette.danger
        }
    }

    /// 数据基础行：归因覆盖 + 估值/涨跌覆盖 + residual 口径说明。
    private func dataBasisText(outcome: DailyAttributionWorkflow.RunOutcome?) -> String {
        var parts = [
            "覆盖 \(pct(outcome?.artifact?.result.coverage.value))",
            "未覆盖 \(pct(outcome?.artifact?.result.unattributedWeight.value))",
        ]
        if let coverage = model.attributionV2Coverage {
            parts.append(coverage.summaryText)
            if !coverage.supportsResidual {
                parts.append("覆盖不完整，不计算残差")
            }
        }
        return "数据基础：" + parts.joined(separator: " · ")
    }

    private func pct(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let scaled = value * 100
        return "\(scaled.rounded(toScale: 1))%"
    }
}
