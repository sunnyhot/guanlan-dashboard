import Combine
import Foundation

// MARK: - 研判实时输出展示模型
//
// 刻意独立于 AppModel：只有「模型实时输出」区块观察本对象——刷新时
// 不带动 AppModel 上其他视图重渲染。此前挂在 AppModel 上时，每次流式
// 刷新都让整窗视图树重新求值（图表/列表全跑一遍），是界面卡顿主因之一。

@MainActor
final class TrendLiveOutputModel: ObservableObject {
    @Published private(set) var output: TrendLiveModelOutput?

    /// 视图展示截断长度：等宽长文本全文重排开销大，展示只留尾部。
    static let displayLimit = 2000
    /// 缓冲截断长度（状态层保真上限）。
    static let bufferLimit = 8000

    private let flushInterval: TimeInterval
    private var buffer: TrendLiveModelOutput?
    private var lastFlushAt = Date.distantPast
    /// 每次刷盘后回调（AppModel 用来把输出镜像进运行日志条目）。
    var onFlush: (@MainActor (TrendLiveModelOutput) -> Void)?

    init(flushInterval: TimeInterval = 0.25) {
        self.flushInterval = flushInterval
    }

    func reset() {
        buffer = nil
        output = nil
        lastFlushAt = Date.distantPast
    }

    /// 增量进缓冲（微秒级）；距上次刷新 ≥ flushInterval 才发布一次。
    func update(turn: Int, kind: AgentStreamDeltaKind, delta: String) {
        if buffer == nil || buffer?.turn != turn {
            buffer = TrendLiveModelOutput(turn: turn, text: "")
        }
        guard var updated = buffer else { return }
        updated.text += Self.separator(for: kind, previous: updated.lastKind, currentText: updated.text) + delta
        updated.lastKind = kind
        buffer = updated

        let now = Date()
        if now.timeIntervalSince(lastFlushAt) >= flushInterval {
            flush(now: now)
        }
    }

    /// 缓冲刷到发布状态（截断保尾部）。流结束/换事件时兜底调用，
    /// 保证最后一批增量不因节流丢失。
    func flush(now: Date = Date()) {
        guard var updated = buffer else { return }
        if updated.text.count > Self.bufferLimit {
            updated.text = String(updated.text.suffix(Self.bufferLimit))
        }
        output = updated
        lastFlushAt = now
        onFlush?(updated)
    }

    /// 视图用的展示文本（尾部截断；空输出返回 nil 不显示区块）。
    var displayText: String? {
        guard let output, !output.text.isEmpty else { return nil }
        if output.text.count > Self.displayLimit {
            return "…" + String(output.text.suffix(Self.displayLimit))
        }
        return output.text
    }

    /// 两行子条目预览：只取最近的 1–2 个非空行（流式最新内容在末尾，
    /// 从行尾取才能跟随「正在生成」的部分），每行限长、总计限两行。
    var displayTailLines: String? {
        guard let output, !output.text.isEmpty else { return nil }
        let lines = output.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(2)
            .map { line in
                line.count > 160 ? "…" + String(line.suffix(159)) : String(line)
            }
        return lines.joined(separator: "\n")
    }

    /// 种类切换时插入分隔/标记行——思考、正文、工具调用三类增量交替到达。
    private static func separator(
        for kind: AgentStreamDeltaKind,
        previous: AgentStreamDeltaKind?,
        currentText: String
    ) -> String {
        if previous == kind { return "" }
        switch kind {
        case .reasoning:
            return currentText.isEmpty ? "〔思考〕" : "\n〔思考〕"
        case .content:
            return currentText.isEmpty ? "" : "\n"
        case .toolCall:
            // 工具转写自带「\n[调用工具 …」前缀，不再额外加标记。
            return ""
        }
    }
}
