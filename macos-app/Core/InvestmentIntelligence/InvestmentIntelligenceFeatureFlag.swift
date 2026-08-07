import Foundation

// 投资智能系统(Investment Intelligence)Feature Flag。
//
// 投资智能已成为 AI 研判的正式主路径。保留统一 gate，便于未来灰度或应急回退，
// 但默认必须开启，否则用户实际看不到已经完成的决策闭环。
//
// 详见 docs/ai-pipeline-baseline.md 第 9 节「投资智能改造的复用边界」。
enum InvestmentIntelligence {
    static let releaseDefaultEnabled = true

    /// 当前是否启用。DEBUG 模式下可通过启动参数开启。
    static var enabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-enable-investment-intelligence") {
            return true
        }
        #endif
        return releaseDefaultEnabled
    }
}
