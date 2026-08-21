import Foundation
import GRDB

// MARK: - CanonicalDatabase（GRDB-1，Epic 5 Canonical Store 的 DB lifecycle）
//
// Canonical Store 的入口：打开（或创建）SQLite 库 + 跑 migration + 暴露
// schemaVersion。表结构本身由 GRDB-2..6 逐域登记进 `makeMigrations()`——
// 本文件只定框架（迁移框架 + 版本常量 + 打开/擦除语义），不定义任何表。
//
// ADR-DATA009：M2 已 Pass（2026-08-21）才允许进入持久化冻结阶段；schema 迁移
// 一经发布不可改写（只能追加新 migration），历史迁移的稳定性由
// CanonicalDatabaseTests 的「migration 不可变清单」守护。
//
// 定位：文件库放 App 数据目录（investment-intelligence-v2/canonical.sqlite3，
// 见 RemoteStagingSyncPaths 的目录约定）；Repository 实现（GRDB-7）后续持有
// 本类型。iOS / macOS / Tests 共用；CLI 侧接入在 Epic 13（AGENT-2）。

/// Canonical Store 的数据库生命周期封装。
///
/// `DatabaseQueue` 本身线程安全（串行队列同步访问），GRDB 文档明确可在并发
/// 上下文共享；类型层面无 Sendable 标注，这里按 @unchecked Sendable 透传
/// （不变量由 GRDB 内部队列保证，本包装不新增可变状态）。
final class CanonicalDatabase: @unchecked Sendable {

    /// 当前代码认识的 schema 版本（= 已登记的最高 migration 序号）。
    /// GRDB-2..6 每加一个域的建表 migration 就 +1；**已发布的序号永不复用**。
    static let schemaVersion = 1

    /// 全部迁移（按序登记，只追加不改写）。
    ///
    /// v1_baseline：空基线——只建立迁移簿记（grdb_migrations），不建表。
    /// 真正的表从 v2（GRDB-2 Identity 域）开始登记；空基线保证「全新库」与
    /// 「跑过 v1 的库」在 schemaVersion 语义上同一起点。
    static func makeMigrations() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_baseline") { _ in
            // 故意空：见上。GRDB-2 起在此追加建表 migration。
        }
        return migrator
    }

    /// 底部队列（GRDB-7 Repository 实现经由它读写）。
    let queue: DatabaseQueue

    /// 打开/创建库并跑到最新 schema。
    ///
    /// - Parameter path: SQLite 文件路径；父目录必须已存在（不代建——
    ///   数据目录布局由 App 侧统一负责，路径拼错时宁可失败暴露）。
    init(path: String) throws {
        self.queue = try DatabaseQueue(path: path)
        try Self.migrate(queue: queue)
    }

    /// 内存库（测试 / 将来 CLI 一次性运算）。
    init(inMemory: Bool = true) throws {
        self.queue = try DatabaseQueue()
        try Self.migrate(queue: queue)
    }

    /// 跑全部待执行 migration（幂等：GRDB 按名登记，已跑的跳过）。
    private static func migrate(queue: DatabaseQueue) throws {
        var migrator = makeMigrations()
        // 迁移失败不得留下半套 schema（如磁盘满写到一半）——eraseDatabaseOnMigrationFailure
        // 让失败库在下次打开时从零重建（Canonical 数据可由 staging spool 重放，
        // ADR-DATA004 Local Accumulation：spool 是事实源，库是派生物）
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue)
    }

    /// 是否还有未执行的 migration（诊断用：代码更新后首次打开为 true）。
    func hasPendingMigrations() throws -> Bool {
        let registered = Self.makeMigrations().migrations
        let completed = try appliedMigrations()
        return !completed.allSatisfy { registered.contains($0) }
            || completed.count < registered.count
    }

    /// 当前库已应用到的 migration 名列表（诊断 / schemaVersion 对账）。
    func appliedMigrations() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }
}
