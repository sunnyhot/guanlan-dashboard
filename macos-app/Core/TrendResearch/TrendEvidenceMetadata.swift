import Foundation

enum TrendEvidenceSourceKind: String, Codable, Hashable, Sendable {
    case portfolioSnapshot
    case marketQuote
    case fundDisclosure
    case platformSignal
    case managerSignal
    case officialFiling
    case officialFinancial
    case licensedMarketData
    case webSearch
    case derived
    case unknown

    var isOfficialPrimary: Bool {
        self == .officialFiling || self == .officialFinancial
    }

    var isExternalResearch: Bool {
        isOfficialPrimary || self == .licensedMarketData || self == .webSearch
    }
}

enum TrendEvidenceSourceTier: String, Codable, Hashable, Sendable {
    case primary
    case authoritative
    case secondary
    case community
    case unknown
}

enum TrendEvidenceMetadataConfidence: String, Codable, Hashable, Sendable {
    case deterministic
    case ruleDerived
    case semanticDerived
    case unknown
}

enum TrendResearchTargetKind: String, Codable, Hashable, Sendable {
    case asset
    case index
    case sector
    case assetClass
    case macro
}

struct TrendResearchTarget: Codable, Hashable, Sendable {
    let kind: TrendResearchTargetKind
    let key: String
    let entityCodes: [String]
    let sectorKeys: [String]
    let assetClassKeys: [String]

    init(
        kind: TrendResearchTargetKind,
        key: String,
        entityCodes: [String] = [],
        sectorKeys: [String] = [],
        assetClassKeys: [String] = []
    ) {
        self.kind = kind
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entityCodes = Self.normalized(entityCodes)
        self.sectorKeys = Self.normalized(sectorKeys)
        self.assetClassKeys = Self.normalized(assetClassKeys)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(TrendResearchTargetKind.self, forKey: .kind),
            key: try container.decode(String.self, forKey: .key),
            entityCodes: try container.decodeIfPresent([String].self, forKey: .entityCodes) ?? [],
            sectorKeys: try container.decodeIfPresent([String].self, forKey: .sectorKeys) ?? [],
            assetClassKeys: try container.decodeIfPresent([String].self, forKey: .assetClassKeys) ?? []
        )
    }

    var topicKeys: [String] {
        Self.normalized(
            [kind.rawValue, key] + entityCodes + sectorKeys + assetClassKeys
        )
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.lowercased()
            return seen.insert(normalized).inserted ? trimmed : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case key
        case entityCodes
        case sectorKeys
        case assetClassKeys
    }
}

struct TrendEvidenceMetadata: Codable, Hashable, Sendable {
    let sourceKind: TrendEvidenceSourceKind
    let sourceTier: TrendEvidenceSourceTier
    let publisherKey: String?
    let requestedTopicKeys: [String]
    let entityCodes: [String]
    let entityNames: [String]
    let sectorKeys: [String]
    let assetClassKeys: [String]
    let quoteType: TrendQuoteType?
    let freshnessStatus: TrendFreshnessStatus?
    let metadataConfidence: TrendEvidenceMetadataConfidence

    static let unknown = TrendEvidenceMetadata(
        sourceKind: .unknown,
        sourceTier: .unknown,
        metadataConfidence: .unknown
    )

    init(
        sourceKind: TrendEvidenceSourceKind,
        sourceTier: TrendEvidenceSourceTier = .unknown,
        publisherKey: String? = nil,
        requestedTopicKeys: [String] = [],
        entityCodes: [String] = [],
        entityNames: [String] = [],
        sectorKeys: [String] = [],
        assetClassKeys: [String] = [],
        quoteType: TrendQuoteType? = nil,
        freshnessStatus: TrendFreshnessStatus? = nil,
        metadataConfidence: TrendEvidenceMetadataConfidence
    ) {
        self.sourceKind = sourceKind
        self.sourceTier = sourceTier
        self.publisherKey = publisherKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.requestedTopicKeys = Self.normalized(requestedTopicKeys)
        self.entityCodes = Self.normalized(entityCodes)
        self.entityNames = Self.normalized(entityNames)
        self.sectorKeys = Self.normalized(sectorKeys)
        self.assetClassKeys = Self.normalized(assetClassKeys)
        self.quoteType = quoteType
        self.freshnessStatus = freshnessStatus
        self.metadataConfidence = metadataConfidence
    }

    func isAssociated(
        entityCode: String? = nil,
        entityName: String? = nil,
        sectorKey: String? = nil
    ) -> Bool {
        let candidates = [
            entityCode,
            entityName,
            sectorKey,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return true }

        // requestedTopicKeys 只表示“搜索时想研究什么”，不能冒充结果正文
        // 实际支持了该主题。Claim 关联只接受工具从结构化字段或结果正文提取的标签。
        let searchable = (
            entityCodes
                + entityNames
                + sectorKeys
                + assetClassKeys
        ).map { $0.lowercased() }
        return candidates.contains { candidate in
            searchable.contains { value in
                value == candidate || value.contains(candidate) || candidate.contains(value)
            }
        }
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.lowercased()
            return seen.insert(normalized).inserted ? trimmed : nil
        }
    }
}

struct TrendSourceAuthorityRegistry: Sendable {
    struct Classification: Hashable, Sendable {
        let publisherKey: String
        let tier: TrendEvidenceSourceTier
    }

    private static let primaryDomains = [
        "gov.cn",
        "pbc.gov.cn",
        "csrc.gov.cn",
        "sse.com.cn",
        "szse.cn",
        "bse.cn",
        "cninfo.com.cn",
    ]

    private static let authoritativeDomains = [
        "news.cn",
        "xinhuanet.com",
        "people.com.cn",
        "cs.com.cn",
        "stcn.com",
        "yicai.com",
        "caixin.com",
        "cls.cn",
    ]

    private static let secondaryDomains = [
        "eastmoney.com",
        "finance.sina.com.cn",
        "10jqka.com.cn",
    ]

    private static let communityDomains = [
        "xueqiu.com",
        "guba.eastmoney.com",
    ]

    func classify(urlString: String?) -> Classification {
        guard let urlString,
              let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return Classification(publisherKey: "unknown", tier: .unknown)
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let matched = Self.primaryDomains.first(where: { Self.matches(normalizedHost, domain: $0) }) {
            return Classification(publisherKey: matched, tier: .primary)
        }
        if let matched = Self.authoritativeDomains.first(where: { Self.matches(normalizedHost, domain: $0) }) {
            return Classification(publisherKey: matched, tier: .authoritative)
        }
        if let matched = Self.communityDomains.first(where: { Self.matches(normalizedHost, domain: $0) }) {
            return Classification(publisherKey: matched, tier: .community)
        }
        if let matched = Self.secondaryDomains.first(where: { Self.matches(normalizedHost, domain: $0) }) {
            return Classification(publisherKey: matched, tier: .secondary)
        }
        return Classification(publisherKey: normalizedHost, tier: .unknown)
    }

    private static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
