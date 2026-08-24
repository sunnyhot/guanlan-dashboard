import Foundation
import GRDB

// MARK: - MarketSchema（GRDB-3，行情 / 净值 / 公司行动域）
//
// 3 张表：daily_bars / nav_observations / corporate_actions。
//
// - **PIT 查询路径**：四时间是 ISO8601 UTC 毫秒字符串（字典序 = 时间序），
//   `WHERE available_at <= ?` / `ingested_at <= ?` 在 SQL 里直接字符串比较
//   （GRDB-7 Repository 的 economic/operational 查询走此路径，无需读回 Swift）。
// - **DATA008 行情单 vintage 简化**：daily_bars 99.9% 单 vintage，但 schema 仍
//   完整支持 multi-vintage（偶发修订追加行）；三表统一落
//   (维度键, effective_at, vintage) 唯一索引（DATA008 Compliance Check 要求）。
// - **外键**：daily_bars.listing_id → listings、nav_observations.share_class_id →
//   fund_share_classes、corporate_actions.listing_id → listings——观测只能挂在
//   已解析的 Canonical Identity 上（防火墙 1 的库级形态；ObservationFactory
//   对未解析 identity 本就拒收，这里兜底）。
// - **价格列**：Decimal 走 TEXT（CanonicalColumnCodec）。同一观测内的多个
//   Price 域内共享同一 currency（类型层重复携带只是类型安全），落库单列
//   currency + codec 校验一致（不一致 = 构造期就该拦的语义错误，编解码期拒收）。

/// Market 域 schema（migration v3_market 的建表体）。
enum MarketSchema {

    /// 建全部 Market 表 + 索引（migration v3_market 调用；只追加不改写）。
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE daily_bars (
                id                      TEXT PRIMARY KEY NOT NULL,
                listing_id              TEXT NOT NULL REFERENCES listings(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                raw_currency            TEXT NOT NULL,
                raw_open                TEXT NOT NULL,
                raw_high                TEXT NOT NULL,
                raw_low                 TEXT NOT NULL,
                raw_close               TEXT NOT NULL,
                volume                  INTEGER,
                adjustment_factor       TEXT NOT NULL,
                fx_rate                 TEXT,
                UNIQUE (listing_id, effective_at, vintage_announcement_date, vintage_publisher_version)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE nav_observations (
                id                              TEXT PRIMARY KEY NOT NULL,
                share_class_id                  TEXT NOT NULL REFERENCES fund_share_classes(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                nav_currency                    TEXT NOT NULL,
                unit_nav                        TEXT NOT NULL,
                accumulated_nav                 TEXT,
                cumulative_dividend_per_share   TEXT,
                UNIQUE (share_class_id, effective_at, vintage_announcement_date, vintage_publisher_version)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE corporate_actions (
                id                      TEXT PRIMARY KEY NOT NULL,
                listing_id              TEXT NOT NULL REFERENCES listings(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                kind                    TEXT NOT NULL,
                ex_date                 TEXT NOT NULL,
                record_date             TEXT,
                pay_date                TEXT,
                ratio                   TEXT NOT NULL,
                action_currency         TEXT,
                UNIQUE (listing_id, effective_at, vintage_announcement_date, vintage_publisher_version)
            )
            """)
        // 公司行动按除权日查询是业务热路径（Factor / Attribution 复权计算）
        try db.execute(sql: """
            CREATE INDEX corporate_actions_listing_exdate_idx
                ON corporate_actions(listing_id, ex_date)
            """)
    }
}

// MARK: - 行类型

struct DailyBarRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "daily_bars"

    let id: String
    let listingID: String
    let envelope: ObservationEnvelopeColumns
    let rawCurrency: String
    let rawOpen: String
    let rawHigh: String
    let rawLow: String
    let rawClose: String
    let volume: Int64?
    let adjustmentFactor: String
    let fxRate: String?

    init(row: Row) {
        id = row["id"]
        listingID = row["listing_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        rawCurrency = row["raw_currency"]
        rawOpen = row["raw_open"]
        rawHigh = row["raw_high"]
        rawLow = row["raw_low"]
        rawClose = row["raw_close"]
        volume = row["volume"]
        adjustmentFactor = row["adjustment_factor"]
        fxRate = row["fx_rate"]
    }

    init(
        id: String,
        listingID: String,
        envelope: ObservationEnvelopeColumns,
        rawCurrency: String,
        rawOpen: String,
        rawHigh: String,
        rawLow: String,
        rawClose: String,
        volume: Int64?,
        adjustmentFactor: String,
        fxRate: String?
    ) {
        self.id = id
        self.listingID = listingID
        self.envelope = envelope
        self.rawCurrency = rawCurrency
        self.rawOpen = rawOpen
        self.rawHigh = rawHigh
        self.rawLow = rawLow
        self.rawClose = rawClose
        self.volume = volume
        self.adjustmentFactor = adjustmentFactor
        self.fxRate = fxRate
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["listing_id"] = listingID
        envelope.encode(to: &container)
        container["raw_currency"] = rawCurrency
        container["raw_open"] = rawOpen
        container["raw_high"] = rawHigh
        container["raw_low"] = rawLow
        container["raw_close"] = rawClose
        container["volume"] = volume
        container["adjustment_factor"] = adjustmentFactor
        container["fx_rate"] = fxRate
    }

    static func from(_ domain: DailyBar) throws -> DailyBarRow {
        // 单 currency 列的完整性前提：一条 bar 的四个 raw Price 币种必须一致
        //（ObservationFactory 按 listing.tradingCurrency 产出，恒成立；
        // 不一致说明上游构造错误，编解码期拒收）
        let currency = domain.rawClose.currency
        guard domain.rawOpen.currency == currency,
              domain.rawHigh.currency == currency,
              domain.rawLow.currency == currency
        else {
            throw MarketSchemaError.mixedPriceCurrency(table: "daily_bars", id: domain.id.rawValue)
        }

        return DailyBarRow(
            id: domain.id.rawValue,
            listingID: domain.listingID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            rawCurrency: currency.rawValue,
            rawOpen: CanonicalColumnCodec.encodeDecimal(domain.rawOpen.value),
            rawHigh: CanonicalColumnCodec.encodeDecimal(domain.rawHigh.value),
            rawLow: CanonicalColumnCodec.encodeDecimal(domain.rawLow.value),
            rawClose: CanonicalColumnCodec.encodeDecimal(domain.rawClose.value),
            volume: domain.volume,
            adjustmentFactor: CanonicalColumnCodec.encodeDecimal(domain.adjustmentFactor),
            fxRate: domain.fxRate.map { CanonicalColumnCodec.encodeDecimal($0) }
        )
    }

    func toDomain() throws -> DailyBar {
        let currency = try CanonicalColumnCodec.decodeEnum(
            Currency.self, rawValue: rawCurrency, column: "raw_currency"
        )
        return try DailyBar(
            id: ObservationID(rawValue: id),
            listingID: ListingID(rawValue: listingID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            rawOpen: Price(value: try CanonicalColumnCodec.decodeDecimal(rawOpen), currency: currency),
            rawHigh: Price(value: try CanonicalColumnCodec.decodeDecimal(rawHigh), currency: currency),
            rawLow: Price(value: try CanonicalColumnCodec.decodeDecimal(rawLow), currency: currency),
            rawClose: Price(value: try CanonicalColumnCodec.decodeDecimal(rawClose), currency: currency),
            volume: volume,
            adjustmentFactor: try CanonicalColumnCodec.decodeDecimal(adjustmentFactor),
            fxRate: try fxRate.map { try CanonicalColumnCodec.decodeDecimal($0) }
        )
    }
}

struct NAVObservationRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "nav_observations"

    let id: String
    let shareClassID: String
    let envelope: ObservationEnvelopeColumns
    let navCurrency: String
    let unitNAV: String
    let accumulatedNAV: String?
    let cumulativeDividendPerShare: String?

    init(row: Row) {
        id = row["id"]
        shareClassID = row["share_class_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        navCurrency = row["nav_currency"]
        unitNAV = row["unit_nav"]
        accumulatedNAV = row["accumulated_nav"]
        cumulativeDividendPerShare = row["cumulative_dividend_per_share"]
    }

    init(
        id: String,
        shareClassID: String,
        envelope: ObservationEnvelopeColumns,
        navCurrency: String,
        unitNAV: String,
        accumulatedNAV: String?,
        cumulativeDividendPerShare: String?
    ) {
        self.id = id
        self.shareClassID = shareClassID
        self.envelope = envelope
        self.navCurrency = navCurrency
        self.unitNAV = unitNAV
        self.accumulatedNAV = accumulatedNAV
        self.cumulativeDividendPerShare = cumulativeDividendPerShare
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["share_class_id"] = shareClassID
        envelope.encode(to: &container)
        container["nav_currency"] = navCurrency
        container["unit_nav"] = unitNAV
        container["accumulated_nav"] = accumulatedNAV
        container["cumulative_dividend_per_share"] = cumulativeDividendPerShare
    }

    static func from(_ domain: NAVObservation) throws -> NAVObservationRow {
        // 与 daily_bars 同理：多个 Price 字段币种必须一致，落单 currency 列
        let currency = domain.unitNAV.currency
        if let accumulated = domain.accumulatedNAV, accumulated.currency != currency {
            throw MarketSchemaError.mixedPriceCurrency(table: "nav_observations", id: domain.id.rawValue)
        }
        if let dividend = domain.cumulativeDividendPerShare, dividend.currency != currency {
            throw MarketSchemaError.mixedPriceCurrency(table: "nav_observations", id: domain.id.rawValue)
        }

        return NAVObservationRow(
            id: domain.id.rawValue,
            shareClassID: domain.shareClassID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            navCurrency: currency.rawValue,
            unitNAV: CanonicalColumnCodec.encodeDecimal(domain.unitNAV.value),
            accumulatedNAV: domain.accumulatedNAV.map { CanonicalColumnCodec.encodeDecimal($0.value) },
            cumulativeDividendPerShare: domain.cumulativeDividendPerShare.map {
                CanonicalColumnCodec.encodeDecimal($0.value)
            }
        )
    }

    func toDomain() throws -> NAVObservation {
        let currency = try CanonicalColumnCodec.decodeEnum(
            Currency.self, rawValue: navCurrency, column: "nav_currency"
        )
        return try NAVObservation(
            id: ObservationID(rawValue: id),
            shareClassID: FundShareClassID(rawValue: shareClassID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            unitNAV: Price(value: try CanonicalColumnCodec.decodeDecimal(unitNAV), currency: currency),
            accumulatedNAV: try accumulatedNAV.map {
                Price(value: try CanonicalColumnCodec.decodeDecimal($0), currency: currency)
            },
            cumulativeDividendPerShare: try cumulativeDividendPerShare.map {
                Price(value: try CanonicalColumnCodec.decodeDecimal($0), currency: currency)
            }
        )
    }
}

struct CorporateActionRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "corporate_actions"

    let id: String
    let listingID: String
    let envelope: ObservationEnvelopeColumns
    let kind: String
    let exDate: String
    let recordDate: String?
    let payDate: String?
    let ratio: String
    let actionCurrency: String?

    init(row: Row) {
        id = row["id"]
        listingID = row["listing_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        kind = row["kind"]
        exDate = row["ex_date"]
        recordDate = row["record_date"]
        payDate = row["pay_date"]
        ratio = row["ratio"]
        actionCurrency = row["action_currency"]
    }

    init(
        id: String,
        listingID: String,
        envelope: ObservationEnvelopeColumns,
        kind: String,
        exDate: String,
        recordDate: String?,
        payDate: String?,
        ratio: String,
        actionCurrency: String?
    ) {
        self.id = id
        self.listingID = listingID
        self.envelope = envelope
        self.kind = kind
        self.exDate = exDate
        self.recordDate = recordDate
        self.payDate = payDate
        self.ratio = ratio
        self.actionCurrency = actionCurrency
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["listing_id"] = listingID
        envelope.encode(to: &container)
        container["kind"] = kind
        container["ex_date"] = exDate
        container["record_date"] = recordDate
        container["pay_date"] = payDate
        container["ratio"] = ratio
        container["action_currency"] = actionCurrency
    }

    static func from(_ domain: CorporateAction) throws -> CorporateActionRow {
        CorporateActionRow(
            id: domain.id.rawValue,
            listingID: domain.listingID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            kind: domain.kind.rawValue,
            exDate: CanonicalColumnCodec.encodeTimestamp(domain.exDate),
            recordDate: domain.recordDate.map { CanonicalColumnCodec.encodeTimestamp($0) },
            payDate: domain.payDate.map { CanonicalColumnCodec.encodeTimestamp($0) },
            ratio: CanonicalColumnCodec.encodeDecimal(domain.ratio),
            actionCurrency: domain.currency?.rawValue
        )
    }

    func toDomain() throws -> CorporateAction {
        try CorporateAction(
            id: ObservationID(rawValue: id),
            listingID: ListingID(rawValue: listingID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            kind: CanonicalColumnCodec.decodeEnum(
                CorporateAction.Kind.self, rawValue: kind, column: "kind"
            ),
            exDate: try CanonicalColumnCodec.decodeTimestamp(exDate),
            recordDate: try recordDate.map { try CanonicalColumnCodec.decodeTimestamp($0) },
            payDate: try payDate.map { try CanonicalColumnCodec.decodeTimestamp($0) },
            ratio: try CanonicalColumnCodec.decodeDecimal(ratio),
            currency: try actionCurrency.map {
                try CanonicalColumnCodec.decodeEnum(Currency.self, rawValue: $0, column: "action_currency")
            }
        )
    }
}

/// Market schema 编解码错误。
enum MarketSchemaError: Error, Equatable, CustomStringConvertible {
    /// 同一观测的多个 Price 币种不一致（单 currency 列的完整性前提被破坏）
    case mixedPriceCurrency(table: String, id: String)
    /// 可选 Price 的 value/currency 双列只有一列非空（正常写入同空同非空）
    case priceColumnsDisagree(value: String?, currency: String?)

    var description: String {
        switch self {
        case .mixedPriceCurrency(let table, let id):
            return "MarketSchema: \(table) 行 \(id) 的 Price 币种不一致"
        case .priceColumnsDisagree(let value, let currency):
            return "MarketSchema: 可选 Price 列不配套（value=\(value ?? "nil"), currency=\(currency ?? "nil")）"
        }
    }
}
