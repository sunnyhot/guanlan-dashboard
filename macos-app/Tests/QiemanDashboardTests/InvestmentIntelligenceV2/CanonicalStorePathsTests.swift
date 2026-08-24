import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-9 测试：Canonical Store 数据目录规划——库落点与 remote-staging
/// 同住 V2 工作目录（spool 是事实源、库是派生物，ADR-DATA004）、
/// openDatabase 建目录幂等、重开迁移不重跑。
final class CanonicalStorePathsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDatabaseURL_livesInV2WorkDirectory() {
        let appData = tempDir.appendingPathComponent("appdata", isDirectory: true)
        XCTAssertEqual(
            CanonicalStorePaths.databaseURL(in: appData).path,
            appData
                .appendingPathComponent("investment-intelligence-v2", isDirectory: true)
                .appendingPathComponent("canonical.sqlite3", isDirectory: false)
                .path
        )
        // 与 remote-staging spool 同住 V2 工作目录（事实源与派生物同区，
        // 删库重放路径不跨区）
        XCTAssertEqual(
            CanonicalStorePaths.workDirectory(in: appData),
            RemoteStagingSyncPaths.workDirectory(in: appData)
                .deletingLastPathComponent()
        )
    }

    func testOpenDatabase_createsWorkDirectoryAndMigrates() throws {
        let appData = tempDir.appendingPathComponent("fresh-app", isDirectory: true)
        // 父目录不存在也不怕：openDatabase 幂等建工作目录
        let db = try CanonicalStorePaths.openDatabase(in: appData)
        XCTAssertEqual(try db.migrationState(), .current)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: CanonicalStorePaths.databaseURL(in: appData).path
            ),
            "库文件应落在规划路径"
        )

        // 重开：迁移不重跑
        let reopened = try CanonicalStorePaths.openDatabase(in: appData)
        XCTAssertEqual(
            try reopened.appliedMigrations(),
            Array(CanonicalDatabase.makeMigrations().migrations)
        )
    }

    /// spool 与库共存一区：remote-staging 子目录不被库打开影响（布局互不侵占）。
    func testLayout_coexistsWithRemoteStagingSpool() throws {
        let appData = tempDir.appendingPathComponent("both", isDirectory: true)
        let spool = RemoteStagingSyncPaths.spoolURL(in: appData)
        try FileManager.default.createDirectory(
            at: spool.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".data(using: .utf8)!).write(to: spool)

        let db = try CanonicalStorePaths.openDatabase(in: appData)
        XCTAssertEqual(try db.migrationState(), .current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.path), "spool 不受影响")
    }
}
