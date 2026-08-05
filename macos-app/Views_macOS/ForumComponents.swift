import SwiftUI

struct CommentBlock: View {
    let comment: CommentPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.userName ?? comment.brokerUserId ?? "未知用户")
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(comment.createdAt ?? "未知时间")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Text("赞 \(comment.likeCount ?? 0)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            Text(comment.content ?? "无内容")
                .font(AppPalette.appFont(.body))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !comment.children.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comment.children) { reply in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                                .fill(AppPalette.brand.opacity(0.28))
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reply.userName ?? reply.brokerUserId ?? "未知回复")
                                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                Text(reply.content ?? "无内容")
                                    .font(AppPalette.appFont(.subheadline))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                        .padding(8)
                        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(12)
        .staticSurface(
            tint: AppPalette.brand,
            fill: AppPalette.card,
            strokeOpacity: 0.28
        )
    }
}

struct InvestmentPlanCard: View {
    let plan: PersonalInvestmentPlan
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var accent: Color {
        if plan.isEndedPlan {
            return AppPalette.muted
        }
        if plan.isPausedPlan {
            return AppPalette.warning
        }
        return plan.isSmartPlan ? AppPalette.info : AppPalette.brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.planTypeLabel)
                            .font(AppPalette.appFont(.body, weight: .bold))
                            .foregroundStyle(accent)
                        Text(plan.fundName)
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                            .layoutPriority(1)
                            .help(plan.fundName)
                        if plan.isDrawdownMode {
                            ToolbarBadge(title: "涨跌幅模式", tint: AppPalette.info)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(plan.scheduleText)
                        if let fundCode = plan.fundCode, !fundCode.isEmpty {
                            Text(fundCode)
                        }
                    }
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(plan.amountRangeText)
                        .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(plan.normalizedStatus)
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 10) {
                LabeledValue(title: "累计期数", value: plan.investedPeriods.map(String.init) ?? "—")
                LabeledValue(title: "累计投入", value: plan.cumulativeInvestedAmount.map(currencyText) ?? "—")
                LabeledValue(title: "支付方式", value: plan.paymentMethod ?? "—")
                LabeledValue(title: "下次执行", value: plan.nextExecutionDate.isEmpty ? "—" : plan.nextExecutionDate)
            }

            if let note = plan.note, !note.isEmpty {
                Text(note)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(5)
            }

            if onEdit != nil || onDelete != nil {
                HStack(spacing: 8) {
                    Spacer()
                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("修改", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    }
                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.appDanger)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .staticSurface(
            tint: accent,
            fill: AppPalette.card,
            strokeOpacity: 0.28,
            activeStrokeOpacity: 0.46
        )
    }
}

struct PendingTradeCard: View {
    let trade: PersonalPendingTrade
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var accent: Color {
        switch trade.actionLabel {
        case "买入", "定投":
            return AppPalette.danger
        case "转换":
            return AppPalette.info
        default:
            return AppPalette.brand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(trade.actionLabel)
                            .font(AppPalette.appFont(.body, weight: .bold))
                            .foregroundStyle(accent)
                        Text(trade.displayTitle)
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                    }

                    if let codeText = trade.displayCodeText, !codeText.isEmpty {
                        Text(codeText)
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(trade.amountText)
                        .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(trade.status)
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.brand)
                        .lineLimit(1)
                }
            }

            HStack {
                Text(trade.occurredAt)
                Spacer()
                if let note = trade.note, !note.isEmpty {
                    Text(note)
                }
            }
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)

            if onEdit != nil || onDelete != nil {
                HStack(spacing: 8) {
                    Spacer()
                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("修改", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    }
                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.appDanger)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .staticSurface(
            tint: accent,
            fill: AppPalette.card,
            strokeOpacity: 0.28,
            activeStrokeOpacity: 0.46
        )
    }
}
