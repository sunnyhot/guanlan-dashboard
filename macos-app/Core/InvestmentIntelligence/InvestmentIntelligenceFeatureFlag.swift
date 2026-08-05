import Foundation

// 投资智能系统(Investment Intelligence)Feature Flag。
//
// Slice 0 只定义,Slice 1 起被新代码 gate。默认 false:所有新逻辑不生效,
// 旧趋势研究 / 下一小时研判 / 跟踪清单的行为完全不变。
//
// 设计原则:
// - 新增的投资智能代码路径统一用 `if InvestmentIntelligence.enabled { ... }` gate。
// - 旧代码路径不读此 flag,保证改造期旧系统行为零变化。
// - Slice 1 有真功能后,此值改为可配置(接入设置 UI + 持久化),届时同步补测试。
//
// 详见 docs/ai-pipeline-baseline.md 第 9 节「投资智能改造的复用边界」。
enum InvestmentIntelligence {
    /// 当前是否启用投资智能系统。临时开启用于预览(Slice 0-7 已完成)。
    static let enabled: Bool = true
}
