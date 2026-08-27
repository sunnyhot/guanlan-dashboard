import SwiftUI

// MARK: - 决策事项卡（审计 A2：跟踪与复核闭环的 UI 面）
//
// 数据只读 AppModel.decisionCases（用户意图文件 Store 的发布镜像）；
// 动作（关注/解决/关闭/重开/复盘）全部经 AppModel 管道落 Store。
// 状态徽章配色：watch→info / prepare→warning / adjustReview→danger。

struct DecisionCaseCard: View {
    @ObservedObject var model: AppModel
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?

    private var openCases: [DecisionCase] {
        model.openDecisionCases
    }

    var body: some View {
        SectionCard(
            title: "关注与复核",
            subtitle: "风险跟踪 · 行动验证 · 复盘闭环",
            icon: "checklist",
            trailing: {
                HStack(spacing: AppPalette.spaceS) {
                    if model.isRefreshingDecisionCases {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("查看全部") { activeSheet = .decisionCases }
                        .buttonStyle(.appText)
                        .controlSize(.small)
                }
            }
        ) {
            if openCases.isEmpty {
                Text("暂无待关注事项——持仓刷新后自动评估集中度、回撤与目标偏离。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    ForEach(openCases.prefix(5)) { decisionCase in
                        DecisionCaseRow(decisionCase: decisionCase) {
                            model.selectedDecisionCaseID = decisionCase.id
                        }
                    }
                    if openCases.count > 5 {
                        Text("还有 \(openCases.count - 5) 项——「查看全部」见完整列表")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
    }
}

// MARK: - 单行

struct DecisionCaseRow: View {
    let decisionCase: DecisionCase
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(decisionCase.title)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text("\(decisionCase.kind.displayName) · \(decisionCase.metricDescription)\(decisionCase.metricLabel.isEmpty ? "" : " \(decisionCase.metricLabel)")")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if decisionCase.lifecycle == .reviewDue {
                    Text("待复盘")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppPalette.warning.opacity(0.1), in: Capsule())
                }
                stateBadge(decisionCase.decisionState)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(decisionCase.title)，\(decisionCase.decisionState.displayName)")
        }
    }

    private var iconName: String {
        switch decisionCase.kind {
        case .concentrationRisk: return "scope"
        case .drawdownExpansion: return "arrow.down.right.circle"
        case .targetDeviation: return "target"
        case .actionMigration: return "arrow.triangle.swap"
        }
    }

    private var iconColor: Color {
        switch decisionCase.decisionState {
        case .stable: return AppPalette.muted
        case .watch: return AppPalette.info
        case .prepare: return AppPalette.warning
        case .adjustReview: return AppPalette.danger
        case .insufficientEvidence: return AppPalette.muted
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: PortfolioDecisionState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .stable: return ("稳定", AppPalette.muted)
            case .watch: return ("观察", AppPalette.info)
            case .prepare: return ("准备", AppPalette.warning)
            case .adjustReview: return ("复核", AppPalette.danger)
            case .insufficientEvidence: return ("证据不足", AppPalette.muted)
            }
        }()
        Text(text)
            .font(AppPalette.appFont(.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }
}

// MARK: - 全量列表 Sheet

struct DecisionCaseListSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var openCases: [DecisionCase] {
        model.decisionCases.filter { $0.lifecycle != .closed }
    }

    private var closedCases: [DecisionCase] {
        model.decisionCases.filter { $0.lifecycle == .closed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack {
                Text("决策事项")
                    .font(AppPalette.appFont(.title3, weight: .bold))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    if openCases.isEmpty && closedCases.isEmpty {
                        Text("暂无决策事项。")
                            .foregroundStyle(AppPalette.muted)
                    }
                    if !openCases.isEmpty {
                        sectionTitle("跟踪中（\(openCases.count)）")
                        ForEach(openCases) { decisionCase in
                            DecisionCaseRow(decisionCase: decisionCase) {
                                model.selectedDecisionCaseID = decisionCase.id
                            }
                        }
                    }
                    if !closedCases.isEmpty {
                        sectionTitle("已结束（\(closedCases.count)）")
                        ForEach(closedCases) { decisionCase in
                            DecisionCaseRow(decisionCase: decisionCase) {
                                model.selectedDecisionCaseID = decisionCase.id
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 620, height: 520)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
    }
}

// MARK: - 详情 Sheet（事件历史 + 动作 + 复盘入口）

struct DecisionCaseDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let decisionCase: DecisionCase

    @State private var isReviewSheetPresented = false
    @State private var confirmNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(decisionCase.title)
                        .font(AppPalette.appFont(.title3, weight: .bold))
                    Text("\(decisionCase.kind.displayName) · \(decisionCase.lifecycle.displayName) · \(decisionCase.userDisposition.displayName)")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    LabeledValue(
                        title: decisionCase.metricDescription,
                        value: decisionCase.metricLabel.isEmpty ? "—" : decisionCase.metricLabel)
                    LabeledValue(
                        title: "最近评估",
                        value: IntelligencePresentationFormatter.dateTimeText(decisionCase.lastEvaluatedAt))
                    if let reviewDueAt = decisionCase.reviewDueAt,
                       decisionCase.lifecycle == .monitoring || decisionCase.lifecycle == .reviewDue {
                        LabeledValue(
                            title: "复查时间",
                            value: IntelligencePresentationFormatter.dateTimeText(reviewDueAt))
                    }

                    if !decisionCase.detail.isEmpty {
                        Text(decisionCase.detail)
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let trigger = decisionCase.triggerCondition {
                        conditionRow(title: "触发条件", text: trigger, color: AppPalette.warning)
                    }
                    if let invalidation = decisionCase.invalidationCondition {
                        conditionRow(title: "失效条件", text: invalidation, color: AppPalette.positive)
                    }

                    if !decisionCase.reviews.isEmpty {
                        Text("复盘记录（\(decisionCase.reviews.count)）")
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                            .foregroundStyle(AppPalette.muted)
                        ForEach(decisionCase.reviews) { review in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(IntelligencePresentationFormatter.dateTimeText(review.reviewedAt)) · \(review.conclusion.displayName)")
                                    .font(AppPalette.appFont(.footnote, weight: .medium))
                                if !review.lessons.isEmpty {
                                    Text(review.lessons)
                                        .font(AppPalette.appFont(.footnote))
                                        .foregroundStyle(AppPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(AppPalette.spaceS)
                            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                        }
                    }

                    DisclosureGroup("事件历史（\(decisionCase.events.count)）") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(
                                Array(decisionCase.events.reversed().enumerated()),
                                id: \.element.id
                            ) { _, event in
                                Text("· \(IntelligencePresentationFormatter.dateTimeText(event.at)) [\(event.type.rawValue)] \(event.reason)")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .font(AppPalette.appFont(.footnote))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionBar
        }
        .padding(AppPalette.spaceL)
        .frame(width: 620, height: 640)
        .sheet(isPresented: $isReviewSheetPresented) {
            DecisionReviewSheet(decisionCase: decisionCase)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: AppPalette.spaceS) {
            switch decisionCase.lifecycle {
            case .closed:
                if decisionCase.userDisposition != .closed {
                    Button("重新打开") { model.reopenDecisionCase(id: decisionCase.id) }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                }
            default:
                if decisionCase.userDisposition == .pending {
                    Button("加入跟踪") { model.acknowledgeDecisionCase(id: decisionCase.id) }
                        .buttonStyle(.appPrimary)
                        .controlSize(.small)
                }
                Button("记录复盘") { isReviewSheetPresented = true }
                    .buttonStyle(.appPrimary)
                    .controlSize(.small)
                Button("标记已解决") { model.resolveDecisionCase(id: decisionCase.id, note: nil) }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                Button("不再关注") { model.closeDecisionCase(id: decisionCase.id) }
                    .buttonStyle(.appText)
                    .controlSize(.small)
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer()
            Text(decisionCase.id)
                .font(AppPalette.appFont(.caption, design: .monospaced))
                .foregroundStyle(AppPalette.muted)
                .textSelection(.enabled)
        }
    }

    private func conditionRow(title: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1), in: Capsule())
            Text(text)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 复盘 Sheet（六选一 + 经验笔记）

struct DecisionReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let decisionCase: DecisionCase

    @State private var conclusion: DecisionReviewConclusion = .supported
    @State private var lessons = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack {
                Text("记录复盘")
                    .font(AppPalette.appFont(.title3, weight: .bold))
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            Text("复盘「\(decisionCase.title)」——根据触发/失效条件与后续事实选择结论。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("结论", selection: $conclusion) {
                ForEach(DecisionReviewConclusion.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 4) {
                Text("可复用经验（可选）")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                TextEditor(text: $lessons)
                    .font(AppPalette.appFont(.footnote))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            }

            HStack {
                Spacer()
                Button("提交复盘") {
                    model.recordDecisionReview(
                        caseID: decisionCase.id,
                        conclusion: conclusion,
                        lessons: lessons)
                    dismiss()
                }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 480, height: 420)
    }
}
