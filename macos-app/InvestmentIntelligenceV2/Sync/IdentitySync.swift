import CryptoKit
import Foundation

// MARK: - IdentitySync（SYNC-8：非持仓标的的 identity 增量建立）
//
// ADR-DATA001 §Decision 3：4 条路径是「建立时」算法——登记一条
// ProviderIdentifier 时执行的重匹配，成功后记为 resolutionMethod 元数据；
// IdentityResolver（REPO-4）是查询层，只查表不重新匹配。
//
// 优先级（先高后低，命中即停）：
// 1. **providerAuthoritative**：Provider 声明的官方等价（hint 的
//    crossRefs 指向其他已登记 (provider, scheme, value)）→ 继承其 canonical；
// 2. **exchangeSymbolExact**：(exchange, symbol) 与已有 Listing 精确匹配；
// 3. **isinOrCik**：ISIN 匹配已有 Instrument / CIK 匹配已有 LegalEntity
//    的 regulatoryIDs；
// 4. **manualVerified**：人工审核登记（REPO-4b 初始数据 / fuzzy candidate
//    经 Verification 升级）。
//
// **创建模式**（「新标的能进 Instrument Master」）：路径 1-3 全 miss 但
// hint 携带权威证据时创建新 canonical 实体链——
// - exchange + symbol：创建 LegalEntity + Instrument + Listing，
//   以 exchangeSymbolExact 登记（交易所代码全局唯一，注册即权威）；
// - ISIN（无 exchange）：创建 LegalEntity + Instrument（含 isin），
//   以 isinOrCik 登记。**基金类不自动创建**：份额结构（A/C、Product 层
//   语义）不能从 hint 猜，走 manualVerified（REPO-4b 形态）。
// ID 从稳定输入确定性派生（SHA256 截断）：重复建立同一 hint 幂等
// （同 ID upsert，行数不翻倍）。
//
// **fuzzy 只产 candidate**：无权威证据但有 displayName 时按字符 bigram
// Dice 相似度对已有 Instruments 产候选，最佳候选登记为 fuzzyCandidate
// 行（lookup 拒绝，防火墙 1），完整候选清单在结果里等 Verification。
//
// **冲突不覆盖**：(provider, scheme, value) 已有权威映射时，新提案指向
// 不同 canonical → 报 conflict，保留既有（identity 单点，改映射污染下游）。

// MARK: - Hint 与结局

/// 一次 identity 建立的原始证据（来自持仓披露新标的 / sync 发现等）。
struct IdentityHint: Sendable, Hashable {
    let providerID: DataProviderID
    let code: ProviderCode
    /// ISIN（路径 3 / 创建模式）
    var isin: String?
    /// SEC CIK，10 位补零（路径 3，映射到 LegalEntity——SEC 事实的 canonical 目标）
    var cik: String?
    /// 交易所（路径 2 / 创建模式）
    var exchange: Exchange?
    /// 显示名（fuzzy 候选生成 / 创建模式命名）
    var displayName: String?
    /// 路径 1：Provider 声明的官方等价代码（已登记则继承 canonical）
    var authoritativeCrossRefs: [ProviderCode] = []
    /// 创建模式的补充字段（缺省按股票 + 交易所法域推断）
    var instrumentKind: InstrumentKind?
    var assetClass: AssetClass?
    var currency: Currency?
    var jurisdiction: Jurisdiction?

    init(
        providerID: DataProviderID,
        code: ProviderCode,
        isin: String? = nil,
        cik: String? = nil,
        exchange: Exchange? = nil,
        displayName: String? = nil,
        authoritativeCrossRefs: [ProviderCode] = [],
        instrumentKind: InstrumentKind? = nil,
        assetClass: AssetClass? = nil,
        currency: Currency? = nil,
        jurisdiction: Jurisdiction? = nil
    ) {
        self.providerID = providerID
        self.code = code
        self.isin = isin
        self.cik = cik
        self.exchange = exchange
        self.displayName = displayName
        self.authoritativeCrossRefs = authoritativeCrossRefs
        self.instrumentKind = instrumentKind
        self.assetClass = assetClass
        self.currency = currency
        self.jurisdiction = jurisdiction
    }
}

/// fuzzy 候选（等 Verification，未登记为权威映射）。
struct IdentityFuzzyCandidate: Sendable, Equatable {
    let canonical: CanonicalRef
    let matchedName: String
    let confidence: Double
    let rationale: String
}

/// 单条 hint 的建立结局。
enum IdentityEstablishmentOutcome: Sendable, Equatable {
    /// 已建立权威映射（含创建模式新建的实体链）
    case established(method: IdentityResolutionMethod, canonical: CanonicalRef, createdEntities: Bool)
    /// 该代码已有权威映射（幂等重跑 / 与本轮提案一致）
    case alreadyRegistered(method: IdentityResolutionMethod, canonical: CanonicalRef)
    /// 已有映射与新提案指向不同 canonical——保留既有，报告冲突
    case conflict(existing: CanonicalRef, attempted: CanonicalRef)
    /// 无权威证据，产出 fuzzy 候选（等 Verification）
    case fuzzyCandidates([IdentityFuzzyCandidate])
    /// 无法建立（无证据 / fuzzy 也无匹配）
    case unresolved
}

// MARK: - 引擎

/// Identity 增量建立引擎（4 路径 + 创建模式 + fuzzy 候选 + Verification）。
struct IdentitySync: Sendable {

    let repository: GRDBRepository
    let now: @Sendable () -> Date
    /// fuzzy 候选的最低相似度门槛
    var fuzzyThreshold: Double

    init(
        repository: GRDBRepository,
        now: @escaping @Sendable () -> Date = { .now },
        fuzzyThreshold: Double = 0.5
    ) {
        self.repository = repository
        self.now = now
        self.fuzzyThreshold = fuzzyThreshold
    }

    /// 对一批 hint 执行建立算法（逐条独立，单条失败不影响他者）。
    func establish(hints: [IdentityHint]) throws -> [String: IdentityEstablishmentOutcome] {
        var outcomes: [String: IdentityEstablishmentOutcome] = [:]
        for hint in hints {
            let key = "\(hint.providerID.rawValue)|\(hint.code.scheme)|\(hint.code.value)"
            outcomes[key] = try establishOne(hint)
        }
        return outcomes
    }

    // MARK: - 单条建立

    private func establishOne(_ hint: IdentityHint) throws -> IdentityEstablishmentOutcome {
        // 0. 已有权威映射：幂等（一致→alreadyRegistered；提案不同→conflict）
        if let existing = repository.resolve(
            providerID: hint.providerID, scheme: hint.code.scheme, value: hint.code.value
        ) {
            if let proposal = authoritativeMatch(hint) ?? creationMatch(hint), proposal.canonical != existing {
                return .conflict(existing: existing, attempted: proposal.canonical)
            }
            return .alreadyRegistered(method: existingAuthoritativeMethod(hint), canonical: existing)
        }

        // 路径 1-3（优先级序）
        if let match = authoritativeMatch(hint) {
            try register(hint, canonical: match.canonical, method: match.method)
            return .established(method: match.method, canonical: match.canonical, createdEntities: false)
        }

        // 创建模式（权威证据齐备才建实体）
        if let creation = creationMatch(hint) {
            try createEntities(for: hint, canonical: creation.canonical)
            try register(hint, canonical: creation.canonical, method: creation.method)
            return .established(method: creation.method, canonical: creation.canonical, createdEntities: true)
        }

        // fuzzy：只产 candidate（防火墙 1）
        let candidates = fuzzyMatches(hint)
        if let best = candidates.first {
            try register(hint, canonical: best.canonical, method: .fuzzyCandidate)
        }
        return candidates.isEmpty ? .unresolved : .fuzzyCandidates(candidates)
    }

    /// 已登记映射的 method（resolve 只回 canonical，method 从登记行查）。
    private func existingAuthoritativeMethod(_ hint: IdentityHint) -> IdentityResolutionMethod {
        let registered = repository.allProviderIdentifiers().first {
            $0.providerID == hint.providerID
                && $0.identifierScheme == hint.code.scheme
                && $0.identifierValue == hint.code.value
        }
        return registered?.resolutionMethod ?? .manualVerified
    }

    // MARK: - 路径 1-3

    private func authoritativeMatch(_ hint: IdentityHint)
        -> (canonical: CanonicalRef, method: IdentityResolutionMethod)?
    {
        // 路径 1：Provider authoritative（官方 cross-ref 继承）
        for ref in hint.authoritativeCrossRefs {
            if let canonical = repository.resolve(
                providerID: ref.scheme == hint.code.scheme ? hint.providerID : crossRefProvider(ref),
                scheme: ref.scheme, value: ref.value
            ) {
                return (canonical, .providerAuthoritative)
            }
        }
        // 路径 2：exchange + symbol 精确匹配已有 Listing
        if let exchange = hint.exchange,
           let listing = repository.allListings().first(where: {
               $0.exchange == exchange && $0.symbol == hint.code.value
           }) {
            return (.listing(listing.id), .exchangeSymbolExact)
        }
        // 路径 3a：ISIN 匹配已有 Instrument
        if let isin = hint.isin?.uppercased(),
           let instrument = repository.allInstruments().first(where: { $0.isin?.uppercased() == isin }) {
            // Instrument 唯一挂牌时映射到 Listing（行情语义），否则 Instrument 层
            let listings = repository.listings(forInstrument: instrument.id)
            if listings.count == 1, let only = listings.first {
                return (.listing(only.id), .isinOrCik)
            }
            return (.instrument(instrument.id), .isinOrCik)
        }
        // 路径 3b：CIK 匹配已有 LegalEntity（SEC 事实的 canonical 目标）
        if let cik = normalizedCIK(hint.cik),
           let entity = repository.allLegalEntities().first(where: { entity in
               entity.regulatoryIDs.contains { $0.scheme == "CIK" && $0.value == cik }
           }) {
            return (.legalEntity(entity.id), .isinOrCik)
        }
        return nil
    }

    /// CIK 归一化：10 位补零。
    private func normalizedCIK(_ raw: String?) -> String? {
        guard let raw, let digits = Int(raw.filter(\.isNumber)) else { return nil }
        return String(format: "%010d", digits)
    }

    /// cross-ref 的 Provider 推断：scheme 与本体同 Provider（如另一 fund_code），
    /// 否则按 scheme 的全局命名空间（SEC cik → sec）。
    private func crossRefProvider(_ ref: ProviderCode) -> DataProviderID {
        switch ref.scheme {
        case "sec_cik": return .sec
        default: return .eastmoney
        }
    }

    // MARK: - 创建模式

    /// 权威证据齐备时的新实体提案（不执行写入）。
    private func creationMatch(_ hint: IdentityHint)
        -> (canonical: CanonicalRef, method: IdentityResolutionMethod)?
    {
        // 基金类不自动创建（份额/Product 语义不能猜，走 manualVerified）
        if hint.instrumentKind == .fund || hint.instrumentKind == .moneyMarketFund {
            return nil
        }
        if let exchange = hint.exchange {
            let listingID = ListingID(Self.deriveID("lst", "\(exchange.rawValue)|\(hint.code.value)"))
            return (.listing(listingID), .exchangeSymbolExact)
        }
        if let isin = hint.isin?.uppercased() {
            let instrumentID = InstrumentID(Self.deriveID("inst", "isin|\(isin)"))
            return (.instrument(instrumentID), .isinOrCik)
        }
        return nil
    }

    /// 创建实体链（确定性 ID → 幂等 upsert，重复建立不翻倍）。
    private func createEntities(for hint: IdentityHint, canonical: CanonicalRef) throws {
        let jurisdiction = hint.jurisdiction ?? hint.exchange?.jurisdiction ?? .chinaMainland
        let kind = hint.instrumentKind ?? .stock
        let assetClass = hint.assetClass ?? .equity
        let currency = hint.currency ?? (jurisdiction == .unitedStates ? .usd : .cny)
        let name = hint.displayName ?? hint.code.value

        // 1) LegalEntity（发行人占位——真实发行人信息后续由披露数据补）
        let entityID = LegalEntityID(Self.deriveID("le", "\(jurisdiction.rawValue)|\(kind.rawValue)|\(name)"))
        try repository.upsert(LegalEntity(
            id: entityID, displayName: name, jurisdiction: jurisdiction,
            kind: kind == .stock ? .listedCompany : .other
        ))

        switch canonical {
        case .listing(let listingID):
            // 2) Instrument + 3) Listing（exchange + symbol 注册即权威）
            let exchange = hint.exchange!
            let instrumentID = InstrumentID(Self.deriveID("inst", "\(exchange.rawValue)|\(kind.rawValue)|\(name)"))
            try repository.upsert(Instrument(
                id: instrumentID, issuerID: entityID, kind: kind,
                displayName: name, baseCurrency: currency, assetClass: assetClass,
                isin: hint.isin?.uppercased()
            ))
            try repository.upsert(Listing(
                id: listingID, instrumentID: instrumentID, exchange: exchange,
                symbol: hint.code.value, tradingCurrency: currency
            ))
        case .instrument(let instrumentID):
            // ISIN-only：无挂牌层（指数 / 场外抽象工具）
            try repository.upsert(Instrument(
                id: instrumentID, issuerID: entityID, kind: kind,
                displayName: name, baseCurrency: currency, assetClass: assetClass,
                isin: hint.isin?.uppercased()
            ))
        default:
            // creationMatch 只产 listing/instrument 两种提案
            return
        }
    }

    // MARK: - fuzzy（只产 candidate）

    private func fuzzyMatches(_ hint: IdentityHint) -> [IdentityFuzzyCandidate] {
        guard let query = hint.displayName?.lowercased() else { return [] }
        var matches: [IdentityFuzzyCandidate] = []
        for instrument in repository.allInstruments() {
            let score = Self.bigramDice(query, instrument.displayName.lowercased())
            guard score >= fuzzyThreshold else { continue }
            let listings = repository.listings(forInstrument: instrument.id)
            let canonical: CanonicalRef = listings.count == 1
                ? .listing(listings[0].id)
                : .instrument(instrument.id)
            matches.append(IdentityFuzzyCandidate(
                canonical: canonical,
                matchedName: instrument.displayName,
                confidence: (score * 100).rounded() / 100,
                rationale: "名称 bigram Dice 相似度 \(score)"
            ))
        }
        return matches.sorted { $0.confidence > $1.confidence }
    }

    /// 字符 bigram Dice 系数（CJK / 拉丁统一处理，确定性）。
    static func bigramDice(_ a: String, _ b: String) -> Double {
        let normalize = { (s: String) -> String in
            s.filter { $0.isLetter || $0.isNumber }.lowercased()
        }
        let na = Array(normalize(a)), nb = Array(normalize(b))
        guard na.count >= 2, nb.count >= 2 else {
            return normalize(a) == normalize(b) ? 1.0 : 0.0
        }
        var bagsA: [String: Int] = [:]
        for i in 0..<(na.count - 1) {
            let pair = String(na[i...i + 1])
            bagsA[pair, default: 0] += 1
        }
        var bagsB: [String: Int] = [:]
        for i in 0..<(nb.count - 1) {
            let pair = String(nb[i...i + 1])
            bagsB[pair, default: 0] += 1
        }
        var intersection = 0
        for (pair, countA) in bagsA {
            intersection += min(countA, bagsB[pair] ?? 0)
        }
        let total = (na.count - 1) + (nb.count - 1)
        return Double(2 * intersection) / Double(total)
    }

    // MARK: - 登记

    private func register(
        _ hint: IdentityHint,
        canonical: CanonicalRef,
        method: IdentityResolutionMethod
    ) throws {
        try repository.upsert(ProviderIdentifier(
            providerID: hint.providerID,
            identifierScheme: hint.code.scheme,
            identifierValue: hint.code.value,
            canonical: canonical,
            resolutionMethod: method,
            resolvedAt: now()
        ))
    }

    // MARK: - Verification（fuzzy candidate 的裁决入口）

    /// 对 fuzzy candidate 做 Verification：accept 升级为 manualVerified
    /// （此后 lookup 可解析），reject 保持 lookup 拒绝（fuzzy 行无害保留）。
    @discardableResult
    func verify(
        providerID: DataProviderID,
        scheme: String,
        value: String,
        canonical: CanonicalRef,
        decision: IdentityVerificationDecision
    ) throws -> Bool {
        guard decision == .accept else { return false }
        try repository.upsert(ProviderIdentifier(
            providerID: providerID,
            identifierScheme: scheme,
            identifierValue: value,
            canonical: canonical,
            resolutionMethod: .manualVerified,
            resolvedAt: now()
        ))
        return true
    }

    /// 路径 4 直登：人工 verified 映射（REPO-4b 形态的增量入口）。
    @discardableResult
    func registerManualVerified(
        providerID: DataProviderID,
        scheme: String,
        value: String,
        canonical: CanonicalRef
    ) throws -> Bool {
        if let existing = repository.resolve(providerID: providerID, scheme: scheme, value: value),
           existing != canonical {
            return false   // 冲突不覆盖
        }
        try repository.upsert(ProviderIdentifier(
            providerID: providerID,
            identifierScheme: scheme,
            identifierValue: value,
            canonical: canonical,
            resolutionMethod: .manualVerified,
            resolvedAt: now()
        ))
        return true
    }

    // MARK: - 确定性 ID 派生

    /// SHA256(inputs) 截断 16 字节 hex，带前缀（ObservationID 同款手法）。
    static func deriveID(_ prefix: String, _ inputs: String) -> ID8 {
        let digest = SHA256.hash(data: Data(inputs.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return ID8(rawValue: "\(prefix)_\(hex)")
    }
}

/// 派生 ID 的轻量载体（listing/instrument/entity 各自的 ID 类型在调用侧
/// 构造——这里只承载 rawValue，避免为三种 ID 类型写三遍同款函数）。
struct ID8: Sendable, Hashable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }
}

extension ListingID {
    init(_ id: ID8) { self.init(rawValue: id.rawValue) }
}

extension InstrumentID {
    init(_ id: ID8) { self.init(rawValue: id.rawValue) }
}

extension LegalEntityID {
    init(_ id: ID8) { self.init(rawValue: id.rawValue) }
}
