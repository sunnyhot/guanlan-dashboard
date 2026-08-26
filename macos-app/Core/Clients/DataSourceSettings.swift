import Foundation
import CryptoKit

// 数据源与 AI Provider 的配置值类型（Clients / V2 Research 共用）。
//
// 原生于 Core/Trend/TrendAnalysisModels.swift（旧趋势链路），旧链路下线
// （WF-4）时随消费方 Core/Clients 迁入此处归位。磁盘迁移语义保留
// （decodeIfPresent + 默认值），Keychain 拆分逻辑由调用方管理。

struct TrendAIProviderSettings: Codable, Hashable {
    var providerName: String
    var baseURL: String
    var model: String
    var apiKey: String
    var timeoutSeconds: Double

    static let defaultGenerationTimeoutSeconds: Double = 300

    static let empty = TrendAIProviderSettings(
        providerName: "",
        baseURL: "",
        model: "",
        apiKey: "",
        timeoutSeconds: defaultGenerationTimeoutSeconds
    )

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 基于 baseURL+model+apiKey 的稳定指纹（SHA256 截断），用于判断能力检测结果是否仍对当前配置有效。
    /// 不含 apiKey 明文，跨进程稳定。
    var fingerprint: String {
        let raw = "\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))|\(model.trimmingCharacters(in: .whitespacesAndNewlines))|\(apiKey)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    var redactedAPIKey: String {
        Self.mask(apiKey)
    }

    var upgradedForTrendGeneration: TrendAIProviderSettings {
        guard isConfigured, timeoutSeconds < Self.defaultGenerationTimeoutSeconds else { return self }
        var upgraded = self
        upgraded.timeoutSeconds = Self.defaultGenerationTimeoutSeconds
        return upgraded
    }

    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "" : "...." }
        return "\(trimmed.prefix(3))...\(trimmed.suffix(4))"
    }

    init(
        providerName: String,
        baseURL: String,
        model: String,
        apiKey: String,
        timeoutSeconds: Double
    ) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? Self.defaultGenerationTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case providerName
        case baseURL
        case model
        case apiKey
        case timeoutSeconds
    }
}

struct TavilySearchSettings: Codable, Hashable, Sendable {
    var apiKey: String

    static let empty = TavilySearchSettings(apiKey: "")

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var redactedAPIKey: String {
        TrendAIProviderSettings.mask(apiKey)
    }

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey
    }
}

struct OfficialSourceSettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var secContactEmail: String

    static let empty = OfficialSourceSettings(
        enabled: true,
        secContactEmail: ""
    )

    var isSECConfigured: Bool {
        let email = secContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return enabled
            && email.contains("@")
            && email.contains(".")
            && !email.contains(" ")
    }

    var secUserAgent: String {
        let contact = secContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return "QiemanDashboard/4.0 \(contact)"
    }

    init(enabled: Bool = true, secContactEmail: String) {
        self.enabled = enabled
        self.secContactEmail = secContactEmail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        secContactEmail = try container.decodeIfPresent(
            String.self,
            forKey: .secContactEmail
        ) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case secContactEmail
    }
}

struct AlphaVantageSettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var apiKey: String
    var dailyRequestLimit: Int

    static let freeDailyRequestLimit = 25
    static let empty = AlphaVantageSettings(
        enabled: false,
        apiKey: "",
        dailyRequestLimit: freeDailyRequestLimit
    )

    var isConfigured: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedDailyRequestLimit: Int {
        min(10_000, max(1, dailyRequestLimit))
    }

    var redactedAPIKey: String {
        TrendAIProviderSettings.mask(apiKey)
    }

    init(
        enabled: Bool = false,
        apiKey: String,
        dailyRequestLimit: Int = freeDailyRequestLimit
    ) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.dailyRequestLimit = min(10_000, max(1, dailyRequestLimit))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        dailyRequestLimit = min(
            10_000,
            max(
                1,
                try container.decodeIfPresent(Int.self, forKey: .dailyRequestLimit)
                    ?? Self.freeDailyRequestLimit
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case apiKey
        case dailyRequestLimit
    }
}
