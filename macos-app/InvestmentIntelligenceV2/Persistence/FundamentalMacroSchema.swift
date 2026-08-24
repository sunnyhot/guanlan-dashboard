import Foundation
import GRDB

// MARK: - FundamentalMacroSchema（GRDB-5，基本面 / 宏观域）
//
// 2 张表：fundamental_observations / macro_observations。
//
// - **对齐 FRED vintage**（ADR-DATA008）：宏观指标同一 effectiveAt 多次发布
//   （advance / second / third）= 不同 vintage 的多行，economicKnowledge 取
//   可知最新；exactSnapshot 全可见。
// - **基本面事实身份**（REPO-1b 语义）：同一事实 = (entity, metricKey, unit,
//   periodStart, periodEnd) + vintage。**concept 不进唯一键**——公司换 XBRL
//   标签的年份，同事实两段历史靠 metricKey 归并，concept 只是审计痕迹
//   （PROV-4 逐事实概念选择语义）。
// - **NULL 陷阱**：period_start 可空（时点项），SQLite 唯一索引把 NULL 视为
//   互不相等——两条同键 NULL 行不会撞约束。唯一索引用
//   `COALESCE(period_start, '')` 表达式索引封死该洞（测试守护）。
// - 外键：entity_id → legal_entities（SEC CIK 的 Canonical 目标）、
//   indicator_id → instruments（宏观指标注册为 index kind 的 Instrument）。

/// Fundamental / Macro 域 schema（migration v5_fundamental_macro 的建表体）。
enum FundamentalMacroSchema {

    /// 建全部 Fundamental / Macro 表 + 索引（migration 调用；只追加不改写）。
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE fundamental_observations (
                id                          TEXT PRIMARY KEY NOT NULL,
                entity_id                   TEXT NOT NULL REFERENCES legal_entities(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                metric_key                  TEXT NOT NULL,
                concept                     TEXT NOT NULL,
                value                       TEXT NOT NULL,
                unit                        TEXT NOT NULL,
                period_start                TEXT,
                period_end                  TEXT NOT NULL,
                form                        TEXT NOT NULL,
                frame                       TEXT,
                extraction_method           TEXT NOT NULL
            )
            """)
        // 事实身份唯一键：NULL period_start 经 COALESCE 封口（见文件头）；
        // effectiveAt == periodEnd（PROV-4），不重复出现在键里
        try db.execute(sql: """
            CREATE UNIQUE INDEX fundamental_observations_fact_identity_uq
                ON fundamental_observations(
                    entity_id, metric_key, unit,
                    COALESCE(period_start, ''), period_end,
                    vintage_announcement_date, vintage_publisher_version
                )
            """)
        // economic 查询热路径：按实体 + 指标取期间分组
        try db.execute(sql: """
            CREATE INDEX fundamental_observations_entity_metric_idx
                ON fundamental_observations(entity_id, metric_key, period_end)
            """)

        try db.execute(sql: """
            CREATE TABLE macro_observations (
                id                          TEXT PRIMARY KEY NOT NULL,
                indicator_id                TEXT NOT NULL REFERENCES instruments(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                value                       TEXT NOT NULL,
                unit                        TEXT NOT NULL,
                frequency                   TEXT NOT NULL,
                is_seasonally_adjusted      INTEGER NOT NULL,
                base_period_json            TEXT
            )
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX macro_observations_identity_uq
                ON macro_observations(
                    indicator_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version
                )
            """)
        try db.execute(sql: """
            CREATE INDEX macro_observations_indicator_idx
                ON macro_observations(indicator_id, effective_at)
            """)
    }
}

// MARK: - 行类型

struct FundamentalObservationRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "fundamental_observations"

    let id: String
    let entityID: String
    let envelope: ObservationEnvelopeColumns
    let metricKey: String
    let concept: String
    let value: String
    let unit: String
    let periodStart: String?
    let periodEnd: String
    let form: String
    let frame: String?
    let extractionMethod: String

    init(row: Row) {
        id = row["id"]
        entityID = row["entity_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        metricKey = row["metric_key"]
        concept = row["concept"]
        value = row["value"]
        unit = row["unit"]
        periodStart = row["period_start"]
        periodEnd = row["period_end"]
        form = row["form"]
        frame = row["frame"]
        extractionMethod = row["extraction_method"]
    }

    init(
        id: String,
        entityID: String,
        envelope: ObservationEnvelopeColumns,
        metricKey: String,
        concept: String,
        value: String,
        unit: String,
        periodStart: String?,
        periodEnd: String,
        form: String,
        frame: String?,
        extractionMethod: String
    ) {
        self.id = id
        self.entityID = entityID
        self.envelope = envelope
        self.metricKey = metricKey
        self.concept = concept
        self.value = value
        self.unit = unit
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.form = form
        self.frame = frame
        self.extractionMethod = extractionMethod
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["entity_id"] = entityID
        envelope.encode(to: &container)
        container["metric_key"] = metricKey
        container["concept"] = concept
        container["value"] = value
        container["unit"] = unit
        container["period_start"] = periodStart
        container["period_end"] = periodEnd
        container["form"] = form
        container["frame"] = frame
        container["extraction_method"] = extractionMethod
    }

    static func from(_ domain: FundamentalObservation) -> FundamentalObservationRow {
        FundamentalObservationRow(
            id: domain.id.rawValue,
            entityID: domain.entityID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            metricKey: domain.metricKey,
            concept: domain.concept,
            value: CanonicalColumnCodec.encodeDecimal(domain.value),
            unit: domain.unit,
            periodStart: domain.periodStart.map { CanonicalColumnCodec.encodeTimestamp($0) },
            periodEnd: CanonicalColumnCodec.encodeTimestamp(domain.periodEnd),
            form: domain.form.rawValue,
            frame: domain.frame,
            extractionMethod: domain.extractionMethod.rawValue
        )
    }

    func toDomain() throws -> FundamentalObservation {
        try FundamentalObservation(
            id: ObservationID(rawValue: id),
            entityID: LegalEntityID(rawValue: entityID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            metricKey: metricKey,
            concept: concept,
            value: try CanonicalColumnCodec.decodeDecimal(value),
            unit: unit,
            periodStart: try periodStart.map { try CanonicalColumnCodec.decodeTimestamp($0) },
            periodEnd: try CanonicalColumnCodec.decodeTimestamp(periodEnd),
            form: CanonicalColumnCodec.decodeEnum(
                FundamentalObservation.FilingForm.self, rawValue: form, column: "form"
            ),
            frame: frame,
            extractionMethod: CanonicalColumnCodec.decodeEnum(
                EvidenceExtractionMethod.self, rawValue: extractionMethod, column: "extraction_method"
            )
        )
    }
}

struct MacroObservationRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "macro_observations"

    let id: String
    let indicatorID: String
    let envelope: ObservationEnvelopeColumns
    let value: String
    let unit: String
    let frequency: String
    let isSeasonallyAdjusted: Bool
    let basePeriodJSON: String?

    init(row: Row) {
        id = row["id"]
        indicatorID = row["indicator_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        value = row["value"]
        unit = row["unit"]
        frequency = row["frequency"]
        isSeasonallyAdjusted = row["is_seasonally_adjusted"]
        basePeriodJSON = row["base_period_json"]
    }

    init(
        id: String,
        indicatorID: String,
        envelope: ObservationEnvelopeColumns,
        value: String,
        unit: String,
        frequency: String,
        isSeasonallyAdjusted: Bool,
        basePeriodJSON: String?
    ) {
        self.id = id
        self.indicatorID = indicatorID
        self.envelope = envelope
        self.value = value
        self.unit = unit
        self.frequency = frequency
        self.isSeasonallyAdjusted = isSeasonallyAdjusted
        self.basePeriodJSON = basePeriodJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["indicator_id"] = indicatorID
        envelope.encode(to: &container)
        container["value"] = value
        container["unit"] = unit
        container["frequency"] = frequency
        container["is_seasonally_adjusted"] = isSeasonallyAdjusted
        container["base_period_json"] = basePeriodJSON
    }

    static func from(_ domain: MacroObservation) throws -> MacroObservationRow {
        MacroObservationRow(
            id: domain.id.rawValue,
            indicatorID: domain.indicatorID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            value: CanonicalColumnCodec.encodeDecimal(domain.value),
            unit: domain.unit.rawValue,
            frequency: domain.frequency.rawValue,
            isSeasonallyAdjusted: domain.isSeasonallyAdjusted,
            basePeriodJSON: try domain.basePeriod.map {
                try CanonicalColumnCodec.encodeJSON($0)
            }
        )
    }

    func toDomain() throws -> MacroObservation {
        try MacroObservation(
            id: ObservationID(rawValue: id),
            indicatorID: InstrumentID(rawValue: indicatorID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            value: try CanonicalColumnCodec.decodeDecimal(value),
            unit: CanonicalColumnCodec.decodeEnum(
                MacroObservation.MacroUnit.self, rawValue: unit, column: "unit"
            ),
            frequency: CanonicalColumnCodec.decodeEnum(
                MacroObservation.MacroFrequency.self, rawValue: frequency, column: "frequency"
            ),
            isSeasonallyAdjusted: isSeasonallyAdjusted,
            basePeriod: try basePeriodJSON.map {
                try CanonicalColumnCodec.decodeJSON(
                    MacroObservation.MacroBasePeriod.self, from: $0
                )
            }
        )
    }
}
