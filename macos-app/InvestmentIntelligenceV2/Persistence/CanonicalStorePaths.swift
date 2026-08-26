import Foundation

// MARK: - CanonicalStorePaths（GRDB-9，数据目录规划）
//
// Canonical Store 在 App 数据目录下的落点：
//
// ```
// <AppData>/
// └─ investment-intelligence-v2/          ← V2 工作目录（与 remote-staging 同级）
//    ├─ canonical.sqlite3                 ← 本类型管辖（可删库重放，派生物）
//    ├─ remote-staging/                   ← RemoteStagingSyncPaths 管辖
//    │  ├─ spool.jsonl
//    │  └─ state.json
//    └─ user-intent/                      ← 用户意图事实源（不进 SQLite、不可重放）
//       ├─ allocation-targets/            ← StrategicAllocationTargetStore
//       │  ├─ <target-id>.json
//       │  └─ current.json
//       └─ asset-class-assignments/       ← StrategicAssetClassAssignmentStore
//          └─ <event-id>.json
// ```
//
// 分层语义：`CanonicalDatabase.init(path:)` 刻意要求父目录已存在（路径拼错
// 宁可失败暴露，不静默落到别处）——「数据目录布局由 App 侧统一负责」指的就是
// 本类型：建工作目录（幂等）+ 给出库文件 URL + 打开生产库的单一入口。
// GRDB-7 的 Repository 装配、Epic 6 的 Sync 循环都经 `openDatabase(in:)`
// 拿库，不各自拼路径。user-intent/ 是用户输入（Target / 资产分类）的事实源
// ——删库重放只重建派生的行情与 artifact，用户意图永不丢。

/// Canonical Store 的数据目录规划（纯函数命名空间 + 生产库打开入口）。
enum CanonicalStorePaths {

    /// 库文件名（App 数据目录约定唯一落点，见 RemoteStagingSyncPaths 同款布局）。
    static let databaseFileName = "canonical.sqlite3"

    /// V2 工作目录（<AppData>/investment-intelligence-v2/）。
    ///
    /// 与 `RemoteStagingSyncPaths.workDirectory` 前缀一致：spool 与库同住
    /// V2 目录——spool 是事实源、库是派生物（ADR-DATA004），删库重放走 spool。
    static func workDirectory(in dataDirectory: URL) -> URL {
        dataDirectory
            .appendingPathComponent("investment-intelligence-v2", isDirectory: true)
    }

    /// 库文件 URL（<AppData>/investment-intelligence-v2/canonical.sqlite3）。
    static func databaseURL(in dataDirectory: URL) -> URL {
        workDirectory(in: dataDirectory)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// 打开（或创建）生产库：幂等建工作目录 + 走 `CanonicalDatabase` 迁移。
    ///
    /// 降级保护语义随 `CanonicalDatabase.init`：库来自更新版本的 App 时抛
    /// `supersededByNewerSchema`，由调用方决定提示升级（不静默删库）。
    static func openDatabase(in dataDirectory: URL) throws -> CanonicalDatabase {
        try FileManager.default.createDirectory(
            at: workDirectory(in: dataDirectory),
            withIntermediateDirectories: true
        )
        return try CanonicalDatabase(path: databaseURL(in: dataDirectory).path)
    }
}
