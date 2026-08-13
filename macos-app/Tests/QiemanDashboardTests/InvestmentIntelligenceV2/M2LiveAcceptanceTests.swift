import XCTest
@testable import QiemanDashboard

/// M2 真 gate：使用天天基金历史持仓/公告 API 与 Stooq CSV 端点，贯穿
/// ProviderRecord → ObservationFactory → InMemoryRepository。
///
/// 这些测试故意不注入 StaticResponseFetcher，也不把网络失败转成 XCTSkip。
/// 免费 Provider 被风控或返回契约漂移时，测试必须失败并保留原因；在此之前
/// 不得把 M2 标记为通过（ADR-DATA009 / ADR-DATA006）。
final class M2LiveAcceptanceTests: XCTestCase {

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return (2...6).contains(weekday)
        }

        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date
            var remaining = max(offset, 0)
            var safety = 0
            while remaining > 0 && safety < 30 {
                current = calendar.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
                safety += 1
            }
            return current
        }

        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar.startOfDay(for: date)
        }
    }

    private let calendar = WeekdayCalendar()
    private let fundCode = "110022"

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(
            for: calendar.date(from: DateComponents(year: year, month: month, day: day))!
        )
    }

    private func dateText(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }

    private func liveHoldingRecord(ingestedAt: Date) async throws -> ProviderRecord {
        let adapter = EastmoneyHistoricalHoldingProviderAdapter(
            fetcher: URLSessionResponseFetcher(),
            reportDate: date(2024, 6, 30),
            ingestedAt: { ingestedAt }
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: fundCode),
            from: date(2024, 6, 30),
            to: date(2024, 6, 30)
        )
        guard let record = records.first else {
            throw M2LiveTestError.noHistoricalHoldingRecord
        }
        return record
    }

    private func resolver(for payload: FundHoldingPayload) -> IdentityResolver {
        let resolvedAt = date(2024, 6, 30)
        var identifiers: [ProviderIdentifier] = [
            ProviderIdentifier(
                providerID: .eastmoney,
                identifierScheme: "fund_code",
                identifierValue: fundCode,
                canonical: .fundProduct(FundProductID(rawValue: "prod_110022")),
                resolutionMethod: .manualVerified,
                resolvedAt: resolvedAt
            ),
            // Stooq's live symbol for the Shanghai listing is 600519.cn.
            ProviderIdentifier(
                providerID: .stooq,
                identifierScheme: "stock_symbol",
                identifierValue: "600519.cn",
                canonical: .listing(ListingID(rawValue: "list_sh600519")),
                resolutionMethod: .exchangeSymbolExact,
                resolvedAt: resolvedAt
            )
        ]

        for position in payload.positions {
            let value = position.providerCode.value
            let listingID = value == "600519"
                ? ListingID(rawValue: "list_sh600519")
                : ListingID(rawValue: "live_\(position.providerCode.scheme)_\(value)")
            identifiers.append(ProviderIdentifier(
                providerID: position.providerID,
                identifierScheme: position.providerCode.scheme,
                identifierValue: value,
                canonical: .listing(listingID),
                resolutionMethod: .manualVerified,
                resolvedAt: resolvedAt
            ))
        }
        return IdentityResolver.from(identifiers)
    }

    private func factory(for resolver: IdentityResolver) -> ObservationFactory {
        ObservationFactory(
            normalizer: TemporalNormalizer(calendar: calendar),
            resolver: resolver
        )
    }

    private func snapshot(
        from record: ProviderRecord,
        id: String,
        vintage: Vintage,
        resolver: IdentityResolver
    ) throws -> FundHoldingSnapshot {
        let result = try factory(for: resolver).makeObservation(
            from: record,
            observationID: ObservationID(rawValue: id),
            vintage: vintage
        )
        guard case .fundHoldingSnapshot(let snapshot) = result else {
            throw M2LiveTestError.unexpectedObservationKind
        }
        return snapshot
    }

    // MARK: - 场景 1：天天基金持仓股票 + Stooq 日线 → 同一 ListingID

    func testM2LiveScenario1_eastmoneyAndStooqResolveSameListing() async throws {
        do {
            let holdingRecord = try await liveHoldingRecord(ingestedAt: date(2024, 7, 22))
            let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: holdingRecord.rawPayload)
            XCTAssertTrue(
                payload.positions.contains { $0.providerID == .eastmoney && $0.providerCode.value == "600519" },
                "真实天天基金 Q2 持仓应包含 600519，实际代码：\(payload.positions.map { $0.providerCode.value })"
            )

            let resolver = resolver(for: payload)
            guard case .resolved(let eastmoneyRef, _) = resolver.resolve(
                providerID: .eastmoney,
                scheme: "stock_symbol",
                value: "600519"
            ) else {
                XCTFail("真实天天基金股票代码 600519 未能解析")
                return
            }

            let stooq = StooqProviderAdapter(fetcher: URLSessionResponseFetcher())
            let records = try await stooq.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "600519.cn"),
                from: date(2024, 7, 1),
                to: date(2024, 7, 31)
            )
            XCTAssertFalse(records.isEmpty, "Stooq 真实 CSV 应返回 600519.cn 日线")
            guard case .resolved(let stooqRef, _) = resolver.resolve(
                providerID: .stooq,
                scheme: "stock_symbol",
                value: "600519.cn"
            ) else {
                XCTFail("真实 Stooq 代码 600519.cn 未能解析")
                return
            }
            XCTAssertEqual(eastmoneyRef, stooqRef)

            // 至少把真实两端都送入 Canonical pipeline，防止只测 resolver lookup。
            _ = try snapshot(
                from: holdingRecord,
                id: "m2_live_s1_holding",
                vintage: Vintage(announcementDate: holdingRecord.publishedAt, publisherVersion: 1),
                resolver: resolver
            )
            if let dailyRecord = records.first {
                let dailyResult = try factory(for: resolver).makeObservation(
                    from: dailyRecord,
                    observationID: ObservationID(rawValue: "m2_live_s1_daily"),
                    vintage: Vintage(announcementDate: dailyRecord.publishedAt, publisherVersion: 1)
                )
                guard case .dailyBar = dailyResult else {
                    XCTFail("Stooq ProviderRecord 未转换为 DailyBar")
                    return
                }
            }
        } catch {
            XCTFail("M2 场景 1 真实链路阻塞：\(error)")
        }
    }

    // MARK: - 场景 2：2024-07-20 公告 → 07-22；07-10 不可见

    func testM2LiveScenario2_q2DisclosurePIT() async throws {
        do {
            let record = try await liveHoldingRecord(ingestedAt: date(2024, 7, 22))
            let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload)
            let resolver = resolver(for: payload)
            let observation = try snapshot(
                from: record,
                id: "m2_live_s2",
                vintage: Vintage(announcementDate: record.publishedAt, publisherVersion: 1),
                resolver: resolver
            )
            let repo = InMemoryRepository(calendarBackend: calendar)
            repo.upsert(observation)

            let expectedAnnouncement = date(2024, 7, 20)
            let expectedAvailable = date(2024, 7, 22)
            XCTAssertEqual(
                record.publishedAt,
                expectedAnnouncement,
                "天天基金公告 API 实际返回 \(dateText(record.publishedAt))，不是 M2 要求的 2024-07-20"
            )
            XCTAssertEqual(observation.temporalEnvelope.availableAt, expectedAvailable)
            XCTAssertTrue(repo.holdingSnapshots(
                productID: FundProductID(rawValue: "prod_110022"),
                context: .economicKnowledge(asOf: date(2024, 7, 10))
            ).isEmpty)
            XCTAssertFalse(repo.holdingSnapshots(
                productID: FundProductID(rawValue: "prod_110022"),
                context: .economicKnowledge(asOf: expectedAvailable)
            ).isEmpty)
        } catch {
            XCTFail("M2 场景 2 真实链路阻塞：\(error)")
        }
    }

    // MARK: - 场景 3：延迟抓取下 economic / operational 分流

    func testM2LiveScenario3_delayedIngestionSplitsKnowledgeModes() async throws {
        do {
            let record = try await liveHoldingRecord(ingestedAt: date(2024, 8, 1))
            let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload)
            let resolver = resolver(for: payload)
            let observation = try snapshot(
                from: record,
                id: "m2_live_s3",
                vintage: Vintage(announcementDate: record.publishedAt, publisherVersion: 1),
                resolver: resolver
            )
            let repo = InMemoryRepository(calendarBackend: calendar)
            repo.upsert(observation)

            let expectedAnnouncement = date(2024, 7, 20)
            let expectedAvailable = date(2024, 7, 22)
            XCTAssertEqual(record.publishedAt, expectedAnnouncement)
            XCTAssertEqual(observation.temporalEnvelope.availableAt, expectedAvailable)
            XCTAssertEqual(observation.temporalEnvelope.ingestedAt, date(2024, 8, 1))
            XCTAssertFalse(repo.holdingSnapshots(
                productID: FundProductID(rawValue: "prod_110022"),
                context: .economicKnowledge(asOf: expectedAvailable)
            ).isEmpty)
            XCTAssertTrue(repo.holdingSnapshots(
                productID: FundProductID(rawValue: "prod_110022"),
                context: .operationalKnowledge(asOf: expectedAvailable)
            ).isEmpty)
            XCTAssertFalse(repo.holdingSnapshots(
                productID: FundProductID(rawValue: "prod_110022"),
                context: .operationalKnowledge(asOf: date(2024, 8, 1))
            ).isEmpty)
        } catch {
            XCTFail("M2 场景 3 真实链路阻塞：\(error)")
        }
    }

    // MARK: - 场景 4：真实 payload 上模拟 v1 → v2，保留历史 vintage

    func testM2LiveScenario4_revisionPreservesHistoricalVintage() async throws {
        do {
            let v1Record = try await liveHoldingRecord(ingestedAt: date(2024, 7, 22))
            let v1Payload = try JSONDecoder().decode(FundHoldingPayload.self, from: v1Record.rawPayload)
            let resolver = resolver(for: v1Payload)
            let v1Vintage = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
            let v2Vintage = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 2)
            let v1 = try snapshot(from: v1Record, id: "m2_live_s4_v1", vintage: v1Vintage, resolver: resolver)

            guard let first = v1Payload.positions.first else {
                XCTFail("真实 Q2 持仓没有 position，无法执行 revision 场景")
                return
            }
            let revisedFirst = FundHoldingPayload.Position(
                providerID: first.providerID,
                providerCode: first.providerCode,
                weight: Ratio(value: first.weight.value + Decimal(string: "0.01")!),
                shares: first.shares,
                marketValue: first.marketValue,
                isDisclosed: first.isDisclosed
            )
            var revisedPositions = v1Payload.positions
            revisedPositions[0] = revisedFirst
            let v2Payload = FundHoldingPayload(
                reportPeriod: v1Payload.reportPeriod,
                positions: revisedPositions,
                disclosedWeightTotal: Ratio(
                    value: min(
                        Decimal(1),
                        revisedPositions.reduce(Decimal.zero) { $0 + $1.weight.value }
                    )
                )
            )
            let v2Record = ProviderRecord(
                providerID: v1Record.providerID,
                providerCode: v1Record.providerCode,
                effectiveAt: v1Record.effectiveAt,
                publishedAt: date(2024, 8, 15),
                ingestedAt: date(2024, 8, 16),
                kind: v1Record.kind,
                rawPayload: try JSONEncoder().encode(v2Payload),
                reliabilityClass: v1Record.reliabilityClass,
                jurisdiction: v1Record.jurisdiction
            )
            let v2 = try snapshot(from: v2Record, id: "m2_live_s4_v2", vintage: v2Vintage, resolver: resolver)

            let repo = InMemoryRepository(calendarBackend: calendar)
            repo.upsert(v1)
            repo.upsert(v2)
            let productID = FundProductID(rawValue: "prod_110022")
            let at801 = repo.holdingSnapshots(
                productID: productID,
                context: .economicKnowledge(asOf: date(2024, 8, 1))
            )
            XCTAssertEqual(at801.count, 1)
            XCTAssertEqual(at801.first?.vintage, v1Vintage)
            XCTAssertEqual(at801.first?.disclosedWeightTotal, v1.disclosedWeightTotal)

            let latest = try XCTUnwrap(repo.latestHoldingSnapshot(
                productID: productID,
                context: .economicKnowledge(asOf: date(2024, 9, 1))
            ))
            XCTAssertEqual(latest.vintage, v2Vintage)
            XCTAssertEqual(latest.disclosedWeightTotal, v2.disclosedWeightTotal)
            XCTAssertEqual(repo.holdingSnapshots(
                productID: productID,
                context: .exactSnapshot(at: date(2024, 6, 30))
            ).count, 2)
        } catch {
            XCTFail("M2 场景 4 真实链路阻塞：\(error)")
        }
    }
}

private enum M2LiveTestError: Error, Equatable, Sendable {
    case noHistoricalHoldingRecord
    case unexpectedObservationKind
}
