import XCTest
@testable import QiemanDashboard

final class ContractFixtureTests: XCTestCase {
    func testPostSnapshotFixtureMatchesSwiftNormalizer() throws {
        let raw = try loadJSONFixture(named: "post-snapshot.json")
        let fixtureURL = try fixtureURL(named: "post-snapshot", extension: "json")

        let payload = NativeSnapshotStore().snapshot(
            from: raw,
            fileURL: fixtureURL,
            createdAt: "2026-06-12 12:00:00",
            includeRecords: true
        )

        XCTAssertEqual(payload.snapshotType, "posts")
        XCTAssertEqual(payload.mode, "group-manager")
        XCTAssertEqual(payload.title, "ETF拯救世界")
        XCTAssertEqual(payload.subtitle, "长赢指数投资计划")
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload.records.first?.postId, 9001)
        XCTAssertEqual(payload.records.first?.title, "本周调仓说明")
        XCTAssertEqual(payload.stats?.count, 2)
    }

    private func loadJSONFixture(named name: String) throws -> Any {
        let url = try fixtureURL(named: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, extension: "json")
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
    }
}
