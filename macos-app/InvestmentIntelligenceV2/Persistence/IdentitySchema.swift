import Foundation
import GRDB

// MARK: - IdentitySchema（GRDB-2，ADR-DATA001 §7-14 的持久化形态）
//
// Identity 域 7 张表：legal_entities / instruments / listings / fund_products /
// fund_share_classes / provider_identifiers / instrument_relationships。
//
// 设计要点（对照 ADR-DATA001）：
// - **五层实体各一表**，主键全是 Canonical ID（TEXT）——ID 一旦写入永不更改、
//   永不复用（§Decision 2），因此没有 UPDATE 主键的路径，也不做软删除。
// - **Provider 原始代码只活在 provider_identifiers**（防火墙 1）：业务表零
//   Provider 字段；(provider_id, identifier_scheme, identifier_value) 复合主键
//   编码「一个 Provider 代码至多一条映射」——这是 IdentityResolver lookup 层
//   （按三元组查表）的 schema 级保证。
// - **关系显式建模**（§14）：instrument_relationships 用扁平的
//   (relationship_type, source, target) 存储；端点实体类型由 codec 按关系类型
//   校验（tracksIndex 两端必须是 instrument 等），类型错配在解码层拒收，
//   不靠命名约定。
// - **外键约束**（GRDB 默认启用 foreign keys）：子表引用不存在的父实体直接
//   拒绝写入——Identity 是下游一切计算的锚点，引用完整性交给数据库而不是
//   应用层自觉。
// - **时间戳 / Decimal / JSON 列**统一走 CanonicalColumnCodec（见该文件头）。
//
// 本文件只定 schema + 行编解码（domain struct ↔ row）；Repository 协议实现
// （查询 API）在 GRDB-7。

/// Identity 域 schema（migration v2_identity 的建表体）。
enum IdentitySchema {

    /// 建全部 Identity 表 + 索引（migration v2_identity 调用；只追加不改写）。
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE legal_entities (
                id              TEXT PRIMARY KEY NOT NULL,
                display_name    TEXT NOT NULL,
                jurisdiction    TEXT NOT NULL,
                kind            TEXT NOT NULL,
                regulatory_ids  TEXT NOT NULL DEFAULT '[]'
            )
            """)

        try db.execute(sql: """
            CREATE TABLE instruments (
                id              TEXT PRIMARY KEY NOT NULL,
                issuer_id       TEXT NOT NULL REFERENCES legal_entities(id),
                kind            TEXT NOT NULL,
                display_name    TEXT NOT NULL,
                base_currency   TEXT NOT NULL,
                asset_class     TEXT NOT NULL,
                isin            TEXT
            )
            """)
        try db.execute(sql: """
            CREATE INDEX instruments_issuer_idx ON instruments(issuer_id)
            """)

        try db.execute(sql: """
            CREATE TABLE listings (
                id                TEXT PRIMARY KEY NOT NULL,
                instrument_id     TEXT NOT NULL REFERENCES instruments(id),
                exchange          TEXT NOT NULL,
                symbol            TEXT NOT NULL,
                trading_currency  TEXT NOT NULL,
                is_active         INTEGER NOT NULL DEFAULT 1
            )
            """)
        try db.execute(sql: """
            CREATE INDEX listings_instrument_idx ON listings(instrument_id)
            """)
        // 「交易所+代码 全局唯一」是 ADR-DATA001 路径 2（exchangeSymbolExact）
        // 的前提，schema 层落成约束。只对 active 挂牌唯一：退市 Listing 保留
        //（isActive=false，ID 不删），同代码重新上市是新 Listing，历史不冲突。
        try db.execute(sql: """
            CREATE UNIQUE INDEX listings_active_exchange_symbol_uq
                ON listings(exchange, symbol) WHERE is_active = 1
            """)

        try db.execute(sql: """
            CREATE TABLE fund_products (
                id              TEXT PRIMARY KEY NOT NULL,
                instrument_id   TEXT NOT NULL REFERENCES instruments(id),
                fund_type       TEXT NOT NULL,
                display_name    TEXT NOT NULL,
                regulatory_ids  TEXT NOT NULL DEFAULT '[]'
            )
            """)
        try db.execute(sql: """
            CREATE INDEX fund_products_instrument_idx ON fund_products(instrument_id)
            """)

        try db.execute(sql: """
            CREATE TABLE fund_share_classes (
                id                TEXT PRIMARY KEY NOT NULL,
                product_id        TEXT NOT NULL REFERENCES fund_products(id),
                instrument_id     TEXT NOT NULL REFERENCES instruments(id),
                share_class_code  TEXT NOT NULL,
                display_name      TEXT NOT NULL,
                fee_structure     TEXT NOT NULL,
                regulatory_ids    TEXT NOT NULL DEFAULT '[]',
                UNIQUE (product_id, share_class_code)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX fund_share_classes_instrument_idx
                ON fund_share_classes(instrument_id)
            """)

        try db.execute(sql: """
            CREATE TABLE provider_identifiers (
                provider_id            TEXT NOT NULL,
                identifier_scheme      TEXT NOT NULL,
                identifier_value       TEXT NOT NULL,
                canonical_entity_type  TEXT NOT NULL,
                canonical_entity_id    TEXT NOT NULL,
                resolution_method      TEXT NOT NULL,
                resolved_at            TEXT NOT NULL,
                PRIMARY KEY (provider_id, identifier_scheme, identifier_value)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE instrument_relationships (
                id                 TEXT PRIMARY KEY NOT NULL,
                relationship_type  TEXT NOT NULL,
                source_type        TEXT NOT NULL,
                source_id          TEXT NOT NULL,
                target_type        TEXT NOT NULL,
                target_id          TEXT NOT NULL,
                strength           TEXT,
                provenance         TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX instrument_relationships_source_idx
                ON instrument_relationships(source_type, source_id)
            """)
        try db.execute(sql: """
            CREATE INDEX instrument_relationships_target_idx
                ON instrument_relationships(target_type, target_id)
            """)
    }
}

// MARK: - CanonicalRef 的落库形态
//
// provider_identifiers 的 canonical 指向与 instrument_relationships 的端点都是
// 「五层实体之一」，落库拆成 (entity_type, entity_id) 两列。类型判别字符串与
// CanonicalRef.stableKey 的前缀一致（single source of semantics）。

extension CanonicalRef {

    /// 实体类型判别（落库 entity_type 列）。
    var entityType: String {
        switch self {
        case .legalEntity: return "legalEntity"
        case .instrument: return "instrument"
        case .listing: return "listing"
        case .fundProduct: return "fundProduct"
        case .fundShareClass: return "fundShareClass"
        }
    }

    /// 实体 ID 的 rawValue（落库 entity_id 列）。
    var entityIDRawValue: String {
        switch self {
        case .legalEntity(let id): return id.rawValue
        case .instrument(let id): return id.rawValue
        case .listing(let id): return id.rawValue
        case .fundProduct(let id): return id.rawValue
        case .fundShareClass(let id): return id.rawValue
        }
    }

    /// 从落库两列还原。未知类型字符串拒收（fail-closed：库被外部改过时
    /// 宁可报错，不猜语义）。
    init(entityType: String, entityIDRawValue: String) throws {
        switch entityType {
        case "legalEntity":
            self = .legalEntity(LegalEntityID(rawValue: entityIDRawValue))
        case "instrument":
            self = .instrument(InstrumentID(rawValue: entityIDRawValue))
        case "listing":
            self = .listing(ListingID(rawValue: entityIDRawValue))
        case "fundProduct":
            self = .fundProduct(FundProductID(rawValue: entityIDRawValue))
        case "fundShareClass":
            self = .fundShareClass(FundShareClassID(rawValue: entityIDRawValue))
        default:
            throw IdentitySchemaError.unknownEntityType(entityType)
        }
    }
}

/// Identity schema 编解码错误。
enum IdentitySchemaError: Error, Equatable, CustomStringConvertible {
    /// entity_type 列出现五层之外的类型字符串
    case unknownEntityType(String)
    /// instrument_relationships 行的端点类型与 relationship_type 的契约不符
    case relationshipEndpointMismatch(relationshipType: String, detail: String)

    var description: String {
        switch self {
        case .unknownEntityType(let t):
            return "IdentitySchema: 未知实体类型列值 \(t)"
        case .relationshipEndpointMismatch(let type, let detail):
            return "IdentitySchema: 关系 \(type) 端点类型错配（\(detail)）"
        }
    }
}

// MARK: - 行类型（domain struct ↔ 表行）
//
// 每张表一个 row struct：`FetchableRecord`（读）+ `PersistableRecord`（写），
// 手写列编解码（不经 Codable 策略推断），时间戳 / Decimal / JSON 列一律走
// CanonicalColumnCodec。`from(_:)` / `toDomain()` 是 domain 转换的唯一入口，
// GRDB-7 的 Repository 实现经由它们进出。

struct LegalEntityRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "legal_entities"

    let id: String
    let displayName: String
    let jurisdiction: String
    let kind: String
    let regulatoryIDsJSON: String

    init(id: String, displayName: String, jurisdiction: String, kind: String, regulatoryIDsJSON: String) {
        self.id = id
        self.displayName = displayName
        self.jurisdiction = jurisdiction
        self.kind = kind
        self.regulatoryIDsJSON = regulatoryIDsJSON
    }

    init(row: Row) throws {
        id = row["id"]
        displayName = row["display_name"]
        jurisdiction = row["jurisdiction"]
        kind = row["kind"]
        regulatoryIDsJSON = row["regulatory_ids"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["display_name"] = displayName
        container["jurisdiction"] = jurisdiction
        container["kind"] = kind
        container["regulatory_ids"] = regulatoryIDsJSON
    }

    static func from(_ domain: LegalEntity) throws -> LegalEntityRow {
        LegalEntityRow(
            id: domain.id.rawValue,
            displayName: domain.displayName,
            jurisdiction: domain.jurisdiction.rawValue,
            kind: domain.kind.rawValue,
            regulatoryIDsJSON: try CanonicalColumnCodec.encodeJSON(domain.regulatoryIDs)
        )
    }

    func toDomain() throws -> LegalEntity {
        try LegalEntity(
            id: LegalEntityID(rawValue: id),
            displayName: displayName,
            jurisdiction: CanonicalColumnCodec.decodeEnum(
                Jurisdiction.self, rawValue: jurisdiction, column: "jurisdiction"
            ),
            kind: CanonicalColumnCodec.decodeEnum(
                LegalEntity.Kind.self, rawValue: kind, column: "kind"
            ),
            regulatoryIDs: try CanonicalColumnCodec.decodeJSON([RegulatoryID].self, from: regulatoryIDsJSON)
        )
    }
}

struct InstrumentRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "instruments"

    let id: String
    let issuerID: String
    let kind: String
    let displayName: String
    let baseCurrency: String
    let assetClass: String
    let isin: String?

    init(id: String, issuerID: String, kind: String, displayName: String, baseCurrency: String, assetClass: String, isin: String?) {
        self.id = id
        self.issuerID = issuerID
        self.kind = kind
        self.displayName = displayName
        self.baseCurrency = baseCurrency
        self.assetClass = assetClass
        self.isin = isin
    }

    init(row: Row) throws {
        id = row["id"]
        issuerID = row["issuer_id"]
        kind = row["kind"]
        displayName = row["display_name"]
        baseCurrency = row["base_currency"]
        assetClass = row["asset_class"]
        isin = row["isin"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["issuer_id"] = issuerID
        container["kind"] = kind
        container["display_name"] = displayName
        container["base_currency"] = baseCurrency
        container["asset_class"] = assetClass
        container["isin"] = isin
    }

    static func from(_ domain: Instrument) throws -> InstrumentRow {
        InstrumentRow(
            id: domain.id.rawValue,
            issuerID: domain.issuerID.rawValue,
            kind: domain.kind.rawValue,
            displayName: domain.displayName,
            baseCurrency: domain.baseCurrency.rawValue,
            assetClass: domain.assetClass.rawValue,
            isin: domain.isin
        )
    }

    func toDomain() throws -> Instrument {
        try Instrument(
            id: InstrumentID(rawValue: id),
            issuerID: LegalEntityID(rawValue: issuerID),
            kind: CanonicalColumnCodec.decodeEnum(
                InstrumentKind.self, rawValue: kind, column: "kind"
            ),
            displayName: displayName,
            baseCurrency: CanonicalColumnCodec.decodeEnum(
                Currency.self, rawValue: baseCurrency, column: "base_currency"
            ),
            assetClass: CanonicalColumnCodec.decodeEnum(
                AssetClass.self, rawValue: assetClass, column: "asset_class"
            ),
            isin: isin
        )
    }
}

struct ListingRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "listings"

    let id: String
    let instrumentID: String
    let exchange: String
    let symbol: String
    let tradingCurrency: String
    let isActive: Bool

    init(id: String, instrumentID: String, exchange: String, symbol: String, tradingCurrency: String, isActive: Bool) {
        self.id = id
        self.instrumentID = instrumentID
        self.exchange = exchange
        self.symbol = symbol
        self.tradingCurrency = tradingCurrency
        self.isActive = isActive
    }

    init(row: Row) throws {
        id = row["id"]
        instrumentID = row["instrument_id"]
        exchange = row["exchange"]
        symbol = row["symbol"]
        tradingCurrency = row["trading_currency"]
        isActive = row["is_active"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["instrument_id"] = instrumentID
        container["exchange"] = exchange
        container["symbol"] = symbol
        container["trading_currency"] = tradingCurrency
        container["is_active"] = isActive
    }

    static func from(_ domain: Listing) throws -> ListingRow {
        ListingRow(
            id: domain.id.rawValue,
            instrumentID: domain.instrumentID.rawValue,
            exchange: domain.exchange.rawValue,
            symbol: domain.symbol,
            tradingCurrency: domain.tradingCurrency.rawValue,
            isActive: domain.isActive
        )
    }

    func toDomain() throws -> Listing {
        try Listing(
            id: ListingID(rawValue: id),
            instrumentID: InstrumentID(rawValue: instrumentID),
            exchange: CanonicalColumnCodec.decodeEnum(
                Exchange.self, rawValue: exchange, column: "exchange"
            ),
            symbol: symbol,
            tradingCurrency: CanonicalColumnCodec.decodeEnum(
                Currency.self, rawValue: tradingCurrency, column: "trading_currency"
            ),
            isActive: isActive
        )
    }
}

struct FundProductRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "fund_products"

    let id: String
    let instrumentID: String
    let fundType: String
    let displayName: String
    let regulatoryIDsJSON: String

    init(id: String, instrumentID: String, fundType: String, displayName: String, regulatoryIDsJSON: String) {
        self.id = id
        self.instrumentID = instrumentID
        self.fundType = fundType
        self.displayName = displayName
        self.regulatoryIDsJSON = regulatoryIDsJSON
    }

    init(row: Row) throws {
        id = row["id"]
        instrumentID = row["instrument_id"]
        fundType = row["fund_type"]
        displayName = row["display_name"]
        regulatoryIDsJSON = row["regulatory_ids"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["instrument_id"] = instrumentID
        container["fund_type"] = fundType
        container["display_name"] = displayName
        container["regulatory_ids"] = regulatoryIDsJSON
    }

    static func from(_ domain: FundProduct) throws -> FundProductRow {
        FundProductRow(
            id: domain.id.rawValue,
            instrumentID: domain.instrumentID.rawValue,
            fundType: domain.fundType.rawValue,
            displayName: domain.displayName,
            regulatoryIDsJSON: try CanonicalColumnCodec.encodeJSON(domain.regulatoryIDs)
        )
    }

    func toDomain() throws -> FundProduct {
        try FundProduct(
            id: FundProductID(rawValue: id),
            instrumentID: InstrumentID(rawValue: instrumentID),
            fundType: CanonicalColumnCodec.decodeEnum(
                FundProduct.FundType.self, rawValue: fundType, column: "fund_type"
            ),
            displayName: displayName,
            regulatoryIDs: try CanonicalColumnCodec.decodeJSON([RegulatoryID].self, from: regulatoryIDsJSON)
        )
    }
}

struct FundShareClassRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "fund_share_classes"

    let id: String
    let productID: String
    let instrumentID: String
    let shareClassCode: String
    let displayName: String
    let feeStructureJSON: String
    let regulatoryIDsJSON: String

    init(id: String, productID: String, instrumentID: String, shareClassCode: String, displayName: String, feeStructureJSON: String, regulatoryIDsJSON: String) {
        self.id = id
        self.productID = productID
        self.instrumentID = instrumentID
        self.shareClassCode = shareClassCode
        self.displayName = displayName
        self.feeStructureJSON = feeStructureJSON
        self.regulatoryIDsJSON = regulatoryIDsJSON
    }

    init(row: Row) throws {
        id = row["id"]
        productID = row["product_id"]
        instrumentID = row["instrument_id"]
        shareClassCode = row["share_class_code"]
        displayName = row["display_name"]
        feeStructureJSON = row["fee_structure"]
        regulatoryIDsJSON = row["regulatory_ids"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["product_id"] = productID
        container["instrument_id"] = instrumentID
        container["share_class_code"] = shareClassCode
        container["display_name"] = displayName
        container["fee_structure"] = feeStructureJSON
        container["regulatory_ids"] = regulatoryIDsJSON
    }

    static func from(_ domain: FundShareClass) throws -> FundShareClassRow {
        FundShareClassRow(
            id: domain.id.rawValue,
            productID: domain.productID.rawValue,
            instrumentID: domain.instrumentID.rawValue,
            shareClassCode: domain.shareClassCode,
            displayName: domain.displayName,
            feeStructureJSON: try CanonicalColumnCodec.encodeJSON(domain.feeStructure),
            regulatoryIDsJSON: try CanonicalColumnCodec.encodeJSON(domain.regulatoryIDs)
        )
    }

    func toDomain() throws -> FundShareClass {
        FundShareClass(
            id: FundShareClassID(rawValue: id),
            productID: FundProductID(rawValue: productID),
            instrumentID: InstrumentID(rawValue: instrumentID),
            shareClassCode: shareClassCode,
            displayName: displayName,
            feeStructure: try CanonicalColumnCodec.decodeJSON(
                FundShareClass.FeeStructure.self, from: feeStructureJSON
            ),
            regulatoryIDs: try CanonicalColumnCodec.decodeJSON([RegulatoryID].self, from: regulatoryIDsJSON)
        )
    }
}

struct ProviderIdentifierRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "provider_identifiers"

    let providerID: String
    let identifierScheme: String
    let identifierValue: String
    let canonicalEntityType: String
    let canonicalEntityID: String
    let resolutionMethod: String
    let resolvedAt: String

    init(providerID: String, identifierScheme: String, identifierValue: String, canonicalEntityType: String, canonicalEntityID: String, resolutionMethod: String, resolvedAt: String) {
        self.providerID = providerID
        self.identifierScheme = identifierScheme
        self.identifierValue = identifierValue
        self.canonicalEntityType = canonicalEntityType
        self.canonicalEntityID = canonicalEntityID
        self.resolutionMethod = resolutionMethod
        self.resolvedAt = resolvedAt
    }

    init(row: Row) throws {
        providerID = row["provider_id"]
        identifierScheme = row["identifier_scheme"]
        identifierValue = row["identifier_value"]
        canonicalEntityType = row["canonical_entity_type"]
        canonicalEntityID = row["canonical_entity_id"]
        resolutionMethod = row["resolution_method"]
        resolvedAt = row["resolved_at"]
    }

    /// 复合主键按 GRDB Codable 惯例（持久化容器缺失主键时由本方法补齐）；
    /// 显式列出避免依赖插入顺序。
    static var persistenceConflictTarget: [Column] {
        [Column("provider_id"), Column("identifier_scheme"), Column("identifier_value")]
    }

    func encode(to container: inout PersistenceContainer) {
        container["provider_id"] = providerID
        container["identifier_scheme"] = identifierScheme
        container["identifier_value"] = identifierValue
        container["canonical_entity_type"] = canonicalEntityType
        container["canonical_entity_id"] = canonicalEntityID
        container["resolution_method"] = resolutionMethod
        container["resolved_at"] = resolvedAt
    }

    static func from(_ domain: ProviderIdentifier) throws -> ProviderIdentifierRow {
        ProviderIdentifierRow(
            providerID: domain.providerID.rawValue,
            identifierScheme: domain.identifierScheme,
            identifierValue: domain.identifierValue,
            canonicalEntityType: domain.canonical.entityType,
            canonicalEntityID: domain.canonical.entityIDRawValue,
            resolutionMethod: domain.resolutionMethod.rawValue,
            resolvedAt: CanonicalColumnCodec.encodeTimestamp(domain.resolvedAt)
        )
    }

    func toDomain() throws -> ProviderIdentifier {
        ProviderIdentifier(
            providerID: DataProviderID(rawValue: providerID),
            identifierScheme: identifierScheme,
            identifierValue: identifierValue,
            canonical: try CanonicalRef(
                entityType: canonicalEntityType, entityIDRawValue: canonicalEntityID
            ),
            resolutionMethod: try CanonicalColumnCodec.decodeEnum(
                IdentityResolutionMethod.self,
                rawValue: resolutionMethod,
                column: "resolution_method"
            ),
            resolvedAt: try CanonicalColumnCodec.decodeTimestamp(resolvedAt)
        )
    }
}

// MARK: - InstrumentRelationship 的落库形态
//
// enum with associated values 扁平化为
// (relationship_type, source_type, source_id, target_type, target_id) +
// 关系专属载荷（tracksIndex 的 strength）。端点类型契约在 codec 校验：
// 每类关系的两端必须是约定的实体层（ADR-DATA001 §14），错配行拒收——
// 换取「图查询不必猜端点是哪一层」。

/// 关系类型判别（instrument_relationships.relationship_type 列）。
enum RelationshipType: String, CaseIterable {
    case tracksIndex = "TRACKS_INDEX"
    case shareClassOf = "SHARE_CLASS_OF"
    case issuedBy = "ISSUED_BY"
    case adrUnderlying = "ADR_UNDERLYING"

    /// 该关系类型允许的（源端类型, 目标端类型）。
    var endpointContract: (source: String, target: String) {
        switch self {
        case .tracksIndex: return ("instrument", "instrument")
        case .shareClassOf: return ("fundShareClass", "fundProduct")
        case .issuedBy: return ("instrument", "legalEntity")
        case .adrUnderlying: return ("instrument", "instrument")
        }
    }
}

struct InstrumentRelationshipRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "instrument_relationships"

    let id: String
    let relationshipType: String
    let sourceType: String
    let sourceID: String
    let targetType: String
    let targetID: String
    let strength: String?
    let provenance: String

    init(id: String, relationshipType: String, sourceType: String, sourceID: String, targetType: String, targetID: String, strength: String?, provenance: String) {
        self.id = id
        self.relationshipType = relationshipType
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.targetType = targetType
        self.targetID = targetID
        self.strength = strength
        self.provenance = provenance
    }

    init(row: Row) throws {
        id = row["id"]
        relationshipType = row["relationship_type"]
        sourceType = row["source_type"]
        sourceID = row["source_id"]
        targetType = row["target_type"]
        targetID = row["target_id"]
        strength = row["strength"]
        provenance = row["provenance"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["relationship_type"] = relationshipType
        container["source_type"] = sourceType
        container["source_id"] = sourceID
        container["target_type"] = targetType
        container["target_id"] = targetID
        container["strength"] = strength
        container["provenance"] = provenance
    }

    static func from(_ domain: InstrumentRelationship) throws -> InstrumentRelationshipRow {
        let type: RelationshipType
        let sourceType: String
        let sourceID: String
        let targetType: String
        let targetID: String
        var strength: String? = nil

        switch domain {
        case .tracksIndex(let r):
            type = .tracksIndex
            sourceType = "instrument"; sourceID = r.etf.rawValue
            targetType = "instrument"; targetID = r.index.rawValue
            strength = r.strength.map { CanonicalColumnCodec.encodeDecimal($0) }
        case .shareClassOf(let r):
            type = .shareClassOf
            sourceType = "fundShareClass"; sourceID = r.shareClass.rawValue
            targetType = "fundProduct"; targetID = r.product.rawValue
        case .issuedBy(let r):
            type = .issuedBy
            sourceType = "instrument"; sourceID = r.instrument.rawValue
            targetType = "legalEntity"; targetID = r.issuer.rawValue
        case .adrUnderlying(let r):
            type = .adrUnderlying
            sourceType = "instrument"; sourceID = r.adr.rawValue
            targetType = "instrument"; targetID = r.underlying.rawValue
        }

        return InstrumentRelationshipRow(
            id: domain.id.rawValue,
            relationshipType: type.rawValue,
            sourceType: sourceType,
            sourceID: sourceID,
            targetType: targetType,
            targetID: targetID,
            strength: strength,
            provenance: domain.provenance.rawValue
        )
    }

    func toDomain() throws -> InstrumentRelationship {
        let type = try CanonicalColumnCodec.decodeEnum(
            RelationshipType.self, rawValue: relationshipType, column: "relationship_type"
        )

        // 端点契约校验：行数据与关系类型的端点层不符 = 库被外部改过（codec 层
        // 不会产出这种行），fail-closed 拒收。
        let contract = type.endpointContract
        guard sourceType == contract.source, targetType == contract.target else {
            throw IdentitySchemaError.relationshipEndpointMismatch(
                relationshipType: relationshipType,
                detail: "行端点 (\(sourceType), \(targetType)) ≠ 契约 (\(contract.source), \(contract.target))"
            )
        }

        switch type {
        case .tracksIndex:
            return .tracksIndex(.init(
                id: DomainID(rawValue: id),
                etf: InstrumentID(rawValue: sourceID),
                index: InstrumentID(rawValue: targetID),
                strength: try strength.map { try CanonicalColumnCodec.decodeDecimal($0) },
                provenance: try decodeProvenance()
            ))
        case .shareClassOf:
            return .shareClassOf(.init(
                id: DomainID(rawValue: id),
                shareClass: FundShareClassID(rawValue: sourceID),
                product: FundProductID(rawValue: targetID),
                provenance: try decodeProvenance()
            ))
        case .issuedBy:
            return .issuedBy(.init(
                id: DomainID(rawValue: id),
                instrument: InstrumentID(rawValue: sourceID),
                issuer: LegalEntityID(rawValue: targetID),
                provenance: try decodeProvenance()
            ))
        case .adrUnderlying:
            return .adrUnderlying(.init(
                id: DomainID(rawValue: id),
                adr: InstrumentID(rawValue: sourceID),
                underlying: InstrumentID(rawValue: targetID),
                provenance: try decodeProvenance()
            ))
        }
    }

    private func decodeProvenance() throws -> InstrumentRelationship.RelationshipProvenance {
        try CanonicalColumnCodec.decodeEnum(
            InstrumentRelationship.RelationshipProvenance.self,
            rawValue: provenance,
            column: "provenance"
        )
    }
}
