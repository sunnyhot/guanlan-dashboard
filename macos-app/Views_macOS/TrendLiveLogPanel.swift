#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// AI 分析工作台内的实时日志。
///
/// 仅随增强中心页面渲染；Agent 运行时自动展开，新事件到达后滚动到最底部。
/// 运行结束后保留本次记录，便于复制或定位日志文件。
struct TrendLiveLogPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var isExpanded = true
    @State private var isDismissed = false

    private let bottomAnchor = "trend-live-log-bottom"

    var body: some View {
        Group {
            if shouldShow {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if isExpanded {
                        Divider()
                            .overlay(AppPalette.hairline.opacity(AppPalette.borderFaint))
                        logList
                    }
                }
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                        .stroke(stateTint.opacity(0.32), lineWidth: 1)
                )
                .shadow(color: stateTint.opacity(0.08), radius: 12, x: 0, y: 5)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: model.trendGenerationState) { _, state in
            if state == .generating {
                isDismissed = false
                isExpanded = true
            } else {
                // 运行结束自动收起为单行状态条;想回看再点展开。
                withAnimation(AppPalette.motionStandard) {
                    isExpanded = false
                }
            }
        }
    }

    private var shouldShow: Bool {
        !isDismissed
            && (model.trendGenerationState == .generating || !model.trendProgressLogs.isEmpty)
    }

    private var latestLog: TrendProgressLog? {
        model.trendProgressLogs.last
    }

    private var failureExplanation: TrendErrorTriage.Explanation? {
        guard model.trendGenerationState == .failed,
              !model.lastTrendError.isEmpty else { return nil }
        return TrendErrorTriage.explain(model.lastTrendError)
    }

    private var header: some View {
        HStack(spacing: AppPalette.spaceS) {
            ZStack {
                RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                    .fill(stateTint.opacity(AppPalette.accentFill))
                    .frame(width: 30, height: 30)
                if model.trendGenerationState == .generating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(stateTint)
                        .accessibilityLabel("正在扫描市场")
                } else {
                    Image(systemName: stateIcon)
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(stateTint)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(
                        model.trendGenerationState == .generating
                            ? "\(model.trendResearchScope.displayName)进度"
                            : "上次\(model.trendResearchScope.displayName)运行"
                    )
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    TintedCapsuleBadge(
                        text: stateText,
                        tint: stateTint,
                        font: AppPalette.appFont(.caption, weight: .bold),
                        horizontalPadding: 7,
                        verticalPadding: 2,
                        softStrokeOpacity: nil
                    )
                    if let failureExplanation {
                        Text(failureExplanation.actionText ?? "")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }
                }
                if let failureExplanation {
                    Text(failureExplanation.reasonText)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.danger)
                        .lineLimit(2)
                } else {
                    Text(latestLog?.message ?? "正在准备分析")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                if model.trendGenerationState == .generating {
                    HStack(spacing: 7) {
                        ProgressView(value: model.trendResearchProgress.fraction)
                            .progressViewStyle(.linear)
                            .tint(stateTint)
                            .frame(width: 132)
                        Text(model.trendResearchProgress.detailText)
                            .font(AppPalette.appFont(.caption, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: AppPalette.spaceS)

            Text("\(model.trendProgressLogs.count) 条")
                .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.muted)

            if model.trendGenerationState == .generating {
                Button {
                    model.cancelTrendAnalysis()
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
            }

            if let failureExplanation, failureExplanation.shouldOpenSettings {
                Button {
                    model.selectedSection = .settings
                } label: {
                    Label("去设置", systemImage: "gearshape")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
            }

            iconButton("复制本次日志", systemImage: "doc.on.doc") {
                copyLogs()
            }

            if model.aiAnalysisDiagnosticLogsDirectoryURL != nil {
                iconButton("打开完整诊断日志目录", systemImage: "folder") {
                    model.openAIAnalysisDiagnosticLogsDirectory()
                }
            }

            iconButton(isExpanded ? "收起实时日志" : "展开实时日志", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                withAnimation(AppPalette.motionStandard) {
                    isExpanded.toggle()
                }
            }

            if model.trendGenerationState != .generating {
                iconButton("关闭本次日志", systemImage: "xmark") {
                    withAnimation(AppPalette.motionStandard) {
                        isDismissed = true
                    }
                }
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.trendProgressLogs.enumerated()), id: \.element.id) { index, entry in
                        logRow(entry, isLast: index == model.trendProgressLogs.count - 1)
                            .id(entry.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, AppPalette.spaceM)
                .padding(.vertical, AppPalette.spaceS)
            }
            .frame(height: 190)
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: latestLog?.id) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func logRow(_ entry: TrendProgressLog, isLast: Bool) -> some View {
        let levelTint = tint(for: entry.level)
        let isError = entry.level == .error
        return HStack(alignment: .top, spacing: 10) {
            // 左侧时间线轨道：节点 + 连接器。连接器铺满整行高度，最后一条不画，避免悬空。
            VStack(spacing: 0) {
                nodeIcon(message: entry.message, tint: levelTint)
                if !isLast {
                    Rectangle()
                        .fill(AppPalette.hairline.opacity(0.5))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 2)
                }
            }
            .frame(width: 22)

            // 右侧内容
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(logTime(entry.timestamp))
                        .font(AppPalette.appFont(.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                    Text(entry.message)
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(isError ? AppPalette.danger : AppPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                if let detail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                            .fill(levelTint.opacity(0.65))
                            .frame(width: 2.5)
                            .padding(.vertical, 2)
                        Text(detail)
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(isError ? AppPalette.danger : AppPalette.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(levelTint.opacity(0.06), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                            .stroke(levelTint.opacity(0.14), lineWidth: 1)
                    )
                }
            }
            .padding(.bottom, isLast ? 4 : AppPalette.spaceS)

            Spacer(minLength: 0)
        }
    }

    private func nodeIcon(message: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(AppPalette.accentFill))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(tint.opacity(0.35), lineWidth: 1)
                .frame(width: 20, height: 20)
            Image(systemName: semanticIcon(for: message))
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    private func iconButton(
        _ helpText: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 25, height: 25)
                .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private func copyLogs() {
        // 显式 String：GRDB 的 SQL(ExpressibleByStringInterpolation) 扩展会
        // 把无标注的字面量闭包推断成 SQL（joined(separator:) 亦有 SQL 版扩展）
        let text: String = model.trendProgressLogs.map { entry in
            let detail = entry.detail.map { "\n\($0)" } ?? ""
            return "[\(entry.timestamp)] [\(entry.level.rawValue)] \(entry.message)\(detail)"
        }
        .joined(separator: "\n")
        PasteboardHelper.copy(text)
    }

    private func logTime(_ timestamp: String) -> String {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return trimmed }
        return String(trimmed.dropFirst(11).prefix(8))
    }

    private var stateText: String {
        switch model.trendGenerationState {
        case .idle:
            return "待机"
        case .generating:
            return "实时运行中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .rejected:
            return "已拦截"
        }
    }

    private var stateIcon: String {
        switch model.trendGenerationState {
        case .idle:
            return "clock"
        case .generating:
            return "clock.arrow.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .rejected:
            return "hand.raised.fill"
        }
    }

    private var stateTint: Color {
        switch model.trendGenerationState {
        case .idle:
            return AppPalette.muted
        case .generating:
            return AppPalette.info
        case .succeeded:
            return AppPalette.positive
        case .failed:
            return AppPalette.danger
        case .rejected:
            return AppPalette.warning
        }
    }

    /// 按消息语义分类选取小图标（颜色仍由 level 决定）。
    private func semanticIcon(for message: String) -> String {
        if message.contains("已取消") { return "stop.fill" }
        if message.contains("校验失败") || message.contains("需要修正") { return "arrow.counterclockwise.circle.fill" }
        if message.contains("失败") || message.contains("不支持") { return "exclamationmark.triangle.fill" }
        if message.contains("收敛") || message.contains("Harness 预算") { return "scope" }
        if message.contains("首个流式分片") { return "bolt.fill" }
        if message.contains("仍在流式") { return "waveform" }
        if message.contains("流式输出已结束") { return "checkmark.circle" }
        if message.contains("正在等待") { return "clock.fill" }
        if message.contains("已收到模型响应") { return "arrow.down.circle.fill" }
        if message.contains("进入第") { return "arrow.triangle.2.circlepath" }
        if message.hasPrefix("完成：") { return "checkmark.circle.fill" }
        if message.hasPrefix("开始：") { return "wrench.and.screwdriver" }
        if message.contains("能力可用") { return "checkmark.shield.fill" }
        if message.contains("检测") { return "antenna.radiowaves.left.and.right" }
        if message.contains("快照") { return "doc.text.magnifyingglass" }
        if message.contains("准备请求") { return "paperplane.fill" }
        if message.contains("保存趋势报告") { return "tray.and.arrow.down.fill" }
        if message.contains("已生成有效报告") || message == "趋势分析完成" { return "checkmark.seal.fill" }
        if message.contains("已启动") || message.contains("开始内嵌") { return "wand.and.stars" }
        return "circle.fill"
    }

    private func tint(for level: TrendProgressLog.Level) -> Color {
        switch level {
        case .info:
            return AppPalette.muted
        case .activity:
            return AppPalette.info
        case .success:
            return AppPalette.positive
        case .warning:
            return AppPalette.warning
        case .error:
            return AppPalette.danger
        }
    }
}
