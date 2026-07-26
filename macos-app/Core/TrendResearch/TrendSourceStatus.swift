import Foundation

enum TrendDataSource: String, Codable, Hashable, Sendable, CaseIterable {
    case marketIndex
    case portfolioQuote
    case fundNAV
    case fundDisclosure
    case qiemanAdjustment
    case alfaAdjustment
    case managerWatch
    case webSearch
}

enum TrendDataSourceState: String, Codable, Hashable, Sendable {
    case notIntegrated
    case notConfigured
    case notRequested
    case fetching
    case successEmpty
    case success
    case failed

    var hasUsableData: Bool {
        self == .success
    }

    var isMissingOrFailed: Bool {
        switch self {
        case .notIntegrated, .notConfigured, .notRequested, .failed:
            return true
        case .fetching, .successEmpty, .success:
            return false
        }
    }
}

struct TrendSourceStatus: Codable, Hashable, Sendable, Identifiable {
    let source: TrendDataSource
    let status: TrendDataSourceState
    let asOf: String?
    let receivedAt: String
    let errorCode: String?
    let itemCount: Int?
    let detail: String?

    var id: String { source.rawValue }

    init(
        source: TrendDataSource,
        status: TrendDataSourceState,
        asOf: String? = nil,
        receivedAt: String,
        errorCode: String? = nil,
        itemCount: Int? = nil,
        detail: String? = nil
    ) {
        self.source = source
        self.status = status
        self.asOf = Self.nonEmpty(asOf)
        self.receivedAt = receivedAt
        self.errorCode = Self.nonEmpty(errorCode)
        self.itemCount = itemCount
        self.detail = Self.nonEmpty(detail)
    }

    var warningText: String? {
        switch status {
        case .success:
            return nil
        case .successEmpty:
            return "\(source.rawValue) 已成功查询，本次没有返回数据；不得扩大解释为其它来源也没有风险信号。"
        case .notIntegrated:
            return "\(source.rawValue) 尚未接入本次分析，不得把无数据解读为无风险。"
        case .notConfigured:
            return "\(source.rawValue) 未配置，不得把无数据解读为无风险。"
        case .notRequested:
            return "\(source.rawValue) 本次未请求，不得把无数据解读为无风险。"
        case .fetching:
            return "\(source.rawValue) 仍在获取中，本次报告不得据此形成方向结论。"
        case .failed:
            return "\(source.rawValue) 获取失败，不得把无数据解读为无风险。"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
