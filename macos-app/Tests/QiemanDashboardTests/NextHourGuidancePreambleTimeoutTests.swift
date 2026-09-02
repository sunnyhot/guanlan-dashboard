import XCTest
@testable import QiemanDashboard

/// 2026-09-02 根治:前置阶段限时执行器——半开网络(连接建立但不出数据,
/// URLSession 空闲计时器被字节活动续命)不再让 .generating 永久挂起。
/// 当天 14:29 实证:点击「更新盘中研判」后 10 分钟零推进、无日志无失败写入。
@MainActor
final class NextHourGuidancePreambleTimeoutTests: XCTestCase {
    func testTimeoutFiresAndThrowsReadableError() async throws {
        // 操作挂起 10 秒,0.3 秒到点必须打断并给出可读错误
        let start = Date()
        do {
            _ = try await withNextHourPreambleTimeout(seconds: 0.3, kind: .dataRefresh) { () -> Int in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 1
            }
            XCTFail("应抛出超时错误")
        } catch let error as NextHourGuidancePreambleTimeoutError {
            XCTAssertEqual(error.kind, .dataRefresh)
            XCTAssertTrue(error.localizedDescription.contains("数据刷新"), "实际：\(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("网络"), "实际：\(error.localizedDescription)")
        } catch {
            XCTFail("应抛出超时错误，实际：\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "超时必须及时触发")
    }

    func testFastOperationReturnsValueWithoutTimeout() async throws {
        let start = Date()
        let value = try await withNextHourPreambleTimeout(seconds: 5, kind: .researchPreparation) { () -> Int in
            try await Task.sleep(nanoseconds: 50_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "计时器应被取消，不拖满时限")
    }

    func testOperationErrorPropagatesAsIs() async throws {
        struct Boom: Error {}
        do {
            _ = try await withNextHourPreambleTimeout(seconds: 5, kind: .dataRefresh) { () -> Int in
                throw Boom()
            }
            XCTFail("应抛出操作自身错误")
        } catch {
            XCTAssertTrue(error is Boom, "操作错误原样传播，不被吞成超时，实际：\(error)")
        }
    }

    func testCancellationSemanticsPreserved() async throws {
        do {
            _ = try await withNextHourPreambleTimeout(seconds: 5, kind: .dataRefresh) { () -> Int in
                throw CancellationError()
            }
            XCTFail("应抛出取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "取消语义保持，实际：\(error)")
        }
    }

    func testTimeoutConstantsStayGenerousForHealthyPaths() {
        // 健康路径:刷新 ~10-30s、探测一次 LLM 往返 ~5-30s、穿透命中缓存秒回。
        // 上限只拦半开连接,收紧前必须重估健康最慢路径。
        XCTAssertEqual(AppModel.nextHourDataRefreshTimeoutSeconds, 120)
        XCTAssertEqual(AppModel.nextHourResearchPreparationTimeoutSeconds, 120)
    }
}
