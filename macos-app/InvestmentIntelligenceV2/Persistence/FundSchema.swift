import Foundation
import GRDB

// MARK: - FundSchema（GRDB-4，基金持仓 / 资产配置域，DATA008 multi-vintage）
//
// 3 张表：holding_snapshots / holding_positions / allocation_snapshots。
//
// - **持仓多 vintage**（DATA008）：基金披露常修订（Q2 首报 → 更正公告），
//   同一 (product, effectiveAt) 允许同 vintage 语义的多条修订行——唯一索引
//   与 Market 表同款 (product_id, effective_at, vintage)。
// - **positions 子表**：FundHoldingSnapshot.positions 是数组，规范化为
//   一行一持仓；position_index 保序（Factor / 穿透按披露顺序对账）。
//   position 的 listing_id 外键到 listings——REPO-5b 语义是「任意 position
//   未解析即拒收整条 snapshot」，库级兜底同一约束。
// - **allocation_snapshots**：大类占比条目数量小（≤5）且总是整读，
//   allocations 以 JSON 列存储（与持仓明细的子表形态刻意不同——后者需要
//   按 listing 跨基金聚合查询，前者没有该查询路径）。
// - 删除语义：无。快照 append-only，修订 = 新行（DATA008）。

/// Fund 域 schema（migration v4_fund 的建表体）。
enum FundSchema {

    /// 建全部 Fund 表 + 索引（migration v4_fund 调用；只追加不改写）。
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE holding_snapshots (
                id                      TEXT PRIMARY KEY NOT NULL,
                product_id              TEXT NOT NULL REFERENCES fund_products(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                report_period           TEXT NOT NULL,
                disclosed_weight_total  TEXT NOT NULL,
                UNIQUE (product_id, effective_at, vintage_announcement_date, vintage_publisher_version)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE holding_positions (
                snapshot_id             TEXT NOT NULL REFERENCES holding_snapshots(id),
                position_index          INTEGER NOT NULL,
                listing_id              TEXT NOT NULL REFERENCES listings(id),
                weight                  TEXT NOT NULL,
                shares                  TEXT,
                market_value            TEXT,
                market_value_currency   TEXT,
                is_disclosed            INTEGER NOT NULL,
                PRIMARY KEY (snapshot_id, position_index)
            )
            """)
        // 跨基金按底层标的聚合（RISK-1 多基金重复持股识别）是本表存在的主因
        try db.execute(sql: """
            CREATE INDEX holding_positions_listing_idx ON holding_positions(listing_id)
            """)

        try db.execute(sql: """
            CREATE TABLE allocation_snapshots (
                id                  TEXT PRIMARY KEY NOT NULL,
                product_id          TEXT NOT NULL REFERENCES fund_products(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                report_period       TEXT NOT NULL,
                allocations_json    TEXT NOT NULL,
                UNIQUE (product_id, effective_at, vintage_announcement_date, vintage_publisher_version)
            )
            """)
    }
}

// MARK: - 行类型

struct FundHoldingSnapshotRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "holding_snapshots"

    let id: String
    let productID: String
    let envelope: ObservationEnvelopeColumns
    let reportPeriod: String
    let disclosedWeightTotal: String

    init(row: Row) {
        id = row["id"]
        productID = row["product_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        reportPeriod = row["report_period"]
        disclosedWeightTotal = row["disclosed_weight_total"]
    }

    init(
        id: String,
        productID: String,
        envelope: ObservationEnvelopeColumns,
        reportPeriod: String,
        disclosedWeightTotal: String
    ) {
        self.id = id
        self.productID = productID
        self.envelope = envelope
        self.reportPeriod = reportPeriod
        self.disclosedWeightTotal = disclosedWeightTotal
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["product_id"] = productID
        envelope.encode(to: &container)
        container["report_period"] = reportPeriod
        container["disclosed_weight_total"] = disclosedWeightTotal
    }

    /// positions 由 FundHoldingPositionRow 单独落子表（保序 index = 数组下标）。
    static func from(_ domain: FundHoldingSnapshot) -> FundHoldingSnapshotRow {
        FundHoldingSnapshotRow(
            id: domain.id.rawValue,
            productID: domain.productID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            reportPeriod: domain.reportPeriod.rawValue,
            disclosedWeightTotal: CanonicalColumnCodec.encodeDecimal(domain.disclosedWeightTotal.value)
        )
    }

    /// 还原不含 positions 的快照骨架；positions 由查询侧按 snapshot_id 补齐。
    func toDomain() throws -> FundHoldingSnapshot {
        try FundHoldingSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: productID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            reportPeriod: CanonicalColumnCodec.decodeEnum(
                FundHoldingSnapshot.ReportPeriod.self, rawValue: reportPeriod, column: "report_period"
            ),
            positions: [],
            disclosedWeightTotal: Ratio(
                value: try CanonicalColumnCodec.decodeDecimal(disclosedWeightTotal)
            )
        )
    }
}

struct FundHoldingPositionRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "holding_positions"

    let snapshotID: String
    let positionIndex: Int
    let listingID: String
    let weight: String
    let shares: String?
    let marketValue: String?
    let marketValueCurrency: String?
    let isDisclosed: Bool

    init(row: Row) {
        snapshotID = row["snapshot_id"]
        positionIndex = row["position_index"]
        listingID = row["listing_id"]
        weight = row["weight"]
        shares = row["shares"]
        marketValue = row["market_value"]
        marketValueCurrency = row["market_value_currency"]
        isDisclosed = row["is_disclosed"]
    }

    init(
        snapshotID: String,
        positionIndex: Int,
        listingID: String,
        weight: String,
        shares: String?,
        marketValue: String?,
        marketValueCurrency: String?,
        isDisclosed: Bool
    ) {
        self.snapshotID = snapshotID
        self.positionIndex = positionIndex
        self.listingID = listingID
        self.weight = weight
        self.shares = shares
        self.marketValue = marketValue
        self.marketValueCurrency = marketValueCurrency
        self.isDisclosed = isDisclosed
    }

    func encode(to container: inout PersistenceContainer) {
        container["snapshot_id"] = snapshotID
        container["position_index"] = positionIndex
        container["listing_id"] = listingID
        container["weight"] = weight
        container["shares"] = shares
        container["market_value"] = marketValue
        container["market_value_currency"] = marketValueCurrency
        container["is_disclosed"] = isDisclosed
    }

    /// position_index = positions 数组下标（保序契约由调用方满足——
    /// GRDB-7 写入路径与读取 ORDER BY position_index 对应）。
    static func from(
        _ domain: FundHoldingPosition,
        snapshotID: ObservationID,
        index: Int
    ) -> FundHoldingPositionRow {
        FundHoldingPositionRow(
            snapshotID: snapshotID.rawValue,
            positionIndex: index,
            listingID: domain.listingID.rawValue,
            weight: CanonicalColumnCodec.encodeDecimal(domain.weight.value),
            shares: domain.shares.map { CanonicalColumnCodec.encodeDecimal($0) },
            marketValue: domain.marketValue.map { CanonicalColumnCodec.encodeDecimal($0.value) },
            marketValueCurrency: domain.marketValue?.currency.rawValue,
            isDisclosed: domain.isDisclosed
        )
    }

    func toDomain() throws -> FundHoldingPosition {
        FundHoldingPosition(
            listingID: ListingID(rawValue: listingID),
            weight: Ratio(value: try CanonicalColumnCodec.decodeDecimal(weight)),
            shares: try shares.map { try CanonicalColumnCodec.decodeDecimal($0) },
            marketValue: try MarketSchemaError.decodedOptionalPrice(
                value: marketValue, currencyRaw: marketValueCurrency
            ),
            isDisclosed: isDisclosed
        )
    }
}

struct AllocationSnapshotRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "allocation_snapshots"

    let id: String
    let productID: String
    let envelope: ObservationEnvelopeColumns
    let reportPeriod: String
    let allocationsJSON: String

    init(row: Row) {
        id = row["id"]
        productID = row["product_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        reportPeriod = row["report_period"]
        allocationsJSON = row["allocations_json"]
    }

    init(
        id: String,
        productID: String,
        envelope: ObservationEnvelopeColumns,
        reportPeriod: String,
        allocationsJSON: String
    ) {
        self.id = id
        self.productID = productID
        self.envelope = envelope
        self.reportPeriod = reportPeriod
        self.allocationsJSON = allocationsJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["product_id"] = productID
        envelope.encode(to: &container)
        container["report_period"] = reportPeriod
        container["allocations_json"] = allocationsJSON
    }

    static func from(_ domain: AllocationSnapshot) throws -> AllocationSnapshotRow {
        AllocationSnapshotRow(
            id: domain.id.rawValue,
            productID: domain.productID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            reportPeriod: domain.reportPeriod.rawValue,
            allocationsJSON: try CanonicalColumnCodec.encodeJSON(domain.allocations)
        )
    }

    func toDomain() throws -> AllocationSnapshot {
        try AllocationSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: productID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            reportPeriod: CanonicalColumnCodec.decodeEnum(
                FundHoldingSnapshot.ReportPeriod.self, rawValue: reportPeriod, column: "report_period"
            ),
            allocations: try CanonicalColumnCodec.decodeJSON(
                [AllocationSnapshot.AllocationEntry].self, from: allocationsJSON
            )
        )
    }
}

// MARK: - 可选 Price 列还原（value + currency 双列，两者须同空同非空）

extension MarketSchemaError {
    /// 可选 Price 的 (value, currency) 双列还原：只有一列非空 = 库被外部改过
    ///（正常写入要么都空要么都有），fail-closed 拒收。
    static func decodedOptionalPrice(value: String?, currencyRaw: String?) throws -> Price? {
        switch (value, currencyRaw) {
        case (nil, nil):
            return nil
        case (let v?, let c?):
            return Price(
                value: try CanonicalColumnCodec.decodeDecimal(v),
                currency: try CanonicalColumnCodec.decodeEnum(
                    Currency.self, rawValue: c, column: "market_value_currency"
                )
            )
        default:
            throw MarketSchemaError.priceColumnsDisagree(value: value, currency: currencyRaw)
        }
    }
}
