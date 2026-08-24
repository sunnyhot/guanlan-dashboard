import Foundation
import GRDB

// MARK: - CanonicalDatabase（GRDB-1，Epic 5 Canonical Store 的 DB lifecycle）
//
// Canonical Store 的入口：打开（或创建）SQLite 库 + 降级预检 + 跑 migration +
// 暴露 schemaVersion。表结构本身由 GRDB-2..6 逐域登记进 `makeMigrations()`——
// 本文件只定框架（迁移框架 + 版本常量 + 打开/状态语义），不定义任何表。
//
// ADR-DATA009：M2 已 Pass（2026-08-21）才允许进入持久化冻结阶段；schema 迁移
// 一经发布不可改写（只能追加新 migration），历史迁移的稳定性由
// CanonicalDatabaseTests 的「migration 不可变清单」守护。
//
// 定位：文件库放 App 数据目录（investment-intelligence-v2/canonical.sqlite3，
// 见 RemoteStagingSyncPaths 的目录约定）；Repository 实现（GRDB-7）后续持有
// 本类型。iOS / macOS / Tests 共用；CLI 侧接入在 Epic 13（AGENT-2）。

/// Canonical Store 打不开库时的错误。
enum CanonicalDatabaseError: Error, Equatable {
    /// **降级保护**：库带着本代码不认识的 migration（由更新版本的 App 写入）。
    /// 老代码继续迁移/读写会把新库置于未知状态——拒绝打开，等用户升级 App
    ///（或明确删库走 spool 重放恢复，见 migrate(queue:) 的语义注释）。
    case supersededByNewerSchema(unknownMigrations: [String])
}

/// 库相对当前代码迁移清单的状态。
enum CanonicalMigrationState: Equatable {
    /// 已应用全部已登记 migration，且无未知项
    case current
    /// 有本代码认识、库尚未应用的 migration（代码升级后首次打开前可见；
    /// `CanonicalDatabase` 初始化会自动跑完，正常路径不该长期停留在此态）
    case pending(count: Int)
    /// 库含有本代码不认识的 migration（来自更新版本）
    case superseded(unknownMigrations: [String])
}

/// Canonical Store 的数据库生命周期封装。
///
/// `DatabaseQueue` 本身线程安全（串行队列同步访问），GRDB 文档明确可在并发
/// 上下文共享；类型层面无 Sendable 标注，这里按 @unchecked Sendable 透传
/// （不变量由 GRDB 内部队列保证，本包装不新增可变状态）。
final class CanonicalDatabase: @unchecked Sendable {

    /// 当前代码认识的 schema 版本（= 已登记的最高 migration 序号）。
    /// GRDB-2..6 每加一个域的建表 migration 就 +1；**已发布的序号永不复用**。
    static let schemaVersion = 2

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
        // v2（GRDB-2）：Identity 域 7 表（ADR-DATA001 §7-14）。
        migrator.registerMigration("v2_identity") { db in
            try IdentitySchema.create(in: db)
        }
        return migrator
    }

    /// 底部队列（GRDB-7 Repository 实现经由它读写）。
    let queue: DatabaseQueue

    /// 打开/创建文件库并跑到最新 schema。
    ///
    /// - Parameter path: SQLite 文件路径；父目录必须已存在（不代建——
    ///   数据目录布局由 App 侧统一负责，路径拼错时宁可失败暴露）。
    /// - Throws: `CanonicalDatabaseError.supersededByNewerSchema`——降级预检
    ///   （**在自动迁移之前**）发现库来自更新版本时拒绝打开。
    init(path: String) throws {
        self.queue = try DatabaseQueue(path: path)
        if case .superseded(let unknown) = try Self.migrationState(of: queue) {
            throw CanonicalDatabaseError.supersededByNewerSchema(unknownMigrations: unknown)
        }
        try Self.migrate(queue: queue)
    }

    /// 内存库（测试 / 将来 CLI 一次性运算）。刻意不提供 `inMemory: Bool`
    /// 开关——布尔参数既无法表达落盘路径、误传 false 又会静默得到易失库。
    init() throws {
        self.queue = try DatabaseQueue()
        try Self.migrate(queue: queue)
    }

    /// 跑全部待执行 migration（幂等：GRDB 按名登记，已跑的跳过）。
    ///
    /// 失败语义（GRDB 的实际行为，如实记录，不另造重建流程——审查 P2 修正）：
    /// - 每个 migration 运行在**独立事务**里：失败的那个原子回滚（磁盘满 /
    ///   中断不会留下半套表），此前已成功的 migration 保留；
    /// - 下次打开按名重试失败项（不重跑已成功项）；
    /// - `eraseDatabaseOnSchemaChange` 是 GRDB 的**开发期**便利开关（migration
    ///   内容被改写时擦库重来），生产开启等于允许毁数据，保持默认关闭；
    /// - 「库可由 staging spool 重放重建」（ADR-DATA004：spool 是事实源，
    ///   库是派生物）是**运维恢复路径**，不在代码里自动执行——瞬时 IO 故障
    ///   不应被自动升级为整库擦除。
    private static func migrate(queue: DatabaseQueue) throws {
        try makeMigrations().migrate(queue)
    }

    /// 库相对当前代码迁移清单的状态（基于 GRDB 的
    /// `hasCompletedMigrations` / `hasBeenSuperseded`，审查 P2 修正——
    /// 原手写 allSatisfy/count 比较把「降级库」误报成「待执行」）。
    ///
    /// 可对任意 DatabaseQueue 调用（含尚未迁移的裸库）——`CanonicalDatabase`
    /// 初始化后必然是 `.current`，`.pending` 只在自动迁移前的窗口可见。
    static func migrationState(of queue: DatabaseQueue) throws -> CanonicalMigrationState {
        let migrator = makeMigrations()
        return try queue.read { db in
            if try migrator.hasBeenSuperseded(db) {
                let unknown = try migrator.appliedIdentifiers(db)
                    .subtracting(migrator.migrations)
                    .sorted()
                return .superseded(unknownMigrations: unknown)
            }
            guard try migrator.hasCompletedMigrations(db) else {
                let completed = try migrator.completedMigrations(db).count
                return .pending(count: migrator.migrations.count - completed)
            }
            return .current
        }
    }

    /// 本库相对当前代码的状态（初始化自动迁移后正常为 `.current`）。
    func migrationState() throws -> CanonicalMigrationState {
        try Self.migrationState(of: queue)
    }

    /// 当前库已应用到的 migration 名列表（诊断 / schemaVersion 对账）。
    /// 与 `CanonicalMigrationState` 互补：这里按 id 原样列出（含未来版本的
    /// 未知项），状态判读请用 `migrationState()`。
    func appliedMigrations() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }
}
