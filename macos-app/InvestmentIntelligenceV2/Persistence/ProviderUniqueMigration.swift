import Foundation
import GRDB

// MARK: - ProviderUniqueMigration（GRDB-7 前置，migration v7）
//
// **修正 GRDB-3/4/5 唯一索引漏掉 provider 维度的问题**：
//
// 原索引 (维度键, effective_at, vintage) 唯一——但 REPO-2b（2026-08-12 审查
// 新增，晚于 DATA008 ADR 成文）的语义是「同 effectiveAt+vintage **跨 Provider**
// 各存一行、查询时按 reliability → providerID → id 确定性择优」。原索引会把
// 第二家 Provider 的行直接拒收，跨源去重退化为跨源丢弃。
//
// 修正后的唯一键 = (维度键, effective_at, vintage, source_provider_id)：
// - 同 Provider 同 (维度, vintage) 的唯一性由 schema 保证；GRDBRepository
//   写入路径在该键上做显式冲突处理（同内容幂等 / 异内容拒收，见
//   GRDBRepository 的写入语义注释）；
// - 跨 Provider 共存，查询择优走 ObservationQuerySemantics（单一权威）。
//
// 落地方式（迁移只追加不改写）：
// - v3/v4 的 UNIQUE 是**内联表约束**（SQLite 自动索引，不能 DROP INDEX），
//   走标准重建：建新表（不带内联 UNIQUE）→ 拷数据 → DROP 旧表 → RENAME。
//   FK 在事务内用 `PRAGMA defer_foreign_keys = ON` 延迟到提交校验；
//   RENAME 自动改写 holding_positions 对 holding_snapshots 的 FK 引用。
// - v5 的唯一索引是**显式 CREATE UNIQUE INDEX**，直接 DROP + 重建。

/// migration v7_provider_unique 的建表体。
enum ProviderUniqueMigration {

    static func create(in db: Database) throws {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

        // MARK: daily_bars（v3 内联 UNIQUE → 重建）

        try db.execute(sql: """
            CREATE TABLE daily_bars_v7 (
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
                fx_rate                 TEXT
            )
            """)
        try db.execute(sql: "INSERT INTO daily_bars_v7 SELECT * FROM daily_bars")
        try db.execute(sql: "DROP TABLE daily_bars")
        try db.execute(sql: "ALTER TABLE daily_bars_v7 RENAME TO daily_bars")
        try db.execute(sql: """
            CREATE UNIQUE INDEX daily_bars_provider_identity_uq
                ON daily_bars(listing_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        // MARK: nav_observations（v3 内联 UNIQUE → 重建）

        try db.execute(sql: """
            CREATE TABLE nav_observations_v7 (
                id                              TEXT PRIMARY KEY NOT NULL,
                share_class_id                  TEXT NOT NULL REFERENCES fund_share_classes(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                nav_currency                    TEXT NOT NULL,
                unit_nav                        TEXT NOT NULL,
                accumulated_nav                 TEXT,
                cumulative_dividend_per_share   TEXT
            )
            """)
        try db.execute(sql: "INSERT INTO nav_observations_v7 SELECT * FROM nav_observations")
        try db.execute(sql: "DROP TABLE nav_observations")
        try db.execute(sql: "ALTER TABLE nav_observations_v7 RENAME TO nav_observations")
        try db.execute(sql: """
            CREATE UNIQUE INDEX nav_observations_provider_identity_uq
                ON nav_observations(share_class_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        // MARK: corporate_actions（v3 内联 UNIQUE → 重建）

        try db.execute(sql: """
            CREATE TABLE corporate_actions_v7 (
                id                      TEXT PRIMARY KEY NOT NULL,
                listing_id              TEXT NOT NULL REFERENCES listings(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                kind                    TEXT NOT NULL,
                ex_date                 TEXT NOT NULL,
                record_date             TEXT,
                pay_date                TEXT,
                ratio                   TEXT NOT NULL,
                action_currency         TEXT
            )
            """)
        try db.execute(sql: "INSERT INTO corporate_actions_v7 SELECT * FROM corporate_actions")
        try db.execute(sql: "DROP TABLE corporate_actions")
        try db.execute(sql: "ALTER TABLE corporate_actions_v7 RENAME TO corporate_actions")
        try db.execute(sql: """
            CREATE INDEX corporate_actions_listing_exdate_idx
                ON corporate_actions(listing_id, ex_date)
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX corporate_actions_provider_identity_uq
                ON corporate_actions(listing_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        // MARK: holding_snapshots（v4 内联 UNIQUE → 重建；holding_positions FK 延迟）

        try db.execute(sql: """
            CREATE TABLE holding_snapshots_v7 (
                id                      TEXT PRIMARY KEY NOT NULL,
                product_id              TEXT NOT NULL REFERENCES fund_products(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                report_period           TEXT NOT NULL,
                disclosed_weight_total  TEXT NOT NULL
            )
            """)
        try db.execute(sql: "INSERT INTO holding_snapshots_v7 SELECT * FROM holding_snapshots")
        try db.execute(sql: "DROP TABLE holding_snapshots")
        try db.execute(sql: "ALTER TABLE holding_snapshots_v7 RENAME TO holding_snapshots")
        try db.execute(sql: """
            CREATE UNIQUE INDEX holding_snapshots_provider_identity_uq
                ON holding_snapshots(product_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        // MARK: allocation_snapshots（v4 内联 UNIQUE → 重建）

        try db.execute(sql: """
            CREATE TABLE allocation_snapshots_v7 (
                id                  TEXT PRIMARY KEY NOT NULL,
                product_id          TEXT NOT NULL REFERENCES fund_products(id),
                \(ObservationEnvelopeColumns.ddlColumns),
                report_period       TEXT NOT NULL,
                allocations_json    TEXT NOT NULL
            )
            """)
        try db.execute(sql: "INSERT INTO allocation_snapshots_v7 SELECT * FROM allocation_snapshots")
        try db.execute(sql: "DROP TABLE allocation_snapshots")
        try db.execute(sql: "ALTER TABLE allocation_snapshots_v7 RENAME TO allocation_snapshots")
        try db.execute(sql: """
            CREATE UNIQUE INDEX allocation_snapshots_provider_identity_uq
                ON allocation_snapshots(product_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        // MARK: v5 的显式索引（无需重建表）

        try db.execute(sql: "DROP INDEX macro_observations_identity_uq")
        try db.execute(sql: """
            CREATE UNIQUE INDEX macro_observations_provider_identity_uq
                ON macro_observations(indicator_id, effective_at,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id)
            """)

        try db.execute(sql: "DROP INDEX fundamental_observations_fact_identity_uq")
        try db.execute(sql: """
            CREATE UNIQUE INDEX fundamental_observations_fact_identity_uq
                ON fundamental_observations(
                    entity_id, metric_key, unit,
                    COALESCE(period_start, ''), period_end,
                    vintage_announcement_date, vintage_publisher_version, source_provider_id
                )
            """)
    }
}
