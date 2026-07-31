#if os(iOS)
import SwiftUI

// MARK: - iOS 持仓详情 Sheet
//
// 复用 Core 层 PersonalAssetDetailSummary.make(row:) 的跨平台计算,
// 用 iPhone 友好的 sheet 布局展示基金详情(估值/收益/待确认/计划)。

struct IOSPersonalAssetDetailSheet: View {
    let row: PersonalAssetAggregateRow
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirm = false
    @State private var showingEdit = false
    @State private var editingTrade: PersonalPendingTrade?
    @State private var showingAddTrade = false
    @State private var editingPlan: PersonalInvestmentPlan?
    @State private var showingAddPlan = false
    @State private var showingValuationAlert = false

    private var summary: PersonalAssetDetailSummary {
        PersonalAssetDetailSummary.make(row: row)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    metricsSection
                    attentionSection
                    pendingTradesSection
                    plansSection
                    valuationAlertEntry
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(summary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if row.holdingRow != nil {
                            Button {
                                showingEdit = true
                            } label: {
                                Label("编辑持仓", systemImage: "pencil")
                            }
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("确认删除该持仓？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("删除全部(持仓+待确认+计划)", role: .destructive) {
                    model.deletePersonalAssetEntry(row, scope: .all)
                    dismiss()
                }
                if row.holdingRow != nil {
                    Button("仅删除持仓", role: .destructive) {
                        model.deletePersonalAssetEntry(row, scope: .holding)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后不可恢复。可选择删除范围。")
            }
            .sheet(isPresented: $showingEdit) {
                IOSEditHoldingSheet(row: row)
            }
            .sheet(item: $editingTrade) { trade in
                IOSPendingTradeEditSheet(row: row, trade: trade)
            }
            .sheet(isPresented: $showingAddTrade) {
                IOSPendingTradeEditSheet(row: row, trade: nil)
            }
            .sheet(item: $editingPlan) { plan in
                IOSInvestmentPlanEditSheet(row: row, plan: plan)
            }
            .sheet(isPresented: $showingAddPlan) {
                IOSInvestmentPlanEditSheet(row: row, plan: nil)
            }
            .sheet(isPresented: $showingValuationAlert) {
                IOSValuationAlertSheet(row: row)
            }
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                if let code = summary.codeText {
                    Text(code)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let market = summary.marketText {
                    IOSTintedBadge(text: market, tone: .neutral)
                }
                if !summary.statusText.isEmpty {
                    Text(summary.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            Text(summary.effectiveAmountText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSDesign.accent)
                .padding(.top, 4)
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("核心指标")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(summary.metrics.enumerated()), id: \.offset) { _, metric in
                    metricTile(metric)
                }
            }
        }
    }

    private func metricTile(_ metric: PersonalAssetDetailMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.muted)
            Text(metric.value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(metricColor(metric.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = metric.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    // MARK: - 关注项(计划/待确认提醒)

    private var attentionSection: some View {
        Group {
            if !summary.attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("持仓提醒")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(Array(summary.attentionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(AppPalette.warning)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppPalette.ink)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppPalette.muted)
                                }
                            }
                            Spacer()
                            if !item.metric.isEmpty {
                                Text(item.metric)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppPalette.warning)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 待确认交易

    private var pendingTradesSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text("待确认交易").font(IOSDesign.serifHeading(16)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Button { showingAddTrade = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(IOSDesign.accent)
                }
            }
            if row.pendingTrades.isEmpty {
                Text("暂无待确认交易").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                ForEach(row.pendingTrades) { trade in
                    tradeRow(trade)
                }
            }
        }
    }

    private func tradeRow(_ trade: PersonalPendingTrade) -> some View {
        Button { editingTrade = trade } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trade.displayTitle).font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Text("\(String(trade.occurredAt.prefix(10))) · \(trade.status)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                Text(trade.amountText).font(IOSDesign.monoNumber(13)).foregroundStyle(IOSDesign.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deletePendingTrade(trade.id) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 投资计划

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text("投资计划").font(IOSDesign.serifHeading(16)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Button { showingAddPlan = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(IOSDesign.accent)
                }
            }
            if row.plans.isEmpty {
                Text("暂无投资计划").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                ForEach(row.plans) { plan in
                    planRow(plan)
                }
            }
        }
    }

    private func planRow(_ plan: PersonalInvestmentPlan) -> some View {
        Button { editingPlan = plan } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(plan.planTypeLabel) · \(plan.scheduleText)").font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Text("\(plan.status) · 每期 \(plan.amountText)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                if let next = plan.nextExecutionDate.isEmpty ? nil : String(plan.nextExecutionDate.prefix(10)) {
                    Text("下次 \(next)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteInvestmentPlan(plan.id) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 估值告警入口

    private var valuationAlertEntry: some View {
        Button { showingValuationAlert = true } label: {
            HStack {
                Image(systemName: "bell.badge").foregroundStyle(IOSDesign.accent)
                Text("估值告警规则").font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink)
                Spacer()
                let count = (row.fundCode.flatMap { model.portfolioValuationAlertProfile(for: $0).rules.count }) ?? 0
                Text(count > 0 ? "\(count) 条" : "未设置").font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(IOSDesign.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助

    private func metricColor(_ tone: PersonalAssetDetailTone) -> Color {
        switch tone {
        case .neutral: return AppPalette.ink
        case .marketGain: return AppPalette.marketGain
        case .marketLoss: return AppPalette.marketLoss
        case .warning: return AppPalette.warning
        case .info: return AppPalette.info
        case .brand: return AppPalette.brand
        case .muted: return AppPalette.muted
        }
    }
}
#endif
