import XCTest
@testable import QiemanDashboard

/// GRDB-1 测试：DB lifecycle（打开/创建/迁移幂等）、schemaVersion 语义、
/// 迁移不可变清单（已发布 migration 只能追加，不能改写/删除/重排）。
final class CanonicalDatabaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - lifecycle

    func testOpen_createsDatabaseFileAndRunsMigrations() throws {
        let path = tempDir.appendingPathComponent("canonical.sqlite3").path
        let db = try CanonicalDatabase(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "打开后应落库文件")
        XCTAssertFalse(try db.hasPendingMigrations(), "新库应已跑到最新 schema")
        XCTAssertEqual(try db.appliedMigrations(), ["v1_baseline"])
    }

    func testReopen_isIdempotent_migrationsNotRerun() throws {
        let path = tempDir.appendingPathComponent("canonical.sqlite3").path
        _ = try CanonicalDatabase(path: path)
        // 第二次打开：已应用的同名 migration 必须跳过（GRDB 按名去重）
        let reopened = try CanonicalDatabase(path: path)
        XCTAssertEqual(try reopened.appliedMigrations(), ["v1_baseline"], "重开不得重复应用")
        XCTAssertFalse(try reopened.hasPendingMigrations())
    }

    func testInMemory_databaseWorksForTests() throws {
        let db = try CanonicalDatabase(inMemory: true)
        XCTAssertFalse(try db.hasPendingMigrations())
        XCTAssertEqual(try db.appliedMigrations(), ["v1_baseline"])
        XCTAssertEqual(db.queue.path, ":memory:", "内存库无落盘路径")
    }

    func testMissingParentDirectory_failsLoudly() throws {
        // 父目录不存在时打开必须抛错（路径拼错暴露，不静默落到别处）
        let badPath = tempDir
            .appendingPathComponent("no-such-dir")
            .appendingPathComponent("canonical.sqlite3").path
        XCTAssertThrowsError(try CanonicalDatabase(path: badPath))
    }

    // MARK: - schemaVersion 语义

    func testSchemaVersion_equalsRegisteredMigrationCount() {
        // schemaVersion 与已登记 migration 数量一致；GRDB-2..6 每追加一个
        // migration 时两侧同步 +1（此断言防只改一边）
        let migrations = CanonicalDatabase.makeMigrations().migrations
        XCTAssertEqual(
            CanonicalDatabase.schemaVersion,
            migrations.count,
            "schemaVersion(\(CanonicalDatabase.schemaVersion)) 应等于已登记 migration 数（\(migrations.count)）"
        )
    }

    func testMigrationIdentifiers_immutableRegistry() {
        // 迁移不可变清单：v1 起的既有 id 只能追加新 id，不能改名/删除/重排。
        // 已发布的库带着旧名记账，改名 = 老库全量重跑（数据破坏）。
        XCTAssertEqual(
            Array(CanonicalDatabase.makeMigrations().migrations.prefix(1)),
            ["v1_baseline"]
        )
    }

    // MARK: - 与 spool 目录约定的配合（GRDB-9 数据目录规划的前置）

    func testDatabaseFileLivesInV2WorkDirectoryConvention() throws {
        // Canonical 库落 investment-intelligence-v2/ 子目录（与 remote-staging
        // spool 同层）；这里只验证目录约定下打开可用，具体布局归 GRDB-9
        let dataDir = tempDir.appendingPathComponent("appdata", isDirectory: true)
        let v2Dir = dataDir.appendingPathComponent("investment-intelligence-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)
        let db = try CanonicalDatabase(
            path: v2Dir.appendingPathComponent("canonical.sqlite3").path
        )
        XCTAssertEqual(try db.appliedMigrations().count, CanonicalDatabase.schemaVersion)
    }
}
